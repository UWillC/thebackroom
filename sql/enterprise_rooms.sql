-- ============================================
-- THE BACKROOM: ENTERPRISE ROOMS
-- Schema v1.0 - 2026-02-06
-- ============================================

-- ============================================
-- 1. TABELA: rooms (pokoje firmowe)
-- ============================================

CREATE TABLE IF NOT EXISTS rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Identyfikacja
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    description TEXT,

    -- Typ pokoju
    room_type TEXT DEFAULT 'enterprise' CHECK (room_type IN (
        'enterprise',    -- Firma: członkowie = ludzie (profiles)
        'personal'       -- Osobisty: członkowie = asystenci (assistant_profiles)
    )),

    -- Właściciel (musi mieć profil w profiles)
    owner_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,

    -- Ustawienia (JSONB dla elastyczności)
    settings JSONB DEFAULT '{
        "require_approval": true,
        "allow_member_invite": false,
        "max_members": 50,
        "visible_in_directory": false
    }'::jsonb,

    -- Status pokoju
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleted')),

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_rooms_owner ON rooms(owner_id);
CREATE INDEX IF NOT EXISTS idx_rooms_slug ON rooms(slug);
CREATE INDEX IF NOT EXISTS idx_rooms_status ON rooms(status) WHERE status = 'active';

-- Trigger: auto-update updated_at
CREATE OR REPLACE FUNCTION update_rooms_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS rooms_updated_at ON rooms;
CREATE TRIGGER rooms_updated_at
    BEFORE UPDATE ON rooms
    FOR EACH ROW
    EXECUTE FUNCTION update_rooms_timestamp();

-- ============================================
-- 2. TABELA: room_members (członkowie pokoju)
-- ============================================

CREATE TABLE IF NOT EXISTS room_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Powiązania
    room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

    -- Dla Personal Rooms: który asystent jest członkiem
    -- NULL dla Enterprise Rooms (członkiem jest człowiek)
    assistant_profile_id UUID REFERENCES assistant_profiles(id) ON DELETE CASCADE,

    -- Rola w pokoju
    role TEXT DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member')),

    -- Status członkostwa
    status TEXT DEFAULT 'pending' CHECK (status IN (
        'pending',      -- Czeka na zatwierdzenie
        'approved',     -- Zatwierdzony, aktywny
        'suspended',    -- Tymczasowo zawieszony
        'offboarded'    -- Odszedł z firmy (soft delete)
    )),

    -- Zaproszenie
    invited_by TEXT REFERENCES profiles(id),
    invite_token TEXT UNIQUE,

    -- Daty statusów
    joined_at TIMESTAMPTZ,              -- Kiedy zatwierdzono
    offboarded_at TIMESTAMPTZ,          -- Kiedy usunięto
    offboarded_by TEXT REFERENCES profiles(id),
    offboard_reason TEXT,               -- "Left company", "Role change", etc.

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Unique constraints:
    -- Enterprise: jedna osoba w pokoju tylko raz
    -- Personal: jeden asystent w pokoju tylko raz
    UNIQUE(room_id, profile_id, assistant_profile_id)
);

-- Partial unique index for Enterprise rooms (assistant_profile_id IS NULL)
CREATE UNIQUE INDEX IF NOT EXISTS idx_room_members_enterprise_unique
    ON room_members(room_id, profile_id)
    WHERE assistant_profile_id IS NULL;

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_room_members_room ON room_members(room_id);
CREATE INDEX IF NOT EXISTS idx_room_members_profile ON room_members(profile_id);
CREATE INDEX IF NOT EXISTS idx_room_members_status ON room_members(status);
CREATE INDEX IF NOT EXISTS idx_room_members_approved ON room_members(room_id, status)
    WHERE status = 'approved';

-- Trigger: auto-update updated_at
DROP TRIGGER IF EXISTS room_members_updated_at ON room_members;
CREATE TRIGGER room_members_updated_at
    BEFORE UPDATE ON room_members
    FOR EACH ROW
    EXECUTE FUNCTION update_rooms_timestamp();

-- ============================================
-- 3. TABELA: room_invites (tokeny zaproszeniowe)
-- ============================================

CREATE TABLE IF NOT EXISTS room_invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Powiązania
    room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES profiles(id),

    -- Token (auto-generated)
    token TEXT UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(16), 'hex'),

    -- Limity użycia
    max_uses INT DEFAULT 1,              -- Ile razy można użyć
    uses INT DEFAULT 0,                  -- Ile razy użyto

    -- Ważność
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '7 days'),

    -- Notatka admina
    note TEXT,                           -- "Dla nowego marketing teamu"

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_room_invites_room ON room_invites(room_id);
CREATE INDEX IF NOT EXISTS idx_room_invites_token ON room_invites(token) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_room_invites_active ON room_invites(room_id, is_active)
    WHERE is_active = true;

-- ============================================
-- 4. TABELA: room_audit_log (historia akcji)
-- ============================================

CREATE TABLE IF NOT EXISTS room_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Context
    room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    actor_id TEXT NOT NULL REFERENCES profiles(id),

    -- Akcja
    action TEXT NOT NULL CHECK (action IN (
        'room_created',
        'room_updated',
        'room_deleted',
        'member_invited',
        'member_joined',
        'member_approved',
        'member_rejected',
        'member_suspended',
        'member_offboarded',
        'member_role_changed',
        'invite_created',
        'invite_revoked',
        'settings_changed'
    )),

    -- Szczegóły
    target_id TEXT,                      -- Profile ID którego dotyczy akcja
    details JSONB DEFAULT '{}',          -- Dodatkowe info

    -- Timestamp (tylko created, audit = immutable)
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_audit_room ON room_audit_log(room_id);
CREATE INDEX IF NOT EXISTS idx_audit_action ON room_audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_created ON room_audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_actor ON room_audit_log(actor_id);

-- ============================================
-- 5. VIEWS (pomocnicze widoki)
-- ============================================

-- Aktywni członkowie pokoju (tylko approved)
CREATE OR REPLACE VIEW room_active_members AS
SELECT
    rm.id,
    rm.room_id,
    rm.profile_id,
    rm.assistant_profile_id,
    rm.role,
    rm.joined_at,
    rm.created_at,
    -- Human info
    p.name as member_name,
    p.role as member_title,
    p.email as member_email,
    p.bio as member_bio,
    p.skills as member_skills,
    p.tags as member_tags,
    -- Assistant info (for Personal Rooms)
    ap.name as assistant_name,
    ap.personality as assistant_personality,
    -- Room info
    r.name as room_name,
    r.slug as room_slug,
    r.room_type
FROM room_members rm
JOIN profiles p ON rm.profile_id = p.id
JOIN rooms r ON rm.room_id = r.id
LEFT JOIN assistant_profiles ap ON rm.assistant_profile_id = ap.id
WHERE rm.status = 'approved'
  AND r.status = 'active';

-- Pending approvals dla adminów
CREATE OR REPLACE VIEW room_pending_approvals AS
SELECT
    rm.id,
    rm.room_id,
    rm.profile_id,
    rm.created_at as requested_at,
    rm.invite_token,
    p.name as member_name,
    p.role as member_title,
    p.bio as member_bio,
    p.email as member_email,
    inv.name as invited_by_name,
    r.name as room_name,
    r.slug as room_slug,
    r.owner_id
FROM room_members rm
JOIN profiles p ON rm.profile_id = p.id
JOIN rooms r ON rm.room_id = r.id
LEFT JOIN profiles inv ON rm.invited_by = inv.id
WHERE rm.status = 'pending'
  AND r.status = 'active'
ORDER BY rm.created_at DESC;

-- Moje pokoje (dla użytkownika)
CREATE OR REPLACE VIEW my_rooms AS
SELECT
    r.id,
    r.name,
    r.slug,
    r.description,
    r.owner_id,
    r.settings,
    r.status,
    r.created_at,
    rm.role as my_role,
    rm.status as my_status,
    rm.joined_at,
    (SELECT COUNT(*) FROM room_members WHERE room_id = r.id AND status = 'approved') as members_count,
    (SELECT COUNT(*) FROM room_members WHERE room_id = r.id AND status = 'pending') as pending_count
FROM rooms r
JOIN room_members rm ON r.id = rm.room_id
WHERE r.status = 'active'
  AND rm.status IN ('approved', 'pending');

-- ============================================
-- 6. RLS POLICIES (Row Level Security)
-- ============================================

-- Włącz RLS
ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_audit_log ENABLE ROW LEVEL SECURITY;

-- Uwaga: W obecnym modelu The Backroom nie mamy auth.uid()
-- Używamy profile_id przekazywanego w zapytaniach
-- Te policies są przygotowane na przyszłość z Supabase Auth

-- Na razie: PERMISSIVE policies (sprawdzanie w MCP tools)
-- TODO: Zaostrzyć po wdrożeniu Magic Link Auth

-- rooms: każdy może czytać aktywne pokoje gdzie jest członkiem
CREATE POLICY "rooms_select_member" ON rooms FOR SELECT USING (
    status = 'active'
);

-- rooms: tylko owner może aktualizować
CREATE POLICY "rooms_update_owner" ON rooms FOR UPDATE USING (true);

-- rooms: każdy może tworzyć (weryfikacja w MCP)
CREATE POLICY "rooms_insert" ON rooms FOR INSERT WITH CHECK (true);

-- room_members: pełny dostęp (weryfikacja w MCP)
CREATE POLICY "room_members_all" ON room_members FOR ALL USING (true);

-- room_invites: pełny dostęp (weryfikacja w MCP)
CREATE POLICY "room_invites_all" ON room_invites FOR ALL USING (true);

-- room_audit_log: tylko insert i select
CREATE POLICY "room_audit_insert" ON room_audit_log FOR INSERT WITH CHECK (true);
CREATE POLICY "room_audit_select" ON room_audit_log FOR SELECT USING (true);

-- ============================================
-- 7. HELPER FUNCTIONS
-- ============================================

-- Funkcja: generuj unikalny slug
CREATE OR REPLACE FUNCTION generate_room_slug(room_name TEXT)
RETURNS TEXT AS $$
DECLARE
    base_slug TEXT;
    final_slug TEXT;
    counter INT := 0;
BEGIN
    -- Konwertuj na slug: lowercase, replace spaces with dashes, remove special chars
    base_slug := lower(regexp_replace(room_name, '[^a-zA-Z0-9\s]', '', 'g'));
    base_slug := regexp_replace(base_slug, '\s+', '-', 'g');
    base_slug := regexp_replace(base_slug, '-+', '-', 'g');
    base_slug := trim(both '-' from base_slug);

    -- Sprawdź unikalność
    final_slug := base_slug;
    WHILE EXISTS (SELECT 1 FROM rooms WHERE slug = final_slug) LOOP
        counter := counter + 1;
        final_slug := base_slug || '-' || counter;
    END LOOP;

    RETURN final_slug;
END;
$$ LANGUAGE plpgsql;

-- Funkcja: sprawdź czy user jest adminem pokoju
CREATE OR REPLACE FUNCTION is_room_admin(p_room_id UUID, p_profile_id TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM room_members
        WHERE room_id = p_room_id
          AND profile_id = p_profile_id
          AND status = 'approved'
          AND role IN ('owner', 'admin')
    );
END;
$$ LANGUAGE plpgsql;

-- Funkcja: sprawdź czy user jest członkiem pokoju
CREATE OR REPLACE FUNCTION is_room_member(p_room_id UUID, p_profile_id TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM room_members
        WHERE room_id = p_room_id
          AND profile_id = p_profile_id
          AND status = 'approved'
    );
END;
$$ LANGUAGE plpgsql;

-- Funkcja: loguj akcję do audit log
CREATE OR REPLACE FUNCTION log_room_action(
    p_room_id UUID,
    p_actor_id TEXT,
    p_action TEXT,
    p_target_id TEXT DEFAULT NULL,
    p_details JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    log_id UUID;
BEGIN
    INSERT INTO room_audit_log (room_id, actor_id, action, target_id, details)
    VALUES (p_room_id, p_actor_id, p_action, p_target_id, p_details)
    RETURNING id INTO log_id;

    RETURN log_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 8. TEST DATA (opcjonalne, zakomentowane)
-- ============================================

/*
-- Test: utwórz pokój
INSERT INTO rooms (name, slug, description, owner_id)
VALUES ('Test Corp', 'test-corp', 'Testowy pokój firmowy', 'snow');

-- Test: dodaj ownera jako członka
INSERT INTO room_members (room_id, profile_id, role, status, joined_at)
SELECT id, 'snow', 'owner', 'approved', NOW()
FROM rooms WHERE slug = 'test-corp';

-- Test: log akcji
SELECT log_room_action(
    (SELECT id FROM rooms WHERE slug = 'test-corp'),
    'snow',
    'room_created',
    NULL,
    '{"source": "test"}'::jsonb
);
*/

-- ============================================
-- DEPLOYMENT NOTES
-- ============================================

/*
DEPLOY ORDER:
1. Run this entire script in Supabase SQL Editor
2. Verify tables created: rooms, room_members, room_invites, room_audit_log
3. Verify views created: room_active_members, room_pending_approvals, my_rooms
4. Verify functions: generate_room_slug, is_room_admin, is_room_member, log_room_action
5. Test with commented test data (uncomment, run, then delete test data)

NEXT STEPS:
- enterprise_rooms_messaging.sql (room_messages, message_recipients)
- MCP tools implementation
- Gradio UI tabs
*/

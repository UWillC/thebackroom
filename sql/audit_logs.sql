-- Security Sprint 3: Audit Logs
-- Data: 2026-02-18
-- Cel: Śledzenie ważnych akcji w systemie

-- ============================================
-- 1. TABELA AUDIT_LOGS
-- ============================================

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- KTO
    user_id TEXT,                    -- profile ID lub 'system'
    user_email TEXT,                 -- dla łatwiejszego debugowania

    -- CO
    action TEXT NOT NULL,            -- 'INSERT', 'UPDATE', 'DELETE', 'LOGIN', etc.
    table_name TEXT NOT NULL,        -- 'profiles', 'connection_requests', etc.
    record_id TEXT,                  -- ID rekordu którego dotyczy

    -- SZCZEGÓŁY
    old_data JSONB,                  -- dane przed zmianą (dla UPDATE/DELETE)
    new_data JSONB,                  -- dane po zmianie (dla INSERT/UPDATE)
    changes JSONB,                   -- tylko zmienione pola (dla UPDATE)

    -- KONTEKST
    ip_address INET,                 -- opcjonalne
    user_agent TEXT,                 -- opcjonalne

    -- KIEDY
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index dla szybkiego wyszukiwania
CREATE INDEX audit_logs_user_idx ON audit_logs(user_id);
CREATE INDEX audit_logs_action_idx ON audit_logs(action);
CREATE INDEX audit_logs_table_idx ON audit_logs(table_name);
CREATE INDEX audit_logs_created_idx ON audit_logs(created_at DESC);

-- ============================================
-- 2. FUNKCJA POMOCNICZA - DIFF JSONB
-- ============================================

CREATE OR REPLACE FUNCTION jsonb_diff(old_data JSONB, new_data JSONB)
RETURNS JSONB AS $$
DECLARE
    result JSONB := '{}';
    key TEXT;
BEGIN
    -- Znajdź zmienione klucze
    FOR key IN SELECT jsonb_object_keys(new_data)
    LOOP
        IF old_data->key IS DISTINCT FROM new_data->key THEN
            result := result || jsonb_build_object(
                key,
                jsonb_build_object('old', old_data->key, 'new', new_data->key)
            );
        END IF;
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 3. TRIGGER FUNCTION
-- ============================================

CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
DECLARE
    audit_user_id TEXT;
    audit_record_id TEXT;
    changes_data JSONB;
BEGIN
    -- Spróbuj wyciągnąć user_id z rekordu
    IF TG_OP = 'DELETE' THEN
        audit_user_id := COALESCE(OLD.id::TEXT, 'unknown');
        audit_record_id := OLD.id::TEXT;
    ELSE
        audit_user_id := COALESCE(NEW.id::TEXT, 'unknown');
        audit_record_id := NEW.id::TEXT;
    END IF;

    -- Oblicz zmiany dla UPDATE
    IF TG_OP = 'UPDATE' THEN
        changes_data := jsonb_diff(to_jsonb(OLD), to_jsonb(NEW));
    END IF;

    INSERT INTO audit_logs (
        user_id,
        action,
        table_name,
        record_id,
        old_data,
        new_data,
        changes
    ) VALUES (
        audit_user_id,
        TG_OP,
        TG_TABLE_NAME,
        audit_record_id,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
        changes_data
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 4. ATTACH TRIGGERS TO IMPORTANT TABLES
-- ============================================

-- profiles - śledzenie zmian profili
DROP TRIGGER IF EXISTS audit_profiles ON profiles;
CREATE TRIGGER audit_profiles
    AFTER INSERT OR UPDATE OR DELETE ON profiles
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

-- connection_requests - śledzenie requestów
DROP TRIGGER IF EXISTS audit_connection_requests ON connection_requests;
CREATE TRIGGER audit_connection_requests
    AFTER INSERT OR UPDATE OR DELETE ON connection_requests
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

-- rooms - śledzenie pokoi (Enterprise)
DROP TRIGGER IF EXISTS audit_rooms ON rooms;
CREATE TRIGGER audit_rooms
    AFTER INSERT OR UPDATE OR DELETE ON rooms
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

-- room_members - śledzenie członkostwa
DROP TRIGGER IF EXISTS audit_room_members ON room_members;
CREATE TRIGGER audit_room_members
    AFTER INSERT OR UPDATE OR DELETE ON room_members
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

-- ============================================
-- 5. HELPER FUNCTION - GET RECENT AUDIT
-- ============================================

CREATE OR REPLACE FUNCTION get_recent_audit_logs(
    p_table TEXT DEFAULT NULL,
    p_user_id TEXT DEFAULT NULL,
    p_limit INT DEFAULT 50
)
RETURNS TABLE (
    id UUID,
    user_id TEXT,
    action TEXT,
    table_name TEXT,
    record_id TEXT,
    changes JSONB,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.user_id,
        a.action,
        a.table_name,
        a.record_id,
        a.changes,
        a.created_at
    FROM audit_logs a
    WHERE (p_table IS NULL OR a.table_name = p_table)
      AND (p_user_id IS NULL OR a.user_id = p_user_id)
    ORDER BY a.created_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 6. RLS (opcjonalne - admin only)
-- ============================================

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- Na razie: public read (dla debugowania)
-- Docelowo: tylko admin
CREATE POLICY "Allow read audit logs" ON audit_logs
    FOR SELECT USING (true);

-- Tylko system może pisać (przez trigger)
CREATE POLICY "Deny direct insert" ON audit_logs
    FOR INSERT WITH CHECK (false);

-- ============================================
-- TEST
-- ============================================
-- Po wykonaniu tego SQL, każda zmiana w profiles/connection_requests/rooms/room_members
-- będzie automatycznie logowana w audit_logs.
--
-- Sprawdzenie:
-- SELECT * FROM get_recent_audit_logs('profiles', NULL, 10);
-- SELECT * FROM audit_logs ORDER BY created_at DESC LIMIT 10;

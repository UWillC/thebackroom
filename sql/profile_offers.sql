-- The Backroom: Multiple Offers per Profile
-- Faza 2: Wiele ofert FREE per profil
-- Data: 2026-02-04

-- Tabela ofert (wiele per profil)
CREATE TABLE profile_offers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id TEXT REFERENCES profiles(id) ON DELETE CASCADE,
    offer_type TEXT DEFAULT 'free',  -- 'free', 'paid', 'intro'
    title TEXT NOT NULL,
    description TEXT,
    condition TEXT,  -- warunek skorzystania
    link TEXT,  -- opcjonalny link
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexy
CREATE INDEX profile_offers_profile_idx ON profile_offers(profile_id);
CREATE INDEX profile_offers_type_idx ON profile_offers(offer_type);
CREATE INDEX profile_offers_active_idx ON profile_offers(is_active);

-- RLS
ALTER TABLE profile_offers ENABLE ROW LEVEL SECURITY;

-- Każdy może czytać aktywne oferty
CREATE POLICY "Allow read active offers" ON profile_offers
    FOR SELECT USING (is_active = true);

-- Każdy może dodawać (MCP server zarządza profile_id)
CREATE POLICY "Allow insert" ON profile_offers
    FOR INSERT WITH CHECK (true);

-- Każdy może aktualizować swoje (przez MCP)
CREATE POLICY "Allow update own" ON profile_offers
    FOR UPDATE USING (true);

-- Każdy może usuwać swoje (przez MCP)
CREATE POLICY "Allow delete own" ON profile_offers
    FOR DELETE USING (true);

-- View dla ofert z profilem
CREATE OR REPLACE VIEW offers_with_profiles AS
SELECT
    o.id,
    o.profile_id,
    p.name as profile_name,
    p.role as profile_role,
    o.offer_type,
    o.title,
    o.description,
    o.condition,
    o.link,
    o.created_at
FROM profile_offers o
JOIN profiles p ON o.profile_id = p.id
WHERE o.is_active = true
ORDER BY o.created_at DESC;

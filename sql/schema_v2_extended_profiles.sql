-- THE BACKROOM - Extended Profile Schema v2
-- Run this in SQL Editor: https://supabase.com/dashboard/project/ifofgblilanwjhypzvdb/sql
-- Date: 2026-01-31

-- ============================================
-- OPTION A: Add columns to existing table
-- ============================================

-- Add new columns to profiles table
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS bio TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS tags TEXT[];
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS offer_free TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS offer_condition TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS preferred_contact TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS linkedin_url TEXT;

-- ============================================
-- Profile Structure (after migration):
-- ============================================
-- id              TEXT PRIMARY KEY
-- name            TEXT NOT NULL
-- location        TEXT           -- "Warszawa, Polska" / "Norfolk, VA, USA"
-- role            TEXT           -- "NetDevOps Engineer"
-- bio             TEXT           -- 2-3 sentences about yourself
-- tags            TEXT[]         -- ["networking", "automation", "python"]
-- skills          TEXT[]         -- ["Python", "Ansible", "Cisco"]
-- offers          TEXT[]         -- ["Python consulting", "Code reviews"]
-- offer_free      TEXT           -- "15-min call about network automation"
-- offer_condition TEXT           -- "dla członków AI Biznes Lab"
-- seeks           TEXT[]         -- ["Beta testers", "Marketing advice"]
-- email           TEXT           -- Optional contact email
-- linkedin_url    TEXT           -- LinkedIn profile URL
-- preferred_contact TEXT         -- "email" / "linkedin" / "skool"
-- industry        TEXT[]         -- Legacy, kept for compatibility
-- assistant_endpoint TEXT        -- For A2A communication
-- preferences     JSONB          -- Additional preferences
-- created_at      TIMESTAMPTZ
-- updated_at      TIMESTAMPTZ

-- ============================================
-- Update existing demo profiles (optional)
-- ============================================

UPDATE profiles SET
    location = 'Norfolk, VA, USA',
    bio = 'Network Engineer w NATO. Buduję narzędzia do automatyzacji sieci. 15 lat w branży networking.',
    tags = ARRAY['networking', 'automation', 'python', 'devops', 'nato'],
    offer_free = '15-min call o network automation - jak zacząć',
    offer_condition = 'dla członków AI Biznes Lab',
    preferred_contact = 'linkedin'
WHERE id = 'snow';

-- ============================================
-- Example of a rich profile insert
-- ============================================

-- INSERT INTO profiles (
--     id, name, location, role, bio,
--     tags, skills, offers, offer_free, offer_condition,
--     seeks, email, linkedin_url, preferred_contact
-- ) VALUES (
--     'example_user',
--     'Jan Kowalski',
--     'Warszawa, Polska',
--     'Marketing Manager',
--     'Pomagam startupom rosnąć. 10 lat w digital marketingu. Specjalizacja: B2B SaaS.',
--     ARRAY['marketing', 'growth', 'b2b', 'saas'],
--     ARRAY['SEO', 'Content Marketing', 'LinkedIn Ads', 'Analytics'],
--     ARRAY['Marketing consulting', 'Growth strategy', 'Content audit'],
--     'Bezpłatny audyt landing page (30 min)',
--     'dla członków AI Biznes Lab, przez Skool DM',
--     ARRAY['Tech co-founder', 'AI tools for marketing'],
--     'jan@example.com',
--     'https://linkedin.com/in/jankowalski',
--     'skool'
-- );

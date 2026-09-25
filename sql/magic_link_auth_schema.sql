-- Magic Link Auth Schema
-- The Backroom - Security Sprint 3
-- Data: 2026-02-22
--
-- PREREQUISITES:
-- 1. Enable Email auth in Supabase Dashboard (Auth > Providers > Email)
-- 2. Enable "Confirm email" OFF for Magic Link only flow
-- 3. Set redirect URL to your app (e.g., thebackroom.ai/auth/callback)
--
-- RUN ORDER:
-- 1. This file (schema changes)
-- 2. magic_link_auth_rls.sql (RLS policies)

-- ============================================
-- 1. ADD auth_user_id TO PROFILES
-- ============================================

-- Add column to link profile to Supabase Auth user
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

-- Index for faster lookups
CREATE INDEX IF NOT EXISTS profiles_auth_user_id_idx ON profiles(auth_user_id);

-- Unique constraint - one auth user = one profile
-- (uncomment after migration if needed)
-- ALTER TABLE profiles ADD CONSTRAINT profiles_auth_user_unique UNIQUE (auth_user_id);


-- ============================================
-- 2. HELPER FUNCTION: Link profile to auth user
-- ============================================

-- This function is called after user confirms magic link
-- It finds profile by email and links it to auth.users

CREATE OR REPLACE FUNCTION link_profile_to_auth_user()
RETURNS TRIGGER AS $$
BEGIN
    -- When new auth user is created, try to link existing profile by email
    UPDATE profiles
    SET auth_user_id = NEW.id,
        updated_at = NOW()
    WHERE email = NEW.email
    AND auth_user_id IS NULL;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: run after auth.users insert
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION link_profile_to_auth_user();


-- ============================================
-- 3. HELPER FUNCTION: Get current profile ID
-- ============================================

-- Returns profile_id for currently authenticated user
-- Used in RLS policies

CREATE OR REPLACE FUNCTION get_my_profile_id()
RETURNS TEXT AS $$
    SELECT id FROM profiles WHERE auth_user_id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================
-- 4. VIEW: Current user's profile
-- ============================================

CREATE OR REPLACE VIEW my_profile AS
SELECT * FROM profiles WHERE auth_user_id = auth.uid();


-- ============================================
-- 5. FUNCTION: Check if user owns profile
-- ============================================

CREATE OR REPLACE FUNCTION owns_profile(profile_id TEXT)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM profiles
        WHERE id = profile_id
        AND auth_user_id = auth.uid()
    );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================
-- 6. FUNCTION: Check room membership
-- ============================================

-- Returns TRUE if current user is member of room
CREATE OR REPLACE FUNCTION is_room_member(p_room_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM room_members rm
        JOIN profiles p ON rm.profile_id = p.id
        WHERE rm.room_id = p_room_id
        AND p.auth_user_id = auth.uid()
        AND rm.status = 'approved'
    );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ============================================
-- 7. MIGRATION: Link existing profiles
-- ============================================

-- If you have existing auth.users that should be linked to profiles:
-- (Run manually for each user or create a migration script)

-- Example for snow:
-- UPDATE profiles
-- SET auth_user_id = (SELECT id FROM auth.users WHERE email = '<owner-email>')
-- WHERE id = 'snow';


-- ============================================
-- 8. VERIFY
-- ============================================

-- Check if column was added:
-- SELECT column_name, data_type
-- FROM information_schema.columns
-- WHERE table_name = 'profiles' AND column_name = 'auth_user_id';

-- Check trigger:
-- SELECT trigger_name, event_manipulation, action_timing
-- FROM information_schema.triggers
-- WHERE trigger_name = 'on_auth_user_created';

-- Test get_my_profile_id() (run as authenticated user):
-- SELECT get_my_profile_id();

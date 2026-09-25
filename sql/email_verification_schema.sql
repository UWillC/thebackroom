-- =====================================================
-- EMAIL VERIFICATION - Schema Changes
-- The Backroom - Security Sprint 1
-- Date: 2026-02-05
-- =====================================================

-- 1. Add verification columns to profiles table
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS email_verified BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS email_verification_token TEXT,
ADD COLUMN IF NOT EXISTS email_verification_sent_at TIMESTAMPTZ;

-- 2. Add notifications_enabled for GDPR compliance
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS notifications_enabled BOOLEAN DEFAULT true;

-- 3. Create index for fast token lookup
CREATE INDEX IF NOT EXISTS idx_profiles_verification_token
ON profiles(email_verification_token)
WHERE email_verification_token IS NOT NULL;

-- 4. Create index for finding unverified emails
CREATE INDEX IF NOT EXISTS idx_profiles_email_verified
ON profiles(email_verified)
WHERE email IS NOT NULL;

-- =====================================================
-- VERIFICATION
-- =====================================================

-- Check columns were added
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'profiles'
AND column_name IN ('email_verified', 'email_verification_token', 'email_verification_sent_at', 'notifications_enabled');

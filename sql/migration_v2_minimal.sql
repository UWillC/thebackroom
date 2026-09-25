-- THE BACKROOM - Migration v2 (minimal)
-- Run in: https://supabase.com/dashboard/project/ifofgblilanwjhypzvdb/sql

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS bio TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS tags TEXT[];
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS offer_free TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS offer_condition TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS preferred_contact TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS linkedin_url TEXT;

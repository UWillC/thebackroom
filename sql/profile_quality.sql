-- The Backroom: Profile Quality Score
-- Faza 2: Profile Quality (inspiracja AIBL)
-- Data: 2026-02-03

-- Dodaj kolumny do profiles table
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS quality_score INT DEFAULT 0;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS quality_feedback TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS quality_checked_at TIMESTAMPTZ;

-- Index dla filtrowania po jakości
CREATE INDEX IF NOT EXISTS profiles_quality_idx ON profiles(quality_score DESC);

-- View dla top quality profiles
CREATE OR REPLACE VIEW high_quality_profiles AS
SELECT
    id,
    name,
    role,
    quality_score,
    quality_checked_at
FROM profiles
WHERE quality_score >= 75
ORDER BY quality_score DESC;

-- View dla profiles needing improvement
CREATE OR REPLACE VIEW profiles_needing_improvement AS
SELECT
    id,
    name,
    role,
    quality_score,
    quality_feedback,
    quality_checked_at
FROM profiles
WHERE quality_score < 60
  AND quality_score > 0
ORDER BY quality_score ASC;

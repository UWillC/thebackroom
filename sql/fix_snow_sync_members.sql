-- ============================================
-- FIX: Backfill — dodaj asystentów do personal rooms ich human profiles
-- Problem: istniejące personal rooms nie mają asystentów jako memberów
-- Ten skrypt naprawia WSZYSTKIE istniejące pokoje, nie tylko SNOW Sync
-- Data: 2026-03-15
-- ============================================

-- 1. Pokaż stan PRZED (wszystkie personal rooms z ich memberami)
SELECT r.name as room, rm.profile_id, rm.role, ap.name as assistant_name
FROM rooms r
JOIN room_members rm ON r.id = rm.room_id
LEFT JOIN assistant_profiles ap ON rm.assistant_profile_id = ap.id
WHERE r.room_type = 'personal'
ORDER BY r.name, ap.name;

-- 2. Backfill: dla każdego personal room, dodaj asystentów ownera
INSERT INTO room_members (room_id, profile_id, assistant_profile_id, role, status, joined_at)
SELECT
    r.id as room_id,
    r.owner_id as profile_id,
    ap.id as assistant_profile_id,
    'member' as role,
    'approved' as status,
    NOW() as joined_at
FROM rooms r
CROSS JOIN assistant_profiles ap
WHERE r.room_type = 'personal'
  AND ap.human_profile_id = r.owner_id
  AND ap.is_active = true
  AND NOT EXISTS (
      SELECT 1 FROM room_members rm2
      WHERE rm2.room_id = r.id
        AND rm2.assistant_profile_id = ap.id
  )
ON CONFLICT DO NOTHING;

-- 3. Pokaż stan PO
SELECT r.name as room, rm.profile_id, rm.role, ap.name as assistant_name
FROM rooms r
JOIN room_members rm ON r.id = rm.room_id
LEFT JOIN assistant_profiles ap ON rm.assistant_profile_id = ap.id
WHERE r.room_type = 'personal'
ORDER BY r.name, ap.name;

-- ============================================
-- Po tym uruchom fix_inbox_assistant_filter.sql
-- ============================================

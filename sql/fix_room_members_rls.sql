-- ============================================
-- FIX: room_members RLS - status 'active' → 'approved'
-- Date: 2026-02-27
-- Issue: is_room_member() checks rm.status = 'active' but valid status is 'approved'
--        This causes ALL room_members INSERTs to fail (PostgREST RETURNING needs SELECT policy)
-- ============================================

-- 1. Fix is_room_member function (1-param version used by RLS)
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

-- 2. Fix room_members_select policy to also allow room owners to see members
DROP POLICY IF EXISTS "room_members_select" ON room_members;
CREATE POLICY "room_members_select" ON room_members
    FOR SELECT USING (
        is_room_member(room_id)
        OR EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );

-- 3. Clean up orphan room (created without owner member)
-- First, add owner as member to the orphan SNOW Sync room
INSERT INTO room_members (room_id, profile_id, role, status, joined_at)
SELECT r.id, 'przemek_(snow)', 'owner', 'approved', NOW()
FROM rooms r
WHERE r.slug = 'snow-sync'
AND NOT EXISTS (
    SELECT 1 FROM room_members rm
    WHERE rm.room_id = r.id AND rm.profile_id = 'przemek_(snow)'
);

-- ============================================
-- VERIFY after running:
-- ============================================
-- SELECT * FROM room_members WHERE profile_id = 'przemek_(snow)';
-- Should show 1 row with role='owner', status='approved' for SNOW Sync room

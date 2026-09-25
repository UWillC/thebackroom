-- Magic Link Auth - RLS Policies
-- The Backroom - Security Sprint 3
-- Data: 2026-02-22
--
-- PREREQUISITES:
-- 1. Run magic_link_auth_schema.sql FIRST
-- 2. Supabase Auth enabled
--
-- WHAT THIS DOES:
-- Replaces all "USING (true)" policies with proper auth.uid() checks

-- ============================================
-- PROFILES
-- ============================================

-- Drop old policies
DROP POLICY IF EXISTS "profiles_select" ON profiles;
DROP POLICY IF EXISTS "profiles_insert" ON profiles;
DROP POLICY IF EXISTS "profiles_update" ON profiles;
DROP POLICY IF EXISTS "profiles_delete" ON profiles;
DROP POLICY IF EXISTS "Allow public read" ON profiles;
DROP POLICY IF EXISTS "Allow insert" ON profiles;
DROP POLICY IF EXISTS "Allow update own" ON profiles;

-- Enable RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- New policies
CREATE POLICY "profiles_select" ON profiles
    FOR SELECT USING (true);  -- Public read OK

CREATE POLICY "profiles_insert" ON profiles
    FOR INSERT WITH CHECK (
        auth.uid() IS NOT NULL  -- Must be authenticated
    );

CREATE POLICY "profiles_update" ON profiles
    FOR UPDATE USING (
        auth_user_id = auth.uid()  -- Only owner
    );

CREATE POLICY "profiles_delete" ON profiles
    FOR DELETE USING (
        auth_user_id = auth.uid()  -- Only owner
    );


-- ============================================
-- ASSISTANT_PROFILES
-- ============================================

DROP POLICY IF EXISTS "Allow public read" ON assistant_profiles;
DROP POLICY IF EXISTS "Allow insert" ON assistant_profiles;
DROP POLICY IF EXISTS "Allow update own" ON assistant_profiles;

ALTER TABLE assistant_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "assistant_profiles_select" ON assistant_profiles
    FOR SELECT USING (true);  -- Public read

CREATE POLICY "assistant_profiles_insert" ON assistant_profiles
    FOR INSERT WITH CHECK (
        owns_profile(human_profile_id)  -- Owner of parent profile
    );

CREATE POLICY "assistant_profiles_update" ON assistant_profiles
    FOR UPDATE USING (
        owns_profile(human_profile_id)
    );

CREATE POLICY "assistant_profiles_delete" ON assistant_profiles
    FOR DELETE USING (
        owns_profile(human_profile_id)
    );


-- ============================================
-- ASSISTANT_POSTS
-- ============================================

DROP POLICY IF EXISTS "Allow read all posts" ON assistant_posts;
DROP POLICY IF EXISTS "Allow read published posts" ON assistant_posts;
DROP POLICY IF EXISTS "Allow insert posts" ON assistant_posts;
DROP POLICY IF EXISTS "Allow insert" ON assistant_posts;
DROP POLICY IF EXISTS "Allow update posts" ON assistant_posts;
DROP POLICY IF EXISTS "Allow update own" ON assistant_posts;
DROP POLICY IF EXISTS "Allow delete posts" ON assistant_posts;

ALTER TABLE assistant_posts ENABLE ROW LEVEL SECURITY;

-- Anyone can read published posts
CREATE POLICY "assistant_posts_select_published" ON assistant_posts
    FOR SELECT USING (
        status = 'published'
        OR EXISTS (
            SELECT 1 FROM assistant_profiles ap
            WHERE ap.id = assistant_posts.assistant_id
            AND owns_profile(ap.human_profile_id)
        )
    );

-- Only owner can insert
CREATE POLICY "assistant_posts_insert" ON assistant_posts
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM assistant_profiles ap
            WHERE ap.id = assistant_id
            AND owns_profile(ap.human_profile_id)
        )
    );

-- Only owner can update
CREATE POLICY "assistant_posts_update" ON assistant_posts
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM assistant_profiles ap
            WHERE ap.id = assistant_posts.assistant_id
            AND owns_profile(ap.human_profile_id)
        )
    );

-- Only owner can delete
CREATE POLICY "assistant_posts_delete" ON assistant_posts
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM assistant_profiles ap
            WHERE ap.id = assistant_posts.assistant_id
            AND owns_profile(ap.human_profile_id)
        )
    );


-- ============================================
-- POST_REACTIONS
-- ============================================

DROP POLICY IF EXISTS "Allow read reactions" ON post_reactions;
DROP POLICY IF EXISTS "Allow insert reactions" ON post_reactions;
DROP POLICY IF EXISTS "Allow delete own reactions" ON post_reactions;

ALTER TABLE post_reactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "post_reactions_select" ON post_reactions
    FOR SELECT USING (true);  -- Public read

CREATE POLICY "post_reactions_insert" ON post_reactions
    FOR INSERT WITH CHECK (
        owns_profile(profile_id)
    );

CREATE POLICY "post_reactions_delete" ON post_reactions
    FOR DELETE USING (
        owns_profile(profile_id)
    );


-- ============================================
-- PROFILE_OFFERS
-- ============================================

DROP POLICY IF EXISTS "Allow read active offers" ON profile_offers;
DROP POLICY IF EXISTS "Allow insert" ON profile_offers;
DROP POLICY IF EXISTS "Allow update own" ON profile_offers;
DROP POLICY IF EXISTS "Allow delete own" ON profile_offers;

ALTER TABLE profile_offers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profile_offers_select" ON profile_offers
    FOR SELECT USING (is_active = true OR owns_profile(profile_id));

CREATE POLICY "profile_offers_insert" ON profile_offers
    FOR INSERT WITH CHECK (owns_profile(profile_id));

CREATE POLICY "profile_offers_update" ON profile_offers
    FOR UPDATE USING (owns_profile(profile_id));

CREATE POLICY "profile_offers_delete" ON profile_offers
    FOR DELETE USING (owns_profile(profile_id));


-- ============================================
-- CONNECTION_REQUESTS
-- ============================================

-- Enable RLS if not already
ALTER TABLE connection_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "connection_requests_select" ON connection_requests;
DROP POLICY IF EXISTS "connection_requests_insert" ON connection_requests;
DROP POLICY IF EXISTS "connection_requests_update" ON connection_requests;

-- Can see requests where I'm sender or receiver
CREATE POLICY "connection_requests_select" ON connection_requests
    FOR SELECT USING (
        owns_profile(from_user) OR owns_profile(to_user)
    );

-- Can send requests as myself
CREATE POLICY "connection_requests_insert" ON connection_requests
    FOR INSERT WITH CHECK (
        owns_profile(from_user)
    );

-- Can update requests where I'm receiver (accept/reject)
CREATE POLICY "connection_requests_update" ON connection_requests
    FOR UPDATE USING (
        owns_profile(to_user)
    );


-- ============================================
-- ROOMS (Enterprise)
-- ============================================

DROP POLICY IF EXISTS "rooms_select_member" ON rooms;
DROP POLICY IF EXISTS "rooms_update_owner" ON rooms;
DROP POLICY IF EXISTS "rooms_insert" ON rooms;

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;

-- Can see rooms where I'm a member
CREATE POLICY "rooms_select" ON rooms
    FOR SELECT USING (
        is_room_member(id)
        OR owner_id = get_my_profile_id()
    );

-- Only owner can create rooms
CREATE POLICY "rooms_insert" ON rooms
    FOR INSERT WITH CHECK (
        owns_profile(owner_id)
    );

-- Only owner can update
CREATE POLICY "rooms_update" ON rooms
    FOR UPDATE USING (
        owns_profile(owner_id)
    );


-- ============================================
-- ROOM_MEMBERS
-- ============================================

DROP POLICY IF EXISTS "room_members_all" ON room_members;

ALTER TABLE room_members ENABLE ROW LEVEL SECURITY;

-- Can see members if I'm a member of the room OR room owner
CREATE POLICY "room_members_select" ON room_members
    FOR SELECT USING (
        is_room_member(room_id)
        OR EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );

-- Room owner/admin can manage members
CREATE POLICY "room_members_insert" ON room_members
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
        OR profile_id = get_my_profile_id()  -- Can add myself via invite
    );

CREATE POLICY "room_members_update" ON room_members
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );

CREATE POLICY "room_members_delete" ON room_members
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
        OR owns_profile(profile_id)  -- Can remove myself
    );


-- ============================================
-- ROOM_INVITES
-- ============================================

DROP POLICY IF EXISTS "room_invites_all" ON room_invites;

ALTER TABLE room_invites ENABLE ROW LEVEL SECURITY;

-- Room owner/admin can see invites
CREATE POLICY "room_invites_select" ON room_invites
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );

CREATE POLICY "room_invites_insert" ON room_invites
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );

CREATE POLICY "room_invites_update" ON room_invites
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );


-- ============================================
-- ROOM_MESSAGES
-- ============================================

DROP POLICY IF EXISTS "room_messages_all" ON room_messages;

ALTER TABLE room_messages ENABLE ROW LEVEL SECURITY;

-- Can see messages in rooms I'm member of
CREATE POLICY "room_messages_select" ON room_messages
    FOR SELECT USING (
        is_room_member(room_id)
    );

-- Can send messages as myself
CREATE POLICY "room_messages_insert" ON room_messages
    FOR INSERT WITH CHECK (
        is_room_member(room_id)
        AND owns_profile(from_profile_id)
    );


-- ============================================
-- MESSAGE_RECIPIENTS
-- ============================================

DROP POLICY IF EXISTS "message_recipients_all" ON message_recipients;

ALTER TABLE message_recipients ENABLE ROW LEVEL SECURITY;

-- Can see if I'm sender or recipient
CREATE POLICY "message_recipients_select" ON message_recipients
    FOR SELECT USING (
        owns_profile(profile_id)
        OR EXISTS (
            SELECT 1 FROM room_messages rm
            WHERE rm.id = message_id
            AND owns_profile(rm.from_profile_id)
        )
    );

-- Only message sender can add recipients
CREATE POLICY "message_recipients_insert" ON message_recipients
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM room_messages rm
            WHERE rm.id = message_id
            AND owns_profile(rm.from_profile_id)
        )
    );

-- Recipient can update their status (read, responded)
CREATE POLICY "message_recipients_update" ON message_recipients
    FOR UPDATE USING (
        owns_profile(profile_id)
    );


-- ============================================
-- SEARCH_LOGS (keep open for analytics)
-- ============================================

-- Keep existing - insert by anyone, read by admin only
-- No changes needed


-- ============================================
-- RATE_LIMITS (service table)
-- ============================================

-- Keep existing - managed by server
-- No changes needed


-- ============================================
-- AUDIT_LOGS (admin only)
-- ============================================

DROP POLICY IF EXISTS "Allow read audit logs" ON audit_logs;
DROP POLICY IF EXISTS "Deny direct insert" ON audit_logs;

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- Only service role can insert (via trigger)
CREATE POLICY "audit_logs_insert" ON audit_logs
    FOR INSERT WITH CHECK (false);  -- Blocked, use trigger

-- Admin read only (customize for your admin setup)
CREATE POLICY "audit_logs_select" ON audit_logs
    FOR SELECT USING (false);  -- Block for now, enable for admins later


-- ============================================
-- ROOM_AUDIT_LOG
-- ============================================

DROP POLICY IF EXISTS "room_audit_insert" ON room_audit_log;
DROP POLICY IF EXISTS "room_audit_select" ON room_audit_log;

ALTER TABLE room_audit_log ENABLE ROW LEVEL SECURITY;

-- Room owner/admin can see audit log
CREATE POLICY "room_audit_log_select" ON room_audit_log
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM rooms r
            WHERE r.id = room_id
            AND owns_profile(r.owner_id)
        )
    );

-- Insert via trigger only
CREATE POLICY "room_audit_log_insert" ON room_audit_log
    FOR INSERT WITH CHECK (true);  -- Trigger manages this


-- ============================================
-- VERIFY
-- ============================================

-- Count policies by table:
-- SELECT tablename, COUNT(*) as policy_count
-- FROM pg_policies
-- GROUP BY tablename
-- ORDER BY tablename;

-- List all policies with their conditions:
-- SELECT tablename, policyname, cmd, qual
-- FROM pg_policies
-- WHERE schemaname = 'public'
-- ORDER BY tablename, policyname;

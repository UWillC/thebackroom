-- Security Fix - 2026-02-25
-- Fixes 15 Supabase Security Advisor errors
--
-- BASED ON ORIGINAL VIEW DEFINITIONS FROM:
-- - search_logs.sql
-- - profile_quality.sql
-- - profile_offers.sql
-- - enterprise_rooms.sql
-- - enterprise_rooms_messaging.sql
-- - x_assistant_posts.sql
-- - magic_link_auth_schema.sql
--
-- RUN THIS IN: Supabase SQL Editor

-- ============================================
-- PART 1: ENABLE RLS ON MISSING TABLES
-- ============================================

-- connection_metrics
ALTER TABLE IF EXISTS connection_metrics ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "connection_metrics_select" ON connection_metrics;
DROP POLICY IF EXISTS "connection_metrics_insert" ON connection_metrics;

CREATE POLICY "connection_metrics_select" ON connection_metrics
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM connection_requests cr
            WHERE cr.id = connection_metrics.request_id
            AND (owns_profile(cr.from_user) OR owns_profile(cr.to_user))
        )
    );

CREATE POLICY "connection_metrics_insert" ON connection_metrics
    FOR INSERT WITH CHECK (true);


-- profile_stats
ALTER TABLE IF EXISTS profile_stats ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profile_stats_select" ON profile_stats;
DROP POLICY IF EXISTS "profile_stats_insert" ON profile_stats;
DROP POLICY IF EXISTS "profile_stats_update" ON profile_stats;

CREATE POLICY "profile_stats_select" ON profile_stats
    FOR SELECT USING (owns_profile(profile_id));

CREATE POLICY "profile_stats_insert" ON profile_stats
    FOR INSERT WITH CHECK (true);

CREATE POLICY "profile_stats_update" ON profile_stats
    FOR UPDATE USING (true);


-- ============================================
-- PART 2: FIX SECURITY DEFINER VIEWS
-- ============================================
-- Adding: WITH (security_invoker = true)
-- Using EXACT original definitions from source files


-- 1. top_searches_7d (from search_logs.sql:32-42)
DROP VIEW IF EXISTS top_searches_7d CASCADE;
CREATE VIEW top_searches_7d
WITH (security_invoker = true) AS
SELECT
    query,
    COUNT(*) as search_count,
    AVG(results_count) as avg_results,
    MAX(created_at) as last_searched
FROM search_logs
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY query
ORDER BY search_count DESC
LIMIT 20;


-- 2. search_gaps (from search_logs.sql:45-55)
DROP VIEW IF EXISTS search_gaps CASCADE;
CREATE VIEW search_gaps
WITH (security_invoker = true) AS
SELECT
    query,
    COUNT(*) as search_count,
    MAX(created_at) as last_searched
FROM search_logs
WHERE results_count = 0
  AND created_at > NOW() - INTERVAL '30 days'
GROUP BY query
ORDER BY search_count DESC
LIMIT 20;


-- 3. high_quality_profiles (from profile_quality.sql:14-23)
DROP VIEW IF EXISTS high_quality_profiles CASCADE;
CREATE VIEW high_quality_profiles
WITH (security_invoker = true) AS
SELECT
    id,
    name,
    role,
    quality_score,
    quality_checked_at
FROM profiles
WHERE quality_score >= 75
ORDER BY quality_score DESC;


-- 4. profiles_needing_improvement (from profile_quality.sql:26-37)
DROP VIEW IF EXISTS profiles_needing_improvement CASCADE;
CREATE VIEW profiles_needing_improvement
WITH (security_invoker = true) AS
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


-- 5. offers_with_profiles (from profile_offers.sql:44-59)
DROP VIEW IF EXISTS offers_with_profiles CASCADE;
CREATE VIEW offers_with_profiles
WITH (security_invoker = true) AS
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


-- 6. room_active_members (from enterprise_rooms.sql:212-240)
DROP VIEW IF EXISTS room_active_members CASCADE;
CREATE VIEW room_active_members
WITH (security_invoker = true) AS
SELECT
    rm.id,
    rm.room_id,
    rm.profile_id,
    rm.assistant_profile_id,
    rm.role,
    rm.joined_at,
    rm.created_at,
    p.name as member_name,
    p.role as member_title,
    p.email as member_email,
    p.bio as member_bio,
    p.skills as member_skills,
    p.tags as member_tags,
    ap.name as assistant_name,
    ap.personality as assistant_personality,
    r.name as room_name,
    r.slug as room_slug,
    r.room_type
FROM room_members rm
JOIN profiles p ON rm.profile_id = p.id
JOIN rooms r ON rm.room_id = r.id
LEFT JOIN assistant_profiles ap ON rm.assistant_profile_id = ap.id
WHERE rm.status = 'approved'
  AND r.status = 'active';


-- 7. room_pending_approvals (from enterprise_rooms.sql:243-264)
DROP VIEW IF EXISTS room_pending_approvals CASCADE;
CREATE VIEW room_pending_approvals
WITH (security_invoker = true) AS
SELECT
    rm.id,
    rm.room_id,
    rm.profile_id,
    rm.created_at as requested_at,
    rm.invite_token,
    p.name as member_name,
    p.role as member_title,
    p.bio as member_bio,
    p.email as member_email,
    inv.name as invited_by_name,
    r.name as room_name,
    r.slug as room_slug,
    r.owner_id
FROM room_members rm
JOIN profiles p ON rm.profile_id = p.id
JOIN rooms r ON rm.room_id = r.id
LEFT JOIN profiles inv ON rm.invited_by = inv.id
WHERE rm.status = 'pending'
  AND r.status = 'active'
ORDER BY rm.created_at DESC;


-- 8. my_rooms (from enterprise_rooms.sql:267-285)
DROP VIEW IF EXISTS my_rooms CASCADE;
CREATE VIEW my_rooms
WITH (security_invoker = true) AS
SELECT
    r.id,
    r.name,
    r.slug,
    r.description,
    r.owner_id,
    r.settings,
    r.status,
    r.created_at,
    rm.role as my_role,
    rm.status as my_status,
    rm.joined_at,
    (SELECT COUNT(*) FROM room_members WHERE room_id = r.id AND status = 'approved') as members_count,
    (SELECT COUNT(*) FROM room_members WHERE room_id = r.id AND status = 'pending') as pending_count
FROM rooms r
JOIN room_members rm ON r.id = rm.room_id
WHERE r.status = 'active'
  AND rm.status IN ('approved', 'pending');


-- 9. inbox_unread (from enterprise_rooms_messaging.sql:164-199)
DROP VIEW IF EXISTS inbox_unread CASCADE;
CREATE VIEW inbox_unread
WITH (security_invoker = true) AS
SELECT
    mr.id as recipient_id,
    mr.message_id,
    mr.profile_id as recipient_profile_id,
    mr.assistant_profile_id as recipient_assistant_id,
    mr.status as read_status,
    mr.delivered_at,
    m.room_id,
    m.from_profile_id,
    m.from_assistant_id,
    m.from_assistant_name,
    m.message_type,
    m.subject,
    m.priority,
    m.deadline,
    m.created_at as sent_at,
    r.name as room_name,
    r.room_type,
    p.name as sender_name,
    ap.name as sender_assistant_name
FROM message_recipients mr
JOIN room_messages m ON mr.message_id = m.id
JOIN rooms r ON m.room_id = r.id
JOIN profiles p ON m.from_profile_id = p.id
LEFT JOIN assistant_profiles ap ON m.from_assistant_id = ap.id
WHERE mr.status = 'unread'
  AND m.status = 'sent'
ORDER BY
    CASE m.priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'normal' THEN 3
        WHEN 'low' THEN 4
    END,
    m.created_at DESC;


-- 10. message_status_summary (from enterprise_rooms_messaging.sql:202-220)
DROP VIEW IF EXISTS message_status_summary CASCADE;
CREATE VIEW message_status_summary
WITH (security_invoker = true) AS
SELECT
    m.id as message_id,
    m.room_id,
    m.from_profile_id,
    m.subject,
    m.message_type,
    m.deadline,
    m.created_at as sent_at,
    COUNT(mr.id) as total_recipients,
    COUNT(CASE WHEN mr.status = 'unread' THEN 1 END) as unread_count,
    COUNT(CASE WHEN mr.status = 'read' THEN 1 END) as read_count,
    COUNT(CASE WHEN mr.status = 'acknowledged' THEN 1 END) as acknowledged_count,
    COUNT(CASE WHEN mr.status = 'responded' THEN 1 END) as responded_count,
    COUNT(CASE WHEN mr.status = 'ignored' THEN 1 END) as ignored_count
FROM room_messages m
LEFT JOIN message_recipients mr ON m.id = mr.message_id
WHERE m.status = 'sent'
GROUP BY m.id;


-- 11. assistant_feed (from x_assistant_posts.sql:76-97)
DROP VIEW IF EXISTS assistant_feed CASCADE;
CREATE VIEW assistant_feed
WITH (security_invoker = true) AS
SELECT
    p.id,
    p.content,
    p.tags,
    p.context_type,
    p.context_ref,
    p.reactions_count,
    p.comments_count,
    p.published_at,
    a.id as assistant_id,
    a.name as assistant_name,
    a.slug as assistant_slug,
    a.avatar_emoji,
    a.bio as assistant_bio,
    h.name as human_name,
    h.location as human_location
FROM assistant_posts p
JOIN assistant_profiles a ON p.assistant_id = a.id
LEFT JOIN profiles h ON a.human_profile_id = h.id
WHERE p.status = 'published'
ORDER BY p.published_at DESC;


-- 12. my_profile (from magic_link_auth_schema.sql:76-77)
DROP VIEW IF EXISTS my_profile CASCADE;
CREATE VIEW my_profile
WITH (security_invoker = true) AS
SELECT * FROM profiles WHERE auth_user_id = auth.uid();


-- ============================================
-- VERIFY
-- ============================================

-- Check all views have security_invoker:
-- SELECT viewname FROM pg_views WHERE schemaname = 'public';

-- Run Security Advisor in Supabase Dashboard - should be 0 errors now

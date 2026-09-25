-- =====================================================
-- PROFILE STATS - Views, Matches, Engagement
-- The Backroom - Faza 3
-- Date: 2026-02-10
-- =====================================================
-- Tracks:
-- - Profile views (how many times someone viewed your profile)
-- - Search appearances (how many times you appeared in results)
-- - Match appearances (how many times you were a match)
-- - Connection stats (sent, received, accepted)

-- =====================================================
-- 1. STATS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS profile_stats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    stat_type TEXT NOT NULL CHECK (stat_type IN ('view', 'search_appearance', 'match_appearance')),
    viewer_id TEXT,  -- who viewed/searched (optional, for "who viewed me")
    context TEXT,    -- search query or match context
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for fast queries
CREATE INDEX IF NOT EXISTS idx_profile_stats_profile_id ON profile_stats(profile_id);
CREATE INDEX IF NOT EXISTS idx_profile_stats_type ON profile_stats(stat_type);
CREATE INDEX IF NOT EXISTS idx_profile_stats_created ON profile_stats(created_at);

-- =====================================================
-- 2. LOG FUNCTIONS
-- =====================================================

-- Log profile view
CREATE OR REPLACE FUNCTION log_profile_view(
    p_profile_id TEXT,
    p_viewer_id TEXT DEFAULT NULL
)
RETURNS void AS $$
BEGIN
    INSERT INTO profile_stats (profile_id, stat_type, viewer_id)
    VALUES (p_profile_id, 'view', p_viewer_id);
END;
$$ LANGUAGE plpgsql;

-- Log search appearance (batch - for all profiles in results)
CREATE OR REPLACE FUNCTION log_search_appearances(
    p_profile_ids TEXT[],
    p_query TEXT,
    p_searcher_id TEXT DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    pid TEXT;
BEGIN
    FOREACH pid IN ARRAY p_profile_ids
    LOOP
        INSERT INTO profile_stats (profile_id, stat_type, viewer_id, context)
        VALUES (pid, 'search_appearance', p_searcher_id, p_query);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Log match appearance
CREATE OR REPLACE FUNCTION log_match_appearance(
    p_profile_id TEXT,
    p_matched_with TEXT,
    p_match_type TEXT DEFAULT NULL
)
RETURNS void AS $$
BEGIN
    INSERT INTO profile_stats (profile_id, stat_type, viewer_id, context)
    VALUES (p_profile_id, 'match_appearance', p_matched_with, p_match_type);
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 3. GET STATS FOR A PROFILE
-- =====================================================
CREATE OR REPLACE FUNCTION get_profile_stats(
    p_profile_id TEXT,
    p_days INT DEFAULT 30
)
RETURNS jsonb AS $$
DECLARE
    view_count INT;
    search_count INT;
    match_count INT;
    connection_sent INT;
    connection_received INT;
    connection_accepted INT;
    recent_viewers jsonb;
    result jsonb;
BEGIN
    -- Profile views
    SELECT COUNT(*) INTO view_count
    FROM profile_stats
    WHERE profile_id = p_profile_id
    AND stat_type = 'view'
    AND created_at > NOW() - (p_days || ' days')::INTERVAL;

    -- Search appearances
    SELECT COUNT(*) INTO search_count
    FROM profile_stats
    WHERE profile_id = p_profile_id
    AND stat_type = 'search_appearance'
    AND created_at > NOW() - (p_days || ' days')::INTERVAL;

    -- Match appearances
    SELECT COUNT(*) INTO match_count
    FROM profile_stats
    WHERE profile_id = p_profile_id
    AND stat_type = 'match_appearance'
    AND created_at > NOW() - (p_days || ' days')::INTERVAL;

    -- Connection requests sent
    SELECT COUNT(*) INTO connection_sent
    FROM connection_requests
    WHERE from_user = p_profile_id
    AND created_at > NOW() - (p_days || ' days')::INTERVAL;

    -- Connection requests received
    SELECT COUNT(*) INTO connection_received
    FROM connection_requests
    WHERE to_user = p_profile_id
    AND created_at > NOW() - (p_days || ' days')::INTERVAL;

    -- Accepted connections (either direction)
    SELECT COUNT(*) INTO connection_accepted
    FROM connection_requests
    WHERE (from_user = p_profile_id OR to_user = p_profile_id)
    AND status = 'accepted'
    AND created_at > NOW() - (p_days || ' days')::INTERVAL;

    -- Recent viewers (last 5, anonymized if no viewer_id)
    SELECT jsonb_agg(viewer_info)
    INTO recent_viewers
    FROM (
        SELECT DISTINCT ON (viewer_id)
            COALESCE(viewer_id, 'anonymous') as viewer,
            created_at as viewed_at
        FROM profile_stats
        WHERE profile_id = p_profile_id
        AND stat_type = 'view'
        AND created_at > NOW() - (p_days || ' days')::INTERVAL
        ORDER BY viewer_id, created_at DESC
        LIMIT 5
    ) as viewer_info;

    result := jsonb_build_object(
        'profile_id', p_profile_id,
        'period_days', p_days,
        'stats', jsonb_build_object(
            'profile_views', view_count,
            'search_appearances', search_count,
            'match_appearances', match_count,
            'connections_sent', connection_sent,
            'connections_received', connection_received,
            'connections_accepted', connection_accepted
        ),
        'recent_viewers', COALESCE(recent_viewers, '[]'::jsonb),
        'engagement_score', view_count + (search_count * 2) + (match_count * 3) + (connection_accepted * 10),
        'generated_at', NOW()
    );

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 4. LEADERBOARD - Most viewed profiles
-- =====================================================
CREATE OR REPLACE FUNCTION get_profile_leaderboard(
    p_days INT DEFAULT 30,
    p_limit INT DEFAULT 10
)
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_agg(leader)
    INTO result
    FROM (
        SELECT
            ps.profile_id,
            p.name,
            p.role,
            COUNT(*) FILTER (WHERE ps.stat_type = 'view') as views,
            COUNT(*) FILTER (WHERE ps.stat_type = 'search_appearance') as searches,
            COUNT(*) FILTER (WHERE ps.stat_type = 'match_appearance') as matches,
            COUNT(*) as total_engagement
        FROM profile_stats ps
        JOIN profiles p ON ps.profile_id = p.id
        WHERE ps.created_at > NOW() - (p_days || ' days')::INTERVAL
        GROUP BY ps.profile_id, p.name, p.role
        ORDER BY total_engagement DESC
        LIMIT p_limit
    ) as leader;

    RETURN jsonb_build_object(
        'period_days', p_days,
        'leaderboard', COALESCE(result, '[]'::jsonb),
        'generated_at', NOW()
    );
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 5. TEST
-- =====================================================
-- SELECT get_profile_stats('snow', 30);
-- SELECT get_profile_leaderboard(30, 5);

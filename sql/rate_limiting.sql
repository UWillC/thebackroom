-- Rate Limiting for The Backroom
-- Data: 2026-02-05
-- Security Sprint 1

-- ============================================
-- 1. TABELA DO ŚLEDZENIA RATE LIMITS
-- ============================================

CREATE TABLE IF NOT EXISTS rate_limits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,           -- email lub profile_id
    action_type TEXT NOT NULL,       -- 'connection_request', 'post', 'search'
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index dla szybkich query
CREATE INDEX IF NOT EXISTS idx_rate_limits_user_action
ON rate_limits(user_id, action_type, created_at);

-- Automatyczne czyszczenie starych wpisów (starsze niż 24h)
CREATE INDEX IF NOT EXISTS idx_rate_limits_cleanup
ON rate_limits(created_at);

-- ============================================
-- 2. FUNKCJA SPRAWDZAJĄCA RATE LIMIT
-- ============================================

CREATE OR REPLACE FUNCTION check_rate_limit(
    p_user_id TEXT,
    p_action_type TEXT,
    p_max_count INTEGER,
    p_window_hours INTEGER DEFAULT 24
) RETURNS BOOLEAN AS $$
DECLARE
    current_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO current_count
    FROM rate_limits
    WHERE user_id = p_user_id
      AND action_type = p_action_type
      AND created_at > NOW() - (p_window_hours || ' hours')::INTERVAL;

    RETURN current_count < p_max_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 3. FUNKCJA LOGUJĄCA AKCJĘ
-- ============================================

CREATE OR REPLACE FUNCTION log_rate_limit_action(
    p_user_id TEXT,
    p_action_type TEXT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO rate_limits (user_id, action_type)
    VALUES (p_user_id, p_action_type);
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 4. FUNKCJA SPRAWDŹ + ZALOGUJ (ATOMIC)
-- ============================================

CREATE OR REPLACE FUNCTION check_and_log_rate_limit(
    p_user_id TEXT,
    p_action_type TEXT,
    p_max_count INTEGER,
    p_window_hours INTEGER DEFAULT 24
) RETURNS JSONB AS $$
DECLARE
    current_count INTEGER;
    is_allowed BOOLEAN;
BEGIN
    -- Sprawdź aktualny count
    SELECT COUNT(*) INTO current_count
    FROM rate_limits
    WHERE user_id = p_user_id
      AND action_type = p_action_type
      AND created_at > NOW() - (p_window_hours || ' hours')::INTERVAL;

    is_allowed := current_count < p_max_count;

    -- Jeśli dozwolone, zaloguj akcję
    IF is_allowed THEN
        INSERT INTO rate_limits (user_id, action_type)
        VALUES (p_user_id, p_action_type);
    END IF;

    RETURN jsonb_build_object(
        'allowed', is_allowed,
        'current_count', current_count,
        'max_count', p_max_count,
        'remaining', GREATEST(0, p_max_count - current_count - 1),
        'window_hours', p_window_hours
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 5. LIMITY (jako stałe w komentarzu)
-- ============================================

-- CONNECTION_REQUEST: 10/day
-- POST: 5/day
-- SEARCH: 50/hour

-- Przykłady użycia:
-- SELECT check_and_log_rate_limit('user@email.com', 'connection_request', 10, 24);
-- SELECT check_and_log_rate_limit('assistant_id', 'post', 5, 24);
-- SELECT check_and_log_rate_limit('user@email.com', 'search', 50, 1);

-- ============================================
-- 6. CLEANUP JOB (uruchamiać cron/pg_cron)
-- ============================================

CREATE OR REPLACE FUNCTION cleanup_old_rate_limits()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM rate_limits
    WHERE created_at < NOW() - INTERVAL '7 days';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 7. RLS POLICIES
-- ============================================

ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;

-- MCP Server może wszystko
CREATE POLICY "Allow all for rate_limits" ON rate_limits
    FOR ALL USING (true) WITH CHECK (true);

-- ============================================
-- 8. HELPER: Pokaż status limitów użytkownika
-- ============================================

CREATE OR REPLACE FUNCTION get_user_rate_limit_status(p_user_id TEXT)
RETURNS JSONB AS $$
DECLARE
    conn_count INTEGER;
    post_count INTEGER;
    search_count INTEGER;
BEGIN
    -- Connection requests (24h)
    SELECT COUNT(*) INTO conn_count
    FROM rate_limits
    WHERE user_id = p_user_id
      AND action_type = 'connection_request'
      AND created_at > NOW() - INTERVAL '24 hours';

    -- Posts (24h)
    SELECT COUNT(*) INTO post_count
    FROM rate_limits
    WHERE user_id = p_user_id
      AND action_type = 'post'
      AND created_at > NOW() - INTERVAL '24 hours';

    -- Searches (1h)
    SELECT COUNT(*) INTO search_count
    FROM rate_limits
    WHERE user_id = p_user_id
      AND action_type = 'search'
      AND created_at > NOW() - INTERVAL '1 hour';

    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'connection_requests', jsonb_build_object(
            'used', conn_count,
            'limit', 10,
            'remaining', 10 - conn_count,
            'window', '24 hours'
        ),
        'posts', jsonb_build_object(
            'used', post_count,
            'limit', 5,
            'remaining', 5 - post_count,
            'window', '24 hours'
        ),
        'searches', jsonb_build_object(
            'used', search_count,
            'limit', 50,
            'remaining', 50 - search_count,
            'window', '1 hour'
        )
    );
END;
$$ LANGUAGE plpgsql;

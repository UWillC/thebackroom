-- =====================================================
-- CONNECTION FUNNEL METRICS
-- The Backroom - Faza 2 Analytics
-- Date: 2026-02-10
-- =====================================================
-- Tracks: SENT → VIEWED → ACCEPTED → CONTACTED
-- Enables conversion rate analysis

-- =====================================================
-- 1. METRICS TABLE
-- =====================================================
CREATE TABLE IF NOT EXISTS connection_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES connection_requests(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('sent', 'viewed', 'accepted', 'rejected', 'contacted')),
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_connection_metrics_request_id ON connection_metrics(request_id);
CREATE INDEX IF NOT EXISTS idx_connection_metrics_status ON connection_metrics(status);
CREATE INDEX IF NOT EXISTS idx_connection_metrics_timestamp ON connection_metrics(timestamp);

-- =====================================================
-- 2. AUTO-LOG: When request is SENT (INSERT)
-- =====================================================
CREATE OR REPLACE FUNCTION log_connection_sent()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO connection_metrics (request_id, status, metadata)
    VALUES (NEW.id, 'sent', jsonb_build_object(
        'from_user', NEW.from_user,
        'to_user', NEW.to_user
    ));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS on_connection_sent ON connection_requests;
CREATE TRIGGER on_connection_sent
    AFTER INSERT ON connection_requests
    FOR EACH ROW
    EXECUTE FUNCTION log_connection_sent();

-- =====================================================
-- 3. AUTO-LOG: When request status changes
-- =====================================================
CREATE OR REPLACE FUNCTION log_connection_status_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Log accepted
    IF OLD.status != 'accepted' AND NEW.status = 'accepted' THEN
        INSERT INTO connection_metrics (request_id, status, metadata)
        VALUES (NEW.id, 'accepted', jsonb_build_object(
            'response_message', NEW.response_message,
            'responded_at', NEW.responded_at
        ));
    END IF;

    -- Log rejected
    IF OLD.status != 'rejected' AND NEW.status = 'rejected' THEN
        INSERT INTO connection_metrics (request_id, status, metadata)
        VALUES (NEW.id, 'rejected', jsonb_build_object(
            'response_message', NEW.response_message,
            'responded_at', NEW.responded_at
        ));
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS on_connection_status_change ON connection_requests;
CREATE TRIGGER on_connection_status_change
    AFTER UPDATE OF status ON connection_requests
    FOR EACH ROW
    EXECUTE FUNCTION log_connection_status_change();

-- =====================================================
-- 4. MANUAL LOG: Mark as "viewed" (call from MCP)
-- =====================================================
CREATE OR REPLACE FUNCTION log_connection_viewed(p_request_id UUID)
RETURNS jsonb AS $$
DECLARE
    already_viewed BOOLEAN;
BEGIN
    -- Check if already logged as viewed
    SELECT EXISTS(
        SELECT 1 FROM connection_metrics
        WHERE request_id = p_request_id AND status = 'viewed'
    ) INTO already_viewed;

    IF NOT already_viewed THEN
        INSERT INTO connection_metrics (request_id, status)
        VALUES (p_request_id, 'viewed');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'request_id', p_request_id,
        'status', 'viewed'
    );
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 5. MANUAL LOG: Mark as "contacted" (call from MCP)
-- =====================================================
CREATE OR REPLACE FUNCTION log_connection_contacted(
    p_request_id UUID,
    p_contact_method TEXT DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
    already_contacted BOOLEAN;
BEGIN
    -- Check if already logged as contacted
    SELECT EXISTS(
        SELECT 1 FROM connection_metrics
        WHERE request_id = p_request_id AND status = 'contacted'
    ) INTO already_contacted;

    IF NOT already_contacted THEN
        INSERT INTO connection_metrics (request_id, status, metadata)
        VALUES (p_request_id, 'contacted', jsonb_build_object(
            'contact_method', p_contact_method
        ));
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'request_id', p_request_id,
        'status', 'contacted'
    );
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 6. ANALYTICS: Get funnel stats
-- =====================================================
CREATE OR REPLACE FUNCTION get_connection_funnel_stats(
    p_days INT DEFAULT 30
)
RETURNS jsonb AS $$
DECLARE
    sent_count INT;
    viewed_count INT;
    accepted_count INT;
    rejected_count INT;
    contacted_count INT;
    result jsonb;
BEGIN
    -- Count each status in the time period
    SELECT COUNT(DISTINCT request_id) INTO sent_count
    FROM connection_metrics
    WHERE status = 'sent'
    AND timestamp > NOW() - (p_days || ' days')::INTERVAL;

    SELECT COUNT(DISTINCT request_id) INTO viewed_count
    FROM connection_metrics
    WHERE status = 'viewed'
    AND timestamp > NOW() - (p_days || ' days')::INTERVAL;

    SELECT COUNT(DISTINCT request_id) INTO accepted_count
    FROM connection_metrics
    WHERE status = 'accepted'
    AND timestamp > NOW() - (p_days || ' days')::INTERVAL;

    SELECT COUNT(DISTINCT request_id) INTO rejected_count
    FROM connection_metrics
    WHERE status = 'rejected'
    AND timestamp > NOW() - (p_days || ' days')::INTERVAL;

    SELECT COUNT(DISTINCT request_id) INTO contacted_count
    FROM connection_metrics
    WHERE status = 'contacted'
    AND timestamp > NOW() - (p_days || ' days')::INTERVAL;

    result := jsonb_build_object(
        'period_days', p_days,
        'funnel', jsonb_build_object(
            'sent', sent_count,
            'viewed', viewed_count,
            'accepted', accepted_count,
            'rejected', rejected_count,
            'contacted', contacted_count
        ),
        'conversion_rates', jsonb_build_object(
            'sent_to_viewed', CASE WHEN sent_count > 0 THEN ROUND((viewed_count::NUMERIC / sent_count) * 100, 1) ELSE 0 END,
            'viewed_to_accepted', CASE WHEN viewed_count > 0 THEN ROUND((accepted_count::NUMERIC / viewed_count) * 100, 1) ELSE 0 END,
            'accepted_to_contacted', CASE WHEN accepted_count > 0 THEN ROUND((contacted_count::NUMERIC / accepted_count) * 100, 1) ELSE 0 END,
            'overall_success', CASE WHEN sent_count > 0 THEN ROUND((contacted_count::NUMERIC / sent_count) * 100, 1) ELSE 0 END
        ),
        'generated_at', NOW()
    );

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 7. TEST: Verify setup
-- =====================================================
-- SELECT get_connection_funnel_stats(30);

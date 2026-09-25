-- =====================================================
-- WEEKLY MATCHES EMAIL
-- The Backroom - Faza 3 Retention
-- Date: 2026-02-10
-- =====================================================
-- Sends weekly email with personalized matches:
-- "Znaleźliśmy dla Ciebie X osób!"
-- Runs every Monday at 9:00 AM UTC

-- =====================================================
-- 1. FUNCTION: Find matches for a profile
-- =====================================================
CREATE OR REPLACE FUNCTION find_profile_matches(
    p_profile_id TEXT,
    p_max_matches INT DEFAULT 5
)
RETURNS TABLE (
    matched_id TEXT,
    matched_name TEXT,
    matched_role TEXT,
    matched_location TEXT,
    match_score INT,
    match_type TEXT,
    match_reasons TEXT[]
) AS $$
DECLARE
    my_seeks TEXT[];
    my_offers TEXT[];
BEGIN
    -- Get my seeks and offers
    SELECT
        COALESCE(seeks, ARRAY[]::TEXT[]),
        COALESCE(offers, ARRAY[]::TEXT[])
    INTO my_seeks, my_offers
    FROM profiles
    WHERE id = p_profile_id;

    -- Find matches
    RETURN QUERY
    WITH match_calc AS (
        SELECT
            p.id,
            p.name,
            p.role,
            p.location,
            -- Score: their offers match my seeks
            (SELECT COUNT(*) FROM unnest(my_seeks) ms, unnest(COALESCE(p.offers, ARRAY[]::TEXT[])) po
             WHERE LOWER(ms) = LOWER(po) OR LOWER(ms) LIKE '%' || LOWER(po) || '%' OR LOWER(po) LIKE '%' || LOWER(ms) || '%'
            )::INT * 5 AS offers_match_score,
            -- Score: their seeks match my offers
            (SELECT COUNT(*) FROM unnest(my_offers) mo, unnest(COALESCE(p.seeks, ARRAY[]::TEXT[])) ps
             WHERE LOWER(mo) = LOWER(ps) OR LOWER(mo) LIKE '%' || LOWER(ps) || '%' OR LOWER(ps) LIKE '%' || LOWER(mo) || '%'
            )::INT * 4 AS seeks_match_score,
            -- Reasons: what they offer that I seek
            (SELECT ARRAY_AGG(po) FROM unnest(my_seeks) ms, unnest(COALESCE(p.offers, ARRAY[]::TEXT[])) po
             WHERE LOWER(ms) = LOWER(po) OR LOWER(ms) LIKE '%' || LOWER(po) || '%' OR LOWER(po) LIKE '%' || LOWER(ms) || '%'
             LIMIT 3
            ) AS offer_reasons,
            -- Reasons: what they seek that I offer
            (SELECT ARRAY_AGG(ps) FROM unnest(my_offers) mo, unnest(COALESCE(p.seeks, ARRAY[]::TEXT[])) ps
             WHERE LOWER(mo) = LOWER(ps) OR LOWER(mo) LIKE '%' || LOWER(ps) || '%' OR LOWER(ps) LIKE '%' || LOWER(mo) || '%'
             LIMIT 3
            ) AS seek_reasons
        FROM profiles p
        WHERE p.id != p_profile_id
        AND p.email_verified = true  -- Only verified profiles
    )
    SELECT
        mc.id,
        mc.name,
        mc.role,
        mc.location,
        (mc.offers_match_score + mc.seeks_match_score)::INT AS total_score,
        CASE
            WHEN mc.offers_match_score > 0 AND mc.seeks_match_score > 0 THEN 'collaboration'
            WHEN mc.offers_match_score > 0 THEN 'can_help_you'
            WHEN mc.seeks_match_score > 0 THEN 'you_can_help'
            ELSE 'potential'
        END AS match_type,
        COALESCE(mc.offer_reasons, ARRAY[]::TEXT[]) || COALESCE(mc.seek_reasons, ARRAY[]::TEXT[]) AS reasons
    FROM match_calc mc
    WHERE mc.offers_match_score + mc.seeks_match_score > 0
    ORDER BY (mc.offers_match_score + mc.seeks_match_score) DESC
    LIMIT p_max_matches;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 2. FUNCTION: Send weekly matches email to ONE user
-- =====================================================
CREATE OR REPLACE FUNCTION send_weekly_matches_email(p_profile_id TEXT)
RETURNS jsonb AS $$
DECLARE
    profile_record RECORD;
    matches_html TEXT := '';
    match_record RECORD;
    match_count INT := 0;
BEGIN
    -- Get profile info
    SELECT id, name, email, email_verified, COALESCE(notifications_enabled, true) as notifications_enabled
    INTO profile_record
    FROM profiles
    WHERE id = p_profile_id;

    -- Check if we can send
    IF profile_record.email IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'no_email');
    END IF;

    IF NOT profile_record.email_verified THEN
        RETURN jsonb_build_object('success', false, 'reason', 'email_not_verified');
    END IF;

    IF NOT profile_record.notifications_enabled THEN
        RETURN jsonb_build_object('success', false, 'reason', 'notifications_disabled');
    END IF;

    -- Find matches
    FOR match_record IN
        SELECT * FROM find_profile_matches(p_profile_id, 5)
    LOOP
        match_count := match_count + 1;
        matches_html := matches_html || '
        <div style="background: #F7FAFC; padding: 15px; border-radius: 8px; margin: 10px 0; border-left: 4px solid ' ||
            CASE match_record.match_type
                WHEN 'collaboration' THEN '#38A169'
                WHEN 'can_help_you' THEN '#3182CE'
                WHEN 'you_can_help' THEN '#D69E2E'
                ELSE '#718096'
            END || ';">
            <h3 style="margin: 0 0 5px 0;">' ||
                CASE match_record.match_type
                    WHEN 'collaboration' THEN '🤝 '
                    WHEN 'can_help_you' THEN '🎯 '
                    WHEN 'you_can_help' THEN '💡 '
                    ELSE '🔗 '
                END || match_record.matched_name || '</h3>
            <p style="margin: 0; color: #4A5568;">' || COALESCE(match_record.matched_role, '') || '</p>
            <p style="margin: 5px 0 0 0; color: #718096; font-size: 14px;">📍 ' || COALESCE(match_record.matched_location, 'Nie podano') || '</p>
        </div>';
    END LOOP;

    -- If no matches, don't send email
    IF match_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'no_matches', 'profile_id', p_profile_id);
    END IF;

    -- Send email via Resend
    PERFORM net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || public.get_resend_key(),
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
            'from', 'The Backroom <hello@thebackroom.ai>',
            'to', profile_record.email,
            'subject', '🎯 Znaleźliśmy ' || match_count || ' osób dla Ciebie!',
            'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🎯 Twoje tygodniowe dopasowania!</h1>

    <p>Cześć <strong>' || profile_record.name || '</strong>!</p>

    <p>Przeanalizowaliśmy profile w sieci i znaleźliśmy <strong>' || match_count || ' osób</strong>, które mogą Cię zainteresować:</p>

    ' || matches_html || '

    <div style="background: #EBF8FF; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="margin: 0 0 10px 0;"><strong>Chcesz się połączyć?</strong></p>
        <p style="margin: 0;">Powiedz swojemu asystentowi AI:<br>
        <code style="background: #fff; padding: 5px 10px; border-radius: 4px;">"Wyślij request do [imię] w The Backroom"</code></p>
    </div>

    <p style="color: #718096; font-size: 14px;">
        <strong>Legenda:</strong><br>
        🤝 Współpraca (obopólna korzyść)<br>
        🎯 Może Ci pomóc (oferuje co szukasz)<br>
        💡 Możesz pomóc (szuka co oferujesz)
    </p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>

    <p style="color: #A0AEC0; font-size: 12px;">
        Nie chcesz otrzymywać tych emaili? Powiedz: "Wyłącz notyfikacje The Backroom"
    </p>
</div>
'
        )
    );

    -- Log that we sent
    INSERT INTO profile_stats (profile_id, stat_type, context)
    VALUES (p_profile_id, 'weekly_email_sent', 'matches: ' || match_count);

    RETURN jsonb_build_object(
        'success', true,
        'profile_id', p_profile_id,
        'matches_sent', match_count
    );
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 3. FUNCTION: Send weekly emails to ALL eligible users
-- =====================================================
CREATE OR REPLACE FUNCTION send_all_weekly_matches_emails()
RETURNS jsonb AS $$
DECLARE
    profile_record RECORD;
    result RECORD;
    sent_count INT := 0;
    skipped_count INT := 0;
    results jsonb := '[]'::jsonb;
BEGIN
    -- Loop through all verified profiles with notifications enabled
    FOR profile_record IN
        SELECT id, name, email
        FROM profiles
        WHERE email IS NOT NULL
        AND email_verified = true
        AND COALESCE(notifications_enabled, true) = true
    LOOP
        -- Send email
        SELECT * INTO result FROM send_weekly_matches_email(profile_record.id);

        IF (result.send_weekly_matches_email->>'success')::boolean THEN
            sent_count := sent_count + 1;
        ELSE
            skipped_count := skipped_count + 1;
        END IF;

        results := results || jsonb_build_object(
            'profile_id', profile_record.id,
            'result', result.send_weekly_matches_email
        );
    END LOOP;

    RETURN jsonb_build_object(
        'sent', sent_count,
        'skipped', skipped_count,
        'details', results,
        'executed_at', NOW()
    );
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 4. ADD stat_type for weekly email tracking
-- =====================================================
-- Update check constraint if needed
ALTER TABLE profile_stats DROP CONSTRAINT IF EXISTS profile_stats_stat_type_check;
ALTER TABLE profile_stats ADD CONSTRAINT profile_stats_stat_type_check
    CHECK (stat_type IN ('view', 'search_appearance', 'match_appearance', 'weekly_email_sent'));

-- =====================================================
-- 5. CRON JOB: Run every Monday at 9:00 AM UTC
-- =====================================================
-- First, enable pg_cron extension (run as superuser)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule the job (run this after enabling pg_cron)
-- SELECT cron.schedule(
--     'weekly-matches-email',           -- job name
--     '0 9 * * 1',                       -- cron: Monday 9:00 AM UTC
--     $$SELECT send_all_weekly_matches_emails()$$
-- );

-- To check scheduled jobs:
-- SELECT * FROM cron.job;

-- To unschedule:
-- SELECT cron.unschedule('weekly-matches-email');

-- =====================================================
-- 6. MANUAL TEST
-- =====================================================
-- Test finding matches:
-- SELECT * FROM find_profile_matches('snow', 5);

-- Test sending to one user:
-- SELECT send_weekly_matches_email('snow');

-- Test sending to all:
-- SELECT send_all_weekly_matches_emails();

-- LOCAL ONLY. verify_email_token as read from production 2026-11-05 (read-only MCP), with its live ACL.
-- Lets run_mail_links_local.sh prove the new fragment link still verifies end to end.
CREATE OR REPLACE FUNCTION public.verify_email_token(p_profile_id text, p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    profile_record RECORD;
    token_age INTERVAL;
BEGIN
    -- Find profile with matching token
    SELECT id, name, email, email_verification_token, email_verification_sent_at, email_verified
    INTO profile_record
    FROM profiles
    WHERE id = p_profile_id;

    -- Profile not found
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Profile not found'
        );
    END IF;

    -- Already verified
    IF profile_record.email_verified = true THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Email already verified',
            'already_verified', true
        );
    END IF;

    -- Token mismatch
    IF profile_record.email_verification_token IS NULL
       OR profile_record.email_verification_token != encode(extensions.digest(p_token, 'sha256'), 'hex') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invalid verification token'
        );
    END IF;

    -- Check token expiration (48 hours)
    token_age := NOW() - profile_record.email_verification_sent_at;
    IF token_age > INTERVAL '48 hours' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Verification token expired. Please request a new one.'
        );
    END IF;

    -- All checks passed - verify email
    UPDATE profiles
    SET email_verified = true,
        email_verification_token = NULL,  -- Clear token for security
        updated_at = NOW()
    WHERE id = p_profile_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Email verified successfully! You will now receive notifications.',
        'profile_id', p_profile_id,
        'email', profile_record.email
    );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.verify_email_token(text, text) TO anon, authenticated, service_role;

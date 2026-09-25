-- =====================================================
-- EMAIL VERIFICATION - Trigger Functions
-- The Backroom - Security Sprint 1
-- Date: 2026-02-05
-- =====================================================

-- =====================================================
-- 1. FUNCTION: Generate verification token and send email
-- =====================================================
CREATE OR REPLACE FUNCTION send_verification_email()
RETURNS TRIGGER AS $$
DECLARE
    verification_token TEXT;
    verification_link TEXT;
BEGIN
    -- Only send if:
    -- 1. Email is provided
    -- 2. Email is not yet verified
    -- 3. Email just changed (UPDATE) or is new (INSERT)
    IF NEW.email IS NOT NULL
       AND (NEW.email_verified IS NULL OR NEW.email_verified = false)
       AND (TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.email IS DISTINCT FROM NEW.email))
    THEN
        -- Generate unique token
        verification_token := gen_random_uuid()::TEXT;

        -- Store token and timestamp
        NEW.email_verification_token := verification_token;
        NEW.email_verification_sent_at := NOW();
        NEW.email_verified := false;

        -- Build verification link
        -- Using HuggingFace Gradio app URL with query params
        verification_link := 'https://huggingface.co/spaces/UWillC/thebackroom?verify=' || verification_token || '&profile=' || NEW.id;

        -- Send verification email via Resend
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Zweryfikuj swój email - The Backroom',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🔐 Potwierdź swój adres email</h1>

    <p>Cześć <strong>' || NEW.name || '</strong>!</p>

    <p>Aby aktywować powiadomienia email w The Backroom, potwierdź swój adres.</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="margin: 0 0 15px 0;"><strong>Twój kod weryfikacyjny:</strong></p>
        <p style="font-size: 24px; font-family: monospace; background: #EDF2F7; padding: 15px; border-radius: 4px; margin: 0;">
            ' || verification_token || '
        </p>
    </div>

    <p>Lub kliknij link poniżej:</p>
    <p><a href="' || verification_link || '" style="display: inline-block; background: #6B46C1; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Zweryfikuj email</a></p>

    <p style="color: #718096; font-size: 14px;">Link ważny przez 48 godzin.</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        Nie prosiłeś o ten email? Możesz go zignorować.
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 2. TRIGGER: Send verification email on INSERT/UPDATE
-- =====================================================
DROP TRIGGER IF EXISTS on_profile_email_change ON profiles;
CREATE TRIGGER on_profile_email_change
    BEFORE INSERT OR UPDATE OF email ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION send_verification_email();

-- =====================================================
-- 3. FUNCTION: Verify email with token
-- =====================================================
CREATE OR REPLACE FUNCTION verify_email_token(
    p_profile_id TEXT,
    p_token TEXT
)
RETURNS jsonb AS $$
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
       OR profile_record.email_verification_token != p_token THEN
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
$$ LANGUAGE plpgsql;

-- =====================================================
-- 4. FUNCTION: Resend verification email
-- =====================================================
CREATE OR REPLACE FUNCTION resend_verification_email(p_profile_id TEXT)
RETURNS jsonb AS $$
DECLARE
    profile_record RECORD;
    new_token TEXT;
    verification_link TEXT;
BEGIN
    -- Find profile
    SELECT id, name, email, email_verified, email_verification_sent_at
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

    -- No email
    IF profile_record.email IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No email address on profile'
        );
    END IF;

    -- Already verified
    IF profile_record.email_verified = true THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Email already verified'
        );
    END IF;

    -- Rate limit: max 1 resend per 5 minutes
    IF profile_record.email_verification_sent_at IS NOT NULL
       AND NOW() - profile_record.email_verification_sent_at < INTERVAL '5 minutes' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Please wait 5 minutes before requesting another verification email'
        );
    END IF;

    -- Generate new token
    new_token := gen_random_uuid()::TEXT;
    verification_link := 'https://huggingface.co/spaces/UWillC/thebackroom?verify=' || new_token || '&profile=' || p_profile_id;

    -- Update profile with new token
    UPDATE profiles
    SET email_verification_token = new_token,
        email_verification_sent_at = NOW()
    WHERE id = p_profile_id;

    -- Send verification email
    PERFORM net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || public.get_resend_key(),
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
            'from', 'The Backroom <hello@thebackroom.ai>',
            'to', profile_record.email,
            'subject', 'Nowy kod weryfikacyjny - The Backroom',
            'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🔐 Nowy kod weryfikacyjny</h1>

    <p>Cześć <strong>' || profile_record.name || '</strong>!</p>

    <p>Oto Twój nowy kod weryfikacyjny:</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="font-size: 24px; font-family: monospace; background: #EDF2F7; padding: 15px; border-radius: 4px; margin: 0;">
            ' || new_token || '
        </p>
    </div>

    <p><a href="' || verification_link || '" style="display: inline-block; background: #6B46C1; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Zweryfikuj email</a></p>

    <p style="color: #718096; font-size: 14px;">Link ważny przez 48 godzin.</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans
    </p>
</div>
'
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Verification email sent to ' || profile_record.email
    );
END;
$$ LANGUAGE plpgsql;

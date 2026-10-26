-- ============================================================
-- SNAPSHOT (read-only, NOT a migration) of the live definitions touched by
-- 2026-10-26_w44_19_20_hardening.sql, read 2026-10-26 ~07:45 EDT with the read-only
-- Supabase MCP (role supabase_read_only_user, project ifofgblilanwjhypzvdb).
--
-- Uses: (1) local reproduction on postgres:17 (sql/tests/run_w44_local.sh), where the
-- md5 of pg_get_functiondef must equal the live md5 below (proves byte-identical copy);
-- (2) source for the rollback file.
--
-- live md5(pg_get_functiondef) 2026-10-26:
--   send_verification_email()                  02869da99eb42c68ff5a90ec9944ab7e
--   resend_verification_email(text)            9b56025c125f7bfe3d4c8d43a8e433ba
--   notify_new_profile()                       21618b1f78e7919576ad4081f7c8aed4
--   send_welcome_email_after_verification()    9ab25e322520397c6843e7771e37de90
--   notify_connection_accepted()               39d4ec3bb792565bb4f9ae64fa43b78b
--   notify_connection_request()                4622942237534148b90fa4f17dfb1b72
--   notify_room_invite()                       6ebef3c7460d1b3e9c07a571190c9403
--   notify_room_member_approved()              b495378b3e0111c27aec5d173bb650b7
--   notify_room_message()                      a9a305f9d8972bd98495424f358bf027
--   send_weekly_matches_email(text)            59a9cd310e543c3bf42c4e2ebfa8ecf5
--
-- live ACL 2026-10-26:
--   resend_verification_email: PUBLIC, anon, authenticated, service_role (EXECUTE)
--   the other nine: postgres, service_role only
-- live policies 2026-10-26 (pg_policies):
--   profiles "Anyone can create profile"  INSERT  public  WITH CHECK (true)
--   profiles "profiles_insert"            INSERT  public  WITH CHECK (auth.uid() IS NOT NULL)
--   room_members "room_members_insert"    INSERT  public  WITH CHECK
--     ((EXISTS (SELECT 1 FROM rooms r WHERE r.id = room_members.room_id AND owns_profile(r.owner_id)))
--      OR (profile_id = get_my_profile_id()))
-- live table privileges 2026-10-26: anon and authenticated have SELECT, INSERT, UPDATE,
--   DELETE on profiles at table level (all columns).
-- ============================================================

CREATE OR REPLACE FUNCTION public.send_verification_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        NEW.email_verification_token := encode(extensions.digest(verification_token, 'sha256'), 'hex');
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

    <p>Cześć <strong>' || replace(replace(replace(replace(replace(NEW.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;') || '</strong>!</p>

    <p>Aby aktywować powiadomienia email w The Backroom, potwierdź swój adres.</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="margin: 0 0 15px 0;"><strong>Twój kod weryfikacyjny:</strong></p>
        <p style="font-size: 24px; font-family: monospace; background: #EDF2F7; padding: 15px; border-radius: 4px; margin: 0;">
            ' || verification_token || '
        </p>
    </div>

    <p>Lub kliknij link poniżej:</p>
    <p><a href="' || replace(replace(replace(replace(replace(verification_link, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;') || '" style="display: inline-block; background: #6B46C1; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Zweryfikuj email</a></p>

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
$function$
;

CREATE OR REPLACE FUNCTION public.resend_verification_email(p_profile_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    SET email_verification_token = encode(extensions.digest(new_token, 'sha256'), 'hex'),
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

    <p>Cześć <strong>' || replace(replace(replace(replace(replace(profile_record.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;') || '</strong>!</p>

    <p>Oto Twój nowy kod weryfikacyjny:</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="font-size: 24px; font-family: monospace; background: #EDF2F7; padding: 15px; border-radius: 4px; margin: 0;">
            ' || new_token || '
        </p>
    </div>

    <p><a href="' || replace(replace(replace(replace(replace(verification_link, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;') || '" style="display: inline-block; background: #6B46C1; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Zweryfikuj email</a></p>

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
$function$
;

CREATE OR REPLACE FUNCTION public.notify_new_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- Only send if profile has email
    IF NEW.email IS NOT NULL THEN
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Witaj w The Backroom, ' || NEW.name || '!',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
    <h1 style="color: #6B46C1;">🚪 Witaj w The Backroom!</h1>

    <p>Cześć <strong>' || NEW.name || '</strong>!</p>

    <p>Twój profil jest aktywny. Inni członkowie sieci mogą Cię teraz znaleźć.</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">📋 Twój profil:</h3>
        <ul style="list-style: none; padding: 0;">
            <li><strong>ID:</strong> ' || NEW.id || '</li>
            <li><strong>Rola:</strong> ' || COALESCE(NEW.role, 'Nie podano') || '</li>
            <li><strong>Lokalizacja:</strong> ' || COALESCE(NEW.location, 'Nie podano') || '</li>
        </ul>
    </div>

    <h3>🚀 Co możesz teraz zrobić?</h3>
    <ol>
        <li><strong>Szukaj:</strong> "Znajdź kogoś kto zna marketing"</li>
        <li><strong>Łącz się:</strong> "Wyślij request do [osoba]"</li>
        <li><strong>Sprawdzaj:</strong> "Moje requesty"</li>
        <li><strong>Dodaj oferty:</strong> "Dodaj ofertę: 15-min call"</li>
    </ol>

    <p>Potrzebujesz pomocy? Powiedz: <code>"Pomoc The Backroom"</code></p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom">GitHub</a>
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.send_welcome_email_after_verification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- Only send welcome email when:
    -- 1. email_verified changed from false to true
    -- 2. notifications are enabled
    IF OLD.email_verified = false
       AND NEW.email_verified = true
       AND COALESCE(NEW.notifications_enabled, true) = true
       AND NEW.email IS NOT NULL
    THEN
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Email zweryfikowany - Witaj w The Backroom, ' || NEW.name || '!',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
    <h1 style="color: #6B46C1;">✅ Email zweryfikowany!</h1>

    <p>Cześć <strong>' || NEW.name || '</strong>!</p>

    <p>Twój email został zweryfikowany. Będziesz teraz otrzymywać powiadomienia o:</p>
    <ul>
        <li>Nowych connection requests</li>
        <li>Odpowiedziach na Twoje requesty</li>
        <li>Matchach znalezionych przez AI</li>
    </ul>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">📋 Twój profil:</h3>
        <ul style="list-style: none; padding: 0;">
            <li><strong>ID:</strong> ' || NEW.id || '</li>
            <li><strong>Rola:</strong> ' || COALESCE(NEW.role, 'Nie podano') || '</li>
            <li><strong>Lokalizacja:</strong> ' || COALESCE(NEW.location, 'Nie podano') || '</li>
        </ul>
    </div>

    <h3>🚀 Co możesz teraz zrobić?</h3>
    <ol>
        <li><strong>Szukaj:</strong> "Znajdź kogoś kto zna marketing"</li>
        <li><strong>Łącz się:</strong> "Wyślij request do [osoba]"</li>
        <li><strong>Sprawdzaj:</strong> "Moje requesty"</li>
    </ol>

    <p>Potrzebujesz pomocy? Powiedz: <code>"Pomoc The Backroom"</code></p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom">GitHub</a>
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_connection_accepted()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    sender_email TEXT;
    sender_name TEXT;
    sender_verified BOOLEAN;
    sender_notifications BOOLEAN;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_role TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
    recipient_linkedin TEXT;
    recipient_contact TEXT;
BEGIN
    -- Only trigger when status changes to 'accepted'
    IF OLD.status != 'accepted' AND NEW.status = 'accepted' THEN

        -- Get sender (who sent the request) info
        SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
        INTO sender_email, sender_name, sender_verified, sender_notifications
        FROM profiles WHERE id = NEW.from_user;

        -- Get recipient (who accepted) info
        SELECT email, name, role, email_verified, COALESCE(notifications_enabled, true),
               linkedin_url, preferred_contact
        INTO recipient_email, recipient_name, recipient_role, recipient_verified,
             recipient_notifications, recipient_linkedin, recipient_contact
        FROM profiles WHERE id = NEW.to_user;

        -- =====================================================
        -- EMAIL 1: To the SENDER (their request was accepted!)
        -- =====================================================
        IF sender_email IS NOT NULL
           AND sender_verified = true
           AND sender_notifications = true
        THEN
            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', sender_email,
                    'subject', recipient_name || ' zaakceptował(a) Twój request!',
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection Accepted!</h1>

    <p>Cześć <strong>' || sender_name || '</strong>!</p>

    <p>Świetna wiadomość - <strong>' || recipient_name || '</strong> zaakceptował(a) Twój connection request!</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;"><strong>Napisz. Krótko się przedstaw. Umówcie się na kawę lub call.</strong></p>
    </div>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">Dane kontaktowe:</h3>
        <ul style="list-style: none; padding: 0; margin: 0;">
            <li><strong>Imię:</strong> ' || recipient_name || '</li>
            <li><strong>Rola:</strong> ' || COALESCE(recipient_role, 'Nie podano') || '</li>
            ' || CASE WHEN recipient_linkedin IS NOT NULL THEN '
            <li><strong>LinkedIn:</strong> <a href="' || recipient_linkedin || '">' || recipient_linkedin || '</a></li>
            ' ELSE '' END || '
            <li><strong>Preferowany kontakt:</strong> ' || COALESCE(recipient_contact, 'Nie podano') || '</li>
        </ul>
    </div>

    ' || CASE WHEN NEW.response_message IS NOT NULL AND NEW.response_message != '' THEN '
    <div style="background: #EBF8FF; padding: 15px; border-radius: 8px; margin: 20px 0;">
        <p style="margin: 0;"><strong>Wiadomość od ' || recipient_name || ':</strong></p>
        <p style="margin: 10px 0 0 0; font-style: italic;">"' || NEW.response_message || '"</p>
    </div>
    ' ELSE '' END || '

    <h3>Sugerowana pierwsza wiadomość:</h3>
    <div style="background: #FFFAF0; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 14px;">
        Cześć ' || recipient_name || '!<br><br>
        Dzięki za akceptację w The Backroom.<br>
        [WSTAW: krótko czego szukasz / co oferujesz]<br><br>
        Masz czas na krótki call w tym tygodniu?<br><br>
        Pozdrawiam,<br>
        ' || sender_name || '
    </div>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>
</div>
'
                )
            );
        END IF;

        -- =====================================================
        -- EMAIL 2: To the RECIPIENT (confirmation + next steps)
        -- =====================================================
        IF recipient_email IS NOT NULL
           AND recipient_verified = true
           AND recipient_notifications = true
        THEN
            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', recipient_email,
                    'subject', 'Zaakceptowałeś(aś) request od ' || sender_name,
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection nawiązany!</h1>

    <p>Cześć <strong>' || recipient_name || '</strong>!</p>

    <p>Zaakceptowałeś(aś) connection request od <strong>' || sender_name || '</strong>.</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;">' || sender_name || ' otrzymał(a) Twoje dane kontaktowe i prawdopodobnie niedługo się odezwie.</p>
    </div>

    <p style="color: #718096;">Jeśli chcesz, możesz też sam(a) napisać pierwszą wiadomość!</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans
    </p>
</div>
'
                )
            );
        END IF;

    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_connection_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    sender_name TEXT;
    sender_role TEXT;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
BEGIN
    -- Get sender info
    SELECT name, role INTO sender_name, sender_role
    FROM profiles WHERE id = NEW.from_user;

    -- Get recipient info including verification status
    SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
    INTO recipient_email, recipient_name, recipient_verified, recipient_notifications
    FROM profiles WHERE id = NEW.to_user;

    -- Only send email if:
    -- 1. Recipient has email
    -- 2. Email is VERIFIED
    -- 3. Notifications are enabled
    IF recipient_email IS NOT NULL
       AND recipient_verified = true
       AND recipient_notifications = true
    THEN
        -- Send email via Resend
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', recipient_email,
                'subject', sender_name || ' chce się z Tobą połączyć!',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🤝 Nowy Connection Request!</h1>

    <p>Cześć <strong>' || recipient_name || '</strong>!</p>

    <p><strong>' || sender_name || '</strong> (' || COALESCE(sender_role, 'Członek sieci') || ') chce się z Tobą połączyć w The Backroom.</p>

    ' || CASE WHEN NEW.message IS NOT NULL AND NEW.message != '' THEN '
    <div style="background: #F7FAFC; padding: 15px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #6B46C1;">
        <p style="margin: 0; font-style: italic;">"' || NEW.message || '"</p>
    </div>
    ' ELSE '' END || '

    <p>Aby odpowiedzieć, powiedz swojemu asystentowi AI:</p>
    <ul>
        <li><code>"Sprawdź moje requesty w The Backroom"</code></li>
        <li><code>"Odpowiedz na request od ' || sender_name || '"</code></li>
    </ul>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>

    <p style="color: #A0AEC0; font-size: 12px;">
        Nie chcesz otrzymywać powiadomień? Powiedz: "Wyłącz notyfikacje The Backroom"
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_room_invite()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    inviter_name TEXT;
    inviter_email TEXT;
    room_name TEXT;
    room_type TEXT;
    email_html TEXT;
    invite_url TEXT;
BEGIN
    -- Get room info
    SELECT r.name, r.room_type INTO room_name, room_type
    FROM rooms r WHERE r.id = NEW.room_id;

    -- Get inviter info
    SELECT p.name, p.email INTO inviter_name, inviter_email
    FROM profiles p WHERE p.id = NEW.created_by;

    -- Only send if we have recipient email
    IF NEW.email IS NOT NULL THEN
        -- Build invite URL (Gradio UI)
        invite_url := 'https://huggingface.co/spaces/UWillC/thebackroom?token=' || NEW.token;

        -- Build HTML
        email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
        <p style="color: #8B949E; margin-top: 5px;">Where AI assistants connect their humans</p>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <h2 style="color: #F0F6FC; margin-top: 0;">Zaproszenie do pokoju</h2>

        <p><strong style="color: #58A6FF;">' || inviter_name || '</strong> zaprasza Cie do dolaczenia do pokoju:</p>

        <div style="background: #0D1117; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #238636;">
            <h3 style="color: #58A6FF; margin: 0 0 10px 0;">' || room_name || '</h3>
            <p style="color: #8B949E; margin: 0;">Typ: ' ||
                CASE room_type
                    WHEN 'enterprise' THEN 'Enterprise Room (firma)'
                    WHEN 'personal' THEN 'Personal Room (sync asystentow)'
                    ELSE room_type
                END || '</p>
        </div>

        <h3 style="color: #F0F6FC;">Jak dolaczyc?</h3>
        <ol style="color: #C9D1D9; line-height: 1.8;">
            <li>Skopiuj token: <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px; color: #79C0FF;">' || NEW.token || '</code></li>
            <li>Powiedz swojemu asystentowi AI: <em>"Dolacz do pokoju, token: ' || NEW.token || '"</em></li>
            <li>Lub uzyj komendy: <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px;">join_room(token="' || NEW.token || '")</code></li>
        </ol>

        <p style="color: #F85149; font-size: 14px;">Token wazny przez 7 dni (do ' || to_char(NEW.expires_at, 'YYYY-MM-DD HH24:MI') || ' UTC)</p>
    </div>

    <hr style="border: none; border-top: 1px solid #30363D; margin: 30px 0;">

    <p style="color: #8B949E; font-size: 14px; text-align: center;">
        <a href="https://www.thebackroom.ai" style="color: #58A6FF;">thebackroom.ai</a> |
        <a href="https://huggingface.co/spaces/UWillC/thebackroom" style="color: #58A6FF;">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom" style="color: #58A6FF;">GitHub</a>
    </p>
</div>';

        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Zaproszenie do ' || room_name || ' - The Backroom',
                'html', email_html
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_room_member_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    member_email TEXT;
    member_name TEXT;
    room_name TEXT;
    room_type TEXT;
    room_slug TEXT;
    email_html TEXT;
BEGIN
    -- Only trigger on status change to 'approved'
    IF OLD.status != 'approved' AND NEW.status = 'approved' THEN

        -- Get member info
        SELECT p.email, p.name INTO member_email, member_name
        FROM profiles p WHERE p.id = NEW.profile_id;

        -- Get room info
        SELECT r.name, r.room_type, r.slug INTO room_name, room_type, room_slug
        FROM rooms r WHERE r.id = NEW.room_id;

        -- Only send if member has email
        IF member_email IS NOT NULL THEN

            -- Build HTML
            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
        <p style="color: #8B949E; margin-top: 5px;">Where AI assistants connect their humans</p>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <div style="text-align: center; margin-bottom: 20px;">
            <span style="font-size: 48px;">&#10004;&#65039;</span>
        </div>

        <h2 style="color: #238636; margin-top: 0; text-align: center;">Gratulacje, ' || member_name || '!</h2>

        <p style="text-align: center;">Twoje czlonkostwo w pokoju <strong style="color: #58A6FF;">' || room_name || '</strong> zostalo zatwierdzone.</p>

        <div style="background: #0D1117; padding: 20px; border-radius: 8px; margin: 20px 0;">
            <h3 style="color: #F0F6FC; margin-top: 0;">Co mozesz teraz robic?</h3>
            <ul style="color: #C9D1D9; line-height: 1.8;">
                <li><strong>Przegladaj czlonkow:</strong> <code>search_in_room(room_slug="' || room_slug || '")</code></li>
                <li><strong>Sprawdz wiadomosci:</strong> <code>check_room_inbox()</code></li>
                <li><strong>Wyslij wiadomosc:</strong> <code>send_room_message(...)</code></li>
            </ul>
        </div>

        <h3 style="color: #F0F6FC;">Checklista na start:</h3>
        <div style="background: #0D1117; padding: 15px; border-radius: 8px;">
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Sprawdz kto jest w pokoju
            </label>
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Przeczytaj wiadomosci powitalne
            </label>
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Przedstaw sie zespolowi
            </label>
        </div>
    </div>

    <hr style="border: none; border-top: 1px solid #30363D; margin: 30px 0;">

    <p style="color: #8B949E; font-size: 14px; text-align: center;">
        <a href="https://www.thebackroom.ai" style="color: #58A6FF;">thebackroom.ai</a> |
        <a href="https://huggingface.co/spaces/UWillC/thebackroom" style="color: #58A6FF;">Web UI</a>
    </p>
</div>';

            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', member_email,
                    'subject', 'Witamy w ' || room_name || '! - The Backroom',
                    'html', email_html
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_room_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    recipient RECORD;
    sender_name TEXT;
    room_name TEXT;
    email_html TEXT;
BEGIN
    -- Get sender name
    SELECT p.name INTO sender_name
    FROM profiles p WHERE p.id = NEW.from_profile_id;

    -- Get room name
    SELECT r.name INTO room_name
    FROM rooms r WHERE r.id = NEW.room_id;

    -- Only notify for important messages (request, urgent)
    IF NEW.message_type IN ('request', 'reminder') OR NEW.priority IN ('urgent', 'high') THEN

        -- Get all recipients with emails
        FOR recipient IN
            SELECT p.email, p.name
            FROM message_recipients mr
            JOIN profiles p ON mr.profile_id = p.id
            WHERE mr.message_id = NEW.id
              AND p.email IS NOT NULL
              AND p.notifications_enabled = true
        LOOP
            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <p style="color: #8B949E; margin: 0 0 10px 0;">Nowa wiadomosc w <strong style="color: #58A6FF;">' || room_name || '</strong></p>

        <h2 style="color: #F0F6FC; margin: 0 0 20px 0;">' || COALESCE(NEW.subject, '(brak tematu)') || '</h2>

        <div style="background: #0D1117; padding: 15px; border-radius: 8px; border-left: 4px solid ' ||
            CASE NEW.priority
                WHEN 'urgent' THEN '#F85149'
                WHEN 'high' THEN '#F0883E'
                ELSE '#238636'
            END || ';">
            <p style="margin: 0; color: #C9D1D9;">' || COALESCE(NEW.body, '') || '</p>
        </div>

        <p style="margin-top: 20px; color: #8B949E;">
            Od: <strong>' || sender_name || '</strong><br>
            Typ: ' || NEW.message_type || '<br>
            Priorytet: <span style="color: ' ||
                CASE NEW.priority
                    WHEN 'urgent' THEN '#F85149'
                    WHEN 'high' THEN '#F0883E'
                    ELSE '#C9D1D9'
                END || ';">' || NEW.priority || '</span>' ||
            CASE WHEN NEW.deadline IS NOT NULL
                THEN '<br>Deadline: <strong style="color: #F85149;">' || to_char(NEW.deadline, 'YYYY-MM-DD HH24:MI') || '</strong>'
                ELSE ''
            END || '
        </p>

        <p style="margin-top: 20px;">
            <strong>Odpowiedz:</strong> <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px;">respond_to_room_message(message_id="' || NEW.id || '")</code>
        </p>
    </div>
</div>';

            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', recipient.email,
                    'subject', '[' || room_name || '] ' || COALESCE(NEW.subject, 'Nowa wiadomosc'),
                    'html', email_html
                )
            );
        END LOOP;
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.send_weekly_matches_email(p_profile_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

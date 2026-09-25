-- THE BACKROOM - Onboarding Email (Welcome)
-- Faza 2: Lepszy onboarding
-- Data: 2026-02-04
-- Wysyła welcome email po rejestracji profilu

-- Function to send welcome email via Resend
CREATE OR REPLACE FUNCTION notify_new_profile()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

-- Create trigger on profiles table (only for INSERT)
DROP TRIGGER IF EXISTS on_new_profile ON profiles;
CREATE TRIGGER on_new_profile
    AFTER INSERT ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION notify_new_profile();

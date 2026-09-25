# Email Verification - Deployment Guide

## Date: 2026-02-05
## Sprint: Security Sprint 1

---

## 1. SUPABASE SQL (run in order)

Execute these SQL files in Supabase SQL Editor:

```bash
# Step 1: Add columns to profiles table
thebackroom-sql/email_verification_schema.sql

# Step 2: Create trigger functions for verification
thebackroom-sql/email_verification_trigger.sql

# Step 3: Update existing notification triggers
thebackroom-sql/update_notification_triggers.sql
```

### Verification after SQL deployment:

```sql
-- Check columns were added
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'profiles'
AND column_name IN ('email_verified', 'email_verification_token',
                    'email_verification_sent_at', 'notifications_enabled');

-- Should return 4 rows
```

---

## 2. RENDER DEPLOYMENT

### Files changed:
- `thebackroom/server.py` - 4 new MCP tools
- `thebackroom/app.py` - new "Verify Email" tab

### Deploy:
```bash
cd /Users/uwillc/Asystenci/CEO/thebackroom
git add server.py app.py
git commit -m "Add email verification tools and UI"
git push origin main
```

Render will auto-deploy from GitHub.

---

## 3. TEST FLOW

### Test 1: Registration with email
```
register_profile(
    name="test_user",
    role="Tester",
    skills="testing",
    offers="nothing",
    seeks="nothing",
    email="your-test@email.com"
)
```
- Should receive verification email within 1 minute

### Test 2: Check verification status
```
check_email_verification_status("test_user")
```
- Should show status: PENDING

### Test 3: Verify email
```
verify_email("test_user", "TOKEN_FROM_EMAIL")
```
- Should return success

### Test 4: Toggle notifications
```
toggle_notifications("test_user", false)
toggle_notifications("test_user", true)
```
- Should toggle notifications_enabled

---

## 4. NEW MCP TOOLS

| Tool | Description |
|------|-------------|
| `verify_email(profile_id, token)` | Verify email with token from email |
| `resend_verification_email(profile_id)` | Resend verification email (rate limited: 1/5min) |
| `check_email_verification_status(profile_id)` | Check if email is verified |
| `toggle_notifications(profile_id, enabled)` | Enable/disable email notifications |

---

## 5. BEHAVIOR CHANGES

### Connection Requests
- Emails only sent to users with `email_verified = true`
- Must also have `notifications_enabled = true`

### Welcome Email
- No longer sent on profile creation
- Sent AFTER email is verified (via trigger on UPDATE)

### Verification Flow
1. User registers with email
2. Trigger sends verification email (48h valid)
3. User verifies with token
4. Welcome email sent automatically
5. User starts receiving notifications

---

## 6. ROLLBACK (if needed)

```sql
-- Remove verification columns (CAUTION: data loss)
ALTER TABLE profiles
DROP COLUMN IF EXISTS email_verified,
DROP COLUMN IF EXISTS email_verification_token,
DROP COLUMN IF EXISTS email_verification_sent_at,
DROP COLUMN IF EXISTS notifications_enabled;

-- Remove trigger
DROP TRIGGER IF EXISTS on_profile_email_change ON profiles;
DROP TRIGGER IF EXISTS on_email_verified ON profiles;

-- Remove functions
DROP FUNCTION IF EXISTS send_verification_email();
DROP FUNCTION IF EXISTS verify_email_token(TEXT, TEXT);
DROP FUNCTION IF EXISTS resend_verification_email(TEXT);
DROP FUNCTION IF EXISTS send_welcome_email_after_verification();
DROP FUNCTION IF EXISTS toggle_notifications(TEXT, BOOLEAN);
```

# Deploy: Enterprise Rooms

> Date: 2026-02-06
> Status: READY TO DEPLOY

---

## Files to deploy

| # | File | Contents | Dependencies |
|---|------|----------|--------------|
| 1 | `enterprise_rooms.sql` | rooms, room_members, room_invites, room_audit_log | profiles (existing) |
| 2 | `enterprise_rooms_messaging.sql` | room_messages, message_recipients, message_templates | enterprise_rooms.sql |

---

## Deploy Order

### Step 1: Enterprise Rooms (base)

```bash
# In the Supabase SQL Editor:
# 1. Open: enterprise_rooms.sql
# 2. Run the whole script (Ctrl+Enter)
```

**Verification after Step 1:**
```sql
-- Check tables
SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'room%';
-- Expected: rooms, room_members, room_invites, room_audit_log

-- Check views
SELECT viewname FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'room%' OR viewname = 'my_rooms';
-- Expected: room_active_members, room_pending_approvals, my_rooms

-- Check functions
SELECT proname FROM pg_proc WHERE proname LIKE '%room%' OR proname LIKE 'generate_room%' OR proname LIKE 'is_room%' OR proname LIKE 'log_room%';
-- Expected: generate_room_slug, is_room_admin, is_room_member, log_room_action
```

### Step 2: Messaging System

```bash
# In the Supabase SQL Editor:
# 1. Open: enterprise_rooms_messaging.sql
# 2. Run the whole script (Ctrl+Enter)
```

**Verification after Step 2:**
```sql
-- Check tables
SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'room_message%' OR tablename = 'message%';
-- Expected: room_messages, message_recipients, message_templates

-- Check views
SELECT viewname FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'inbox%' OR viewname LIKE 'message%';
-- Expected: inbox_unread, message_status_summary

-- Check functions
SELECT proname FROM pg_proc WHERE proname IN ('send_room_message', 'check_inbox', 'mark_message_read', 'respond_to_message', 'get_message_status', 'get_message_responses');
-- Expected: all 6 functions
```

---

## Quick Test (after deployment)

### Test 1: Create a room

```sql
-- 1. Create a room (as snow)
INSERT INTO rooms (name, slug, description, owner_id)
VALUES ('Test Corp', 'test-corp', 'Test company room', 'snow');

-- 2. Add the owner as a member
INSERT INTO room_members (room_id, profile_id, role, status, joined_at)
SELECT id, 'snow', 'owner', 'approved', NOW()
FROM rooms WHERE slug = 'test-corp';

-- 3. Log the action
SELECT log_room_action(
    (SELECT id FROM rooms WHERE slug = 'test-corp'),
    'snow',
    'room_created',
    NULL,
    '{"source": "test"}'::jsonb
);

-- 4. Check
SELECT * FROM my_rooms WHERE slug = 'test-corp';
```

### Test 2: Invite and approve a member

```sql
-- 1. Create an invite
INSERT INTO room_invites (room_id, created_by, max_uses, note)
SELECT id, 'snow', 5, 'For the team'
FROM rooms WHERE slug = 'test-corp'
RETURNING token;
-- Save the token!

-- 2. Simulate joining (as 'tomek' or another existing profile)
INSERT INTO room_members (room_id, profile_id, status, invited_by, invite_token)
SELECT
    r.id,
    'jakub',  -- change to an existing profile_id
    'pending',
    'snow',
    ri.token
FROM rooms r
JOIN room_invites ri ON ri.room_id = r.id
WHERE r.slug = 'test-corp'
LIMIT 1;

-- 3. Check pending
SELECT * FROM room_pending_approvals WHERE room_slug = 'test-corp';

-- 4. Approve
UPDATE room_members
SET status = 'approved', joined_at = NOW()
WHERE room_id = (SELECT id FROM rooms WHERE slug = 'test-corp')
  AND profile_id = 'jakub';

-- 5. Check active members
SELECT * FROM room_active_members WHERE room_slug = 'test-corp';
```

### Test 3: Messaging

```sql
-- 1. Send a broadcast (as snow)
SELECT send_room_message(
    (SELECT id FROM rooms WHERE slug = 'test-corp'),
    'snow',
    'COO Bot',
    'request',
    'Test Request',
    'This is a test message.',
    NULL,  -- broadcast
    NULL,
    '{"field1": "text"}'::jsonb,
    NOW() + INTERVAL '1 day',
    'high'
);

-- 2. Check inbox (as jakub)
SELECT * FROM check_inbox('jakub');

-- 3. Check status (as snow)
SELECT * FROM message_status_summary WHERE from_profile_id = 'snow';
```

### Cleanup (after tests)

```sql
-- Delete test data
DELETE FROM rooms WHERE slug = 'test-corp';
-- CASCADE deletes: room_members, room_invites, room_audit_log, room_messages
```

---

## New tables: summary

| Table | Description | Key columns |
|-------|-------------|-------------|
| `rooms` | Company rooms | id, name, slug, owner_id, settings, status |
| `room_members` | Members | room_id, profile_id, role, status |
| `room_invites` | Invite tokens | room_id, token, max_uses, expires_at |
| `room_audit_log` | Action history | room_id, actor_id, action, target_id |
| `room_messages` | Messages | room_id, from/to, message_type, subject, body |
| `message_recipients` | Recipient status | message_id, profile_id, status |
| `message_templates` | Templates | room_id, name, subject_template, body_template |

---

## New SQL functions

| Function | Description | Use |
|----------|-------------|-----|
| `generate_room_slug(name)` | Generates a unique slug | Automatic in MCP |
| `is_room_admin(room_id, profile_id)` | Is the user an admin | Permission check |
| `is_room_member(room_id, profile_id)` | Is the user a member | Access check |
| `log_room_action(...)` | Logs to audit | Every admin action |
| `send_room_message(...)` | Sends a message | Broadcast or 1:1 |
| `check_inbox(profile_id)` | Unread messages | Automatic at start |
| `mark_message_read(...)` | Mark as read | After opening |
| `respond_to_message(...)` | Reply | To a request |
| `get_message_status(...)` | Status of a sent message | For the sender |
| `get_message_responses(...)` | List of responses | For the sender |

---

## Next steps

After deploying the SQL:

1. [ ] **MCP Tools**: implementation in `server.py`
2. [ ] **MCP tests**: full flow through Claude Code
3. [ ] **Gradio UI**: "My Rooms" tab

---

*Deploy guide v1.0 - 2026-02-06*

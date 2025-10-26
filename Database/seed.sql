-- Gym Full Application - Seed Data
-- Idempotent seeds using INSERT ... ON CONFLICT
-- Assumes schema.sql already applied

-- Users
INSERT INTO public.users (id, email, password_hash, full_name, role, is_active)
VALUES
    (gen_random_uuid(), 'member1@example.com', 'hashed_password_member1', 'Mia Member', 'member', TRUE),
    (gen_random_uuid(), 'trainer1@example.com', 'hashed_password_trainer1', 'Tom Trainer', 'trainer', TRUE),
    (gen_random_uuid(), 'admin1@example.com', 'hashed_password_admin1', 'Alice Admin', 'admin', TRUE)
ON CONFLICT (email) DO UPDATE
SET full_name = EXCLUDED.full_name,
    role = EXCLUDED.role,
    is_active = EXCLUDED.is_active;

-- Capture ids for further inserts (deterministically via email)
WITH u AS (
  SELECT
    (SELECT id FROM public.users WHERE email='member1@example.com') AS member_id,
    (SELECT id FROM public.users WHERE email='trainer1@example.com') AS trainer_id,
    (SELECT id FROM public.users WHERE email='admin1@example.com') AS admin_id
)
-- Membership for member
INSERT INTO public.memberships (user_id, type, status, start_date)
SELECT member_id, 'basic', 'active', CURRENT_DATE
FROM u
ON CONFLICT DO NOTHING;

-- Classes taught by trainer
WITH ids AS (
  SELECT
    (SELECT id FROM public.users WHERE email='trainer1@example.com') AS trainer_id
)
INSERT INTO public.classes (title, description, trainer_id, capacity, start_time, end_time)
SELECT 'Morning HIIT', 'High intensity interval training', ids.trainer_id, 15, NOW() + INTERVAL '1 day', NOW() + INTERVAL '1 day 1 hour'
FROM ids
UNION ALL
SELECT 'Evening Yoga', 'Relaxing yoga session', ids.trainer_id, 12, NOW() + INTERVAL '2 days', NOW() + INTERVAL '2 days 1 hour'
FROM ids;

-- Prevent duplicates for classes by unique composite if not exists: add natural uniqueness guard via where not exists
WITH ids AS (
  SELECT
    (SELECT id FROM public.users WHERE email='trainer1@example.com') AS trainer_id
)
INSERT INTO public.classes (title, description, trainer_id, capacity, start_time, end_time)
SELECT c.title, c.description, ids.trainer_id, c.capacity, c.start_time, c.end_time
FROM ids
JOIN (
  SELECT 'Spin Class'::text AS title, 'High-energy spin session'::text AS description, 20::int AS capacity, NOW() + INTERVAL '3 days' AS start_time, NOW() + INTERVAL '3 days 1 hour' AS end_time
) c ON TRUE
WHERE NOT EXISTS (
  SELECT 1 FROM public.classes pc
  WHERE pc.title = c.title
    AND pc.trainer_id = ids.trainer_id
    AND ABS(EXTRACT(EPOCH FROM (pc.start_time - c.start_time))) < 60
);

-- Booking for member into first class
WITH member AS (
  SELECT id AS member_id FROM public.users WHERE email='member1@example.com'
),
cls AS (
  SELECT id AS class_id FROM public.classes ORDER BY start_time LIMIT 1
)
INSERT INTO public.bookings (class_id, member_id, status)
SELECT cls.class_id, member.member_id, 'booked'
FROM cls, member
ON CONFLICT DO NOTHING;

-- Workout record
WITH ids AS (
  SELECT
    (SELECT id FROM public.users WHERE email='member1@example.com') AS member_id,
    (SELECT id FROM public.users WHERE email='trainer1@example.com') AS trainer_id
)
INSERT INTO public.workouts (member_id, trainer_id, date, plan, notes)
SELECT ids.member_id, ids.trainer_id, CURRENT_DATE,
       '{"exercises":[{"name":"Squat","sets":3,"reps":10},{"name":"Push-up","sets":3,"reps":12}]}'::jsonb,
       'Initial assessment workout'
FROM ids
WHERE NOT EXISTS (
  SELECT 1 FROM public.workouts w WHERE w.member_id = ids.member_id AND w.date = CURRENT_DATE
);

-- Payment record
INSERT INTO public.payments (user_id, amount_cents, currency, status, payment_method, provider_ref)
SELECT id, 4999, 'USD', 'completed', 'card', 'seed_txn_001'
FROM public.users WHERE email='member1@example.com'
ON CONFLICT DO NOTHING;

-- Seed user_preferences for core users with sensible defaults
INSERT INTO public.user_preferences (user_id, email_notifications, sms_notifications, push_notifications, theme, language, timezone, preferences)
SELECT id, TRUE, FALSE, FALSE, 'light', 'en', 'UTC',
       '{"dashboard":{"showTips":true},"booking":{"reminders":true}}'::jsonb
FROM public.users
WHERE email IN ('member1@example.com','trainer1@example.com','admin1@example.com')
ON CONFLICT (user_id) DO UPDATE
SET email_notifications = EXCLUDED.email_notifications,
    sms_notifications = EXCLUDED.sms_notifications,
    push_notifications = EXCLUDED.push_notifications,
    theme = EXCLUDED.theme,
    language = EXCLUDED.language,
    timezone = EXCLUDED.timezone;

-- Seed a waitlist entry for the earliest class, if capacity would be exceeded logically
WITH cls AS (
  SELECT id AS class_id, capacity FROM public.classes ORDER BY start_time LIMIT 1
),
member2 AS (
  -- If there is no separate member2, we reuse the same member1 for idempotency and uniqueness handled by constraint
  SELECT id AS member_id FROM public.users WHERE email='member1@example.com'
),
desired AS (
  SELECT cls.class_id, member2.member_id,
         COALESCE((
           SELECT MAX(position) FROM public.waitlist w WHERE w.class_id = cls.class_id
         ), 0) + 1 AS next_position
  FROM cls, member2
)
INSERT INTO public.waitlist (class_id, member_id, position, status)
SELECT class_id, member_id, next_position, 'waiting'
FROM desired
ON CONFLICT (class_id, member_id) DO NOTHING;

-- Log a sample notification for seeding
INSERT INTO public.notification_logs (user_id, channel, template, subject, body, data, sent_at, status)
SELECT u.id, 'email', 'welcome', 'Welcome to Gym!', 'Hello and welcome!', '{"source":"seed"}'::jsonb, NOW(), 'sent'
FROM public.users u
WHERE u.email = 'member1@example.com'
AND NOT EXISTS (
  SELECT 1 FROM public.notification_logs nl
  WHERE nl.user_id = u.id AND nl.template = 'welcome'
);

-- Seed scheduler jobs: a daily cleanup and a reminder dispatcher
INSERT INTO public.scheduler_jobs (job_name, job_type, schedule, payload, status, next_run_at)
VALUES
  ('daily_cleanup', 'cron', '0 3 * * *', '{"task":"cleanup","retention_days":30}'::jsonb, 'pending', NOW() + INTERVAL '1 hour'),
  ('booking_reminder_dispatch', 'cron', '*/15 * * * *', '{"task":"send_booking_reminders","lookahead_minutes":120}'::jsonb, 'pending', NOW() + INTERVAL '15 minutes')
ON CONFLICT DO NOTHING;

-- Sample audit log
INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, metadata)
SELECT id, 'SEED_INITIALIZE', 'system', 'seed-001', '{"note":"Initial dataset created"}'::jsonb
FROM public.users WHERE email='admin1@example.com';

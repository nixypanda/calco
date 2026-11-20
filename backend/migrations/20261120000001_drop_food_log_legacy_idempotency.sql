-- Move surviving keys from the pre-journal food_logs columns into the durable
-- operation journal, then remove the duplicate legacy columns and index.
--
-- A key whose log was already deleted before this migration cannot be
-- reconstructed. Do not claim such a key is recoverable; clients must use a
-- fresh key for a new intentional submission.
--
-- Take the strongest table lock before reading the candidate snapshot. This
-- waits for old writers that already hold row locks, then blocks new old-writer
-- statements until this migration transaction commits. Without it, an old
-- writer could commit a keyed row after the snapshot but before the column
-- drop, leaving a surviving log with neither an operation nor a key. Drain old
-- key-writing backend instances before running this migration; the lock
-- serializes in-flight writers, it cannot make a post-drop old binary
-- compatible with the dropped columns.
LOCK TABLE food_logs IN ACCESS EXCLUSIVE MODE;

WITH candidates AS (
    SELECT
        food_logs.id,
        food_logs.user_id,
        food_logs.idempotency_key,
        COALESCE(food_logs.request_fingerprint, repeat('0', 64)) AS request_fingerprint,
        food_logs.created_at
    FROM food_logs
    WHERE food_logs.idempotency_key IS NOT NULL
),
inserted AS (
    INSERT INTO food_log_create_operations (
        id,
        user_id,
        idempotency_key,
        request_fingerprint,
        operation_kind,
        log_count,
        created_at
    )
    SELECT
        gen_random_uuid(),
        user_id,
        idempotency_key,
        request_fingerprint,
        'single',
        1,
        created_at
    FROM candidates
    ON CONFLICT (user_id, idempotency_key) DO NOTHING
    RETURNING id, user_id, idempotency_key
)
INSERT INTO food_log_create_operation_logs (operation_id, food_log_id, position)
SELECT inserted.id, food_logs.id, 0
FROM inserted
JOIN food_logs
    ON food_logs.user_id = inserted.user_id
    AND food_logs.idempotency_key = inserted.idempotency_key
ON CONFLICT (operation_id, food_log_id) DO NOTHING;

DROP INDEX IF EXISTS food_logs_user_idempotency_key_idx;

ALTER TABLE food_logs
    DROP COLUMN IF EXISTS idempotency_key,
    DROP COLUMN IF EXISTS request_fingerprint;

COMMENT ON TABLE food_logs IS
    'Current food-log rows. Create idempotency keys and fingerprints live only in food_log_create_operations.';

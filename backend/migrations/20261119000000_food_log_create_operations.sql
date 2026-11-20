CREATE TABLE IF NOT EXISTS food_log_create_operations (
    id                    UUID PRIMARY KEY,
    user_id               UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    idempotency_key       TEXT NOT NULL,
    request_fingerprint   TEXT NOT NULL,
    operation_kind        TEXT NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT food_log_create_operations_key_length
        CHECK (char_length(idempotency_key) BETWEEN 1 AND 128),
    CONSTRAINT food_log_create_operations_fingerprint_format
        CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
    CONSTRAINT food_log_create_operations_kind
        CHECK (operation_kind IN ('single', 'ad_hoc', 'batch'))
);

CREATE UNIQUE INDEX IF NOT EXISTS food_log_create_operations_user_idempotency_key_idx
    ON food_log_create_operations (user_id, idempotency_key);

CREATE TABLE IF NOT EXISTS food_log_create_operation_logs (
    operation_id  UUID NOT NULL REFERENCES food_log_create_operations(id) ON DELETE CASCADE,
    food_log_id   UUID NOT NULL,
    position      INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (operation_id, position),
    UNIQUE (operation_id, food_log_id)
);

CREATE INDEX IF NOT EXISTS food_log_create_operation_logs_food_log_id_idx
    ON food_log_create_operation_logs (food_log_id);

-- Backfill keyed single-log rows created before this migration. The operation
-- row deliberately has no foreign key to food_logs so deleting a log leaves a
-- tombstone that prevents a late retry from recreating it. A legacy key with
-- no fingerprint is given an impossible fingerprint and continues to conflict.
WITH backfilled AS (
    INSERT INTO food_log_create_operations (
        id,
        user_id,
        idempotency_key,
        request_fingerprint,
        operation_kind,
        created_at
    )
    SELECT
        gen_random_uuid(),
        user_id,
        idempotency_key,
        COALESCE(request_fingerprint, repeat('0', 64)),
        'single',
        created_at
    FROM food_logs
    WHERE idempotency_key IS NOT NULL
    ON CONFLICT (user_id, idempotency_key) DO NOTHING
    RETURNING id, user_id, idempotency_key
)
INSERT INTO food_log_create_operation_logs (operation_id, food_log_id, position)
SELECT backfilled.id, food_logs.id, 0
FROM backfilled
JOIN food_logs
    ON food_logs.user_id = backfilled.user_id
    AND food_logs.idempotency_key = backfilled.idempotency_key
ON CONFLICT (operation_id, position) DO NOTHING;

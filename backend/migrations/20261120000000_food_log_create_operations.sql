-- The operation journal is the sole owner of create idempotency keys and
-- request fingerprints. Food log rows no longer carry duplicate key metadata.
--
-- This migration is forward-compatible with a database that already recorded
-- the earlier journal migration without log_count. It does not rewrite
-- _sqlx_migrations, drop operation rows, or recreate the journal.
CREATE TABLE IF NOT EXISTS food_log_create_operations (
    id                    UUID PRIMARY KEY,
    user_id               UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    idempotency_key       TEXT NOT NULL,
    request_fingerprint   TEXT NOT NULL,
    operation_kind        TEXT NOT NULL,
    log_count             INTEGER NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT food_log_create_operations_key_length
        CHECK (char_length(idempotency_key) BETWEEN 1 AND 128),
    CONSTRAINT food_log_create_operations_fingerprint_format
        CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
    CONSTRAINT food_log_create_operations_kind
        CHECK (operation_kind IN ('single', 'ad_hoc', 'batch')),
    CONSTRAINT food_log_create_operations_log_count
        CHECK (log_count BETWEEN 1 AND 50)
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

-- Upgrade a pre-log_count journal in place. Existing operation rows are
-- retained; the count is derived from their immutable child links.
ALTER TABLE food_log_create_operations
    ADD COLUMN IF NOT EXISTS log_count INTEGER;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'food_log_create_operations'
          AND column_name = 'log_count'
          AND is_nullable = 'YES'
    ) THEN
        UPDATE food_log_create_operations AS operation
        SET log_count = (
            SELECT count(*)::integer
            FROM food_log_create_operation_logs AS link
            WHERE link.operation_id = operation.id
        )
        WHERE operation.log_count IS NULL;

        IF EXISTS (
            SELECT 1
            FROM food_log_create_operations
            WHERE log_count IS NULL OR log_count < 1 OR log_count > 50
        ) THEN
            RAISE EXCEPTION
                'cannot upgrade food_log_create_operations: an operation has an invalid child count';
        END IF;

        ALTER TABLE food_log_create_operations
            ALTER COLUMN log_count SET NOT NULL;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'food_log_create_operations'
          AND c.conname = 'food_log_create_operations_log_count'
    ) THEN
        ALTER TABLE food_log_create_operations
            ADD CONSTRAINT food_log_create_operations_log_count
            CHECK (log_count BETWEEN 1 AND 50);
    END IF;
END $$;

COMMENT ON TABLE food_log_create_operations IS
    'Permanent idempotency tombstones; retained indefinitely for the user profile. Never prune or reuse a key.';
COMMENT ON COLUMN food_log_create_operations.request_fingerprint IS
    'SHA-256 of the normalized create request; immutable after insert.';
COMMENT ON COLUMN food_log_create_operations.log_count IS
    'Expected immutable child-link count; replay rejects any mismatch.';

COMMENT ON TABLE food_log_create_operation_logs IS
    'Immutable ordered links from an operation to the logs it created; retained after log deletion.';
COMMENT ON COLUMN food_log_create_operation_logs.food_log_id IS
    'Deliberately has no foreign key to food_logs so deleting a log leaves a tombstone instead of freeing the operation.';

-- Additive upgrade for operation journals created before log_count existed.
-- This deliberately does not drop or recreate keys, tombstones, or links.
ALTER TABLE food_log_create_operations
    ADD COLUMN IF NOT EXISTS log_count INTEGER;

UPDATE food_log_create_operations AS operation
SET log_count = (
    SELECT count(*)::integer
    FROM food_log_create_operation_logs AS link
    WHERE link.operation_id = operation.id
)
WHERE operation.log_count IS NULL;

-- Do not guess a count for corrupt legacy operations. A zero-link or oversized
-- operation requires an explicit repair decision before the invariant exists.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM food_log_create_operations
        WHERE log_count IS NULL OR log_count < 1 OR log_count > 50
    ) THEN
        RAISE EXCEPTION
            'cannot upgrade food_log_create_operations: an operation has an invalid child count';
    END IF;
END $$;

ALTER TABLE food_log_create_operations
    ALTER COLUMN log_count SET NOT NULL;

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

-- Retention policy: operation rows and their child links are permanent for the
-- lifetime of the user profile. There is no TTL, pruning job, admin cleanup, or
-- log-deletion path that removes a key or an individual child link. A future
-- policy change must replace the tombstone mechanism before deleting anything;
-- deleting a user profile cascades the operation and all child links together.
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

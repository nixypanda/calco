-- Enforce the operation kind/log-count relationship at the database boundary.
-- The earlier 1..50 count constraint allowed a single or ad-hoc operation with
-- more than one child. Do not guess a repair for existing corrupt rows: abort
-- the migration and require an explicit review before the invariant is added.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM food_log_create_operations
        WHERE NOT (
            (operation_kind = 'batch' AND log_count BETWEEN 1 AND 50)
            OR (operation_kind IN ('single', 'ad_hoc') AND log_count = 1)
        )
    ) THEN
        RAISE EXCEPTION
            'cannot enforce food_log_create_operations shape: an operation kind and log_count pair is invalid';
    END IF;
END $$;

-- The shape constraint subsumes the older log_count-only check. Keep the final
-- schema single-sourced instead of depending on two constraints whose
-- definitions can drift apart.
ALTER TABLE food_log_create_operations
    DROP CONSTRAINT IF EXISTS food_log_create_operations_log_count;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'food_log_create_operations'
          AND c.conname = 'food_log_create_operations_shape'
    ) THEN
        ALTER TABLE food_log_create_operations
            ADD CONSTRAINT food_log_create_operations_shape
            CHECK (
                (operation_kind = 'batch' AND log_count BETWEEN 1 AND 50)
                OR (operation_kind IN ('single', 'ad_hoc') AND log_count = 1)
            );
    END IF;
END $$;

COMMENT ON CONSTRAINT food_log_create_operations_shape
    ON food_log_create_operations IS
    'Single and ad-hoc operations have exactly one log; batch operations have 1 to 50.';

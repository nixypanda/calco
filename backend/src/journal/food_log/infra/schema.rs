use sqlx::PgPool;

use crate::BoxError;

/// Fails startup when the database does not expose the durable log-create
/// schema. Migrations remain an explicit deployment step; the server never
/// runs them and never serves a partially upgraded database.
pub async fn validate_schema(pool: &PgPool) -> Result<(), BoxError> {
    let ready: bool = sqlx::query_scalar(JOURNAL_READY_SQL)
        .fetch_one(pool)
        .await?;
    if !ready {
        return Err(
            "database schema is incompatible with this backend: run `just migrate-backend` before starting the server"
                .into(),
        );
    }
    Ok(())
}

const JOURNAL_READY_SQL: &str = r#"
WITH
required_columns (table_name, column_name, data_type, is_nullable) AS (
    VALUES
        ('food_log_create_operations', 'id', 'uuid', 'NO'),
        ('food_log_create_operations', 'user_id', 'uuid', 'NO'),
        ('food_log_create_operations', 'idempotency_key', 'text', 'NO'),
        ('food_log_create_operations', 'request_fingerprint', 'text', 'NO'),
        ('food_log_create_operations', 'operation_kind', 'text', 'NO'),
        ('food_log_create_operations', 'log_count', 'integer', 'NO'),
        ('food_log_create_operations', 'created_at', 'timestamp with time zone', 'NO'),
        ('food_log_create_operation_logs', 'operation_id', 'uuid', 'NO'),
        ('food_log_create_operation_logs', 'food_log_id', 'uuid', 'NO'),
        ('food_log_create_operation_logs', 'position', 'integer', 'NO'),
        ('food_logs', 'id', 'uuid', 'NO'),
        ('food_logs', 'user_id', 'uuid', 'NO')
),
column_mismatches AS (
    SELECT 1
    FROM required_columns required
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns actual
        WHERE actual.table_schema = 'public'
          AND actual.table_name = required.table_name
          AND actual.column_name = required.column_name
          AND actual.data_type = required.data_type
          AND actual.is_nullable = required.is_nullable
    )
),
food_log_columns AS (
    SELECT COALESCE(
        array_agg(column_name::text ORDER BY column_name),
        ARRAY[]::text[]
    ) AS columns
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'food_logs'
),
index_columns AS (
    SELECT
        i.indexrelid,
        i.indrelid,
        i.indisunique,
        i.indisvalid,
        i.indisready,
        i.indislive,
        i.indimmediate,
        i.indisprimary,
        i.indpred IS NULL AS no_predicate,
        i.indexprs IS NULL AS no_expressions,
        i.indnkeyatts,
        array_agg(a.attname::text ORDER BY key_column.ordinality) AS key_columns
    FROM pg_index i
    JOIN pg_class table_name ON table_name.oid = i.indrelid
    JOIN pg_namespace schema_name ON schema_name.oid = table_name.relnamespace
    CROSS JOIN LATERAL unnest(i.indkey)
        WITH ORDINALITY AS key_column(attnum, ordinality)
    JOIN pg_attribute a
        ON a.attrelid = table_name.oid AND a.attnum = key_column.attnum
    WHERE schema_name.nspname = 'public'
      AND table_name.relname IN (
          'food_log_create_operations',
          'food_log_create_operation_logs'
      )
      AND key_column.ordinality <= i.indnkeyatts
    GROUP BY
        i.indexrelid,
        i.indrelid,
        i.indisunique,
        i.indisvalid,
        i.indisready,
        i.indislive,
        i.indimmediate,
        i.indisprimary,
        i.indpred,
        i.indexprs,
        i.indnkeyatts
),
check_constraints AS (
    SELECT
        table_name.relname AS table_name,
        btrim(regexp_replace(
            pg_get_expr(c.conbin, c.conrelid),
            '[[:space:]]+',
            ' ',
            'g'
        )) AS expression,
        c.convalidated
    FROM pg_constraint c
    JOIN pg_class table_name ON table_name.oid = c.conrelid
    JOIN pg_namespace schema_name ON schema_name.oid = table_name.relnamespace
    WHERE schema_name.nspname = 'public'
      AND table_name.relname IN (
          'food_log_create_operations',
          'food_log_create_operation_logs'
      )
      AND c.contype = 'c'
),
-- Compare canonical PostgreSQL 16 output exactly, with only whitespace
-- normalized. Do not fold case: string literals such as the fingerprint regex
-- are case-sensitive and a case-folded comparison would accept weaker checks.
expected_checks (table_name, expression) AS (
    VALUES
        ('food_log_create_operations', $$((char_length(idempotency_key) >= 1) AND (char_length(idempotency_key) <= 128))$$),
        ('food_log_create_operations', $$(request_fingerprint ~ '^[0-9a-f]{64}$'::text)$$),
        ('food_log_create_operations', $$(operation_kind = ANY (ARRAY['single'::text, 'ad_hoc'::text, 'batch'::text]))$$),
        ('food_log_create_operations', $$(((operation_kind = 'batch'::text) AND ((log_count >= 1) AND (log_count <= 50))) OR ((operation_kind = ANY (ARRAY['single'::text, 'ad_hoc'::text])) AND (log_count = 1)))$$),
        ('food_log_create_operation_logs', $$("position" >= 0)$$)
),
foreign_keys AS (
    SELECT
        table_name.relname AS table_name,
        referenced.relname AS referenced_table,
        c.confdeltype,
        c.convalidated,
        btrim(regexp_replace(
            pg_get_constraintdef(c.oid),
            '[[:space:]]+',
            ' ',
            'g'
        )) AS definition
    FROM pg_constraint c
    JOIN pg_class table_name ON table_name.oid = c.conrelid
    JOIN pg_namespace schema_name ON schema_name.oid = table_name.relnamespace
    JOIN pg_class referenced ON referenced.oid = c.confrelid
    JOIN pg_namespace referenced_schema ON referenced_schema.oid = referenced.relnamespace
    WHERE schema_name.nspname = 'public'
      AND referenced_schema.nspname = 'public'
      AND table_name.relname IN (
          'food_log_create_operations',
          'food_log_create_operation_logs'
      )
      AND c.contype = 'f'
),
expected_foreign_keys (table_name, definition) AS (
    VALUES
        ('food_log_create_operations', $$FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE$$),
        ('food_log_create_operation_logs', $$FOREIGN KEY (operation_id) REFERENCES food_log_create_operations(id) ON DELETE CASCADE$$)
)
SELECT
    NOT EXISTS (SELECT 1 FROM column_mismatches)
    AND 'id' = ANY(food_log_columns.columns)
    AND 'user_id' = ANY(food_log_columns.columns)
    AND NOT ('idempotency_key' = ANY(food_log_columns.columns))
    AND NOT ('request_fingerprint' = ANY(food_log_columns.columns))
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operations'
          AND index_info.indisprimary
          AND index_info.indisvalid
          AND index_info.indisready
          AND index_info.indislive
          AND index_info.indimmediate
          AND index_info.indnkeyatts = 1
          AND index_info.key_columns = ARRAY['id']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operations'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND index_info.indisready
          AND index_info.indislive
          AND index_info.indimmediate
          AND NOT index_info.indisprimary
          AND index_info.no_predicate
          AND index_info.no_expressions
          AND index_info.indnkeyatts = 2
          AND index_info.key_columns = ARRAY['user_id', 'idempotency_key']::text[]
    )
    AND NOT EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operations'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND index_info.indisready
          AND index_info.indislive
          AND NOT index_info.indimmediate
          AND index_info.no_predicate
          AND index_info.no_expressions
          AND index_info.indnkeyatts = 2
          AND index_info.key_columns @> ARRAY['user_id', 'idempotency_key']::text[]
          AND index_info.key_columns <@ ARRAY['user_id', 'idempotency_key']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operation_logs'
          AND index_info.indisprimary
          AND index_info.indisvalid
          AND index_info.indisready
          AND index_info.indislive
          AND index_info.indimmediate
          AND index_info.indnkeyatts = 2
          AND index_info.key_columns = ARRAY['operation_id', 'position']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operation_logs'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND index_info.indisready
          AND index_info.indislive
          AND index_info.indimmediate
          AND NOT index_info.indisprimary
          AND index_info.no_predicate
          AND index_info.no_expressions
          AND index_info.indnkeyatts = 2
          AND index_info.key_columns = ARRAY['operation_id', 'food_log_id']::text[]
    )
    AND NOT EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operation_logs'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND index_info.indisready
          AND index_info.indislive
          AND NOT index_info.indimmediate
          AND index_info.no_predicate
          AND index_info.no_expressions
          AND index_info.indnkeyatts = 2
          AND (
              (
                  index_info.key_columns @> ARRAY['operation_id', 'position']::text[]
                  AND index_info.key_columns <@ ARRAY['operation_id', 'position']::text[]
              )
              OR (
                  index_info.key_columns @> ARRAY['operation_id', 'food_log_id']::text[]
                  AND index_info.key_columns <@ ARRAY['operation_id', 'food_log_id']::text[]
              )
          )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM expected_checks expected
        WHERE NOT EXISTS (
            SELECT 1
            FROM check_constraints checks
            WHERE checks.table_name = expected.table_name
              AND checks.convalidated
              AND checks.expression = expected.expression
        )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM expected_foreign_keys expected
        WHERE NOT EXISTS (
            SELECT 1
            FROM foreign_keys keys
            WHERE keys.table_name = expected.table_name
              AND keys.convalidated
              AND keys.definition = expected.definition
        )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM foreign_keys keys
        WHERE keys.table_name = 'food_log_create_operation_logs'
          AND keys.referenced_table = 'food_logs'
    )
FROM food_log_columns
"#;

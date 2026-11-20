use std::sync::Arc;

use async_trait::async_trait;
use axum::Router;
use axum::extract::{FromRef, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use axum::routing::get;
use serde::Serialize;
use sqlx::PgPool;

use crate::AppState;
use crate::auth::api::http::AccountBoundReadUser;

/// Version 2 adds durable operation replay for ad-hoc and batch log creation,
/// including deletion tombstones. A missing or unready journal reports version
/// 0 so clients can fail closed instead of assuming keyed retries are safe.
pub const LOG_CREATION_IDEMPOTENCY_VERSION: u32 = 2;

#[async_trait]
pub trait CapabilityProbe: Send + Sync {
    async fn journal_ready(&self) -> Result<bool, sqlx::Error>;
}

#[derive(Clone)]
pub struct CapabilityModule {
    probe: Arc<dyn CapabilityProbe>,
}

impl CapabilityModule {
    pub fn new(probe: Arc<dyn CapabilityProbe>) -> Self {
        Self { probe }
    }

    pub fn pg(pool: &PgPool) -> Self {
        Self::new(Arc::new(PgCapabilityProbe { pool: pool.clone() }))
    }

    async fn journal_ready(&self) -> Result<bool, sqlx::Error> {
        self.probe.journal_ready().await
    }
}

impl FromRef<AppState> for CapabilityModule {
    fn from_ref(state: &AppState) -> Self {
        state.capabilities.clone()
    }
}

pub fn capability_routes(state: AppState) -> Router {
    Router::new()
        .route("/capabilities", get(capabilities_handler))
        .with_state(state)
}

#[derive(Serialize)]
pub struct CapabilitiesResponse {
    pub log_creation_idempotency: LogCreationIdempotencyCapability,
}

#[derive(Serialize)]
pub struct LogCreationIdempotencyCapability {
    pub version: u32,
    pub single: bool,
    pub ad_hoc: bool,
    pub batch: bool,
    pub batch_key_location: Option<&'static str>,
    pub deleted_operation_replay: &'static str,
    pub pre_migration_deleted_keys: &'static str,
    pub request_account_binding: Option<&'static str>,
}

async fn capabilities_handler(
    _user: AccountBoundReadUser,
    State(capabilities): State<CapabilityModule>,
) -> Result<Json<CapabilitiesResponse>, Response> {
    let ready = capabilities.journal_ready().await.map_err(|error| {
        tracing::error!(error = %error, "capability probe failed");
        capability_unavailable_response()
    })?;
    Ok(Json(CapabilitiesResponse {
        log_creation_idempotency: LogCreationIdempotencyCapability {
            version: if ready {
                LOG_CREATION_IDEMPOTENCY_VERSION
            } else {
                0
            },
            single: ready,
            ad_hoc: ready,
            batch: ready,
            batch_key_location: ready.then_some("top_level"),
            deleted_operation_replay: if ready { "conflict" } else { "unavailable" },
            pre_migration_deleted_keys: "reconciliation_only",
            request_account_binding: ready.then_some("x-calco-account-id"),
        },
    }))
}

#[derive(Serialize)]
struct CapabilityErrorResponse {
    error: CapabilityErrorBody,
}

#[derive(Serialize)]
struct CapabilityErrorBody {
    code: &'static str,
    message: &'static str,
}

fn capability_unavailable_response() -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(CapabilityErrorResponse {
            error: CapabilityErrorBody {
                code: "capability_unavailable",
                message: "capability probe failed temporarily; retry later",
            },
        }),
    )
        .into_response()
}

struct PgCapabilityProbe {
    pool: PgPool,
}

#[async_trait]
impl CapabilityProbe for PgCapabilityProbe {
    async fn journal_ready(&self) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar::<_, bool>(JOURNAL_READY_SQL)
            .fetch_one(&self.pool)
            .await
    }
}

const JOURNAL_READY_SQL: &str = r#"
WITH
operation_columns AS (
    SELECT COALESCE(
        array_agg(column_name::text ORDER BY column_name),
        ARRAY[]::text[]
    ) AS columns
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'food_log_create_operations'
),
child_columns AS (
    SELECT COALESCE(
        array_agg(column_name::text ORDER BY column_name),
        ARRAY[]::text[]
    ) AS columns
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'food_log_create_operation_logs'
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
          'food_log_create_operation_logs',
          'food_logs'
      )
    GROUP BY
        i.indexrelid,
        i.indrelid,
        i.indisunique,
        i.indisvalid,
        i.indisprimary,
        i.indpred,
        i.indexprs,
        i.indnkeyatts
)
SELECT
    operation_columns.columns @> ARRAY[
        'id', 'user_id', 'idempotency_key', 'request_fingerprint',
        'operation_kind', 'log_count', 'created_at'
    ]::text[]
    AND child_columns.columns @> ARRAY[
        'operation_id', 'food_log_id', 'position'
    ]::text[]
    AND food_log_columns.columns @> ARRAY[
        'id', 'user_id', 'idempotency_key', 'request_fingerprint'
    ]::text[]
    AND EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'food_log_create_operations'
          AND column_name = 'log_count'
          AND is_nullable = 'NO'
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operations'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND NOT index_info.indisprimary
          AND index_info.no_predicate
          AND index_info.no_expressions
          AND index_info.indnkeyatts = 2
          AND index_info.key_columns = ARRAY['user_id', 'idempotency_key']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operation_logs'
          AND index_info.indisprimary
          AND index_info.indisvalid
          AND index_info.key_columns = ARRAY['operation_id', 'position']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_log_create_operation_logs'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND NOT index_info.indisprimary
          AND index_info.no_predicate
          AND index_info.no_expressions
          AND index_info.key_columns = ARRAY['operation_id', 'food_log_id']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM index_columns index_info
        JOIN pg_class table_name ON table_name.oid = index_info.indrelid
        WHERE table_name.relname = 'food_logs'
          AND index_info.indisunique
          AND index_info.indisvalid
          AND index_info.key_columns = ARRAY['user_id', 'idempotency_key']::text[]
    )
    AND EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class table_name ON table_name.oid = c.conrelid
        JOIN pg_namespace schema_name ON schema_name.oid = table_name.relnamespace
        WHERE schema_name.nspname = 'public'
          AND table_name.relname = 'food_log_create_operations'
          AND c.contype = 'c'
          AND pg_get_constraintdef(c.oid) LIKE '%log_count%'
          AND pg_get_constraintdef(c.oid) LIKE '%>= 1%'
          AND pg_get_constraintdef(c.oid) LIKE '%<= 50%'
    )
    AND EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class table_name ON table_name.oid = c.conrelid
        JOIN pg_class referenced ON referenced.oid = c.confrelid
        JOIN pg_namespace schema_name ON schema_name.oid = table_name.relnamespace
        WHERE schema_name.nspname = 'public'
          AND table_name.relname = 'food_log_create_operations'
          AND c.contype = 'f'
          AND referenced.relname = 'user_profiles'
          AND c.confdeltype = 'c'
    )
    AND EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class table_name ON table_name.oid = c.conrelid
        JOIN pg_class referenced ON referenced.oid = c.confrelid
        JOIN pg_namespace schema_name ON schema_name.oid = table_name.relnamespace
        WHERE schema_name.nspname = 'public'
          AND table_name.relname = 'food_log_create_operation_logs'
          AND c.contype = 'f'
          AND referenced.relname = 'food_log_create_operations'
          AND c.confdeltype = 'c'
    )
FROM operation_columns, child_columns, food_log_columns
"#;

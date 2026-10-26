use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Clone)]
pub struct PostgresApiKeyRepository {
    pool: PgPool,
}

impl PostgresApiKeyRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ApiKeyRepository for PostgresApiKeyRepository {
    async fn create_if_active_count_below(
        &self,
        key: &ApiKey,
        max_active: usize,
        now: DateTime<Utc>,
    ) -> Result<bool, AuthError> {
        let mut tx = self.pool.begin().await?;

        // Serialize active-key counting and insertion for one identity. The
        // identity row is a stable per-identity lock and is also the row whose
        // security stamp decides whether an existing key is still active.
        // FOR NO KEY UPDATE serializes creators without blocking FK key-share
        // locks held by dependent rows.
        sqlx::query("SELECT id FROM identities WHERE id = $1 FOR NO KEY UPDATE")
            .bind(key.identity_id.0)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        let active_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM api_keys \
             WHERE identity_id = $1 AND identity_security_stamp = $2 AND revoked_at IS NULL \
             AND (expires_at IS NULL OR expires_at > $3)",
        )
        .bind(key.identity_id.0)
        .bind(key.identity_security_stamp.0)
        .bind(now)
        .fetch_one(&mut *tx)
        .await?;

        if active_count >= max_active as i64 {
            tx.rollback().await?;
            return Ok(false);
        }

        sqlx::query(
            "INSERT INTO api_keys (id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
        )
        .bind(key.id.0)
        .bind(key.identity_id.0)
        .bind(key.identity_security_stamp.0)
        .bind(key.name.as_str())
        .bind(&key.token_hash.0)
        .bind(&key.token_hint)
        .bind(key.scope.as_str())
        .bind(key.created_at)
        .bind(key.last_used_at)
        .bind(key.expires_at)
        .bind(key.revoked_at)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(true)
    }

    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<ApiKey>, AuthError> {
        let row = sqlx::query_as::<_, ApiKeyRow>(
            "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
             FROM api_keys WHERE token_hash = $1",
        )
        .bind(token_hash)
        .fetch_optional(&self.pool)
        .await?;

        row.map(api_key_row_to_api_key).transpose()
    }

    async fn find_by_id(&self, id: ApiKeyId) -> Result<Option<ApiKey>, AuthError> {
        let row = sqlx::query_as::<_, ApiKeyRow>(
            "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
             FROM api_keys WHERE id = $1",
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        row.map(api_key_row_to_api_key).transpose()
    }

    async fn find_by_id_and_identity_id(
        &self,
        id: ApiKeyId,
        identity_id: IdentityId,
    ) -> Result<Option<ApiKey>, AuthError> {
        let row = sqlx::query_as::<_, ApiKeyRow>(
            "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
             FROM api_keys WHERE id = $1 AND identity_id = $2",
        )
        .bind(id.0)
        .bind(identity_id.0)
        .fetch_optional(&self.pool)
        .await?;

        row.map(api_key_row_to_api_key).transpose()
    }

    async fn list_by_identity_id(&self, id: IdentityId) -> Result<Vec<ApiKey>, AuthError> {
        let rows = sqlx::query_as::<_, ApiKeyRow>(
            "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
             FROM api_keys WHERE identity_id = $1 ORDER BY created_at DESC",
        )
        .bind(id.0)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(api_key_row_to_api_key).collect()
    }

    async fn update_last_used_at_before(
        &self,
        id: ApiKeyId,
        identity_id: IdentityId,
        now: DateTime<Utc>,
        stale_before: DateTime<Utc>,
    ) -> Result<bool, AuthError> {
        let result = sqlx::query(
            "UPDATE api_keys SET last_used_at = $3 \
             WHERE id = $1 AND identity_id = $2 AND revoked_at IS NULL \
             AND (last_used_at IS NULL OR last_used_at <= $4)",
        )
        .bind(id.0)
        .bind(identity_id.0)
        .bind(now)
        .bind(stale_before)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected() > 0)
    }

    async fn update_revoked_at_if_null(
        &self,
        id: ApiKeyId,
        identity_id: IdentityId,
        now: DateTime<Utc>,
    ) -> Result<bool, AuthError> {
        let result = sqlx::query(
            "UPDATE api_keys SET revoked_at = $3 \
             WHERE id = $1 AND identity_id = $2 AND revoked_at IS NULL",
        )
        .bind(id.0)
        .bind(identity_id.0)
        .bind(now)
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected() > 0)
    }
}

#[derive(sqlx::FromRow)]
struct ApiKeyRow {
    id: Uuid,
    identity_id: Uuid,
    identity_security_stamp: Uuid,
    name: String,
    token_hash: String,
    token_hint: String,
    scope: String,
    created_at: DateTime<Utc>,
    last_used_at: Option<DateTime<Utc>>,
    expires_at: Option<DateTime<Utc>>,
    revoked_at: Option<DateTime<Utc>>,
}

fn api_key_row_to_api_key(row: ApiKeyRow) -> Result<ApiKey, AuthError> {
    Ok(ApiKey {
        id: ApiKeyId(row.id),
        identity_id: IdentityId(row.identity_id),
        identity_security_stamp: SessionSecurityStamp(row.identity_security_stamp),
        name: ApiKeyName::new(&row.name)?,
        token_hash: ApiKeyTokenHash(row.token_hash),
        token_hint: row.token_hint,
        scope: row.scope.parse()?,
        created_at: row.created_at,
        last_used_at: row.last_used_at,
        expires_at: row.expires_at,
        revoked_at: row.revoked_at,
    })
}

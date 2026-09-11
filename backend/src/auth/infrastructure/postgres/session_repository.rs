use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Clone)]
pub struct PostgresSessionRepository {
    pool: PgPool,
}
impl PostgresSessionRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl SessionRepository for PostgresSessionRepository {
    async fn create(&self, session: &Session) -> Result<(), AuthError> {
        sqlx::query(
            "INSERT INTO sessions (id, identity_id, identity_security_stamp, session_token_hash, created_at, last_seen_at, expires_at, revoked_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(session.id)
        .bind(session.identity_id.0)
        .bind(session.identity_security_stamp.0)
        .bind(&session.session_token_hash.0)
        .bind(session.created_at)
        .bind(session.last_seen_at)
        .bind(session.expires_at)
        .bind(session.revoked_at)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<Session>, AuthError> {
        let row = sqlx::query_as::<_, SessionRow>(
            "SELECT id, identity_id, identity_security_stamp, session_token_hash, created_at, last_seen_at, expires_at, revoked_at \
             FROM sessions WHERE session_token_hash = $1",
        )
        .bind(token_hash)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(session_row_to_session))
    }

    async fn update(&self, session: &Session) -> Result<(), AuthError> {
        sqlx::query(
            "UPDATE sessions SET identity_id = $1, identity_security_stamp = $2, session_token_hash = $3, created_at = $4, \
             last_seen_at = $5, expires_at = $6, revoked_at = $7 WHERE id = $8",
        )
        .bind(session.identity_id.0)
        .bind(session.identity_security_stamp.0)
        .bind(&session.session_token_hash.0)
        .bind(session.created_at)
        .bind(session.last_seen_at)
        .bind(session.expires_at)
        .bind(session.revoked_at)
        .bind(session.id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct SessionRow {
    id: Uuid,
    identity_id: Uuid,
    identity_security_stamp: Uuid,
    session_token_hash: String,
    created_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    revoked_at: Option<DateTime<Utc>>,
}

fn session_row_to_session(row: SessionRow) -> Session {
    Session {
        id: row.id,
        identity_id: IdentityId(row.identity_id),
        identity_security_stamp: SessionSecurityStamp(row.identity_security_stamp),
        session_token_hash: SessionTokenHash(row.session_token_hash),
        created_at: row.created_at,
        last_seen_at: row.last_seen_at,
        expires_at: row.expires_at,
        revoked_at: row.revoked_at,
    }
}

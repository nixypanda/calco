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
            "INSERT INTO sessions (id, identity_id, session_token_hash, created_at, last_seen_at, expires_at, revoked_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(session.id)
        .bind(session.identity_id.0)
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
            "SELECT id, identity_id, session_token_hash, created_at, last_seen_at, expires_at, revoked_at \
             FROM sessions WHERE session_token_hash = $1",
        )
        .bind(token_hash)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(session_row_to_session))
    }

    async fn list_by_identity_id(
        &self,
        identity_id: IdentityId,
    ) -> Result<Vec<Session>, AuthError> {
        let rows = sqlx::query_as::<_, SessionRow>(
            "SELECT id, identity_id, session_token_hash, created_at, last_seen_at, expires_at, revoked_at \
             FROM sessions WHERE identity_id = $1",
        )
        .bind(identity_id.0)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().map(session_row_to_session).collect())
    }

    async fn update(&self, session: &Session) -> Result<(), AuthError> {
        sqlx::query(
            "UPDATE sessions SET identity_id = $1, session_token_hash = $2, created_at = $3, \
             last_seen_at = $4, expires_at = $5, revoked_at = $6 WHERE id = $7",
        )
        .bind(session.identity_id.0)
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

    async fn update_many(&self, sessions: &[Session]) -> Result<(), AuthError> {
        if sessions.is_empty() {
            return Ok(());
        }

        let ids: Vec<Uuid> = sessions.iter().map(|session| session.id).collect();
        let identity_ids: Vec<Uuid> = sessions
            .iter()
            .map(|session| session.identity_id.0)
            .collect();
        let token_hashes: Vec<String> = sessions
            .iter()
            .map(|session| session.session_token_hash.0.clone())
            .collect();
        let created_at: Vec<DateTime<Utc>> =
            sessions.iter().map(|session| session.created_at).collect();
        let last_seen_at: Vec<DateTime<Utc>> = sessions
            .iter()
            .map(|session| session.last_seen_at)
            .collect();
        let expires_at: Vec<DateTime<Utc>> =
            sessions.iter().map(|session| session.expires_at).collect();
        let revoked_at: Vec<Option<DateTime<Utc>>> =
            sessions.iter().map(|session| session.revoked_at).collect();

        sqlx::query(
            "UPDATE sessions AS s SET identity_id = data.identity_id, \
             session_token_hash = data.session_token_hash, created_at = data.created_at, \
             last_seen_at = data.last_seen_at, expires_at = data.expires_at, \
             revoked_at = data.revoked_at \
             FROM UNNEST($1::uuid[], $2::uuid[], $3::text[], $4::timestamptz[], \
                         $5::timestamptz[], $6::timestamptz[], $7::timestamptz[]) \
                  AS data(id, identity_id, session_token_hash, created_at, last_seen_at, expires_at, revoked_at) \
             WHERE s.id = data.id",
        )
        .bind(ids)
        .bind(identity_ids)
        .bind(token_hashes)
        .bind(created_at)
        .bind(last_seen_at)
        .bind(expires_at)
        .bind(revoked_at)
        .execute(&self.pool)
        .await?;

        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct SessionRow {
    id: Uuid,
    identity_id: Uuid,
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
        session_token_hash: SessionTokenHash(row.session_token_hash),
        created_at: row.created_at,
        last_seen_at: row.last_seen_at,
        expires_at: row.expires_at,
        revoked_at: row.revoked_at,
    }
}

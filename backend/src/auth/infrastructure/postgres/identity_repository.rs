use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Clone)]
pub struct PostgresIdentityRepository {
    pool: PgPool,
}
impl PostgresIdentityRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl IdentityRepository for PostgresIdentityRepository {
    async fn find_by_username(&self, username: &str) -> Result<Option<Identity>, AuthError> {
        let row = sqlx::query_as::<_, IdentityRow>(
            "SELECT id, username, password_hash, role, status, created_at, updated_at \
             FROM identities WHERE username = $1",
        )
        .bind(username)
        .fetch_optional(&self.pool)
        .await?;

        row.map(identity_row_to_identity).transpose()
    }

    async fn find_by_id(&self, id: IdentityId) -> Result<Option<Identity>, AuthError> {
        let row = sqlx::query_as::<_, IdentityRow>(
            "SELECT id, username, password_hash, role, status, created_at, updated_at \
             FROM identities WHERE id = $1",
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        row.map(identity_row_to_identity).transpose()
    }

    async fn find_by_ids(&self, ids: &[IdentityId]) -> Result<Vec<Identity>, AuthError> {
        let ids: Vec<Uuid> = ids.iter().map(|id| id.0).collect();
        let rows = sqlx::query_as::<_, IdentityRow>(
            "SELECT id, username, password_hash, role, status, created_at, updated_at \
             FROM identities WHERE id = ANY($1)",
        )
        .bind(ids)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(identity_row_to_identity).collect()
    }

    async fn create(&self, identity: &Identity) -> Result<(), AuthError> {
        let result = sqlx::query(
            "INSERT INTO identities (id, username, password_hash, role, status, created_at, updated_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(identity.id.0)
        .bind(identity.username.as_str())
        .bind(&identity.password_hash.0)
        .bind(identity.role.as_str())
        .bind(identity.status.as_str())
        .bind(identity.created_at)
        .bind(identity.updated_at)
        .execute(&self.pool)
        .await;

        match result {
            Ok(_) => Ok(()),
            Err(e) => Err(map_identity_insert_error(e)),
        }
    }

    async fn update(&self, identity: &Identity) -> Result<(), AuthError> {
        sqlx::query(
            "UPDATE identities SET password_hash = $1, status = $2, updated_at = $3 \
             WHERE id = $4",
        )
        .bind(&identity.password_hash.0)
        .bind(identity.status.as_str())
        .bind(identity.updated_at)
        .bind(identity.id.0)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn exists_admin(&self) -> Result<bool, AuthError> {
        let row: (bool,) =
            sqlx::query_as("SELECT EXISTS(SELECT 1 FROM identities WHERE role = 'admin')")
                .fetch_one(&self.pool)
                .await?;

        Ok(row.0)
    }
}

fn map_identity_insert_error(err: sqlx::Error) -> AuthError {
    if let sqlx::Error::Database(db_err) = &err
        && db_err.is_unique_violation()
    {
        let constraint = db_err.constraint().unwrap_or("");
        if constraint.contains("username") {
            return AuthError::UsernameTaken;
        }
        if constraint.contains("admin") {
            return AuthError::AdminAlreadyExists;
        }
    }
    AuthError::Database(err)
}

#[derive(sqlx::FromRow)]
struct IdentityRow {
    id: Uuid,
    username: String,
    password_hash: String,
    role: String,
    status: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

fn identity_row_to_identity(row: IdentityRow) -> Result<Identity, AuthError> {
    Ok(Identity {
        id: IdentityId(row.id),
        username: Username::new(&row.username)?,
        password_hash: PasswordHash(row.password_hash),
        role: row.role.parse::<IdentityRole>()?,
        status: row.status.parse::<IdentityStatus>()?,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Clone)]
pub struct PostgresUserProfileRepository {
    pool: PgPool,
}
impl PostgresUserProfileRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl UserProfileRepository for PostgresUserProfileRepository {
    async fn find_by_identity_id(
        &self,
        identity_id: IdentityId,
    ) -> Result<Option<UserProfile>, AuthError> {
        let row = sqlx::query_as::<_, ProfileRow>(
            "SELECT id, identity_id, display_name, created_at, updated_at \
             FROM user_profiles WHERE identity_id = $1",
        )
        .bind(identity_id.0)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(profile_row_to_user_profile))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<UserProfile>, AuthError> {
        let row = sqlx::query_as::<_, ProfileRow>(
            "SELECT id, identity_id, display_name, created_at, updated_at \
             FROM user_profiles WHERE id = $1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(profile_row_to_user_profile))
    }

    async fn create(&self, profile: &UserProfile) -> Result<(), AuthError> {
        sqlx::query(
            "INSERT INTO user_profiles (id, identity_id, display_name, created_at, updated_at) \
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(profile.id)
        .bind(profile.identity_id.0)
        .bind(&profile.display_name)
        .bind(profile.created_at)
        .bind(profile.updated_at)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn list_all(&self) -> Result<Vec<UserProfile>, AuthError> {
        let rows = sqlx::query_as::<_, ProfileRow>(
            "SELECT id, identity_id, display_name, created_at, updated_at \
             FROM user_profiles ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().map(profile_row_to_user_profile).collect())
    }
}

#[derive(sqlx::FromRow)]
struct ProfileRow {
    id: Uuid,
    identity_id: Uuid,
    display_name: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

fn profile_row_to_user_profile(row: ProfileRow) -> UserProfile {
    UserProfile {
        id: row.id,
        identity_id: IdentityId(row.identity_id),
        display_name: row.display_name,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

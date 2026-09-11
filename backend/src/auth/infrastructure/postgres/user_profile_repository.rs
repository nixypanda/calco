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

    async fn list_all_with_identities(&self) -> Result<Vec<UserWithProfile>, AuthError> {
        let rows = sqlx::query_as::<_, ProfileWithIdentityRow>(
            "SELECT p.id AS profile_id, p.identity_id, p.display_name, \
                    p.created_at AS profile_created_at, p.updated_at AS profile_updated_at, \
                    i.username, i.password_hash, i.role, i.status, \
                    i.created_at AS identity_created_at, i.updated_at AS identity_updated_at, \
                    i.last_login_at \
             FROM user_profiles p \
             JOIN identities i ON i.id = p.identity_id \
             ORDER BY p.created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter()
            .map(profile_with_identity_row_to_user_with_profile)
            .collect()
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

#[derive(sqlx::FromRow)]
struct ProfileWithIdentityRow {
    profile_id: Uuid,
    identity_id: Uuid,
    display_name: String,
    profile_created_at: DateTime<Utc>,
    profile_updated_at: DateTime<Utc>,
    username: String,
    password_hash: String,
    role: String,
    status: String,
    identity_created_at: DateTime<Utc>,
    identity_updated_at: DateTime<Utc>,
    last_login_at: Option<DateTime<Utc>>,
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

fn profile_with_identity_row_to_user_with_profile(
    row: ProfileWithIdentityRow,
) -> Result<UserWithProfile, AuthError> {
    Ok(UserWithProfile {
        identity: Identity {
            id: IdentityId(row.identity_id),
            username: Username::new(&row.username)?,
            password_hash: PasswordHash(row.password_hash),
            role: row.role.parse::<IdentityRole>()?,
            status: row.status.parse::<IdentityStatus>()?,
            created_at: row.identity_created_at,
            updated_at: row.identity_updated_at,
            last_login_at: row.last_login_at,
        },
        profile: UserProfile {
            id: row.profile_id,
            identity_id: IdentityId(row.identity_id),
            display_name: row.display_name,
            created_at: row.profile_created_at,
            updated_at: row.profile_updated_at,
        },
    })
}

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
            "SELECT id, username, password_hash, role, status, created_at, updated_at, last_login_at \
             FROM identities WHERE username = $1",
        )
        .bind(username)
        .fetch_optional(&self.pool)
        .await?;

        row.map(identity_row_to_identity).transpose()
    }

    async fn find_by_id(&self, id: IdentityId) -> Result<Option<Identity>, AuthError> {
        let row = sqlx::query_as::<_, IdentityRow>(
            "SELECT id, username, password_hash, role, status, created_at, updated_at, last_login_at \
             FROM identities WHERE id = $1",
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        row.map(identity_row_to_identity).transpose()
    }

    async fn create(&self, identity: &Identity) -> Result<(), AuthError> {
        let result = sqlx::query(
            "INSERT INTO identities (id, username, password_hash, role, status, created_at, updated_at, last_login_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(identity.id.0)
        .bind(identity.username.as_str())
        .bind(&identity.password_hash.0)
        .bind(identity.role.as_str())
        .bind(identity.status.as_str())
        .bind(identity.created_at)
        .bind(identity.updated_at)
        .bind(identity.last_login_at)
        .execute(&self.pool)
        .await;

        match result {
            Ok(_) => Ok(()),
            Err(e) => Err(map_identity_insert_error(e)),
        }
    }

    async fn update(&self, identity: &Identity) -> Result<(), AuthError> {
        sqlx::query(
            "UPDATE identities SET password_hash = $1, status = $2, updated_at = $3, last_login_at = $4 \
             WHERE id = $5",
        )
        .bind(&identity.password_hash.0)
        .bind(identity.status.as_str())
        .bind(identity.updated_at)
        .bind(identity.last_login_at)
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
    last_login_at: Option<DateTime<Utc>>,
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
        last_login_at: row.last_login_at,
    })
}

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

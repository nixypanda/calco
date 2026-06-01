use argon2::Argon2;
use argon2::password_hash::{
    PasswordHash as ArgonPasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};
use chrono::{DateTime, Utc};
use std::sync::Arc;
use uuid::Uuid;

use crate::config::AppConfig;
use crate::domain::auth::*;

pub struct LoginResult {
    pub identity: Identity,
    pub profile: Option<UserProfile>,
    pub session_token: SessionToken,
}

pub struct SessionResult {
    pub identity: Identity,
    pub profile: Option<UserProfile>,
}

pub struct CreatedUser {
    pub identity: Identity,
    pub profile: UserProfile,
}

#[derive(Clone)]
pub struct AuthBootstrapServices {
    identity_repo: Arc<dyn IdentityRepository>,
    session_repo: Arc<dyn SessionRepository>,
    config: AppConfig,
}

impl AuthBootstrapServices {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepository>,
        session_repo: Arc<dyn SessionRepository>,
        config: AppConfig,
    ) -> Self {
        Self {
            identity_repo,
            session_repo,
            config,
        }
    }

    pub async fn admin_exists(&self) -> Result<bool, AuthError> {
        self.identity_repo.admin_exists().await
    }

    pub async fn create_bootstrap_admin(
        &self,
        username: &str,
        password: &str,
    ) -> Result<LoginResult, AuthError> {
        if self.identity_repo.admin_exists().await? {
            return Err(AuthError::AdminAlreadyExists);
        }

        let username = normalize_username(username)?;
        validate_password(password)?;

        let salt = SaltString::generate(&mut rand::rngs::OsRng);
        let argon2 = Argon2::default();
        let hash = argon2
            .hash_password(password.as_bytes(), &salt)
            .map_err(AuthError::PasswordHash)?
            .to_string();

        let now = Utc::now();
        let identity = Identity {
            id: IdentityId::new(),
            username: Username(username),
            password_hash: PasswordHash(hash),
            role: IdentityRole::Admin,
            status: IdentityStatus::Active,
            created_at: now,
            updated_at: now,
            last_login_at: None,
        };

        self.identity_repo.create(&identity).await?;

        let (session_token, session) = create_session(&identity, &self.config, now)?;
        self.session_repo.create(&session).await?;

        Ok(LoginResult {
            identity,
            profile: None,
            session_token,
        })
    }
}

#[derive(Clone)]
pub struct AuthSessionServices {
    identity_repo: Arc<dyn IdentityRepository>,
    session_repo: Arc<dyn SessionRepository>,
    profile_repo: Arc<dyn UserProfileRepository>,
    config: AppConfig,
}

impl AuthSessionServices {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepository>,
        session_repo: Arc<dyn SessionRepository>,
        profile_repo: Arc<dyn UserProfileRepository>,
        config: AppConfig,
    ) -> Self {
        Self {
            identity_repo,
            session_repo,
            profile_repo,
            config,
        }
    }

    pub async fn login(&self, username: &str, password: &str) -> Result<LoginResult, AuthError> {
        let username = normalize_username(username).map_err(|_| AuthError::InvalidCredentials)?;
        let identity = self
            .identity_repo
            .find_by_username(&username)
            .await?
            .ok_or(AuthError::InvalidCredentials)?;

        if !identity.is_active() {
            return Err(AuthError::IdentityDisabled);
        }

        let parsed_hash =
            ArgonPasswordHash::new(&identity.password_hash.0).map_err(AuthError::PasswordHash)?;
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed_hash)
            .map_err(|_| AuthError::InvalidCredentials)?;

        let now = Utc::now();
        let updated_identity = identity.record_login(now);
        self.identity_repo.update(&updated_identity).await?;

        let (session_token, session) = create_session(&updated_identity, &self.config, now)?;
        self.session_repo.create(&session).await?;

        let profile = if updated_identity.role == IdentityRole::User {
            self.profile_repo
                .find_by_identity_id(updated_identity.id)
                .await?
        } else {
            None
        };

        Ok(LoginResult {
            identity: updated_identity,
            profile,
            session_token,
        })
    }

    pub async fn get_session(&self, raw_token: &str) -> Result<SessionResult, AuthError> {
        let token_hash = hash_session_token(raw_token);
        let session = self
            .session_repo
            .find_by_token_hash(&token_hash)
            .await?
            .ok_or(AuthError::SessionNotFound)?;

        let now = Utc::now();
        session.ensure_usable(now)?;

        let identity = self
            .identity_repo
            .find_by_id(session.identity_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        if !identity.is_active() {
            return Err(AuthError::IdentityDisabled);
        }

        if session
            .should_refresh_last_seen(now, chrono::Duration::seconds(LAST_SEEN_REFRESH_SECONDS))
        {
            let session = session.record_seen(now);
            let _ = self.session_repo.update(&session).await;
        }

        let profile = if identity.role == IdentityRole::User {
            self.profile_repo.find_by_identity_id(identity.id).await?
        } else {
            None
        };

        Ok(SessionResult { identity, profile })
    }

    pub async fn logout(&self, raw_token: &str) -> Result<(), AuthError> {
        let token_hash = hash_session_token(raw_token);
        let session = self
            .session_repo
            .find_by_token_hash(&token_hash)
            .await?
            .ok_or(AuthError::SessionNotFound)?;

        let session = session.revoke(Utc::now());
        self.session_repo.update(&session).await
    }
}

#[derive(Clone)]
pub struct AdminUserServices {
    identity_repo: Arc<dyn IdentityRepository>,
    session_repo: Arc<dyn SessionRepository>,
    profile_repo: Arc<dyn UserProfileRepository>,
}

impl AdminUserServices {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepository>,
        session_repo: Arc<dyn SessionRepository>,
        profile_repo: Arc<dyn UserProfileRepository>,
    ) -> Self {
        Self {
            identity_repo,
            session_repo,
            profile_repo,
        }
    }

    pub async fn list_users(&self) -> Result<Vec<UserWithProfile>, AuthError> {
        self.profile_repo.list_all_with_identities().await
    }

    pub async fn create_user(
        &self,
        username: &str,
        display_name: &str,
        initial_password: &str,
    ) -> Result<CreatedUser, AuthError> {
        let username = normalize_username(username)?;
        validate_password(initial_password)?;

        if self
            .identity_repo
            .find_by_username(&username)
            .await?
            .is_some()
        {
            return Err(AuthError::UsernameTaken);
        }

        let salt = argon2::password_hash::SaltString::generate(&mut rand::rngs::OsRng);
        let argon2 = argon2::Argon2::default();
        let hash = argon2
            .hash_password(initial_password.as_bytes(), &salt)
            .map_err(AuthError::PasswordHash)?
            .to_string();

        let now = Utc::now();
        let identity = Identity {
            id: IdentityId::new(),
            username: Username(username),
            password_hash: PasswordHash(hash),
            role: IdentityRole::User,
            status: IdentityStatus::Active,
            created_at: now,
            updated_at: now,
            last_login_at: None,
        };

        self.identity_repo.create(&identity).await?;

        let profile = UserProfile {
            id: Uuid::new_v4(),
            identity_id: identity.id,
            display_name: display_name.to_string(),
            created_at: now,
            updated_at: now,
        };
        self.profile_repo.create(&profile).await?;

        Ok(CreatedUser { identity, profile })
    }

    pub async fn reset_password(&self, user_id: Uuid, new_password: &str) -> Result<(), AuthError> {
        let profile = self
            .profile_repo
            .find_by_id(user_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        validate_password(new_password)?;

        let salt = argon2::password_hash::SaltString::generate(&mut rand::rngs::OsRng);
        let argon2 = argon2::Argon2::default();
        let hash = argon2
            .hash_password(new_password.as_bytes(), &salt)
            .map_err(AuthError::PasswordHash)?
            .to_string();

        let identity = self
            .identity_repo
            .find_by_id(profile.identity_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;
        let identity = identity.change_password(PasswordHash(hash), Utc::now());

        self.identity_repo.update(&identity).await?;
        self.revoke_sessions_for_identity(profile.identity_id).await
    }

    pub async fn disable_user(&self, user_id: Uuid) -> Result<(), AuthError> {
        let profile = self
            .profile_repo
            .find_by_id(user_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        let identity = self
            .identity_repo
            .find_by_id(profile.identity_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;
        let identity = identity.disable(Utc::now());

        self.identity_repo.update(&identity).await?;
        self.revoke_sessions_for_identity(profile.identity_id).await
    }

    pub async fn enable_user(&self, user_id: Uuid) -> Result<(), AuthError> {
        let profile = self
            .profile_repo
            .find_by_id(user_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        let identity = self
            .identity_repo
            .find_by_id(profile.identity_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;
        let identity = identity.enable(Utc::now());

        self.identity_repo.update(&identity).await
    }

    async fn revoke_sessions_for_identity(&self, identity_id: IdentityId) -> Result<(), AuthError> {
        let now = Utc::now();
        let sessions = self.session_repo.find_by_identity_id(identity_id).await?;
        let revoked_sessions: Vec<Session> = sessions
            .into_iter()
            .filter(|session| session.revoked_at.is_none())
            .map(|session| session.revoke(now))
            .collect();

        self.session_repo.update_many(&revoked_sessions).await
    }
}

fn create_session(
    identity: &Identity,
    config: &AppConfig,
    now: DateTime<Utc>,
) -> Result<(SessionToken, Session), AuthError> {
    use rand::RngCore;
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    let raw_token = SessionToken(base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
        bytes,
    ));
    let token_hash = SessionTokenHash(hash_session_token(&raw_token.0));

    let session = Session {
        id: Uuid::new_v4(),
        identity_id: identity.id,
        session_token_hash: token_hash,
        created_at: now,
        last_seen_at: now,
        expires_at: now + chrono::Duration::seconds(config.session_ttl_seconds),
        revoked_at: None,
    };

    Ok((raw_token, session))
}

fn hash_session_token(token: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

const USERNAME_MAX_LEN: usize = 64;
const PASSWORD_MIN_LEN: usize = 8;
const PASSWORD_MAX_LEN: usize = 256;
const LAST_SEEN_REFRESH_SECONDS: i64 = 60;

fn normalize_username(raw: &str) -> Result<String, AuthError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > USERNAME_MAX_LEN {
        return Err(AuthError::InvalidCredentials);
    }
    if trimmed.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(AuthError::InvalidCredentials);
    }
    Ok(trimmed.to_string())
}

fn validate_password(password: &str) -> Result<(), AuthError> {
    if password.len() < PASSWORD_MIN_LEN || password.len() > PASSWORD_MAX_LEN {
        return Err(AuthError::InvalidCredentials);
    }
    Ok(())
}

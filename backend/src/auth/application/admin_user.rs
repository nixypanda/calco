use std::sync::Arc;

use argon2::Argon2;
use argon2::password_hash::{PasswordHasher, SaltString};
use chrono::Utc;
use uuid::Uuid;

use super::{CreatedUser, validate_password};
use crate::auth::domain::*;

#[derive(Clone)]
pub struct AdminUserService {
    identity_repo: Arc<dyn IdentityRepository>,
    session_repo: Arc<dyn SessionRepository>,
    profile_repo: Arc<dyn UserProfileRepository>,
}

impl AdminUserService {
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

    pub async fn get_user(&self, user_id: Uuid) -> Result<UserWithProfile, AuthError> {
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
        Ok(UserWithProfile { identity, profile })
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
        let username = Username::new(username)?;
        validate_password(initial_password)?;

        if self
            .identity_repo
            .find_by_username(username.as_str())
            .await?
            .is_some()
        {
            return Err(AuthError::UsernameTaken);
        }

        let salt = SaltString::generate(&mut rand::rngs::OsRng);
        let hash = Argon2::default()
            .hash_password(initial_password.as_bytes(), &salt)
            .map_err(AuthError::PasswordHash)?
            .to_string();

        let now = Utc::now();
        let identity = Identity {
            id: IdentityId::new(),
            username,
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

        let salt = SaltString::generate(&mut rand::rngs::OsRng);
        let hash = Argon2::default()
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
        let sessions = self.session_repo.list_by_identity_id(identity_id).await?;
        let revoked_sessions: Vec<Session> = sessions
            .into_iter()
            .filter(|session| session.revoked_at.is_none())
            .map(|session| session.revoke(now))
            .collect();

        self.session_repo.update_many(&revoked_sessions).await
    }
}

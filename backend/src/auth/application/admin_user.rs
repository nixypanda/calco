use std::collections::HashMap;
use std::sync::Arc;

use chrono::Utc;
use uuid::Uuid;

use super::CreatedUser;
use crate::auth::domain::*;

#[derive(Clone)]
pub struct AdminUserService {
    identity_repo: Arc<dyn IdentityRepository>,
    profile_repo: Arc<dyn UserProfileRepository>,
    password_hasher: Arc<dyn PasswordHasher>,
}

impl AdminUserService {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepository>,
        profile_repo: Arc<dyn UserProfileRepository>,
        password_hasher: Arc<dyn PasswordHasher>,
    ) -> Self {
        Self {
            identity_repo,
            profile_repo,
            password_hasher,
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
        let profiles = self.profile_repo.list_all().await?;
        let identity_ids: Vec<IdentityId> =
            profiles.iter().map(|profile| profile.identity_id).collect();
        let identities = self.identity_repo.find_by_ids(&identity_ids).await?;
        let mut identities_by_id: HashMap<IdentityId, Identity> = identities
            .into_iter()
            .map(|identity| (identity.id, identity))
            .collect();

        profiles
            .into_iter()
            .map(|profile| {
                let identity = identities_by_id
                    .remove(&profile.identity_id)
                    .ok_or(AuthError::IdentityNotFound)?;
                Ok(UserWithProfile { identity, profile })
            })
            .collect()
    }

    pub async fn create_user(
        &self,
        username: &str,
        display_name: &str,
        initial_password: &str,
    ) -> Result<CreatedUser, AuthError> {
        let username = Username::new(username)?;
        let password = NewPassword::new(initial_password)?;

        if self
            .identity_repo
            .find_by_username(username.as_str())
            .await?
            .is_some()
        {
            return Err(AuthError::UsernameTaken);
        }

        let password_hash = self.password_hasher.hash(&password)?;

        let now = Utc::now();
        let identity = Identity::new_user(username, password_hash, now);

        self.identity_repo.create(&identity).await?;

        let profile = UserProfile::new(identity.id, display_name, now);
        self.profile_repo.create(&profile).await?;

        Ok(CreatedUser { identity, profile })
    }

    pub async fn reset_password(&self, user_id: Uuid, new_password: &str) -> Result<(), AuthError> {
        let profile = self
            .profile_repo
            .find_by_id(user_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        let password = NewPassword::new(new_password)?;
        let password_hash = self.password_hasher.hash(&password)?;

        let identity = self
            .identity_repo
            .find_by_id(profile.identity_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;
        let identity = identity.change_password(password_hash, Utc::now());

        self.identity_repo.update(&identity).await
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

        self.identity_repo.update(&identity).await
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
}

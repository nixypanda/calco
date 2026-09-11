use std::sync::Arc;

use chrono::Utc;

use super::LoginResult;
use crate::auth::domain::*;

#[derive(Clone)]
pub struct AuthBootstrapService {
    identity_repo: Arc<dyn IdentityRepository>,
    session_repo: Arc<dyn SessionRepository>,
    password_hasher: Arc<dyn PasswordHasher>,
    config: SessionCookieConfig,
}

impl AuthBootstrapService {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepository>,
        session_repo: Arc<dyn SessionRepository>,
        password_hasher: Arc<dyn PasswordHasher>,
        config: SessionCookieConfig,
    ) -> Self {
        Self {
            identity_repo,
            session_repo,
            password_hasher,
            config,
        }
    }

    pub async fn admin_exists(&self) -> Result<bool, AuthError> {
        self.identity_repo.exists_admin().await
    }

    pub async fn create_bootstrap_admin(
        &self,
        username: &str,
        password: &str,
    ) -> Result<LoginResult, AuthError> {
        if self.identity_repo.exists_admin().await? {
            return Err(AuthError::AdminAlreadyExists);
        }

        let username = Username::new(username)?;
        let password = NewPassword::new(password)?;
        let password_hash = self.password_hasher.hash(&password)?;

        let now = Utc::now();
        let identity = Identity {
            id: IdentityId::new(),
            username,
            password_hash,
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

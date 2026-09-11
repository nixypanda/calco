use std::sync::Arc;

use chrono::Utc;

use super::{LAST_SEEN_REFRESH_SECONDS, LoginResult, SessionResult};
use crate::auth::domain::*;

#[derive(Clone)]
pub struct AuthSessionService {
    identity_repo: Arc<dyn IdentityRepository>,
    session_repo: Arc<dyn SessionRepository>,
    profile_repo: Arc<dyn UserProfileRepository>,
    credential_verifier: Arc<dyn CredentialVerifier>,
    session_policy: SessionPolicy,
}

impl AuthSessionService {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepository>,
        session_repo: Arc<dyn SessionRepository>,
        profile_repo: Arc<dyn UserProfileRepository>,
        credential_verifier: Arc<dyn CredentialVerifier>,
        session_policy: SessionPolicy,
    ) -> Self {
        Self {
            identity_repo,
            session_repo,
            profile_repo,
            credential_verifier,
            session_policy,
        }
    }

    pub async fn login(&self, username: &str, password: &str) -> Result<LoginResult, AuthError> {
        let username = Username::new(username).map_err(|_| AuthError::InvalidCredentials)?;
        let identity = self
            .identity_repo
            .find_by_username(username.as_str())
            .await?
            .ok_or(AuthError::InvalidCredentials)?;

        if !identity.is_active() {
            return Err(AuthError::IdentityDisabled);
        }

        let password = Password::new(password);
        if !self
            .credential_verifier
            .verify(&password, &identity.password_hash)?
        {
            return Err(AuthError::InvalidCredentials);
        }

        let now = Utc::now();
        let (session_token, session) = create_session(&identity, &self.session_policy, now)?;
        self.session_repo.create(&session).await?;

        let profile = if identity.role == IdentityRole::User {
            self.profile_repo.find_by_identity_id(identity.id).await?
        } else {
            None
        };

        Ok(LoginResult {
            identity,
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

        let identity = self
            .identity_repo
            .find_by_id(session.identity_id)
            .await?
            .ok_or(AuthError::IdentityNotFound)?;

        let now = Utc::now();
        session.ensure_usable_for(&identity, now)?;

        if !identity.is_active() {
            return Err(AuthError::IdentityDisabled);
        }

        if session
            .should_refresh_last_seen(now, chrono::Duration::seconds(LAST_SEEN_REFRESH_SECONDS))
        {
            let session = session.record_seen(now);
            // Best-effort last-seen heartbeat: failure here must not break session validation.
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

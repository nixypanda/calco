use std::sync::Arc;

use chrono::Utc;

use super::{LAST_SEEN_REFRESH_SECONDS, LoginResult, SessionResult};
use crate::auth::domain::*;

#[derive(Clone)]
pub struct AuthSessionService {
    identity_repo: Arc<dyn IdentityRepo>,
    session_repo: Arc<dyn SessionRepo>,
    profile_repo: Arc<dyn UserProfileRepo>,
    credential_verifier: Arc<dyn CredentialVerifier>,
    session_policy: SessionPolicy,
}

impl AuthSessionService {
    pub fn new(
        identity_repo: Arc<dyn IdentityRepo>,
        session_repo: Arc<dyn SessionRepo>,
        profile_repo: Arc<dyn UserProfileRepo>,
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
            // Best-effort last-seen heartbeat: failure here must not break session validation.
            let refreshed = session.record_seen(now);
            let _ = self.session_repo.update(&refreshed).await;
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

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use chrono::Duration;
    use std::sync::Mutex;
    use uuid::Uuid;

    #[derive(Default)]
    struct MockSessionRepo {
        sessions: Mutex<Vec<Session>>,
        updates: Mutex<usize>,
    }

    impl MockSessionRepo {
        fn with_session(session: Session) -> Self {
            Self {
                sessions: Mutex::new(vec![session]),
                updates: Mutex::new(0),
            }
        }

        fn stored(&self, id: Uuid) -> Session {
            self.sessions
                .lock()
                .unwrap()
                .iter()
                .find(|session| session.id == id)
                .cloned()
                .expect("stored session")
        }

        fn update_count(&self) -> usize {
            *self.updates.lock().unwrap()
        }
    }

    #[async_trait]
    impl SessionRepo for MockSessionRepo {
        async fn create(&self, session: &Session) -> Result<(), AuthError> {
            self.sessions.lock().unwrap().push(session.clone());
            Ok(())
        }

        async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<Session>, AuthError> {
            Ok(self
                .sessions
                .lock()
                .unwrap()
                .iter()
                .find(|session| session.session_token_hash.0 == token_hash)
                .cloned())
        }

        async fn update(&self, session: &Session) -> Result<(), AuthError> {
            *self.updates.lock().unwrap() += 1;
            let mut sessions = self.sessions.lock().unwrap();
            if let Some(stored) = sessions.iter_mut().find(|stored| stored.id == session.id) {
                *stored = session.clone();
            }
            Ok(())
        }
    }

    #[derive(Default)]
    struct MockIdentityRepo {
        identities: Mutex<Vec<Identity>>,
    }

    impl MockIdentityRepo {
        fn with_identities(identities: Vec<Identity>) -> Self {
            Self {
                identities: Mutex::new(identities),
            }
        }
    }

    #[async_trait]
    impl IdentityRepo for MockIdentityRepo {
        async fn find_by_username(&self, username: &str) -> Result<Option<Identity>, AuthError> {
            Ok(self
                .identities
                .lock()
                .unwrap()
                .iter()
                .find(|identity| identity.username.as_str() == username)
                .cloned())
        }

        async fn find_by_id(&self, id: IdentityId) -> Result<Option<Identity>, AuthError> {
            Ok(self
                .identities
                .lock()
                .unwrap()
                .iter()
                .find(|identity| identity.id == id)
                .cloned())
        }

        async fn find_by_ids(&self, ids: &[IdentityId]) -> Result<Vec<Identity>, AuthError> {
            Ok(self
                .identities
                .lock()
                .unwrap()
                .iter()
                .filter(|identity| ids.contains(&identity.id))
                .cloned()
                .collect())
        }

        async fn create(&self, identity: &Identity) -> Result<(), AuthError> {
            self.identities.lock().unwrap().push(identity.clone());
            Ok(())
        }

        async fn update(&self, identity: &Identity) -> Result<(), AuthError> {
            let mut identities = self.identities.lock().unwrap();
            if let Some(stored) = identities
                .iter_mut()
                .find(|stored| stored.id == identity.id)
            {
                *stored = identity.clone();
            }
            Ok(())
        }

        async fn exists_admin(&self) -> Result<bool, AuthError> {
            Ok(self
                .identities
                .lock()
                .unwrap()
                .iter()
                .any(|identity| identity.role == IdentityRole::Admin))
        }
    }

    #[derive(Default)]
    struct MockUserProfileRepo {
        profiles: Mutex<Vec<UserProfile>>,
    }

    #[async_trait]
    impl UserProfileRepo for MockUserProfileRepo {
        async fn find_by_identity_id(
            &self,
            identity_id: IdentityId,
        ) -> Result<Option<UserProfile>, AuthError> {
            Ok(self
                .profiles
                .lock()
                .unwrap()
                .iter()
                .find(|profile| profile.identity_id == identity_id)
                .cloned())
        }

        async fn find_by_id(&self, id: Uuid) -> Result<Option<UserProfile>, AuthError> {
            Ok(self
                .profiles
                .lock()
                .unwrap()
                .iter()
                .find(|profile| profile.id == id)
                .cloned())
        }

        async fn create(&self, profile: &UserProfile) -> Result<(), AuthError> {
            self.profiles.lock().unwrap().push(profile.clone());
            Ok(())
        }

        async fn list_all(&self) -> Result<Vec<UserProfile>, AuthError> {
            Ok(self.profiles.lock().unwrap().clone())
        }
    }

    struct MockCredentialVerifier;

    impl CredentialVerifier for MockCredentialVerifier {
        fn verify(
            &self,
            _password: &Password,
            _expected_hash: &PasswordHash,
        ) -> Result<bool, AuthError> {
            Ok(false)
        }
    }

    fn service_with_session(
        identity: Identity,
        session_repo: Arc<MockSessionRepo>,
    ) -> AuthSessionService {
        AuthSessionService::new(
            Arc::new(MockIdentityRepo::with_identities(vec![identity])),
            session_repo,
            Arc::new(MockUserProfileRepo::default()),
            Arc::new(MockCredentialVerifier),
            SessionPolicy::new(Duration::hours(1)).unwrap(),
        )
    }

    #[tokio::test]
    async fn get_session_refreshes_aged_last_seen() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("session-refresh").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let policy = SessionPolicy::new(Duration::hours(1)).unwrap();
        let (token, session) = create_session(&identity, &policy, now).unwrap();

        let aged = Session {
            last_seen_at: now - Duration::minutes(2),
            ..session.clone()
        };
        let session_repo = Arc::new(MockSessionRepo::with_session(aged.clone()));
        let service = service_with_session(identity.clone(), session_repo.clone());

        service.get_session(&token.0).await.unwrap();
        assert_eq!(session_repo.update_count(), 1);
        assert!(session_repo.stored(session.id).last_seen_at > aged.last_seen_at);

        let recent = Session {
            last_seen_at: Utc::now(),
            ..session
        };
        let session_repo = Arc::new(MockSessionRepo::with_session(recent));
        let service = service_with_session(identity, session_repo.clone());
        service.get_session(&token.0).await.unwrap();
        assert_eq!(session_repo.update_count(), 0);
    }
}

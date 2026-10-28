use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};

use crate::auth::domain::*;

const LAST_USED_REFRESH_SECONDS: i64 = 60;
const MAX_API_KEY_TOKEN_LEN: usize = 256;

pub struct CreatedApiKey {
    pub api_key: ApiKey,
    pub token: ApiKeyToken,
}

pub struct ApiKeyAuth {
    pub identity: Identity,
    pub profile: UserProfile,
    pub scope: ApiKeyScope,
}

#[derive(Clone)]
pub struct ApiKeyService {
    api_key_repo: Arc<dyn ApiKeyRepo>,
    identity_repo: Arc<dyn IdentityRepo>,
    profile_repo: Arc<dyn UserProfileRepo>,
}

impl ApiKeyService {
    pub fn new(
        api_key_repo: Arc<dyn ApiKeyRepo>,
        identity_repo: Arc<dyn IdentityRepo>,
        profile_repo: Arc<dyn UserProfileRepo>,
    ) -> Self {
        Self {
            api_key_repo,
            identity_repo,
            profile_repo,
        }
    }

    pub async fn create(
        &self,
        identity: &Identity,
        name: &str,
        scope: ApiKeyScope,
        expires_in_days: Option<i64>,
        now: DateTime<Utc>,
    ) -> Result<CreatedApiKey, AuthError> {
        if identity.role != IdentityRole::User || !identity.is_active() {
            return Err(AuthError::Unauthorized);
        }

        let name = ApiKeyName::new(name)?;
        let expires_at = match expires_in_days {
            Some(days) if (1..=3650).contains(&days) => Some(now + Duration::days(days)),
            Some(_) => return Err(AuthError::InvalidApiKeyExpiry),
            None => None,
        };

        let keys = self.api_key_repo.list_by_identity_id(identity.id).await?;
        ensure_api_key_capacity(&keys, identity, now)?;

        let (token, api_key) = create_api_key(identity, name, scope, expires_at, now)?;
        self.api_key_repo.create(&api_key).await?;

        Ok(CreatedApiKey { api_key, token })
    }

    pub async fn list(&self, identity: &Identity) -> Result<Vec<ApiKey>, AuthError> {
        let keys = self.api_key_repo.list_by_identity_id(identity.id).await?;

        Ok(keys
            .into_iter()
            .filter(|key| {
                key.revoked_at.is_none()
                    && key.identity_security_stamp == identity.session_security_stamp
            })
            .collect())
    }

    pub async fn revoke(&self, identity: &Identity, key_id: ApiKeyId) -> Result<(), AuthError> {
        let key = self
            .api_key_repo
            .find_by_id_and_identity_id(key_id, identity.id)
            .await?
            .ok_or(AuthError::ApiKeyNotFound)?;

        if key.revoked_at.is_some() {
            return Ok(());
        }

        let key = key.revoke(Utc::now());
        self.api_key_repo.update(&key).await?;

        Ok(())
    }

    pub async fn authenticate(
        &self,
        raw_token: &str,
        now: DateTime<Utc>,
    ) -> Result<ApiKeyAuth, AuthError> {
        if !raw_token.starts_with(API_KEY_TOKEN_PREFIX)
            || raw_token.len() <= API_KEY_TOKEN_PREFIX.len()
            || raw_token.len() > MAX_API_KEY_TOKEN_LEN
        {
            return Err(AuthError::InvalidApiKey);
        }

        let token_hash = hash_api_key_token(raw_token);
        let api_key = self
            .api_key_repo
            .find_by_token_hash(&token_hash)
            .await?
            .ok_or(AuthError::InvalidApiKey)?;

        let identity = self
            .identity_repo
            .find_by_id(api_key.identity_id)
            .await?
            .ok_or(AuthError::InvalidApiKey)?;

        if identity.role != IdentityRole::User || !identity.is_active() {
            return Err(AuthError::InvalidApiKey);
        }

        api_key.ensure_usable_for(&identity, now)?;

        let profile = self
            .profile_repo
            .find_by_identity_id(identity.id)
            .await?
            .ok_or(AuthError::InvalidApiKey)?;

        if api_key.should_refresh_last_used(now, Duration::seconds(LAST_USED_REFRESH_SECONDS)) {
            // Best-effort heartbeat: failure here must not break authentication.
            let refreshed = api_key.record_used(now);
            let _ = self.api_key_repo.update(&refreshed).await;
        }

        Ok(ApiKeyAuth {
            identity,
            profile,
            scope: api_key.scope,
        })
    }
}

#[cfg(test)]
mod tests {
    use rstest::rstest;

    use super::*;
    use async_trait::async_trait;
    use std::sync::Mutex;
    use uuid::Uuid;

    #[derive(Default)]
    struct MockApiKeyRepo {
        keys: Mutex<Vec<ApiKey>>,
        updates: Mutex<usize>,
    }

    impl MockApiKeyRepo {
        fn with_keys(keys: Vec<ApiKey>) -> Self {
            Self {
                keys: Mutex::new(keys),
                updates: Mutex::new(0),
            }
        }

        fn stored(&self, id: ApiKeyId) -> ApiKey {
            self.keys
                .lock()
                .unwrap()
                .iter()
                .find(|key| key.id == id)
                .cloned()
                .expect("stored api key")
        }

        fn update_count(&self) -> usize {
            *self.updates.lock().unwrap()
        }
    }

    #[async_trait]
    impl ApiKeyRepo for MockApiKeyRepo {
        async fn create(&self, key: &ApiKey) -> Result<(), AuthError> {
            self.keys.lock().unwrap().push(key.clone());
            Ok(())
        }

        async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<ApiKey>, AuthError> {
            Ok(self
                .keys
                .lock()
                .unwrap()
                .iter()
                .find(|key| key.token_hash.0 == token_hash)
                .cloned())
        }

        async fn find_by_id(&self, id: ApiKeyId) -> Result<Option<ApiKey>, AuthError> {
            Ok(self
                .keys
                .lock()
                .unwrap()
                .iter()
                .find(|key| key.id == id)
                .cloned())
        }

        async fn find_by_id_and_identity_id(
            &self,
            id: ApiKeyId,
            identity_id: IdentityId,
        ) -> Result<Option<ApiKey>, AuthError> {
            Ok(self
                .keys
                .lock()
                .unwrap()
                .iter()
                .find(|key| key.id == id && key.identity_id == identity_id)
                .cloned())
        }

        async fn list_by_identity_id(
            &self,
            identity_id: IdentityId,
        ) -> Result<Vec<ApiKey>, AuthError> {
            Ok(self
                .keys
                .lock()
                .unwrap()
                .iter()
                .filter(|key| key.identity_id == identity_id)
                .cloned()
                .collect())
        }

        async fn update(&self, key: &ApiKey) -> Result<(), AuthError> {
            *self.updates.lock().unwrap() += 1;
            let mut keys = self.keys.lock().unwrap();
            if let Some(stored) = keys.iter_mut().find(|stored| stored.id == key.id) {
                *stored = key.clone();
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

    impl MockUserProfileRepo {
        fn with_profiles(profiles: Vec<UserProfile>) -> Self {
            Self {
                profiles: Mutex::new(profiles),
            }
        }
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

    fn create_key(identity: &Identity, name: &str, now: DateTime<Utc>) -> (ApiKeyToken, ApiKey) {
        create_api_key(
            identity,
            ApiKeyName::new(name).unwrap(),
            ApiKeyScope::Read,
            None,
            now,
        )
        .unwrap()
    }

    fn identity_and_key(now: DateTime<Utc>) -> (Identity, ApiKey, ApiKeyToken) {
        let identity = Identity::new_user(
            Username::new("api-key-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let (token, key) = create_key(&identity, "Script", now);
        (identity, key, token)
    }

    fn service(
        api_key_repo: Arc<MockApiKeyRepo>,
        identity_repo: Arc<MockIdentityRepo>,
        profile_repo: Arc<MockUserProfileRepo>,
    ) -> ApiKeyService {
        ApiKeyService::new(api_key_repo, identity_repo, profile_repo)
    }

    #[rstest]
    #[case::zero_days(0)]
    #[case::negative_day(-1)]
    #[case::above_maximum(3651)]
    #[tokio::test]
    async fn create_rejects_invalid_expiry_days(#[case] days: i64) {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("expiry-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let api_key_repo = Arc::new(MockApiKeyRepo::default());
        let service = service(
            api_key_repo.clone(),
            Arc::new(MockIdentityRepo::default()),
            Arc::new(MockUserProfileRepo::default()),
        );

        let result = service
            .create(&identity, "Key", ApiKeyScope::Read, Some(days), now)
            .await;

        match result {
            Err(AuthError::InvalidApiKeyExpiry) => {}
            Err(error) => panic!("{days} days returned {error:?}"),
            Ok(_) => panic!("{days} days should have been rejected"),
        }
        assert!(
            api_key_repo.keys.lock().unwrap().is_empty(),
            "rejected expiry of {days} days must not store a key"
        );
    }

    #[rstest]
    #[case::minimum_days(1)]
    #[case::maximum_days(3650)]
    #[tokio::test]
    async fn create_accepts_valid_expiry_days(#[case] days: i64) {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("expiry-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let api_key_repo = Arc::new(MockApiKeyRepo::default());
        let service = service(
            api_key_repo.clone(),
            Arc::new(MockIdentityRepo::default()),
            Arc::new(MockUserProfileRepo::default()),
        );

        let created = service
            .create(&identity, "Key", ApiKeyScope::Read, Some(days), now)
            .await
            .unwrap();

        assert_eq!(created.api_key.expires_at, Some(now + Duration::days(days)));
        assert_eq!(
            api_key_repo.stored(created.api_key.id).expires_at,
            Some(now + Duration::days(days))
        );
    }

    #[tokio::test]
    async fn create_rejects_when_active_key_limit_reached() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("limit-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let mut keys: Vec<ApiKey> = (0..MAX_ACTIVE_API_KEYS)
            .map(|index| create_key(&identity, &format!("Active {index}"), now).1)
            .collect();
        let (_, mut expired) = create_key(&identity, "Expired", now);
        expired.expires_at = Some(now - Duration::seconds(1));
        let (_, revoked) = create_key(&identity, "Revoked", now);
        let revoked = revoked.revoke(now);
        let (_, mut old_stamp) = create_key(&identity, "Old stamp", now);
        old_stamp.identity_security_stamp = SessionSecurityStamp::new();
        keys.extend([expired, revoked, old_stamp]);

        let api_key_repo = Arc::new(MockApiKeyRepo::with_keys(keys));
        let service = service(
            api_key_repo.clone(),
            Arc::new(MockIdentityRepo::default()),
            Arc::new(MockUserProfileRepo::default()),
        );

        let result = service
            .create(&identity, "Overflow", ApiKeyScope::Read, None, now)
            .await;

        assert!(matches!(result, Err(AuthError::ApiKeyLimitReached)));
        assert_eq!(
            api_key_repo.keys.lock().unwrap().len(),
            MAX_ACTIVE_API_KEYS + 3
        );
    }

    #[tokio::test]
    async fn revoke_is_idempotent() {
        let now = Utc::now();
        let (identity, key, _) = identity_and_key(now);
        let api_key_repo = Arc::new(MockApiKeyRepo::with_keys(vec![key.clone()]));
        let service = service(
            api_key_repo.clone(),
            Arc::new(MockIdentityRepo::default()),
            Arc::new(MockUserProfileRepo::default()),
        );

        service.revoke(&identity, key.id).await.unwrap();
        assert!(api_key_repo.stored(key.id).revoked_at.is_some());

        service.revoke(&identity, key.id).await.unwrap();
        assert!(api_key_repo.stored(key.id).revoked_at.is_some());
        assert_eq!(api_key_repo.update_count(), 1);
    }

    #[tokio::test]
    async fn list_includes_expired_but_excludes_revoked_and_old_stamp() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("list-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let (_, usable) = create_key(&identity, "Usable", now);
        let (_, mut expired) = create_key(&identity, "Expired", now);
        expired.expires_at = Some(now - Duration::seconds(1));
        let (_, revoked) = create_key(&identity, "Revoked", now);
        let revoked = revoked.revoke(now);
        let (_, mut old_stamp) = create_key(&identity, "Old stamp", now);
        old_stamp.identity_security_stamp = SessionSecurityStamp::new();

        let service = service(
            Arc::new(MockApiKeyRepo::with_keys(vec![
                usable.clone(),
                expired.clone(),
                revoked,
                old_stamp,
            ])),
            Arc::new(MockIdentityRepo::default()),
            Arc::new(MockUserProfileRepo::default()),
        );

        let listed = service.list(&identity).await.unwrap();
        let ids: Vec<ApiKeyId> = listed.iter().map(|key| key.id).collect();
        assert_eq!(ids, vec![usable.id, expired.id]);
    }

    #[derive(Clone, Copy, Debug)]
    enum InvalidToken {
        Malformed,
        AboveMaximumLength,
        IssuedKeyWithoutProfile,
    }

    #[rstest]
    #[case::malformed(InvalidToken::Malformed)]
    #[case::above_maximum_length(InvalidToken::AboveMaximumLength)]
    #[case::issued_key_without_profile(InvalidToken::IssuedKeyWithoutProfile)]
    #[tokio::test]
    async fn authenticate_rejects_bad_token_shape_and_missing_profile(
        #[case] invalid_token: InvalidToken,
    ) {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("auth-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let (token, key) = create_key(&identity, "Auth", now);
        let raw_token = match invalid_token {
            InvalidToken::Malformed => "not-a-calco-token".to_string(),
            InvalidToken::AboveMaximumLength => {
                format!("{API_KEY_TOKEN_PREFIX}{}", "A".repeat(300))
            }
            InvalidToken::IssuedKeyWithoutProfile => token.0,
        };
        let service = service(
            Arc::new(MockApiKeyRepo::with_keys(vec![key])),
            Arc::new(MockIdentityRepo::with_identities(vec![identity])),
            Arc::new(MockUserProfileRepo::default()),
        );

        match service.authenticate(&raw_token, now).await.map(|_| ()) {
            Err(AuthError::InvalidApiKey) => {}
            Err(error) => panic!("{invalid_token:?} token returned {error:?}"),
            Ok(()) => panic!("{invalid_token:?} token should have been rejected"),
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum UnusableApiKey {
        Expired,
        Revoked,
        SecurityStampMismatch,
    }

    #[rstest]
    #[case::expired(UnusableApiKey::Expired)]
    #[case::revoked(UnusableApiKey::Revoked)]
    #[case::security_stamp_mismatch(UnusableApiKey::SecurityStampMismatch)]
    #[tokio::test]
    async fn authenticate_rejects_expired_revoked_and_old_stamp_keys(
        #[case] key_state: UnusableApiKey,
    ) {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("auth-usability-service").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let profile = UserProfile::new(identity.id, "Tester", now);
        let (token, key) = create_key(&identity, "Key", now);
        let key = match key_state {
            UnusableApiKey::Expired => ApiKey {
                expires_at: Some(now - Duration::seconds(1)),
                ..key
            },
            UnusableApiKey::Revoked => key.revoke(now),
            UnusableApiKey::SecurityStampMismatch => ApiKey {
                identity_security_stamp: SessionSecurityStamp::new(),
                ..key
            },
        };
        let service = service(
            Arc::new(MockApiKeyRepo::with_keys(vec![key])),
            Arc::new(MockIdentityRepo::with_identities(vec![identity])),
            Arc::new(MockUserProfileRepo::with_profiles(vec![profile])),
        );

        match (
            key_state,
            service.authenticate(&token.0, now).await.map(|_| ()),
        ) {
            (UnusableApiKey::Expired, Err(AuthError::ApiKeyExpired)) => {}
            (UnusableApiKey::Revoked, Err(AuthError::ApiKeyRevoked)) => {}
            (UnusableApiKey::SecurityStampMismatch, Err(AuthError::InvalidApiKey)) => {}
            (key_state, result) => panic!("{key_state:?} key returned {result:?}"),
        }
    }

    #[tokio::test]
    async fn authenticate_refreshes_last_used_at() {
        let now = Utc::now();
        let (identity, key, token) = identity_and_key(now);
        let profile = UserProfile::new(identity.id, "Tester", now);
        let api_key_repo = Arc::new(MockApiKeyRepo::with_keys(vec![key.clone()]));
        let service = service(
            api_key_repo.clone(),
            Arc::new(MockIdentityRepo::with_identities(vec![identity])),
            Arc::new(MockUserProfileRepo::with_profiles(vec![profile])),
        );

        service.authenticate(&token.0, now).await.unwrap();
        assert_eq!(api_key_repo.stored(key.id).last_used_at, Some(now));
        assert_eq!(api_key_repo.update_count(), 1);

        service
            .authenticate(&token.0, now + Duration::seconds(1))
            .await
            .unwrap();
        assert_eq!(api_key_repo.update_count(), 1);
    }
}

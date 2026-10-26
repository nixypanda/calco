use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};

use crate::auth::domain::*;

const LAST_USED_REFRESH_SECONDS: i64 = 60;
const MAX_API_KEY_TOKEN_LEN: usize = 256;

pub struct CreatedApiKey {
    pub api_key: ApiKey,
    pub token: ApiKeyToken,
}

pub struct ApiKeyAuthentication {
    pub identity: Identity,
    pub profile: UserProfile,
    pub scope: ApiKeyScope,
}

#[derive(Clone)]
pub struct ApiKeyService {
    api_key_repo: Arc<dyn ApiKeyRepository>,
    identity_repo: Arc<dyn IdentityRepository>,
    profile_repo: Arc<dyn UserProfileRepository>,
}

impl ApiKeyService {
    pub fn new(
        api_key_repo: Arc<dyn ApiKeyRepository>,
        identity_repo: Arc<dyn IdentityRepository>,
        profile_repo: Arc<dyn UserProfileRepository>,
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
    ) -> Result<ApiKeyAuthentication, AuthError> {
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

        Ok(ApiKeyAuthentication {
            identity,
            profile,
            scope: api_key.scope,
        })
    }
}

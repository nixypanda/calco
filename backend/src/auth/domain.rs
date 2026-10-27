use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use std::str::FromStr;
use uuid::Uuid;
use zeroize::Zeroize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IdentityId(pub uuid::Uuid);

impl Default for IdentityId {
    fn default() -> Self {
        Self::new()
    }
}

impl IdentityId {
    pub fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}

impl From<uuid::Uuid> for IdentityId {
    fn from(id: uuid::Uuid) -> Self {
        Self(id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionSecurityStamp(pub uuid::Uuid);

impl Default for SessionSecurityStamp {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionSecurityStamp {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Username(String);

impl Username {
    const MAX_LEN: usize = 64;

    pub fn new(raw: &str) -> Result<Self, AuthError> {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.len() > Self::MAX_LEN {
            return Err(AuthError::InvalidCredentials);
        }
        if trimmed.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Err(AuthError::InvalidCredentials);
        }
        Ok(Self(trimmed.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

pub struct Password(String);

impl Password {
    pub fn new(raw: impl Into<String>) -> Self {
        Self(raw.into())
    }

    pub(crate) fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl Drop for Password {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

pub struct NewPassword(Password);

impl NewPassword {
    const MIN_LEN: usize = 8;
    const MAX_LEN: usize = 256;

    pub fn new(raw: impl Into<String>) -> Result<Self, AuthError> {
        let password = raw.into();
        if password.len() < Self::MIN_LEN || password.len() > Self::MAX_LEN {
            return Err(AuthError::InvalidPassword);
        }

        Ok(Self(Password::new(password)))
    }

    pub(crate) fn password(&self) -> &Password {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasswordHash(pub String);

#[derive(Debug, Clone)]
pub struct SessionToken(pub String);

#[derive(Debug, Clone)]
pub struct SessionTokenHash(pub String);

#[derive(Debug, Clone, Copy)]
pub struct SessionPolicy {
    lifetime: Duration,
}

#[derive(Debug, thiserror::Error)]
#[error("session lifetime must be positive")]
pub struct InvalidSessionLifetime;

impl SessionPolicy {
    pub fn new(lifetime: Duration) -> Result<Self, InvalidSessionLifetime> {
        if lifetime <= Duration::zero() {
            return Err(InvalidSessionLifetime);
        }

        Ok(Self { lifetime })
    }

    pub fn lifetime(&self) -> Duration {
        self.lifetime
    }

    pub fn expires_at(&self, created_at: DateTime<Utc>) -> DateTime<Utc> {
        created_at + self.lifetime
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityRole {
    User,
    Admin,
}

impl IdentityRole {
    pub fn as_str(&self) -> &'static str {
        match self {
            IdentityRole::User => "user",
            IdentityRole::Admin => "admin",
        }
    }
}

impl FromStr for IdentityRole {
    type Err = AuthError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "user" => Ok(IdentityRole::User),
            "admin" => Ok(IdentityRole::Admin),
            _ => Err(AuthError::Internal(format!("Invalid role: {s}"))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityStatus {
    Active,
    Disabled,
}

impl IdentityStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            IdentityStatus::Active => "active",
            IdentityStatus::Disabled => "disabled",
        }
    }
}

impl FromStr for IdentityStatus {
    type Err = AuthError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "active" => Ok(IdentityStatus::Active),
            "disabled" => Ok(IdentityStatus::Disabled),
            _ => Err(AuthError::Internal(format!("Invalid status: {s}"))),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Identity {
    pub id: IdentityId,
    pub username: Username,
    pub password_hash: PasswordHash,
    pub role: IdentityRole,
    pub status: IdentityStatus,
    /// Opaque value copied into new sessions and rotated by security-sensitive
    /// identity changes. This makes invalidation a single-aggregate write and
    /// avoids an application-level unit of work spanning identities and sessions.
    pub session_security_stamp: SessionSecurityStamp,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Identity {
    pub fn new_user(username: Username, password_hash: PasswordHash, now: DateTime<Utc>) -> Self {
        Self::new(username, password_hash, IdentityRole::User, now)
    }

    pub fn new_admin(username: Username, password_hash: PasswordHash, now: DateTime<Utc>) -> Self {
        Self::new(username, password_hash, IdentityRole::Admin, now)
    }

    fn new(
        username: Username,
        password_hash: PasswordHash,
        role: IdentityRole,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            id: IdentityId::new(),
            username,
            password_hash,
            role,
            status: IdentityStatus::Active,
            session_security_stamp: SessionSecurityStamp::new(),
            created_at: now,
            updated_at: now,
        }
    }

    pub fn is_active(&self) -> bool {
        self.status == IdentityStatus::Active
    }

    pub fn change_password(&self, password_hash: PasswordHash, now: DateTime<Utc>) -> Self {
        Self {
            password_hash,
            session_security_stamp: SessionSecurityStamp::new(),
            updated_at: now,
            ..self.clone()
        }
    }

    pub fn disable(&self, now: DateTime<Utc>) -> Self {
        Self {
            status: IdentityStatus::Disabled,
            session_security_stamp: SessionSecurityStamp::new(),
            updated_at: now,
            ..self.clone()
        }
    }

    pub fn enable(&self, now: DateTime<Utc>) -> Self {
        Self {
            status: IdentityStatus::Active,
            updated_at: now,
            ..self.clone()
        }
    }
}

#[derive(Debug, Clone)]
pub struct UserProfile {
    pub id: uuid::Uuid,
    pub identity_id: IdentityId,
    pub display_name: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl UserProfile {
    pub fn new(
        identity_id: IdentityId,
        display_name: impl Into<String>,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            identity_id,
            display_name: display_name.into(),
            created_at: now,
            updated_at: now,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Session {
    pub id: uuid::Uuid,
    pub identity_id: IdentityId,
    /// Snapshot of the identity's security stamp when this session was issued.
    pub identity_security_stamp: SessionSecurityStamp,
    pub session_token_hash: SessionTokenHash,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}

impl Session {
    pub fn is_revoked_for(&self, identity: &Identity) -> bool {
        self.revoked_at.is_some() || self.identity_security_stamp != identity.session_security_stamp
    }

    pub fn ensure_usable_for(
        &self,
        identity: &Identity,
        now: DateTime<Utc>,
    ) -> Result<(), AuthError> {
        if self.is_revoked_for(identity) {
            return Err(AuthError::SessionRevoked);
        }
        if self.expires_at < now {
            return Err(AuthError::SessionExpired);
        }
        Ok(())
    }

    pub fn should_refresh_last_seen(&self, now: DateTime<Utc>, threshold: Duration) -> bool {
        now - self.last_seen_at >= threshold
    }

    pub fn record_seen(&self, now: DateTime<Utc>) -> Self {
        Self {
            last_seen_at: now,
            ..self.clone()
        }
    }

    pub fn revoke(&self, now: DateTime<Utc>) -> Self {
        Self {
            revoked_at: Some(now),
            ..self.clone()
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ApiKeyId(pub Uuid);

impl ApiKeyId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for ApiKeyId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiKeyName(String);

impl ApiKeyName {
    const MAX_LEN: usize = 64;

    pub fn new(raw: &str) -> Result<Self, AuthError> {
        let trimmed = raw.trim();
        let len = trimmed.chars().count();
        if len == 0
            || len > Self::MAX_LEN
            || trimmed.chars().any(is_forbidden_api_key_name_char)
            || !trimmed.chars().any(is_visible_api_key_name_char)
        {
            return Err(AuthError::InvalidApiKeyName);
        }
        Ok(Self(trimmed.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

pub struct ApiKeyToken(pub String);

fn is_visible_api_key_name_char(c: char) -> bool {
    !c.is_whitespace() && !c.is_control() && !matches!(c, '\u{200C}' | '\u{200D}')
}

fn is_forbidden_api_key_name_char(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{00AD}'
                | '\u{061C}'
                | '\u{180E}'
                | '\u{200B}'
                | '\u{200E}'
                | '\u{200F}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202A}'..='\u{202E}'
                | '\u{2060}'..='\u{206F}'
                | '\u{FEFF}'
                | '\u{FFF9}'..='\u{FFFB}'
        )
}

#[derive(Debug, Clone)]
pub struct ApiKeyTokenHash(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiKeyScope {
    Read,
    ReadWrite,
}

impl ApiKeyScope {
    pub fn as_str(&self) -> &'static str {
        match self {
            ApiKeyScope::Read => "read",
            ApiKeyScope::ReadWrite => "read_write",
        }
    }
}

impl FromStr for ApiKeyScope {
    type Err = AuthError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "read" => Ok(ApiKeyScope::Read),
            "read_write" => Ok(ApiKeyScope::ReadWrite),
            _ => Err(AuthError::InvalidApiKeyScope),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ApiKey {
    pub id: ApiKeyId,
    pub identity_id: IdentityId,
    pub identity_security_stamp: SessionSecurityStamp,
    pub name: ApiKeyName,
    pub token_hash: ApiKeyTokenHash,
    pub token_hint: String,
    pub scope: ApiKeyScope,
    pub created_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
}

impl ApiKey {
    pub fn is_usable_for(&self, identity: &Identity, now: DateTime<Utc>) -> bool {
        self.revoked_at.is_none()
            && self.expires_at.is_none_or(|expires_at| now < expires_at)
            && self.identity_security_stamp == identity.session_security_stamp
    }

    pub fn ensure_usable_for(
        &self,
        identity: &Identity,
        now: DateTime<Utc>,
    ) -> Result<(), AuthError> {
        if self.revoked_at.is_some() {
            return Err(AuthError::ApiKeyRevoked);
        }
        if self.expires_at.is_some_and(|expires_at| now >= expires_at) {
            return Err(AuthError::ApiKeyExpired);
        }
        if self.identity_security_stamp != identity.session_security_stamp {
            return Err(AuthError::InvalidApiKey);
        }
        Ok(())
    }

    pub fn should_refresh_last_used(&self, now: DateTime<Utc>, threshold: Duration) -> bool {
        self.last_used_at
            .is_none_or(|last_used_at| now - last_used_at >= threshold)
    }

    pub fn record_used(&self, now: DateTime<Utc>) -> Self {
        Self {
            last_used_at: Some(now),
            ..self.clone()
        }
    }

    pub fn revoke(&self, now: DateTime<Utc>) -> Self {
        Self {
            revoked_at: Some(now),
            ..self.clone()
        }
    }
}

pub const MAX_ACTIVE_API_KEYS: usize = 10;

/// Best-effort pre-check for the active-key cap. Concurrent creates can race
/// past this check, so callers must treat it as a UX guard, not an invariant.
pub fn ensure_api_key_capacity(
    keys: &[ApiKey],
    identity: &Identity,
    now: DateTime<Utc>,
) -> Result<(), AuthError> {
    let active_count = keys
        .iter()
        .filter(|key| key.is_usable_for(identity, now))
        .count();

    if active_count >= MAX_ACTIVE_API_KEYS {
        return Err(AuthError::ApiKeyLimitReached);
    }

    Ok(())
}

pub const API_KEY_TOKEN_PREFIX: &str = "calco_pat_";

pub fn create_api_key(
    identity: &Identity,
    name: ApiKeyName,
    scope: ApiKeyScope,
    expires_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Result<(ApiKeyToken, ApiKey), AuthError> {
    use rand::RngCore;

    if expires_at.is_some_and(|expires_at| expires_at <= now) {
        return Err(AuthError::InvalidApiKeyExpiry);
    }

    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    let encoded = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, bytes);
    let raw_token = format!("{API_KEY_TOKEN_PREFIX}{encoded}");
    let token_hint = raw_token.chars().take(18).collect();
    let token_hash = ApiKeyTokenHash(hash_api_key_token(&raw_token));

    let api_key = ApiKey {
        id: ApiKeyId::new(),
        identity_id: identity.id,
        identity_security_stamp: identity.session_security_stamp,
        name,
        token_hash,
        token_hint,
        scope,
        created_at: now,
        last_used_at: None,
        expires_at,
        revoked_at: None,
    };

    Ok((ApiKeyToken(raw_token), api_key))
}

pub fn hash_api_key_token(token: &str) -> String {
    use sha2::{Digest, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn create_session(
    identity: &Identity,
    policy: &SessionPolicy,
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
        identity_security_stamp: identity.session_security_stamp,
        session_token_hash: token_hash,
        created_at: now,
        last_seen_at: now,
        expires_at: policy.expires_at(now),
        revoked_at: None,
    };

    Ok((raw_token, session))
}

pub fn hash_session_token(token: &str) -> String {
    use sha2::{Digest, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("invalid_credentials")]
    InvalidCredentials,
    #[error("invalid_password")]
    InvalidPassword,
    #[error("identity_disabled")]
    IdentityDisabled,
    #[error("identity_not_found")]
    IdentityNotFound,
    #[error("session_not_found")]
    SessionNotFound,
    #[error("session_expired")]
    SessionExpired,
    #[error("session_revoked")]
    SessionRevoked,
    #[error("admin_already_exists")]
    AdminAlreadyExists,
    #[error("username_taken")]
    UsernameTaken,
    #[error("unauthorized")]
    Unauthorized,
    #[error("invalid_api_key")]
    InvalidApiKey,
    #[error("api_key_expired")]
    ApiKeyExpired,
    #[error("api_key_revoked")]
    ApiKeyRevoked,
    #[error("api_key_not_found")]
    ApiKeyNotFound,
    #[error("api_key_limit_reached")]
    ApiKeyLimitReached,
    #[error("invalid_api_key_name")]
    InvalidApiKeyName,
    #[error("invalid_api_key_scope")]
    InvalidApiKeyScope,
    #[error("invalid_api_key_expiry")]
    InvalidApiKeyExpiry,
    #[error("insufficient_scope")]
    InsufficientScope,
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error("credential_processing_failed")]
    CredentialProcessingFailed,
    #[error("internal: {0}")]
    Internal(String),
}

pub struct UserWithProfile {
    pub identity: Identity,
    pub profile: UserProfile,
}

pub trait PasswordHasher: Send + Sync {
    fn hash(&self, password: &NewPassword) -> Result<PasswordHash, AuthError>;
}

pub trait CredentialVerifier: Send + Sync {
    fn verify(&self, password: &Password, expected_hash: &PasswordHash) -> Result<bool, AuthError>;
}

#[async_trait]
pub trait IdentityRepo: Send + Sync {
    async fn find_by_username(&self, username: &str) -> Result<Option<Identity>, AuthError>;
    async fn find_by_id(&self, id: IdentityId) -> Result<Option<Identity>, AuthError>;
    async fn find_by_ids(&self, ids: &[IdentityId]) -> Result<Vec<Identity>, AuthError>;
    async fn create(&self, identity: &Identity) -> Result<(), AuthError>;
    async fn update(&self, identity: &Identity) -> Result<(), AuthError>;
    async fn exists_admin(&self) -> Result<bool, AuthError>;
}

#[async_trait]
pub trait SessionRepo: Send + Sync {
    async fn create(&self, session: &Session) -> Result<(), AuthError>;
    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<Session>, AuthError>;
    async fn update(&self, session: &Session) -> Result<(), AuthError>;
}

#[async_trait]
pub trait ApiKeyRepo: Send + Sync {
    async fn create(&self, key: &ApiKey) -> Result<(), AuthError>;
    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<ApiKey>, AuthError>;
    async fn find_by_id(&self, id: ApiKeyId) -> Result<Option<ApiKey>, AuthError>;
    async fn find_by_id_and_identity_id(
        &self,
        id: ApiKeyId,
        identity_id: IdentityId,
    ) -> Result<Option<ApiKey>, AuthError>;
    async fn list_by_identity_id(&self, id: IdentityId) -> Result<Vec<ApiKey>, AuthError>;
    async fn update(&self, key: &ApiKey) -> Result<(), AuthError>;
}

#[async_trait]
pub trait UserProfileRepo: Send + Sync {
    async fn find_by_identity_id(
        &self,
        identity_id: IdentityId,
    ) -> Result<Option<UserProfile>, AuthError>;
    async fn find_by_id(&self, id: Uuid) -> Result<Option<UserProfile>, AuthError>;
    async fn create(&self, profile: &UserProfile) -> Result<(), AuthError>;
    async fn list_all(&self) -> Result<Vec<UserProfile>, AuthError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_change_and_disable_rotate_the_session_security_stamp() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("tester").unwrap(),
            PasswordHash("old-hash".into()),
            now,
        );

        let password_changed =
            identity.change_password(PasswordHash("new-hash".into()), now + Duration::seconds(1));
        assert_ne!(
            password_changed.session_security_stamp,
            identity.session_security_stamp
        );

        let disabled = password_changed.disable(now + Duration::seconds(2));
        assert_ne!(
            disabled.session_security_stamp,
            password_changed.session_security_stamp
        );

        let enabled = disabled.enable(now + Duration::seconds(3));
        assert_eq!(
            enabled.session_security_stamp,
            disabled.session_security_stamp
        );
    }

    #[test]
    fn session_is_revoked_when_its_identity_rotates_the_security_stamp() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("tester").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let (_, session) = create_session(
            &identity,
            &SessionPolicy::new(Duration::hours(1)).unwrap(),
            now,
        )
        .unwrap();

        assert!(!session.is_revoked_for(&identity));
        assert!(session.revoke(now).is_revoked_for(&identity));

        let identity = identity.disable(now + Duration::seconds(1));

        assert!(session.is_revoked_for(&identity));
        assert!(matches!(
            session.ensure_usable_for(&identity, now),
            Err(AuthError::SessionRevoked)
        ));
    }

    #[test]
    fn new_password_enforces_length_boundaries() {
        assert!(matches!(
            NewPassword::new("a".repeat(7)),
            Err(AuthError::InvalidPassword)
        ));
        assert!(NewPassword::new("a".repeat(8)).is_ok());
        assert!(NewPassword::new("a".repeat(256)).is_ok());
        assert!(matches!(
            NewPassword::new("a".repeat(257)),
            Err(AuthError::InvalidPassword)
        ));
    }

    #[test]
    fn session_policy_requires_a_positive_lifetime() {
        assert!(SessionPolicy::new(Duration::seconds(1)).is_ok());
        assert!(matches!(
            SessionPolicy::new(Duration::zero()),
            Err(InvalidSessionLifetime)
        ));
        assert!(matches!(
            SessionPolicy::new(Duration::seconds(-1)),
            Err(InvalidSessionLifetime)
        ));
    }

    fn api_key_fixture() -> (Identity, ApiKey) {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("api-key-user").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let (_, api_key) = create_api_key(
            &identity,
            ApiKeyName::new("Script").unwrap(),
            ApiKeyScope::Read,
            None,
            now,
        )
        .unwrap();
        (identity, api_key)
    }

    #[test]
    fn api_key_token_has_prefix_length_hint_and_deterministic_hash() {
        let (identity, api_key) = api_key_fixture();
        let now = Utc::now();
        let (token, key) = create_api_key(
            &identity,
            ApiKeyName::new("Script").unwrap(),
            ApiKeyScope::ReadWrite,
            None,
            now,
        )
        .unwrap();

        assert!(token.0.starts_with(API_KEY_TOKEN_PREFIX));
        assert_eq!(token.0.len(), 53);
        assert_eq!(key.token_hint, token.0.chars().take(18).collect::<String>());
        assert_eq!(key.token_hash.0, hash_api_key_token(&token.0));
        assert_eq!(key.token_hash.0, hash_api_key_token(&token.0));
        assert_eq!(key.token_hash.0.len(), 64);
        assert_ne!(key.token_hash.0, token.0);
        assert_ne!(api_key.token_hash.0, key.token_hash.0);
    }

    #[test]
    fn api_key_name_is_trimmed_and_bounded() {
        assert_eq!(ApiKeyName::new("  Script  ").unwrap().as_str(), "Script");
        assert!(matches!(
            ApiKeyName::new("   "),
            Err(AuthError::InvalidApiKeyName)
        ));
        assert!(ApiKeyName::new(&"a".repeat(64)).is_ok());
        assert!(matches!(
            ApiKeyName::new(&"a".repeat(65)),
            Err(AuthError::InvalidApiKeyName)
        ));
        assert!(matches!(
            ApiKeyName::new("bad\nname"),
            Err(AuthError::InvalidApiKeyName)
        ));
    }

    #[test]
    fn api_key_name_rejects_bidi_and_invisible_format_controls() {
        assert!(ApiKeyName::new("Café 日本語 key").is_ok());
        assert!(ApiKeyName::new("family 👨\u{200D}👩\u{200D}👧").is_ok());
        assert!(ApiKeyName::new("हिन्दी\u{200C}key").is_ok());

        for name in [
            "zero\u{200B}width",
            "left\u{200E}mark",
            "right\u{200F}mark",
            "line\u{2028}separator",
            "paragraph\u{2029}separator",
            "embed\u{202A}ding",
            "override\u{202E}ding",
            "word\u{2060}joiner",
            "bom\u{FEFF}mark",
            "soft\u{00AD}hyphen",
            "\u{200C}",
            "\u{200D}",
            " \u{200C} ",
        ] {
            assert!(
                matches!(ApiKeyName::new(name), Err(AuthError::InvalidApiKeyName)),
                "expected {name:?} to be rejected"
            );
        }
    }

    #[test]
    fn api_key_expiry_must_be_in_the_future() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("expiry-user").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let name = || ApiKeyName::new("Script").unwrap();

        assert!(
            create_api_key(
                &identity,
                name(),
                ApiKeyScope::Read,
                Some(now + Duration::seconds(1)),
                now,
            )
            .is_ok()
        );
        assert!(matches!(
            create_api_key(&identity, name(), ApiKeyScope::Read, Some(now), now),
            Err(AuthError::InvalidApiKeyExpiry)
        ));
        assert!(matches!(
            create_api_key(
                &identity,
                name(),
                ApiKeyScope::Read,
                Some(now - Duration::seconds(1)),
                now,
            ),
            Err(AuthError::InvalidApiKeyExpiry)
        ));
        assert!(create_api_key(&identity, name(), ApiKeyScope::Read, None, now).is_ok());
    }

    #[test]
    fn api_key_usability_rejects_revoked_expired_and_stamp_mismatch() {
        let (identity, api_key) = api_key_fixture();
        let now = Utc::now();

        assert!(api_key.is_usable_for(&identity, now));
        assert!(api_key.ensure_usable_for(&identity, now).is_ok());

        let revoked = api_key.revoke(now);
        assert!(!revoked.is_usable_for(&identity, now));
        assert!(matches!(
            revoked.ensure_usable_for(&identity, now),
            Err(AuthError::ApiKeyRevoked)
        ));

        let expired = ApiKey {
            expires_at: Some(now - Duration::seconds(1)),
            ..api_key.clone()
        };
        assert!(!expired.is_usable_for(&identity, now));
        assert!(matches!(
            expired.ensure_usable_for(&identity, now),
            Err(AuthError::ApiKeyExpired)
        ));

        let rotated_identity = identity.disable(now);
        assert!(!api_key.is_usable_for(&rotated_identity, now));
        assert!(matches!(
            api_key.ensure_usable_for(&rotated_identity, now),
            Err(AuthError::InvalidApiKey)
        ));
    }

    #[test]
    fn api_key_last_used_refresh_respects_the_threshold() {
        let (_, api_key) = api_key_fixture();
        let now = Utc::now();
        let threshold = Duration::seconds(60);

        assert!(api_key.should_refresh_last_used(now, threshold));
        let recently_used = api_key.record_used(now);
        assert!(!recently_used.should_refresh_last_used(now + Duration::seconds(30), threshold));
        assert!(recently_used.should_refresh_last_used(now + Duration::seconds(60), threshold));
    }

    #[test]
    fn api_key_scope_parses_known_values_only() {
        assert_eq!("read".parse::<ApiKeyScope>().unwrap(), ApiKeyScope::Read);
        assert_eq!(
            "read_write".parse::<ApiKeyScope>().unwrap(),
            ApiKeyScope::ReadWrite
        );
        assert!(matches!(
            "admin".parse::<ApiKeyScope>(),
            Err(AuthError::InvalidApiKeyScope)
        ));
    }
}

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
    pub fn ensure_usable(&self, now: DateTime<Utc>) -> Result<(), AuthError> {
        if self.revoked_at.is_some() {
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
pub trait IdentityRepository: Send + Sync {
    async fn find_by_username(&self, username: &str) -> Result<Option<Identity>, AuthError>;
    async fn find_by_id(&self, id: IdentityId) -> Result<Option<Identity>, AuthError>;
    async fn find_by_ids(&self, ids: &[IdentityId]) -> Result<Vec<Identity>, AuthError>;
    async fn create(&self, identity: &Identity) -> Result<(), AuthError>;
    async fn update(&self, identity: &Identity) -> Result<(), AuthError>;
    async fn exists_admin(&self) -> Result<bool, AuthError>;
}

#[async_trait]
pub trait SessionRepository: Send + Sync {
    async fn create(&self, session: &Session) -> Result<(), AuthError>;
    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<Session>, AuthError>;
    async fn update(&self, session: &Session) -> Result<(), AuthError>;
}

#[async_trait]
pub trait UserProfileRepository: Send + Sync {
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
    fn session_captures_the_identity_security_stamp() {
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

        assert_eq!(
            session.identity_security_stamp,
            identity.session_security_stamp
        );
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
    fn login_password_does_not_apply_new_password_policy() {
        let password = Password::new("short");

        assert_eq!(password.as_bytes(), b"short");
    }

    #[test]
    fn identity_factories_create_active_identity_with_requested_role() {
        let now = Utc::now();
        let user = Identity::new_user(
            Username::new("user").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let admin = Identity::new_admin(
            Username::new("admin").unwrap(),
            PasswordHash("hash".into()),
            now,
        );

        assert_eq!(user.role, IdentityRole::User);
        assert_eq!(admin.role, IdentityRole::Admin);
        assert_eq!(user.status, IdentityStatus::Active);
        assert_eq!(admin.status, IdentityStatus::Active);
        assert_eq!(user.created_at, now);
        assert_eq!(user.updated_at, now);
    }

    #[test]
    fn user_profile_factory_associates_a_new_profile_with_an_identity() {
        let now = Utc::now();
        let identity_id = IdentityId::new();
        let profile = UserProfile::new(identity_id, "Display Name", now);

        assert_eq!(profile.identity_id, identity_id);
        assert_eq!(profile.display_name, "Display Name");
        assert_eq!(profile.created_at, now);
        assert_eq!(profile.updated_at, now);
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

    #[test]
    fn session_policy_determines_session_expiration() {
        let now = Utc::now();
        let identity = Identity::new_user(
            Username::new("user").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        let policy = SessionPolicy::new(Duration::hours(2)).unwrap();

        let (_, session) = create_session(&identity, &policy, now).unwrap();

        assert_eq!(session.expires_at, now + Duration::hours(2));
    }
}

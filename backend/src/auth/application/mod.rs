mod admin_user;
mod bootstrap;
mod session;

pub use admin_user::AdminUserService;
pub use bootstrap::AuthBootstrapService;
pub use session::AuthSessionService;

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::auth::domain::*;

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

fn create_session(
    identity: &Identity,
    config: &SessionCookieConfig,
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
        expires_at: now + chrono::Duration::seconds(config.ttl_seconds),
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

const PASSWORD_MIN_LEN: usize = 8;
const PASSWORD_MAX_LEN: usize = 256;
const LAST_SEEN_REFRESH_SECONDS: i64 = 60;

fn validate_password(password: &str) -> Result<(), AuthError> {
    if password.len() < PASSWORD_MIN_LEN || password.len() > PASSWORD_MAX_LEN {
        return Err(AuthError::InvalidCredentials);
    }
    Ok(())
}

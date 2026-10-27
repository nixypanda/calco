mod admin_user;
mod api_key;
mod bootstrap;
mod session;

pub use admin_user::AdminUserService;
pub use api_key::{ApiKeyAuth, ApiKeyService, CreatedApiKey};
pub use bootstrap::AuthBootstrapService;
pub use session::AuthSessionService;

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

const LAST_SEEN_REFRESH_SECONDS: i64 = 60;

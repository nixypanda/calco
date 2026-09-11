use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::auth::application::{AdminUserService, AuthBootstrapService, AuthSessionService};
use crate::auth::domain::{
    IdentityRepository, SessionCookieConfig, SessionRepository, UserProfileRepository,
};
use crate::auth::infrastructure::argon2_credentials::Argon2Credentials;
use crate::auth::infrastructure::postgres::{
    PostgresIdentityRepository, PostgresSessionRepository, PostgresUserProfileRepository,
};

#[derive(Clone)]
pub struct AuthModule {
    pub cookie_config: SessionCookieConfig,
    pub bootstrap: AuthBootstrapService,
    pub sessions: AuthSessionService,
    pub admin_users: AdminUserService,
}

impl AuthModule {
    pub fn build(pool: &PgPool, cookie_config: SessionCookieConfig) -> Self {
        let identity_repo =
            Arc::new(PostgresIdentityRepository::new(pool.clone())) as Arc<dyn IdentityRepository>;
        let session_repo =
            Arc::new(PostgresSessionRepository::new(pool.clone())) as Arc<dyn SessionRepository>;
        let profile_repo = Arc::new(PostgresUserProfileRepository::new(pool.clone()))
            as Arc<dyn UserProfileRepository>;
        let credentials = Arc::new(Argon2Credentials);

        let bootstrap = AuthBootstrapService::new(
            identity_repo.clone(),
            session_repo.clone(),
            credentials.clone(),
            cookie_config.clone(),
        );
        let sessions = AuthSessionService::new(
            identity_repo.clone(),
            session_repo.clone(),
            profile_repo.clone(),
            credentials.clone(),
            cookie_config.clone(),
        );
        let admin_users =
            AdminUserService::new(identity_repo, session_repo, profile_repo, credentials);

        Self {
            cookie_config,
            bootstrap,
            sessions,
            admin_users,
        }
    }
}

impl FromRef<AppState> for AuthModule {
    fn from_ref(app: &AppState) -> Self {
        app.auth.clone()
    }
}

impl FromRef<AppState> for SessionCookieConfig {
    fn from_ref(app: &AppState) -> Self {
        app.auth.cookie_config.clone()
    }
}

impl FromRef<AuthModule> for SessionCookieConfig {
    fn from_ref(auth: &AuthModule) -> Self {
        auth.cookie_config.clone()
    }
}

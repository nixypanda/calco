use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::auth::api::SessionCookieConfig;
use crate::auth::app::{AdminUserService, ApiKeyService, AuthBootstrapService, AuthSessionService};
use crate::auth::domain::{ApiKeyRepo, IdentityRepo, SessionPolicy, SessionRepo, UserProfileRepo};
use crate::auth::infra::argon2_credentials::Argon2Credentials;
use crate::auth::infra::pg::{PgApiKeyRepo, PgIdentityRepo, PgSessionRepo, PgUserProfileRepo};

#[derive(Clone)]
pub struct AuthModule {
    pub cookie_config: SessionCookieConfig,
    pub session_policy: SessionPolicy,
    pub bootstrap: AuthBootstrapService,
    pub sessions: AuthSessionService,
    pub admin_users: AdminUserService,
    pub api_keys: ApiKeyService,
}

impl AuthModule {
    pub fn build(
        pool: &PgPool,
        cookie_config: SessionCookieConfig,
        session_policy: SessionPolicy,
    ) -> Self {
        let identity_repo = Arc::new(PgIdentityRepo::new(pool.clone())) as Arc<dyn IdentityRepo>;
        let session_repo = Arc::new(PgSessionRepo::new(pool.clone())) as Arc<dyn SessionRepo>;
        let profile_repo =
            Arc::new(PgUserProfileRepo::new(pool.clone())) as Arc<dyn UserProfileRepo>;
        let api_key_repo = Arc::new(PgApiKeyRepo::new(pool.clone())) as Arc<dyn ApiKeyRepo>;
        let credentials = Arc::new(Argon2Credentials);

        let bootstrap = AuthBootstrapService::new(
            identity_repo.clone(),
            session_repo.clone(),
            credentials.clone(),
            session_policy,
        );
        let sessions = AuthSessionService::new(
            identity_repo.clone(),
            session_repo.clone(),
            profile_repo.clone(),
            credentials.clone(),
            session_policy,
        );
        let admin_users =
            AdminUserService::new(identity_repo.clone(), profile_repo.clone(), credentials);
        let api_keys = ApiKeyService::new(api_key_repo, identity_repo, profile_repo);

        Self {
            cookie_config,
            session_policy,
            bootstrap,
            sessions,
            admin_users,
            api_keys,
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

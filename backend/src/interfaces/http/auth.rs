use axum::{
    extract::{FromRequestParts, Path, State},
    http::{request::Parts, Response, StatusCode, header},
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::auth::*;
use crate::application::food_log::FoodLogServices;
use crate::application::meal::MealServices;
use crate::config::AppConfig;
use crate::domain::auth::*;

#[derive(Clone)]
pub struct AppState {
    pub identity_repo: std::sync::Arc<dyn IdentityRepository>,
    pub session_repo: std::sync::Arc<dyn SessionRepository>,
    pub profile_repo: std::sync::Arc<dyn UserProfileRepository>,
    pub config: AppConfig,
    pub food_log_services: Option<FoodLogServices>,
    pub meal_services: Option<MealServices>,
}

pub fn auth_routes(state: AppState) -> Router {
    Router::new()
        .route("/auth/bootstrap/status", get(bootstrap_status_handler))
        .route("/auth/bootstrap/admin", post(bootstrap_create_admin_handler))
        .route("/auth/login", post(login_handler))
        .route("/auth/session", get(session_handler))
        .route("/auth/logout", post(logout_handler))
        .route("/admin/users", get(admin_list_users_handler).post(admin_create_user_handler))
        .route("/admin/users/{id}/reset-password", post(admin_reset_password_handler))
        .route("/admin/users/{id}/disable", post(admin_disable_user_handler))
        .route("/admin/users/{id}/enable", post(admin_enable_user_handler))
        .with_state(state)
}

// ─── Session Token Extractor ──────────────────────────────────

pub struct RawSessionToken(pub String);

impl FromRequestParts<AppState> for RawSessionToken {
    type Rejection = AuthErrorResponse;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = extract_session_token(parts, &state.config)?;
        Ok(RawSessionToken(token))
    }
}

// ─── Auth Extractors ──────────────────────────────────────────

pub struct AuthIdentity(pub Identity);

impl FromRequestParts<AppState> for AuthIdentity {
    type Rejection = AuthErrorResponse;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let RawSessionToken(token) = RawSessionToken::from_request_parts(parts, state).await?;
        let result = get_session(
            &*state.session_repo,
            &*state.identity_repo,
            &*state.profile_repo,
            &token,
        )
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;
        Ok(AuthIdentity(result.identity))
    }
}

pub struct AuthUser(pub Identity, pub UserProfile);

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AuthErrorResponse;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let RawSessionToken(token) = RawSessionToken::from_request_parts(parts, state).await?;
        let result = get_session(
            &*state.session_repo,
            &*state.identity_repo,
            &*state.profile_repo,
            &token,
        )
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

        if result.identity.role != IdentityRole::User {
            return Err(AuthErrorResponse::forbidden());
        }

        let profile = result
            .profile
            .ok_or_else(AuthErrorResponse::forbidden)?;

        Ok(AuthUser(result.identity, profile))
    }
}

pub struct AuthAdmin(pub Identity);

impl FromRequestParts<AppState> for AuthAdmin {
    type Rejection = AuthErrorResponse;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let RawSessionToken(token) = RawSessionToken::from_request_parts(parts, state).await?;
        let result = get_session(
            &*state.session_repo,
            &*state.identity_repo,
            &*state.profile_repo,
            &token,
        )
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

        if result.identity.role != IdentityRole::Admin {
            return Err(AuthErrorResponse::forbidden());
        }

        Ok(AuthAdmin(result.identity))
    }
}

// ─── DTOs ─────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}

#[derive(Serialize)]
pub struct ErrorBody {
    pub error: ApiError,
}

pub struct AuthErrorResponse {
    status: StatusCode,
    body: ErrorBody,
}

impl AuthErrorResponse {
    fn from_auth_error(err: &AuthError) -> Self {
        let (status, code) = match err {
            AuthError::InvalidCredentials => (StatusCode::UNAUTHORIZED, "invalid_credentials"),
            AuthError::IdentityDisabled => (StatusCode::FORBIDDEN, "identity_disabled"),
            AuthError::IdentityNotFound => (StatusCode::UNAUTHORIZED, "invalid_credentials"),
            AuthError::SessionNotFound => (StatusCode::UNAUTHORIZED, "session_not_found"),
            AuthError::SessionExpired => (StatusCode::UNAUTHORIZED, "session_expired"),
            AuthError::SessionRevoked => (StatusCode::UNAUTHORIZED, "session_revoked"),
            AuthError::AdminAlreadyExists => (StatusCode::CONFLICT, "admin_already_exists"),
            AuthError::UsernameTaken => (StatusCode::CONFLICT, "username_taken"),
            AuthError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            AuthError::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
            AuthError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
        };
        Self {
            status,
            body: ErrorBody {
                error: ApiError {
                    code: code.to_string(),
                    message: err.to_string(),
                },
            },
        }
    }

    fn forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            body: ErrorBody {
                error: ApiError {
                    code: "forbidden".into(),
                    message: "Forbidden".into(),
                },
            },
        }
    }
}

impl IntoResponse for AuthErrorResponse {
    fn into_response(self) -> Response<axum::body::Body> {
        (self.status, Json(self.body)).into_response()
    }
}

#[derive(Serialize)]
pub struct BootstrapStatusResponse {
    pub admin_exists: bool,
}

#[derive(Deserialize)]
pub struct CreateAdminRequest {
    pub username: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct IdentityResponse {
    pub id: Uuid,
    pub username: String,
    pub role: String,
}

#[derive(Serialize)]
pub struct ProfileResponse {
    pub id: Uuid,
    pub display_name: String,
}

#[derive(Serialize)]
pub struct LoginSessionResponse {
    pub identity: IdentityResponse,
    pub profile: Option<ProfileResponse>,
}

#[derive(Deserialize)]
pub struct CreateUserRequest {
    pub username: String,
    pub display_name: String,
    pub initial_password: String,
}

#[derive(Serialize)]
pub struct UserItem {
    pub id: Uuid,
    pub username: String,
    pub display_name: String,
    pub status: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
pub struct ListUsersResponse {
    pub users: Vec<UserItem>,
}

#[derive(Deserialize)]
pub struct ResetPasswordRequest {
    pub new_password: String,
}

// ─── Handlers ─────────────────────────────────────────────────

async fn bootstrap_status_handler(
    State(state): State<AppState>,
) -> Result<Json<BootstrapStatusResponse>, AuthErrorResponse> {
    let info = bootstrap_status(&*state.identity_repo)
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;
    Ok(Json(BootstrapStatusResponse {
        admin_exists: info.admin_exists,
    }))
}

type CookieHeader = (header::HeaderName, String);

async fn bootstrap_create_admin_handler(
    State(state): State<AppState>,
    Json(body): Json<CreateAdminRequest>,
) -> Result<(StatusCode, [CookieHeader; 1], Json<LoginSessionResponse>), AuthErrorResponse> {
    let result = create_bootstrap_admin(
        &*state.identity_repo,
        &*state.session_repo,
        &state.config,
        &body.username,
        &body.password,
    )
    .await
    .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    let cookie = build_session_cookie(&result.session_token.0, &state.config);
    let resp = LoginSessionResponse {
        identity: IdentityResponse {
            id: result.identity.id.0,
            username: result.identity.username.0,
            role: result.identity.role.as_str().to_string(),
        },
        profile: result.profile.map(|p| ProfileResponse {
            id: p.id,
            display_name: p.display_name,
        }),
    };

    Ok((StatusCode::CREATED, [cookie], Json(resp)))
}

async fn login_handler(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> Result<(StatusCode, [CookieHeader; 1], Json<LoginSessionResponse>), AuthErrorResponse> {
    let result = login(
        &*state.identity_repo,
        &*state.session_repo,
        &*state.profile_repo,
        &state.config,
        &body.username,
        &body.password,
    )
    .await
    .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    let cookie = build_session_cookie(&result.session_token.0, &state.config);
    let resp = LoginSessionResponse {
        identity: IdentityResponse {
            id: result.identity.id.0,
            username: result.identity.username.0,
            role: result.identity.role.as_str().to_string(),
        },
        profile: result.profile.map(|p| ProfileResponse {
            id: p.id,
            display_name: p.display_name,
        }),
    };

    Ok((StatusCode::OK, [cookie], Json(resp)))
}

async fn session_handler(
    AuthIdentity(identity): AuthIdentity,
    State(state): State<AppState>,
) -> Result<Json<LoginSessionResponse>, AuthErrorResponse> {
    let profile = if identity.role == IdentityRole::User {
        state
            .profile_repo
            .find_by_identity_id(identity.id)
            .await
            .map_err(|e| AuthErrorResponse::from_auth_error(&e))?
    } else {
        None
    };

    Ok(Json(LoginSessionResponse {
        identity: IdentityResponse {
            id: identity.id.0,
            username: identity.username.0,
            role: identity.role.as_str().to_string(),
        },
        profile: profile.map(|p| ProfileResponse {
            id: p.id,
            display_name: p.display_name,
        }),
    }))
}

async fn logout_handler(
    State(state): State<AppState>,
    RawSessionToken(token): RawSessionToken,
) -> Result<(StatusCode, [CookieHeader; 1]), AuthErrorResponse> {
    logout(&*state.session_repo, &token)
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    let clear_cookie = build_clear_cookie(&state.config);
    Ok((StatusCode::OK, [clear_cookie]))
}

async fn admin_create_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Json(body): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<LoginSessionResponse>), AuthErrorResponse> {
    let result = admin_create_user(
        &*state.identity_repo,
        &*state.profile_repo,
        &body.username,
        &body.display_name,
        &body.initial_password,
    )
    .await
    .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    Ok((
        StatusCode::CREATED,
        Json(LoginSessionResponse {
            identity: IdentityResponse {
                id: result.identity.id.0,
                username: result.identity.username.0,
                role: result.identity.role.as_str().to_string(),
            },
            profile: Some(ProfileResponse {
                id: result.profile.id,
                display_name: result.profile.display_name,
            }),
        }),
    ))
}

async fn admin_list_users_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
) -> Result<Json<ListUsersResponse>, AuthErrorResponse> {
    let users = admin_list_users(&*state.identity_repo, &*state.profile_repo)
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    Ok(Json(ListUsersResponse {
        users: users
            .into_iter()
            .map(|u| UserItem {
                id: u.profile.id,
                username: u.identity.username.0,
                display_name: u.profile.display_name,
                status: u.identity.status.as_str().to_string(),
                created_at: u.profile.created_at,
            })
            .collect(),
    }))
}

async fn admin_reset_password_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
    Json(body): Json<ResetPasswordRequest>,
) -> Result<StatusCode, AuthErrorResponse> {
    admin_reset_password(
        &*state.identity_repo,
        &*state.session_repo,
        &*state.profile_repo,
        user_id,
        &body.new_password,
    )
    .await
    .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    Ok(StatusCode::OK)
}

async fn admin_disable_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
) -> Result<StatusCode, AuthErrorResponse> {
    admin_disable_user(
        &*state.identity_repo,
        &*state.session_repo,
        &*state.profile_repo,
        user_id,
    )
    .await
    .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    Ok(StatusCode::OK)
}

async fn admin_enable_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
) -> Result<StatusCode, AuthErrorResponse> {
    admin_enable_user(&*state.identity_repo, &*state.profile_repo, user_id)
        .await
        .map_err(|e| AuthErrorResponse::from_auth_error(&e))?;

    Ok(StatusCode::OK)
}

// ─── Helpers ──────────────────────────────────────────────────

fn extract_session_token(
    parts: &Parts,
    config: &AppConfig,
) -> Result<String, AuthErrorResponse> {
    let cookie_header = parts
        .headers
        .get(header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| AuthErrorResponse::from_auth_error(&AuthError::Unauthorized))?;

    for pair in cookie_header.split(';') {
        let pair = pair.trim();
        if let Some(value) = pair.strip_prefix(&format!("{}=", config.session_cookie_name)) {
            return Ok(value.to_string());
        }
    }

    Err(AuthErrorResponse::from_auth_error(&AuthError::Unauthorized))
}

fn build_session_cookie(
    token: &str,
    config: &AppConfig,
) -> CookieHeader {
    let mut cookie = format!(
        "{}={}; HttpOnly; SameSite=Lax; Path=/; Max-Age={}",
        config.session_cookie_name, token, config.session_ttl_seconds
    );
    if config.session_cookie_secure {
        cookie.push_str("; Secure");
    }
    (header::SET_COOKIE, cookie)
}

fn build_clear_cookie(config: &AppConfig) -> CookieHeader {
    let mut cookie = format!(
        "{}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0",
        config.session_cookie_name
    );
    if config.session_cookie_secure {
        cookie.push_str("; Secure");
    }
    (header::SET_COOKIE, cookie)
}

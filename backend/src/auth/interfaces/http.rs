use axum::{
    Router,
    extract::{FromRequestParts, Path, State},
    http::{Response, StatusCode, header, request::Parts},
    response::{IntoResponse, Json},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::AppState;
use crate::auth::application::*;
use crate::auth::domain::*;
use crate::config::AppConfig;

pub fn auth_routes(state: AppState) -> Router {
    Router::new()
        .route("/auth/bootstrap/status", get(bootstrap_status_handler))
        .route(
            "/auth/bootstrap/admin",
            post(bootstrap_create_admin_handler),
        )
        .route("/auth/login", post(login_handler))
        .route("/auth/session", get(session_handler))
        .route("/auth/logout", post(logout_handler))
        .route(
            "/admin/users",
            get(admin_list_users_handler).post(admin_create_user_handler),
        )
        .route(
            "/admin/users/{id}/reset-password",
            post(admin_reset_password_handler),
        )
        .route(
            "/admin/users/{id}/disable",
            post(admin_disable_user_handler),
        )
        .route("/admin/users/{id}", get(admin_get_user_handler))
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
        let result = state
            .auth_sessions
            .get_session(&token)
            .await
            .map_err(|e| auth_error_to_response(&e))?;
        Ok(AuthIdentity(result.identity))
    }
}

pub struct AuthUser(pub UserProfile);

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AuthErrorResponse;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let RawSessionToken(token) = RawSessionToken::from_request_parts(parts, state).await?;
        let result = state
            .auth_sessions
            .get_session(&token)
            .await
            .map_err(|e| auth_error_to_response(&e))?;

        if result.identity.role != IdentityRole::User {
            return Err(forbidden_auth_error_response());
        }

        let profile = result.profile.ok_or_else(forbidden_auth_error_response)?;

        Ok(AuthUser(profile))
    }
}

pub struct AuthAdmin;

impl FromRequestParts<AppState> for AuthAdmin {
    type Rejection = AuthErrorResponse;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let RawSessionToken(token) = RawSessionToken::from_request_parts(parts, state).await?;
        let result = state
            .auth_sessions
            .get_session(&token)
            .await
            .map_err(|e| auth_error_to_response(&e))?;

        if result.identity.role != IdentityRole::Admin {
            return Err(forbidden_auth_error_response());
        }

        Ok(AuthAdmin)
    }
}

// ─── DTOs ─────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: ErrorBody,
}

pub struct AuthErrorResponse {
    status: StatusCode,
    body: ErrorResponse,
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
#[serde(rename_all = "snake_case")]
pub enum IdentityRoleDto {
    User,
    Admin,
}

impl From<IdentityRole> for IdentityRoleDto {
    fn from(role: IdentityRole) -> Self {
        match role {
            IdentityRole::User => IdentityRoleDto::User,
            IdentityRole::Admin => IdentityRoleDto::Admin,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IdentityStatusDto {
    Active,
    Disabled,
}

impl From<IdentityStatus> for IdentityStatusDto {
    fn from(status: IdentityStatus) -> Self {
        match status {
            IdentityStatus::Active => IdentityStatusDto::Active,
            IdentityStatus::Disabled => IdentityStatusDto::Disabled,
        }
    }
}

#[derive(Serialize)]
pub struct IdentityDto {
    pub id: Uuid,
    pub username: String,
    pub role: IdentityRoleDto,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
pub struct ProfileDto {
    pub id: Uuid,
    pub display_name: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
pub struct LoginSessionResponse {
    pub identity: IdentityDto,
    pub profile: Option<ProfileDto>,
}

#[derive(Deserialize)]
pub struct CreateUserRequest {
    pub username: String,
    pub display_name: String,
    pub initial_password: String,
}

#[derive(Serialize)]
pub struct UserItemDto {
    pub id: Uuid,
    pub username: String,
    pub display_name: String,
    pub status: IdentityStatusDto,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
pub struct UserListResponse {
    pub users: Vec<UserItemDto>,
}

#[derive(Deserialize)]
pub struct ResetPasswordRequest {
    pub new_password: String,
}

// ─── Handlers ─────────────────────────────────────────────────

async fn bootstrap_status_handler(
    State(state): State<AppState>,
) -> Result<Json<BootstrapStatusResponse>, AuthErrorResponse> {
    let admin_exists = state
        .auth_bootstrap
        .admin_exists()
        .await
        .map_err(|e| auth_error_to_response(&e))?;
    Ok(Json(BootstrapStatusResponse { admin_exists }))
}

type CookieHeader = (header::HeaderName, String);

async fn bootstrap_create_admin_handler(
    State(state): State<AppState>,
    Json(body): Json<CreateAdminRequest>,
) -> Result<(StatusCode, [CookieHeader; 1], Json<LoginSessionResponse>), AuthErrorResponse> {
    let result = state
        .auth_bootstrap
        .create_bootstrap_admin(&body.username, &body.password)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    let cookie = build_session_cookie(&result.session_token.0, &state.config);
    let resp = login_result_to_response(result);

    Ok((StatusCode::CREATED, [cookie], Json(resp)))
}

async fn login_handler(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> Result<(StatusCode, [CookieHeader; 1], Json<LoginSessionResponse>), AuthErrorResponse> {
    let result = state
        .auth_sessions
        .login(&body.username, &body.password)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    let cookie = build_session_cookie(&result.session_token.0, &state.config);
    let resp = login_result_to_response(result);

    Ok((StatusCode::OK, [cookie], Json(resp)))
}

async fn session_handler(
    State(state): State<AppState>,
    RawSessionToken(token): RawSessionToken,
) -> Result<Json<LoginSessionResponse>, AuthErrorResponse> {
    let result = state
        .auth_sessions
        .get_session(&token)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok(Json(identity_and_profile_to_response(
        result.identity,
        result.profile,
    )))
}

async fn logout_handler(
    State(state): State<AppState>,
    RawSessionToken(token): RawSessionToken,
) -> Result<(StatusCode, [CookieHeader; 1]), AuthErrorResponse> {
    state
        .auth_sessions
        .logout(&token)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    let clear_cookie = build_clear_cookie(&state.config);
    Ok((StatusCode::OK, [clear_cookie]))
}

async fn admin_create_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Json(body): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<LoginSessionResponse>), AuthErrorResponse> {
    let result = state
        .admin_users
        .create_user(&body.username, &body.display_name, &body.initial_password)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok((
        StatusCode::CREATED,
        Json(created_user_to_login_session_response(result)),
    ))
}

async fn admin_get_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
) -> Result<Json<UserItemDto>, AuthErrorResponse> {
    let user = state
        .admin_users
        .get_user(user_id)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok(Json(user_with_profile_to_item_dto(user)))
}

async fn admin_list_users_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
) -> Result<Json<UserListResponse>, AuthErrorResponse> {
    let users = state
        .admin_users
        .list_users()
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok(Json(users_to_list_response(users)))
}

async fn admin_reset_password_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
    Json(body): Json<ResetPasswordRequest>,
) -> Result<StatusCode, AuthErrorResponse> {
    state
        .admin_users
        .reset_password(user_id, &body.new_password)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok(StatusCode::OK)
}

async fn admin_disable_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
) -> Result<StatusCode, AuthErrorResponse> {
    state
        .admin_users
        .disable_user(user_id)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok(StatusCode::OK)
}

async fn admin_enable_user_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
) -> Result<StatusCode, AuthErrorResponse> {
    state
        .admin_users
        .enable_user(user_id)
        .await
        .map_err(|e| auth_error_to_response(&e))?;

    Ok(StatusCode::OK)
}

// ─── Conversions ───────────────────────────────────────────────

fn auth_error_to_response(err: &AuthError) -> AuthErrorResponse {
    let (status, code) = auth_error_to_status_and_code(err);
    AuthErrorResponse {
        status,
        body: ErrorResponse {
            error: ErrorBody {
                code: code.to_string(),
                message: auth_error_to_message(err),
            },
        },
    }
}

fn auth_error_to_status_and_code(err: &AuthError) -> (StatusCode, &'static str) {
    match err {
        AuthError::InvalidCredentials => (StatusCode::UNAUTHORIZED, "invalid_credentials"),
        AuthError::IdentityDisabled => (StatusCode::FORBIDDEN, "identity_disabled"),
        AuthError::IdentityNotFound => (StatusCode::UNAUTHORIZED, "invalid_credentials"),
        AuthError::SessionNotFound => (StatusCode::UNAUTHORIZED, "session_not_found"),
        AuthError::SessionExpired => (StatusCode::UNAUTHORIZED, "session_expired"),
        AuthError::SessionRevoked => (StatusCode::UNAUTHORIZED, "session_revoked"),
        AuthError::AdminAlreadyExists => (StatusCode::CONFLICT, "admin_already_exists"),
        AuthError::UsernameTaken => (StatusCode::CONFLICT, "username_taken"),
        AuthError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
        AuthError::Database(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
        AuthError::PasswordHash(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
        AuthError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
    }
}

fn auth_error_to_message(err: &AuthError) -> String {
    match err {
        AuthError::Database(_) | AuthError::PasswordHash(_) | AuthError::Internal(_) => {
            tracing::error!(error = %err, "auth request failed");
            "internal server error".to_string()
        }
        _ => err.to_string(),
    }
}

fn forbidden_auth_error_response() -> AuthErrorResponse {
    AuthErrorResponse {
        status: StatusCode::FORBIDDEN,
        body: ErrorResponse {
            error: ErrorBody {
                code: "forbidden".into(),
                message: "Forbidden".into(),
            },
        },
    }
}

fn login_result_to_response(result: LoginResult) -> LoginSessionResponse {
    identity_and_profile_to_response(result.identity, result.profile)
}

fn identity_and_profile_to_response(
    identity: Identity,
    profile: Option<UserProfile>,
) -> LoginSessionResponse {
    LoginSessionResponse {
        identity: identity_to_dto(identity),
        profile: profile.map(profile_to_dto),
    }
}

fn identity_to_dto(identity: Identity) -> IdentityDto {
    IdentityDto {
        id: identity.id.0,
        username: identity.username.into_inner(),
        role: identity.role.into(),
        created_at: identity.created_at,
        updated_at: identity.updated_at,
    }
}

fn profile_to_dto(profile: UserProfile) -> ProfileDto {
    ProfileDto {
        id: profile.id,
        display_name: profile.display_name,
        created_at: profile.created_at,
        updated_at: profile.updated_at,
    }
}

fn created_user_to_login_session_response(user: CreatedUser) -> LoginSessionResponse {
    LoginSessionResponse {
        identity: identity_to_dto(user.identity),
        profile: Some(profile_to_dto(user.profile)),
    }
}

fn users_to_list_response(users: Vec<UserWithProfile>) -> UserListResponse {
    UserListResponse {
        users: users
            .into_iter()
            .map(user_with_profile_to_item_dto)
            .collect(),
    }
}

fn user_with_profile_to_item_dto(user: UserWithProfile) -> UserItemDto {
    UserItemDto {
        id: user.profile.id,
        username: user.identity.username.into_inner(),
        display_name: user.profile.display_name,
        status: user.identity.status.into(),
        created_at: user.profile.created_at,
    }
}

// ─── Helpers ──────────────────────────────────────────────────

fn extract_session_token(parts: &Parts, config: &AppConfig) -> Result<String, AuthErrorResponse> {
    let cookie_header = parts
        .headers
        .get(header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| auth_error_to_response(&AuthError::Unauthorized))?;

    for pair in cookie_header.split(';') {
        let pair = pair.trim();
        if let Some(value) = pair.strip_prefix(&format!("{}=", config.session_cookie_name)) {
            return Ok(value.to_string());
        }
    }

    Err(auth_error_to_response(&AuthError::Unauthorized))
}

fn build_session_cookie(token: &str, config: &AppConfig) -> CookieHeader {
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

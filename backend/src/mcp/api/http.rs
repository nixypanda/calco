use std::sync::Arc;

use axum::{
    Router,
    extract::{Request, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
};
use chrono::Utc;
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService, session::never::NeverSessionManager,
};

use crate::auth::api::http::{auth_error_to_response, parse_bearer_token};
use crate::auth::domain::AuthError;
use crate::auth::module::AuthModule;
use crate::mcp::api::{McpServer, McpUser};
use crate::mcp::module::{McpConfig, McpModule};

const MCP_MAX_REQUEST_BODY_BYTES: usize = 64 * 1024;

#[derive(Clone)]
struct McpAuthState {
    auth: AuthModule,
}

pub fn mcp_routes(module: &McpModule, auth: AuthModule) -> Router {
    let catalog = module.catalog.clone();
    let summary = module.summary.clone();
    let service = StreamableHttpService::new(
        move || Ok::<_, std::io::Error>(McpServer::new(catalog.clone(), summary.clone())),
        Arc::new(NeverSessionManager::default()),
        streamable_http_config(&module.config),
    );

    Router::new()
        .route_service("/mcp", service)
        .layer(middleware::from_fn_with_state(
            McpAuthState { auth },
            authenticate_mcp_request,
        ))
}

fn streamable_http_config(config: &McpConfig) -> StreamableHttpServerConfig {
    StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_allowed_hosts(config.allowed_hosts.clone())
        .with_allowed_origins(config.allowed_origins.clone())
        .enforce_origin_validation()
        .with_max_request_body_bytes(MCP_MAX_REQUEST_BODY_BYTES)
}

async fn authenticate_mcp_request(
    State(state): State<McpAuthState>,
    mut request: Request,
    next: Next,
) -> Response {
    let mut authorization = request.headers().get_all(header::AUTHORIZATION).iter();
    let Some(value) = authorization.next() else {
        return mcp_auth_error_response(&AuthError::InvalidApiKey);
    };
    if authorization.next().is_some() {
        return mcp_auth_error_response(&AuthError::InvalidApiKey);
    }

    let raw_token = match parse_bearer_token(value) {
        Ok(token) => token,
        Err(response) => return with_www_authenticate(response.into_response()),
    };
    let authenticated = match state
        .auth
        .api_keys
        .authenticate(raw_token, Utc::now())
        .await
    {
        Ok(authenticated) => authenticated,
        Err(error) => {
            tracing::debug!(error = %error, "MCP API key authentication failed");
            return mcp_auth_error_response(&error);
        }
    };

    request.extensions_mut().insert(McpUser {
        profile_id: authenticated.profile.id,
        scope: authenticated.scope,
    });

    next.run(request).await
}

fn mcp_auth_error_response(error: &AuthError) -> Response {
    with_www_authenticate(auth_error_to_response(error).into_response())
}

fn with_www_authenticate(mut response: Response) -> Response {
    if response.status() == StatusCode::UNAUTHORIZED {
        response
            .headers_mut()
            .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
    }
    response
}

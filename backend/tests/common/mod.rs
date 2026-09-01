#![allow(dead_code)]

use std::net::SocketAddr;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use calco_backend::build_router;
use calco_backend::config::{
    AiRuntimeSettings, AppConfig, EnvironmentConfig, SessionEnvironmentConfig,
};
use http_body_util::BodyExt;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tower::ServiceExt;

pub const COOKIE_NAME: &str = "calco_session";

pub fn test_config() -> AppConfig {
    AppConfig {
        environment: EnvironmentConfig {
            database_url: String::new(),
            bind_addr: SocketAddr::from(([127, 0, 0, 1], 0)),
            session: SessionEnvironmentConfig {
                cookie_name: COOKIE_NAME.into(),
                cookie_secure: false,
                ttl_seconds: 3600,
            },
            cors_allowed_origins: Vec::new(),
        },
        ai: AiRuntimeSettings::Disabled,
    }
}

pub async fn app(pool: PgPool) -> Router {
    init_tracing();
    build_router(pool, test_config())
        .await
        .expect("build_router failed in test harness")
}

fn init_tracing() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
            )
            .with_test_writer()
            .try_init();
    });
}

pub async fn send(router: &Router, req: Request<Body>) -> (StatusCode, HeaderMap, Bytes) {
    let response = router
        .clone()
        .oneshot(req)
        .await
        .expect("router oneshot failed");
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("collect body failed")
        .to_bytes();
    (status, headers, bytes)
}

pub fn json_request(
    method: Method,
    uri: &str,
    cookie: Option<&str>,
    body: &impl Serialize,
) -> Request<Body> {
    let bytes = serde_json::to_vec(body).expect("serialize body");
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json");
    if let Some(c) = cookie {
        builder = builder.header(header::COOKIE, c);
    }
    builder.body(Body::from(bytes)).expect("build json request")
}

pub fn empty_request(method: Method, uri: &str, cookie: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(c) = cookie {
        builder = builder.header(header::COOKIE, c);
    }
    builder.body(Body::empty()).expect("build empty request")
}

pub fn parse_json<T: DeserializeOwned>(bytes: &Bytes) -> T {
    serde_json::from_slice(bytes).unwrap_or_else(|e| {
        let preview = std::str::from_utf8(bytes).unwrap_or("<invalid utf-8>");
        panic!("failed to parse JSON: {e}\nbody: {preview}")
    })
}

pub fn assert_status(actual: StatusCode, expected: StatusCode, bytes: &Bytes) {
    if actual != expected {
        let preview = std::str::from_utf8(bytes).unwrap_or("<invalid utf-8>");
        panic!("expected {expected}, got {actual}\nbody: {preview}")
    }
}

fn extract_session_cookie(headers: &HeaderMap) -> String {
    let raw = headers
        .get(header::SET_COOKIE)
        .expect("missing Set-Cookie")
        .to_str()
        .expect("Set-Cookie not utf-8");
    let first_pair = raw.split(';').next().expect("empty Set-Cookie");
    assert!(
        first_pair.starts_with(&format!("{COOKIE_NAME}=")),
        "unexpected Set-Cookie prefix: {first_pair}"
    );
    first_pair.to_string()
}

pub async fn bootstrap_admin(router: &Router) -> String {
    let body = serde_json::json!({
        "username": "admin",
        "password": "adminpassword",
    });
    let req = json_request(Method::POST, "/api/auth/bootstrap/admin", None, &body);
    let (status, headers, bytes) = send(router, req).await;
    assert_status(status, StatusCode::CREATED, &bytes);
    extract_session_cookie(&headers)
}

/// Bootstraps an admin (if needed) and then creates a regular user via the admin endpoint,
/// logs in as that user and returns the user's session cookie.
pub async fn create_user_session(
    router: &Router,
    admin_cookie: &str,
    username: &str,
    password: &str,
) -> String {
    let body = serde_json::json!({
        "username": username,
        "display_name": username,
        "initial_password": password,
    });
    let req = json_request(Method::POST, "/api/admin/users", Some(admin_cookie), &body);
    let (status, _headers, bytes) = send(router, req).await;
    assert_status(status, StatusCode::CREATED, &bytes);

    login(router, username, password).await
}

pub async fn login(router: &Router, username: &str, password: &str) -> String {
    let body = serde_json::json!({ "username": username, "password": password });
    let req = json_request(Method::POST, "/api/auth/login", None, &body);
    let (status, headers, bytes) = send(router, req).await;
    assert_status(status, StatusCode::OK, &bytes);
    extract_session_cookie(&headers)
}

/// Convenience: bootstrap admin, create one user, return (admin_cookie, user_cookie).
pub async fn bootstrap_and_user(router: &Router) -> (String, String) {
    let admin = bootstrap_admin(router).await;
    let user = create_user_session(router, &admin, "tester", "testpassword").await;
    (admin, user)
}

pub async fn get_json<T: DeserializeOwned>(router: &Router, uri: &str, cookie: &str) -> T {
    let req = empty_request(Method::GET, uri, Some(cookie));
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, StatusCode::OK, &bytes);
    parse_json(&bytes)
}

pub async fn post_json<T: DeserializeOwned>(
    router: &Router,
    uri: &str,
    cookie: &str,
    body: &impl Serialize,
    expected: StatusCode,
) -> T {
    let req = json_request(Method::POST, uri, Some(cookie), body);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, expected, &bytes);
    parse_json(&bytes)
}

pub async fn put_json<T: DeserializeOwned>(
    router: &Router,
    uri: &str,
    cookie: &str,
    body: &impl Serialize,
    expected: StatusCode,
) -> T {
    let req = json_request(Method::PUT, uri, Some(cookie), body);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, expected, &bytes);
    parse_json(&bytes)
}

pub async fn delete_no_content(router: &Router, uri: &str, cookie: &str) {
    let req = empty_request(Method::DELETE, uri, Some(cookie));
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);
}

pub async fn get_status(router: &Router, uri: &str, cookie: &str) -> (StatusCode, Value) {
    let req = empty_request(Method::GET, uri, Some(cookie));
    let (status, _h, bytes) = send(router, req).await;
    let body: Value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, body)
}

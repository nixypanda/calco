#![allow(dead_code)]

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Mutex, OnceLock};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use calco_backend::build_router;
use calco_backend::config::{AppConfig, AssistantConfig, ServerConfig, SessionConfig};
use http_body_util::BodyExt;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tower::ServiceExt;

pub const COOKIE_NAME: &str = "calco_session";
pub const ACCOUNT_HEADER: &str = "x-calco-account-id";

fn cookie_accounts() -> &'static Mutex<HashMap<String, String>> {
    static ACCOUNTS: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    ACCOUNTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn bearer_accounts() -> &'static Mutex<HashMap<String, String>> {
    static ACCOUNTS: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    ACCOUNTS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn remember_account(cookie: &str, profile_id: &str) {
    cookie_accounts()
        .lock()
        .expect("cookie account map poisoned")
        .insert(cookie.to_string(), profile_id.to_string());
}

pub fn remember_api_key(token: &str, profile_id: &str) {
    bearer_accounts()
        .lock()
        .expect("bearer account map poisoned")
        .insert(token.to_string(), profile_id.to_string());
}

pub fn remembered_cookie_account(cookie: &str) -> Option<String> {
    cookie_accounts()
        .lock()
        .expect("cookie account map poisoned")
        .get(cookie)
        .cloned()
}

fn remembered_bearer_account(token: &str) -> Option<String> {
    bearer_accounts()
        .lock()
        .expect("bearer account map poisoned")
        .get(token)
        .cloned()
}

fn remember_created_api_key(cookie: Option<&str>, bytes: &Bytes) {
    let Some(cookie) = cookie else {
        return;
    };
    let Some(account_id) = remembered_cookie_account(cookie) else {
        return;
    };
    let Ok(body) = serde_json::from_slice::<Value>(bytes) else {
        return;
    };
    if let Some(token) = body["token"].as_str() {
        remember_api_key(token, &account_id);
    }
}

pub fn test_config() -> AppConfig {
    AppConfig {
        database_url: String::new(),
        server: ServerConfig {
            bind_addr: SocketAddr::from(([127, 0, 0, 1], 0)),
            cors_allowed_origins: Vec::new(),
        },
        session: SessionConfig {
            cookie_name: COOKIE_NAME.into(),
            cookie_secure: false,
            ttl_seconds: 3600,
        },
        assistant: AssistantConfig::Disabled,
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
    let api_key_create = req.uri().path() == "/api/auth/api-keys";
    let cookie = req
        .headers()
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
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
    if api_key_create && status == StatusCode::CREATED {
        remember_created_api_key(cookie.as_deref(), &bytes);
    }
    (status, headers, bytes)
}

pub fn json_request(
    method: Method,
    uri: &str,
    cookie: Option<&str>,
    body: &impl Serialize,
) -> Request<Body> {
    let mut request = json_request_unbound(method, uri, cookie, body);
    add_remembered_cookie_account(&mut request, cookie);
    request
}

pub fn json_request_unbound(
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
    let mut request = empty_request_unbound(method, uri, cookie);
    add_remembered_cookie_account(&mut request, cookie);
    request
}

pub fn empty_request_unbound(method: Method, uri: &str, cookie: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(c) = cookie {
        builder = builder.header(header::COOKIE, c);
    }
    builder.body(Body::empty()).expect("build empty request")
}

fn add_remembered_cookie_account(request: &mut Request<Body>, cookie: Option<&str>) {
    let Some(cookie) = cookie else {
        return;
    };
    let Some(account_id) = remembered_cookie_account(cookie) else {
        return;
    };
    request.headers_mut().insert(
        header::HeaderName::from_static(ACCOUNT_HEADER),
        header::HeaderValue::from_str(&account_id).expect("account id header"),
    );
}

fn add_remembered_bearer_account(request: &mut Request<Body>, token: &str) {
    let Some(account_id) = remembered_bearer_account(token) else {
        return;
    };
    request.headers_mut().insert(
        header::HeaderName::from_static(ACCOUNT_HEADER),
        header::HeaderValue::from_str(&account_id).expect("account id header"),
    );
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
    let cookie = extract_session_cookie(&headers);
    let session: Value = parse_json(&bytes);
    if let Some(profile_id) = session["profile"]["id"].as_str() {
        remember_account(&cookie, profile_id);
    }
    cookie
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

/// Performs a GET without attaching the remembered account-binding header.
/// Use this to prove that explicitly unbound routes authenticate from the
/// cookie alone rather than accidentally passing because of test-harness
/// header injection.
pub async fn get_json_unbound<T: DeserializeOwned>(router: &Router, uri: &str, cookie: &str) -> T {
    let req = empty_request_unbound(Method::GET, uri, Some(cookie));
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
    let mut payload = serde_json::to_value(body).expect("serialize body");
    ensure_test_idempotency_key(uri, &mut payload);
    let req = json_request(Method::POST, uri, Some(cookie), &payload);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, expected, &bytes);
    parse_json(&bytes)
}

/// Ordinary lifecycle tests exercise the keyed create path by default.
/// Dedicated contract tests use raw requests when they need to prove that a
/// missing key is rejected.
fn ensure_test_idempotency_key(uri: &str, payload: &mut Value) {
    let is_log_create = matches!(uri, "/api/logs" | "/api/logs/ad-hoc" | "/api/logs/batch");
    if is_log_create && payload.get("idempotency_key").is_none() {
        payload["idempotency_key"] = Value::String(format!("test-{}", uuid::Uuid::new_v4()));
    }
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

pub async fn put_status(
    router: &Router,
    uri: &str,
    cookie: &str,
    body: &impl Serialize,
) -> (StatusCode, Value) {
    let req = json_request(Method::PUT, uri, Some(cookie), body);
    let (status, _h, bytes) = send(router, req).await;
    body_or_null(status, &bytes)
}

pub async fn post_status(
    router: &Router,
    uri: &str,
    cookie: &str,
    body: &impl Serialize,
) -> (StatusCode, Value) {
    let req = json_request(Method::POST, uri, Some(cookie), body);
    let (status, _h, bytes) = send(router, req).await;
    body_or_null(status, &bytes)
}

pub async fn delete_no_content(router: &Router, uri: &str, cookie: &str) {
    let req = empty_request(Method::DELETE, uri, Some(cookie));
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);
}

pub async fn get_status(router: &Router, uri: &str, cookie: &str) -> (StatusCode, Value) {
    let req = empty_request(Method::GET, uri, Some(cookie));
    let (status, _h, bytes) = send(router, req).await;
    body_or_null(status, &bytes)
}

pub fn bearer_json_request(
    method: Method,
    uri: &str,
    token: &str,
    body: &impl Serialize,
) -> Request<Body> {
    let mut request = bearer_json_request_unbound(method, uri, token, body);
    add_remembered_bearer_account(&mut request, token);
    request
}

pub fn bearer_json_request_unbound(
    method: Method,
    uri: &str,
    token: &str,
    body: &impl Serialize,
) -> Request<Body> {
    let bytes = serde_json::to_vec(body).expect("serialize body");
    Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(bytes))
        .expect("build bearer json request")
}

pub fn bearer_empty_request(method: Method, uri: &str, token: &str) -> Request<Body> {
    let mut request = bearer_empty_request_unbound(method, uri, token);
    add_remembered_bearer_account(&mut request, token);
    request
}

pub fn bearer_empty_request_unbound(method: Method, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .expect("build bearer request")
}

pub async fn get_json_bearer<T: DeserializeOwned>(router: &Router, uri: &str, token: &str) -> T {
    let req = bearer_empty_request(Method::GET, uri, token);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, StatusCode::OK, &bytes);
    parse_json(&bytes)
}

pub async fn post_json_bearer<T: DeserializeOwned>(
    router: &Router,
    uri: &str,
    token: &str,
    body: &impl Serialize,
    expected: StatusCode,
) -> T {
    let mut payload = serde_json::to_value(body).expect("serialize body");
    ensure_test_idempotency_key(uri, &mut payload);
    let req = bearer_json_request(Method::POST, uri, token, &payload);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, expected, &bytes);
    parse_json(&bytes)
}

pub async fn put_json_bearer<T: DeserializeOwned>(
    router: &Router,
    uri: &str,
    token: &str,
    body: &impl Serialize,
    expected: StatusCode,
) -> T {
    let req = bearer_json_request(Method::PUT, uri, token, body);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, expected, &bytes);
    parse_json(&bytes)
}

pub async fn delete_bearer_no_content(router: &Router, uri: &str, token: &str) {
    let req = bearer_empty_request(Method::DELETE, uri, token);
    let (status, _h, bytes) = send(router, req).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);
}

pub async fn get_status_bearer(router: &Router, uri: &str, token: &str) -> (StatusCode, Value) {
    let req = bearer_empty_request(Method::GET, uri, token);
    let (status, _h, bytes) = send(router, req).await;
    body_or_null(status, &bytes)
}

fn body_or_null(status: StatusCode, bytes: &Bytes) -> (StatusCode, Value) {
    let body: Value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(bytes).unwrap_or(Value::Null)
    };
    (status, body)
}

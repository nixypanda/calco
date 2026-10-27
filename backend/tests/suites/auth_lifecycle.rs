use crate::common::*;
use axum::http::{Method, StatusCode, header};
use calco_backend::auth::domain::{SessionRepo, hash_session_token};
use calco_backend::auth::infra::pg::PgSessionRepo;
use chrono::{Duration, Utc};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

#[sqlx::test]
async fn session_lifecycle_bootstrap_login_session_logout(pool: PgPool) {
    let router = app(pool).await;

    let status: Value = get_json(&router, "/api/auth/bootstrap/status", "").await;
    assert_eq!(status["admin_exists"], false);

    let bootstrap_body = json!({
        "username": "admin",
        "password": "adminpassword",
    });
    let bootstrap_req = json_request(
        Method::POST,
        "/api/auth/bootstrap/admin",
        None,
        &bootstrap_body,
    );
    let (bootstrap_status, bootstrap_headers, bootstrap_bytes) = send(&router, bootstrap_req).await;
    assert_status(bootstrap_status, StatusCode::CREATED, &bootstrap_bytes);
    let bootstrap_response: Value = parse_json(&bootstrap_bytes);
    let admin_cookie = extract_cookie_pair(&bootstrap_headers);
    assert_eq!(bootstrap_response["identity"]["username"], "admin");
    assert_eq!(bootstrap_response["identity"]["role"], "admin");
    assert!(bootstrap_response["profile"].is_null());

    let status: Value = get_json(&router, "/api/auth/bootstrap/status", &admin_cookie).await;
    assert_eq!(status["admin_exists"], true);

    let session: Value = get_json(&router, "/api/auth/session", &admin_cookie).await;
    assert_eq!(session["identity"]["username"], "admin");
    assert_eq!(session["identity"]["role"], "admin");
    assert!(session["profile"].is_null());

    let logout_req = empty_request(Method::POST, "/api/auth/logout", Some(&admin_cookie));
    let (logout_status, logout_headers, logout_bytes) = send(&router, logout_req).await;
    assert_status(logout_status, StatusCode::OK, &logout_bytes);
    assert_cookie_cleared(&logout_headers);

    let revoked_req = empty_request(Method::GET, "/api/auth/session", Some(&admin_cookie));
    let (revoked_status, _revoked_headers, revoked_bytes) = send(&router, revoked_req).await;
    assert_status(revoked_status, StatusCode::UNAUTHORIZED, &revoked_bytes);
    let revoked_body: Value = parse_json(&revoked_bytes);
    assert_eq!(revoked_body["error"]["code"], "session_revoked");

    let login_body = json!({
        "username": "admin",
        "password": "adminpassword",
    });
    let login_req = json_request(Method::POST, "/api/auth/login", None, &login_body);
    let (login_status, login_headers, login_bytes) = send(&router, login_req).await;
    assert_status(login_status, StatusCode::OK, &login_bytes);
    let login_response: Value = parse_json(&login_bytes);
    let refreshed_cookie = extract_cookie_pair(&login_headers);
    assert_ne!(refreshed_cookie, admin_cookie);
    assert_eq!(login_response["identity"]["username"], "admin");
    assert_eq!(login_response["identity"]["role"], "admin");
    assert!(login_response["profile"].is_null());
}

#[sqlx::test]
async fn session_heartbeat_after_logout_cannot_restore_the_session(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin_cookie = bootstrap_admin(&router).await;
    let raw_token = admin_cookie
        .strip_prefix(&format!("{COOKIE_NAME}="))
        .expect("session cookie value");
    let token_hash = hash_session_token(raw_token);
    let session_id: Uuid =
        sqlx::query_scalar("SELECT id FROM sessions WHERE session_token_hash = $1")
            .bind(&token_hash)
            .fetch_one(&pool)
            .await
            .unwrap();

    let aged_last_seen: chrono::DateTime<Utc> = sqlx::query_scalar(
        "UPDATE sessions SET last_seen_at = $2 WHERE id = $1 RETURNING last_seen_at",
    )
    .bind(session_id)
    .bind(Utc::now() - Duration::hours(2))
    .fetch_one(&pool)
    .await
    .unwrap();

    let repo = PgSessionRepo::new(pool.clone());
    let stale_session = repo
        .find_by_token_hash(&token_hash)
        .await
        .unwrap()
        .expect("session should exist");
    assert!(stale_session.revoked_at.is_none());

    let logout_req = empty_request(Method::POST, "/api/auth/logout", Some(&admin_cookie));
    let (logout_status, _headers, logout_bytes) = send(&router, logout_req).await;
    assert_status(logout_status, StatusCode::OK, &logout_bytes);

    repo.update(&stale_session.record_seen(Utc::now()))
        .await
        .unwrap();

    let (last_seen_after, revoked_at): (chrono::DateTime<Utc>, Option<chrono::DateTime<Utc>>) =
        sqlx::query_as("SELECT last_seen_at, revoked_at FROM sessions WHERE id = $1")
            .bind(session_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(last_seen_after, aged_last_seen);
    assert!(revoked_at.is_some());

    let session_req = empty_request(Method::GET, "/api/auth/session", Some(&admin_cookie));
    let (session_status, _headers, session_bytes) = send(&router, session_req).await;
    assert_status(session_status, StatusCode::UNAUTHORIZED, &session_bytes);
}

#[sqlx::test]
async fn session_heartbeat_advances_an_aged_last_seen(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin_cookie = bootstrap_admin(&router).await;
    let raw_token = admin_cookie
        .strip_prefix(&format!("{COOKIE_NAME}="))
        .expect("session cookie value");
    let token_hash = hash_session_token(raw_token);
    let session_id: Uuid =
        sqlx::query_scalar("SELECT id FROM sessions WHERE session_token_hash = $1")
            .bind(&token_hash)
            .fetch_one(&pool)
            .await
            .unwrap();

    let aged_last_seen: chrono::DateTime<Utc> = sqlx::query_scalar(
        "UPDATE sessions SET last_seen_at = $2 WHERE id = $1 RETURNING last_seen_at",
    )
    .bind(session_id)
    .bind(Utc::now() - Duration::hours(2))
    .fetch_one(&pool)
    .await
    .unwrap();

    let _: Value = get_json(&router, "/api/auth/session", &admin_cookie).await;

    let advanced: chrono::DateTime<Utc> =
        sqlx::query_scalar("SELECT last_seen_at FROM sessions WHERE id = $1")
            .bind(session_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(advanced > aged_last_seen);
    assert!(advanced > Utc::now() - Duration::minutes(1));
}

#[sqlx::test]
async fn new_password_policy_errors_are_reported_as_bad_requests(pool: PgPool) {
    let router = app(pool).await;

    let short_bootstrap_req = json_request(
        Method::POST,
        "/api/auth/bootstrap/admin",
        None,
        &json!({
            "username": "admin",
            "password": "short",
        }),
    );
    let (status, _headers, bytes) = send(&router, short_bootstrap_req).await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);
    let body: Value = parse_json(&bytes);
    assert_eq!(body["error"]["code"], "invalid_password");

    let admin_cookie = bootstrap_admin(&router).await;
    let short_create_req = json_request(
        Method::POST,
        "/api/admin/users",
        Some(&admin_cookie),
        &json!({
            "username": "tester",
            "display_name": "Tester",
            "initial_password": "short",
        }),
    );
    let (status, _headers, bytes) = send(&router, short_create_req).await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);
    let body: Value = parse_json(&bytes);
    assert_eq!(body["error"]["code"], "invalid_password");

    let valid_create_req = json_request(
        Method::POST,
        "/api/admin/users",
        Some(&admin_cookie),
        &json!({
            "username": "tester",
            "display_name": "Tester",
            "initial_password": "testpassword",
        }),
    );
    let (status, _headers, bytes) = send(&router, valid_create_req).await;
    assert_status(status, StatusCode::CREATED, &bytes);
    let body: Value = parse_json(&bytes);
    let user_id = body["profile"]["id"].as_str().unwrap();

    let short_reset_req = json_request(
        Method::POST,
        &format!("/api/admin/users/{user_id}/reset-password"),
        Some(&admin_cookie),
        &json!({ "new_password": "short" }),
    );
    let (status, _headers, bytes) = send(&router, short_reset_req).await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);
    let body: Value = parse_json(&bytes);
    assert_eq!(body["error"]["code"], "invalid_password");
}

#[sqlx::test]
async fn admin_user_workflows_disable_enable_reset_password(pool: PgPool) {
    let router = app(pool).await;
    let admin_cookie = bootstrap_admin(&router).await;

    let create_payload = json!({
        "username": "tester",
        "display_name": "Tester",
        "initial_password": "testpassword",
    });
    let create_req = json_request(
        Method::POST,
        "/api/admin/users",
        Some(&admin_cookie),
        &create_payload,
    );
    let (create_status, _create_headers, create_bytes) = send(&router, create_req).await;
    assert_status(create_status, StatusCode::CREATED, &create_bytes);
    let created_user: Value = parse_json(&create_bytes);
    let user_id = created_user["profile"]["id"]
        .as_str()
        .expect("user profile id missing")
        .to_string();
    assert_eq!(created_user["identity"]["username"], "tester");
    assert_eq!(created_user["identity"]["role"], "user");
    assert_eq!(created_user["profile"]["display_name"], "Tester");

    let users: Value = get_json(&router, "/api/admin/users", &admin_cookie).await;
    let listed_user = users["users"]
        .as_array()
        .expect("users array missing")
        .iter()
        .find(|user| user["id"].as_str() == Some(user_id.as_str()))
        .expect("created user missing from admin list");
    assert_eq!(listed_user["username"], "tester");
    assert_eq!(listed_user["display_name"], "Tester");
    assert_eq!(listed_user["status"], "active");

    let user_cookie = login(&router, "tester", "testpassword").await;
    let user_session: Value = get_json(&router, "/api/auth/session", &user_cookie).await;
    assert_eq!(user_session["identity"]["username"], "tester");
    assert_eq!(user_session["identity"]["role"], "user");
    assert_eq!(user_session["profile"]["id"], user_id);
    assert_eq!(user_session["profile"]["display_name"], "Tester");

    let disable_req = json_request(
        Method::POST,
        &format!("/api/admin/users/{user_id}/disable"),
        Some(&admin_cookie),
        &json!({}),
    );
    let (disable_status, _disable_headers, disable_bytes) = send(&router, disable_req).await;
    assert_status(disable_status, StatusCode::OK, &disable_bytes);

    let disabled_detail: Value = get_json(
        &router,
        &format!("/api/admin/users/{user_id}"),
        &admin_cookie,
    )
    .await;
    assert_eq!(disabled_detail["status"], "disabled");

    let disabled_session_req = empty_request(Method::GET, "/api/auth/session", Some(&user_cookie));
    let (disabled_session_status, _session_headers, disabled_session_bytes) =
        send(&router, disabled_session_req).await;
    assert_status(
        disabled_session_status,
        StatusCode::UNAUTHORIZED,
        &disabled_session_bytes,
    );
    let disabled_session_body: Value = parse_json(&disabled_session_bytes);
    assert_eq!(disabled_session_body["error"]["code"], "session_revoked");

    let disabled_login_req = json_request(
        Method::POST,
        "/api/auth/login",
        None,
        &json!({
            "username": "tester",
            "password": "testpassword",
        }),
    );
    let (disabled_login_status, _login_headers, disabled_login_bytes) =
        send(&router, disabled_login_req).await;
    assert_status(
        disabled_login_status,
        StatusCode::FORBIDDEN,
        &disabled_login_bytes,
    );
    let disabled_login_body: Value = parse_json(&disabled_login_bytes);
    assert_eq!(disabled_login_body["error"]["code"], "identity_disabled");

    let enable_req = json_request(
        Method::POST,
        &format!("/api/admin/users/{user_id}/enable"),
        Some(&admin_cookie),
        &json!({}),
    );
    let (enable_status, _enable_headers, enable_bytes) = send(&router, enable_req).await;
    assert_status(enable_status, StatusCode::OK, &enable_bytes);

    let pre_disable_session_req =
        empty_request(Method::GET, "/api/auth/session", Some(&user_cookie));
    let (pre_disable_session_status, _headers, pre_disable_session_bytes) =
        send(&router, pre_disable_session_req).await;
    assert_status(
        pre_disable_session_status,
        StatusCode::UNAUTHORIZED,
        &pre_disable_session_bytes,
    );
    let pre_disable_session_body: Value = parse_json(&pre_disable_session_bytes);
    assert_eq!(pre_disable_session_body["error"]["code"], "session_revoked");

    let old_password_cookie = login(&router, "tester", "testpassword").await;

    let reset_req = json_request(
        Method::POST,
        &format!("/api/admin/users/{user_id}/reset-password"),
        Some(&admin_cookie),
        &json!({
            "new_password": "newpassword123",
        }),
    );
    let (reset_status, _reset_headers, reset_bytes) = send(&router, reset_req).await;
    assert_status(reset_status, StatusCode::OK, &reset_bytes);

    let revoked_after_reset_req =
        empty_request(Method::GET, "/api/auth/session", Some(&old_password_cookie));
    let (revoked_after_reset_status, _headers, revoked_after_reset_bytes) =
        send(&router, revoked_after_reset_req).await;
    assert_status(
        revoked_after_reset_status,
        StatusCode::UNAUTHORIZED,
        &revoked_after_reset_bytes,
    );
    let revoked_after_reset_body: Value = parse_json(&revoked_after_reset_bytes);
    assert_eq!(revoked_after_reset_body["error"]["code"], "session_revoked");

    let old_password_login_req = json_request(
        Method::POST,
        "/api/auth/login",
        None,
        &json!({
            "username": "tester",
            "password": "testpassword",
        }),
    );
    let (old_password_login_status, _headers, old_password_login_bytes) =
        send(&router, old_password_login_req).await;
    assert_status(
        old_password_login_status,
        StatusCode::UNAUTHORIZED,
        &old_password_login_bytes,
    );
    let old_password_login_body: Value = parse_json(&old_password_login_bytes);
    assert_eq!(
        old_password_login_body["error"]["code"],
        "invalid_credentials"
    );

    let new_password_cookie = login(&router, "tester", "newpassword123").await;
    let new_session: Value = get_json(&router, "/api/auth/session", &new_password_cookie).await;
    assert_eq!(new_session["identity"]["username"], "tester");
    assert_eq!(new_session["profile"]["display_name"], "Tester");

    let final_detail: Value = get_json(
        &router,
        &format!("/api/admin/users/{user_id}"),
        &admin_cookie,
    )
    .await;
    assert_eq!(final_detail["status"], "active");
}

fn extract_cookie_pair(headers: &axum::http::HeaderMap) -> String {
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

fn assert_cookie_cleared(headers: &axum::http::HeaderMap) {
    let raw = headers
        .get(header::SET_COOKIE)
        .expect("missing Set-Cookie")
        .to_str()
        .expect("Set-Cookie not utf-8");
    assert!(
        raw.starts_with(&format!("{COOKIE_NAME}=")),
        "unexpected Set-Cookie value: {raw}"
    );
    assert!(
        raw.contains("Max-Age=0"),
        "expected logout to clear cookie, got: {raw}"
    );
}

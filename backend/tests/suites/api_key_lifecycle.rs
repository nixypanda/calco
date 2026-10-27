use crate::common::*;
use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use calco_backend::auth::domain::{ApiKeyId, ApiKeyRepo, IdentityId, hash_api_key_token};
use calco_backend::auth::infra::pg::PgApiKeyRepo;
use chrono::Utc;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

fn api_key_body(name: &str, scope: Option<&str>, expires_in_days: Option<i64>) -> Value {
    let mut body = json!({ "name": name });
    if let Some(scope) = scope {
        body["scope"] = json!(scope);
    }
    if let Some(days) = expires_in_days {
        body["expires_in_days"] = json!(days);
    }
    body
}

async fn create_api_key(
    router: &Router,
    cookie: &str,
    name: &str,
    scope: Option<&str>,
    expires_in_days: Option<i64>,
) -> Value {
    post_json(
        router,
        "/api/auth/api-keys",
        cookie,
        &api_key_body(name, scope, expires_in_days),
        StatusCode::CREATED,
    )
    .await
}

async fn create_api_key_token(
    router: &Router,
    cookie: &str,
    name: &str,
    scope: Option<&str>,
) -> String {
    let created = create_api_key(router, cookie, name, scope, None).await;
    created["token"].as_str().unwrap().to_string()
}

fn create_api_key_request(cookie: &str, body: &Value) -> Request<Body> {
    json_request(Method::POST, "/api/auth/api-keys", Some(cookie), body)
}

async fn assert_api_error(
    router: &Router,
    request: Request<Body>,
    expected_status: StatusCode,
    expected_code: &str,
) -> Value {
    let (status, _headers, bytes) = send(router, request).await;
    assert_status(status, expected_status, &bytes);
    let body: Value = parse_json(&bytes);
    assert_eq!(body["error"]["code"], expected_code);
    body
}

async fn assert_bearer_error(router: &Router, request: Request<Body>, expected_code: &str) {
    assert_api_error(router, request, StatusCode::UNAUTHORIZED, expected_code).await;
}

async fn seed_product(router: &Router, cookie: &str, name: &str) -> String {
    let product: Value = post_json(
        router,
        "/api/foods/custom",
        cookie,
        &json!({
            "name": name,
            "categories": ["api-key-tests"],
            "default_quantity": 1,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
                { "code": "PROTEIN_G", "amount_per_100g": 10 },
                { "code": "CARBS_G", "amount_per_100g": 10 },
                { "code": "FAT_G", "amount_per_100g": 2 }
            ],
            "servings": [{ "unit": "serving", "grams_per_unit": 50 }]
        }),
        StatusCode::CREATED,
    )
    .await;
    product["id"].as_str().unwrap().to_string()
}

async fn seed_log(router: &Router, cookie: &str, product_id: &str, log_date: &str) -> String {
    let log: Value = post_json(
        router,
        "/api/logs",
        cookie,
        &json!({
            "log_date": log_date,
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 50, "unit": "g" }
        }),
        StatusCode::CREATED,
    )
    .await;
    log["id"].as_str().unwrap().to_string()
}

#[sqlx::test]
async fn create_and_list_keys_store_only_hashes(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let body = api_key_body("Laptop script", None, None);
    let request = create_api_key_request(&user, &body);
    let (status, headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::CREATED, &bytes);
    let cache_control = headers
        .get(header::CACHE_CONTROL)
        .expect("create API key response must be no-store")
        .to_str()
        .unwrap();
    assert_eq!(cache_control, "no-store");

    let created: Value = parse_json(&bytes);
    let token = created["token"].as_str().expect("raw token missing");
    let key_id = created["id"].as_str().expect("key id missing");
    assert!(token.starts_with("calco_pat_"));
    assert_eq!(token.len(), 53);
    assert_eq!(created["token_hint"], token[..18]);
    assert_eq!(created["scope"], "read");
    assert!(created["expires_at"].is_null());
    assert!(created["last_used_at"].is_null());
    assert!(created.get("token_hash").is_none());

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    let items = listed["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], key_id);
    assert_eq!(items[0]["token_hint"], token[..18]);
    assert!(items[0].get("token").is_none());
    assert!(!listed.to_string().contains(token));

    let (token_hash, token_hint, scope): (String, String, String) =
        sqlx::query_as("SELECT token_hash, token_hint, scope FROM api_keys WHERE id = $1")
            .bind(Uuid::parse_str(key_id).unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(token_hash, hash_api_key_token(token));
    assert_ne!(token_hash, token);
    assert_eq!(token_hint, &token[..18]);
    assert_eq!(scope, "read");

    let raw_matches: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM api_keys WHERE token_hash = $1")
            .bind(token)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(raw_matches, 0);
}

#[sqlx::test]
async fn read_key_can_read_user_data_but_cannot_write(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Read Key Apple").await;
    let log_id = seed_log(&router, &user, &product_id, "2026-06-01").await;
    let meal: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "Read Key Meal",
            "total_quantity": { "amount": 100, "unit": "g" },
            "components": [{
                "item": { "type": "product", "id": product_id },
                "quantity": { "amount": 100, "unit": "g" }
            }]
        }),
        StatusCode::CREATED,
    )
    .await;
    let meal_id = meal["id"].as_str().unwrap();
    let token = create_api_key_token(&router, &user, "Read script", Some("read")).await;

    for uri in [
        "/api/foods/search?q=Read".to_string(),
        "/api/foods/categories".to_string(),
        format!("/api/foods/{product_id}"),
        "/api/foods/custom".to_string(),
        "/api/nutrients".to_string(),
        "/api/nutrients/ENERGY_KCAL".to_string(),
        "/api/units".to_string(),
        "/api/logs?log_date=2026-06-01".to_string(),
        format!("/api/logs/{log_id}"),
        "/api/logs/summary?from_date=2026-06-01&to_date=2026-06-01".to_string(),
        "/api/logs/recent-items?from_date=2026-06-01&to_date=2026-06-01".to_string(),
        "/api/logs/latest-slots?before=2026-06-02".to_string(),
        "/api/meals".to_string(),
        format!("/api/meals/{meal_id}"),
        format!("/api/meals/{meal_id}/nutrients?amount=100&unit=g"),
        "/api/goal?date=2026-06-01".to_string(),
        "/api/diary-preferences".to_string(),
        "/api/nutrition/details?date=2026-06-01".to_string(),
    ] {
        let request = bearer_empty_request(Method::GET, &uri, &token);
        let (status, _headers, bytes) = send(&router, request).await;
        assert_status(status, StatusCode::OK, &bytes);
    }

    let last_used: Value = post_json_bearer(
        &router,
        "/api/logs/last-used",
        &token,
        &json!({
            "from_date": "2026-05-01",
            "to_date": "2026-06-01",
            "items": [{ "type": "product", "id": product_id }]
        }),
        StatusCode::OK,
    )
    .await;
    assert!(last_used["items"].is_array());

    let write_attempts = [
        (
            "post log",
            bearer_json_request(
                Method::POST,
                "/api/logs",
                &token,
                &json!({
                    "log_date": "2026-06-01",
                    "item": { "type": "product", "id": product_id },
                    "quantity": { "amount": 10, "unit": "g" }
                }),
            ),
        ),
        (
            "create food",
            bearer_json_request(
                Method::POST,
                "/api/foods/custom",
                &token,
                &json!({
                    "name": "Denied",
                    "nutrients": [],
                    "servings": []
                }),
            ),
        ),
        (
            "update food",
            bearer_json_request(
                Method::PUT,
                &format!("/api/foods/custom/{product_id}"),
                &token,
                &json!({
                    "name": "Denied",
                    "nutrients": [],
                    "servings": []
                }),
            ),
        ),
        (
            "delete food",
            bearer_empty_request(
                Method::DELETE,
                &format!("/api/foods/custom/{product_id}"),
                &token,
            ),
        ),
        (
            "create meal",
            bearer_json_request(
                Method::POST,
                "/api/meals",
                &token,
                &json!({ "name": "Denied", "components": [] }),
            ),
        ),
        (
            "create ad hoc log",
            bearer_json_request(
                Method::POST,
                "/api/logs/ad-hoc",
                &token,
                &json!({
                    "log_date": "2026-06-01",
                    "name": "Denied",
                    "quantity": { "amount": 1, "unit": "serving" },
                    "nutrients": [
                        { "code": "ENERGY_KCAL", "amount": 100, "unit": "kcal" }
                    ]
                }),
            ),
        ),
        (
            "create logs batch",
            bearer_json_request(
                Method::POST,
                "/api/logs/batch",
                &token,
                &json!({
                    "items": [{
                        "log_date": "2026-06-01",
                        "meal_slot": "lunch",
                        "item": { "type": "product", "id": product_id },
                        "quantity": { "amount": 10, "unit": "g" }
                    }]
                }),
            ),
        ),
        (
            "update meal",
            bearer_json_request(
                Method::PUT,
                &format!("/api/meals/{meal_id}"),
                &token,
                &json!({ "name": "Denied" }),
            ),
        ),
        (
            "delete meal",
            bearer_empty_request(Method::DELETE, &format!("/api/meals/{meal_id}"), &token),
        ),
        (
            "update log",
            bearer_json_request(
                Method::PUT,
                &format!("/api/logs/{log_id}"),
                &token,
                &json!({ "notes": "denied" }),
            ),
        ),
        (
            "delete log",
            bearer_empty_request(Method::DELETE, &format!("/api/logs/{log_id}"), &token),
        ),
        (
            "update goal",
            bearer_json_request(
                Method::PUT,
                "/api/goal",
                &token,
                &json!({
                    "local_date": "2026-06-01",
                    "device_timezone": "UTC",
                    "calorie_target": 2000,
                    "protein_target_g": 150,
                    "carbs_target_g": 200,
                    "fat_target_g": 67
                }),
            ),
        ),
        (
            "update diary preferences",
            bearer_json_request(
                Method::PUT,
                "/api/diary-preferences",
                &token,
                &json!({ "enabled_meal_slots": ["lunch"] }),
            ),
        ),
    ];

    for (label, request) in write_attempts {
        let body = assert_api_error(
            &router,
            request,
            StatusCode::FORBIDDEN,
            "insufficient_scope",
        )
        .await;
        assert_eq!(body["error"]["message"], "insufficient_scope", "{label}");
    }
}

#[sqlx::test]
async fn write_key_can_create_and_mutate_own_logs(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Write Key Bread").await;
    let token = create_api_key_token(&router, &user, "Write script", Some("read_write")).await;

    let created: Value = post_json_bearer(
        &router,
        "/api/logs",
        &token,
        &json!({
            "log_date": "2026-06-02",
            "meal_slot": "lunch",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 100, "unit": "g" }
        }),
        StatusCode::CREATED,
    )
    .await;
    let log_id = created["id"].as_str().unwrap().to_string();

    let updated: Value = put_json_bearer(
        &router,
        &format!("/api/logs/{log_id}"),
        &token,
        &json!({ "notes": "written by API key" }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["notes"], "written by API key");

    let fetched: Value = get_json_bearer(&router, &format!("/api/logs/{log_id}"), &token).await;
    assert_eq!(fetched["id"], log_id);

    delete_bearer_no_content(&router, &format!("/api/logs/{log_id}"), &token).await;

    let listed: Value = get_json(&router, "/api/logs?log_date=2026-06-02", &user).await;
    assert!(listed["items"].as_array().unwrap().is_empty());
}

#[sqlx::test]
async fn api_key_access_stays_within_the_owner(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "api-key-user-b", "testpassword").await;

    let product_id = seed_product(&router, &user_a, "Owner Scoped Apple").await;
    let log_a = seed_log(&router, &user_a, &product_id, "2026-06-03").await;
    let log_b = seed_log(&router, &user_b, &product_id, "2026-06-03").await;
    let token_a = create_api_key_token(&router, &user_a, "Owner A", Some("read_write")).await;

    let (status, body) = get_status_bearer(&router, &format!("/api/logs/{log_b}"), &token_a).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "not_found");

    let request = bearer_json_request(
        Method::PUT,
        &format!("/api/logs/{log_b}"),
        &token_a,
        &json!({ "notes": "not mine" }),
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::NOT_FOUND, &bytes);

    let request = bearer_empty_request(Method::DELETE, &format!("/api/logs/{log_b}"), &token_a);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::NOT_FOUND, &bytes);

    let listed: Value = get_json_bearer(&router, "/api/logs?log_date=2026-06-03", &token_a).await;
    let ids: Vec<&str> = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![log_a.as_str()]);

    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let _: Value = put_json(
        &router,
        "/api/goal",
        &user_b,
        &json!({
            "local_date": today,
            "device_timezone": "UTC",
            "calorie_target": 2440,
            "protein_target_g": 180,
            "carbs_target_g": 250,
            "fat_target_g": 80
        }),
        StatusCode::OK,
    )
    .await;
    let goal_a: Value =
        get_json_bearer(&router, &format!("/api/goal?date={today}"), &token_a).await;
    assert_eq!(goal_a["source"], "default");
    assert_eq!(goal_a["calorie_target"], "2100");

    let _: Value = put_json(
        &router,
        "/api/diary-preferences",
        &user_b,
        &json!({ "enabled_meal_slots": ["lunch"] }),
        StatusCode::OK,
    )
    .await;
    let preferences_a: Value = get_json_bearer(&router, "/api/diary-preferences", &token_a).await;
    assert_eq!(
        preferences_a["enabled_meal_slots"],
        json!(["breakfast", "lunch", "dinner", "snack"])
    );
}

#[sqlx::test]
async fn api_key_management_is_owner_scoped(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "api-key-owner-b", "testpassword").await;

    let created = create_api_key(&router, &user_a, "Owner A key", None, None).await;
    let key_id = created["id"].as_str().unwrap();
    let token_a = created["token"].as_str().unwrap();

    let listed_b: Value = get_json(&router, "/api/auth/api-keys", &user_b).await;
    assert!(listed_b["items"].as_array().unwrap().is_empty());

    let request = empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{key_id}"),
        Some(&user_b),
    );
    assert_api_error(&router, request, StatusCode::NOT_FOUND, "api_key_not_found").await;

    let listed_a: Value = get_json(&router, "/api/auth/api-keys", &user_a).await;
    assert_eq!(listed_a["items"].as_array().unwrap().len(), 1);
    assert_eq!(listed_a["items"][0]["id"], key_id);

    let _: Value = get_json_bearer(&router, "/api/logs?log_date=2026-06-01", token_a).await;
}

#[sqlx::test]
async fn api_key_management_rejects_an_admin_cookie(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;

    let request = empty_request(Method::GET, "/api/auth/api-keys", Some(&admin));
    assert_api_error(&router, request, StatusCode::FORBIDDEN, "forbidden").await;
}

#[sqlx::test]
async fn api_key_authentication_requires_a_profile(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let token = create_api_key_token(&router, &user, "No profile", None).await;

    sqlx::query(
        "DELETE FROM user_profiles WHERE identity_id = (SELECT id FROM identities WHERE username = $1)",
    )
    .bind("tester")
    .execute(&pool)
    .await
    .unwrap();

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &token);
    assert_bearer_error(&router, request, "invalid_api_key").await;
}

#[sqlx::test]
async fn bearer_key_owner_wins_over_cookie_and_read_key_stays_read_only(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "api-key-cookie-b", "testpassword").await;

    let product_id = seed_product(&router, &user_a, "Cookie Precedence Apple").await;
    let log_a = seed_log(&router, &user_a, &product_id, "2026-06-04").await;
    let log_b = seed_log(&router, &user_b, &product_id, "2026-06-04").await;
    let read_token = create_api_key_token(&router, &user_a, "Read precedence", Some("read")).await;

    let request = Request::builder()
        .method(Method::GET)
        .uri("/api/logs?log_date=2026-06-04")
        .header(header::COOKIE, &user_b)
        .header(header::AUTHORIZATION, format!("Bearer {read_token}"))
        .body(Body::empty())
        .unwrap();
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::OK, &bytes);
    let listed: Value = parse_json(&bytes);
    let ids: Vec<&str> = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![log_a.as_str()]);
    assert!(!ids.contains(&log_b.as_str()));

    let body = serde_json::to_vec(&json!({
        "log_date": "2026-06-04",
        "meal_slot": "lunch",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 10, "unit": "g" }
    }))
    .unwrap();
    let request = Request::builder()
        .method(Method::POST)
        .uri("/api/logs")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::COOKIE, &user_b)
        .header(header::AUTHORIZATION, format!("Bearer {read_token}"))
        .body(Body::from(body))
        .unwrap();
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::FORBIDDEN, &bytes);
    let error: Value = parse_json(&bytes);
    assert_eq!(error["error"]["code"], "insufficient_scope");
}

#[sqlx::test]
async fn api_key_cannot_use_management_admin_import_or_assistant_routes(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let token = create_api_key_token(&router, &user, "Restricted", Some("read_write")).await;
    let unknown_id = Uuid::new_v4();

    for request in [
        bearer_empty_request(Method::GET, "/api/auth/api-keys", &token),
        bearer_json_request(
            Method::POST,
            "/api/auth/api-keys",
            &token,
            &api_key_body("Denied", None, None),
        ),
        bearer_empty_request(
            Method::DELETE,
            &format!("/api/auth/api-keys/{unknown_id}"),
            &token,
        ),
        bearer_empty_request(Method::GET, "/api/admin/users", &token),
        bearer_json_request(
            Method::POST,
            "/api/imports",
            &token,
            &json!({ "source": "usda" }),
        ),
        bearer_empty_request(Method::GET, &format!("/api/imports/{unknown_id}"), &token),
        bearer_empty_request(Method::GET, "/api/ai/food-assistant/status", &token),
        bearer_empty_request(Method::POST, "/api/ai/custom-food/draft", &token),
    ] {
        assert_bearer_error(&router, request, "unauthorized").await;
    }

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);
    let admin_users: Value = get_json(&router, "/api/admin/users", &admin).await;
    assert_eq!(admin_users["users"].as_array().unwrap().len(), 1);
}

#[sqlx::test]
async fn revoked_key_is_rejected_and_revocation_is_idempotent(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let created = create_api_key(&router, &user, "Revocable", None, None).await;
    let token = created["token"].as_str().unwrap();
    let key_id = created["id"].as_str().unwrap();

    let request = empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{key_id}"),
        Some(&user),
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    assert!(listed["items"].as_array().unwrap().is_empty());

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", token);
    assert_bearer_error(&router, request, "invalid_api_key").await;

    let request = empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{key_id}"),
        Some(&user),
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);

    let request = empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{}", Uuid::new_v4()),
        Some(&user),
    );
    assert_api_error(&router, request, StatusCode::NOT_FOUND, "api_key_not_found").await;
}

#[sqlx::test]
async fn expired_key_is_rejected_and_still_listed(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let created = create_api_key(&router, &user, "Expiring", None, Some(1)).await;
    let token = created["token"].as_str().unwrap().to_string();
    let key_id = created["id"].as_str().unwrap();
    assert!(!created["expires_at"].is_null());

    sqlx::query(
        "UPDATE api_keys SET created_at = now() - interval '2 days', expires_at = now() - interval '1 day' WHERE id = $1",
    )
    .bind(Uuid::parse_str(key_id).unwrap())
    .execute(&pool)
    .await
    .unwrap();

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &token);
    assert_bearer_error(&router, request, "invalid_api_key").await;

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    let items = listed["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], key_id);
}

#[sqlx::test]
async fn malformed_or_invalid_bearer_does_not_fall_back_to_the_cookie(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let token = create_api_key_token(&router, &user, "Format checks", None).await;

    for authorization in [
        "Bearer garbage".to_string(),
        "Basic abc".to_string(),
        "Bearer".to_string(),
        "Bearer    ".to_string(),
        " Bearer token".to_string(),
        format!("Bearer {token} extra"),
        format!("calco_pat_{}", "A".repeat(43)),
        format!("Bearer calco_pat_{}", "A".repeat(300)),
        token.clone(),
    ] {
        let request = Request::builder()
            .method(Method::GET)
            .uri("/api/logs?log_date=2026-06-01")
            .header(header::AUTHORIZATION, authorization)
            .body(Body::empty())
            .unwrap();
        assert_bearer_error(&router, request, "invalid_api_key").await;
    }

    let request = Request::builder()
        .method(Method::GET)
        .uri("/api/logs?log_date=2026-06-01")
        .header(header::AUTHORIZATION, format!("Bearer   {token}"))
        .body(Body::empty())
        .unwrap();
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::OK, &bytes);

    let request = Request::builder()
        .method(Method::GET)
        .uri("/api/logs?log_date=2026-06-01")
        .header(header::COOKIE, &user)
        .header(header::AUTHORIZATION, "Bearer garbage")
        .body(Body::empty())
        .unwrap();
    assert_bearer_error(&router, request, "invalid_api_key").await;

    let request = empty_request(Method::GET, "/api/logs?log_date=2026-06-01", Some(&user));
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::OK, &bytes);
}

#[sqlx::test]
async fn disable_and_enable_rotate_the_security_stamp(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let session: Value = get_json(&router, "/api/auth/session", &user).await;
    let user_id = session["profile"]["id"].as_str().unwrap().to_string();
    let token = create_api_key_token(&router, &user, "Disable me", None).await;

    for action in ["disable", "enable"] {
        let request = json_request(
            Method::POST,
            &format!("/api/admin/users/{user_id}/{action}"),
            Some(&admin),
            &json!({}),
        );
        let (status, _headers, bytes) = send(&router, request).await;
        assert_status(status, StatusCode::OK, &bytes);

        let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &token);
        assert_bearer_error(&router, request, "invalid_api_key").await;
    }
}

#[sqlx::test]
async fn password_reset_invalidates_existing_keys(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let session: Value = get_json(&router, "/api/auth/session", &user).await;
    let user_id = session["profile"]["id"].as_str().unwrap().to_string();
    let token = create_api_key_token(&router, &user, "Reset me", None).await;

    let request = json_request(
        Method::POST,
        &format!("/api/admin/users/{user_id}/reset-password"),
        Some(&admin),
        &json!({ "new_password": "newpassword123" }),
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::OK, &bytes);

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &token);
    assert_bearer_error(&router, request, "invalid_api_key").await;
}

#[sqlx::test]
async fn last_used_at_is_recorded_after_authenticated_use(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let created = create_api_key(&router, &user, "Heartbeat", None, None).await;
    assert!(created["last_used_at"].is_null());
    let token = created["token"].as_str().unwrap();

    let _: Value = get_json_bearer(&router, "/api/logs?log_date=2026-06-01", token).await;

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    assert!(!listed["items"][0]["last_used_at"].is_null());
}

#[sqlx::test]
async fn heartbeat_after_revoke_cannot_restore_a_key(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let created = create_api_key(&router, &user, "Revoked heartbeat", None, None).await;
    let key_id = created["id"].as_str().unwrap();
    let token = created["token"].as_str().unwrap().to_string();
    let id = ApiKeyId(Uuid::parse_str(key_id).unwrap());
    let repo = PgApiKeyRepo::new(pool.clone());

    let stale_snapshot = repo.find_by_id(id).await.unwrap().unwrap();
    assert!(stale_snapshot.revoked_at.is_none());

    let mut wrong_owner = stale_snapshot.clone();
    wrong_owner.identity_id = IdentityId(Uuid::new_v4());
    repo.update(&wrong_owner.record_used(Utc::now()))
        .await
        .unwrap();
    let untouched = repo.find_by_id(id).await.unwrap().unwrap();
    assert!(untouched.revoked_at.is_none());
    assert!(untouched.last_used_at.is_none());

    let request = empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{key_id}"),
        Some(&user),
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);

    repo.update(&stale_snapshot.record_used(Utc::now()))
        .await
        .unwrap();

    let stored = repo.find_by_id(id).await.unwrap().unwrap();
    assert!(stored.revoked_at.is_some());
    assert!(stored.last_used_at.is_none());

    // Router/service-level check: age last_used_at so a successful
    // authentication would refresh it, then confirm a revoked key fails
    // without touching the timestamp.
    let aged_last_used: chrono::DateTime<Utc> = sqlx::query_scalar(
        "UPDATE api_keys SET last_used_at = now() - interval '5 minutes' WHERE id = $1 RETURNING last_used_at",
    )
    .bind(id.0)
    .fetch_one(&pool)
    .await
    .unwrap();

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &token);
    assert_bearer_error(&router, request, "invalid_api_key").await;

    let after: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT last_used_at FROM api_keys WHERE id = $1")
            .bind(id.0)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(after, Some(aged_last_used));

    let still_revoked: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT revoked_at FROM api_keys WHERE id = $1")
            .bind(id.0)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(still_revoked.is_some());
}

#[sqlx::test]
async fn active_key_limit_rejects_an_eleventh_key(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let mut first_key_id = None;
    for index in 0..10 {
        let created = create_api_key(&router, &user, &format!("Key {index}"), None, None).await;
        if index == 0 {
            first_key_id = Some(created["id"].as_str().unwrap().to_string());
        }
    }

    let request = create_api_key_request(&user, &api_key_body("Over the limit", None, None));
    assert_api_error(
        &router,
        request,
        StatusCode::CONFLICT,
        "api_key_limit_reached",
    )
    .await;

    let first_key_id = first_key_id.unwrap();
    let request = empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{first_key_id}"),
        Some(&user),
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);

    let _ = create_api_key(&router, &user, "Replacement", None, None).await;
}

#[sqlx::test]
async fn expired_and_old_stamp_keys_do_not_count_toward_limit(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let mut keys = Vec::new();
    for index in 0..10 {
        let created = create_api_key(&router, &user, &format!("Key {index}"), None, None).await;
        keys.push((
            created["id"].as_str().unwrap().to_string(),
            created["token"].as_str().unwrap().to_string(),
        ));
    }

    sqlx::query(
        "UPDATE api_keys SET created_at = now() - interval '2 days', expires_at = now() - interval '1 day' WHERE id = $1",
    )
    .bind(Uuid::parse_str(&keys[0].0).unwrap())
    .execute(&pool)
    .await
    .unwrap();

    sqlx::query("UPDATE api_keys SET identity_security_stamp = $2 WHERE id = $1")
        .bind(Uuid::parse_str(&keys[1].0).unwrap())
        .bind(Uuid::new_v4())
        .execute(&pool)
        .await
        .unwrap();

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    let items = listed["items"].as_array().unwrap();
    assert_eq!(items.len(), 9);
    assert!(
        items
            .iter()
            .any(|item| item["id"].as_str() == Some(keys[0].0.as_str()))
    );
    assert!(
        !items
            .iter()
            .any(|item| item["id"].as_str() == Some(keys[1].0.as_str()))
    );
    let expired_item = items
        .iter()
        .find(|item| item["id"].as_str() == Some(keys[0].0.as_str()))
        .unwrap();
    assert!(!expired_item["expires_at"].is_null());

    for key in [&keys[0], &keys[1]] {
        let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &key.1);
        assert_bearer_error(&router, request, "invalid_api_key").await;
    }

    let last_used: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT last_used_at FROM api_keys WHERE id = $1")
            .bind(Uuid::parse_str(&keys[0].0).unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(last_used.is_none());

    let _ = create_api_key(&router, &user, "Replacement 1", None, None).await;
    let _ = create_api_key(&router, &user, "Replacement 2", None, None).await;
    let request = create_api_key_request(&user, &api_key_body("Over the limit", None, None));
    assert_api_error(
        &router,
        request,
        StatusCode::CONFLICT,
        "api_key_limit_reached",
    )
    .await;
}

#[sqlx::test]
async fn create_validates_name_scope_and_expiry(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let invalid_name = api_key_body("   ", None, None);
    assert_api_error(
        &router,
        create_api_key_request(&user, &invalid_name),
        StatusCode::BAD_REQUEST,
        "invalid_api_key_name",
    )
    .await;

    let long_name = "a".repeat(65);
    let invalid_name = api_key_body(&long_name, None, None);
    assert_api_error(
        &router,
        create_api_key_request(&user, &invalid_name),
        StatusCode::BAD_REQUEST,
        "invalid_api_key_name",
    )
    .await;

    let mut control_name = api_key_body("control", None, None);
    control_name["name"] = json!("bad\nname");
    assert_api_error(
        &router,
        create_api_key_request(&user, &control_name),
        StatusCode::BAD_REQUEST,
        "invalid_api_key_name",
    )
    .await;

    for invalid_name in [
        "zero\u{200B}width",
        "override\u{202E}name",
        "line\u{2028}separator",
        "paragraph\u{2029}separator",
        "bom\u{FEFF}name",
        "\u{200C}",
        "\u{200D}",
        " \u{200C} ",
    ] {
        let body = api_key_body(invalid_name, None, None);
        assert_api_error(
            &router,
            create_api_key_request(&user, &body),
            StatusCode::BAD_REQUEST,
            "invalid_api_key_name",
        )
        .await;
    }

    let joined_name = "family 👨\u{200D}👩\u{200D}👧";
    let joined = create_api_key(&router, &user, joined_name, None, None).await;
    assert_eq!(joined["name"], joined_name);

    let hindi_name = "हिन्दी\u{200C}key";
    let hindi = create_api_key(&router, &user, hindi_name, None, None).await;
    assert_eq!(hindi["name"], hindi_name);

    for scope in ["admin", "write", ""] {
        let invalid_scope = api_key_body("Scope", Some(scope), None);
        assert_api_error(
            &router,
            create_api_key_request(&user, &invalid_scope),
            StatusCode::BAD_REQUEST,
            "invalid_api_key_scope",
        )
        .await;
    }

    for days in [0, -1, 3651] {
        let invalid_expiry = api_key_body("Expiry", None, Some(days));
        assert_api_error(
            &router,
            create_api_key_request(&user, &invalid_expiry),
            StatusCode::BAD_REQUEST,
            "invalid_api_key_expiry",
        )
        .await;
    }

    let trimmed = create_api_key(
        &router,
        &user,
        "  Trimmed name  ",
        Some("read_write"),
        Some(30),
    )
    .await;
    assert_eq!(trimmed["name"], "Trimmed name");
    assert_eq!(trimmed["scope"], "read_write");
    assert!(!trimmed["expires_at"].is_null());
}

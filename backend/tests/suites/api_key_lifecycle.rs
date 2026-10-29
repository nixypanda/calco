use crate::common::*;
use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use calco_backend::auth::domain::{MAX_ACTIVE_API_KEYS, hash_api_key_token};
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
    let request = json_request(Method::POST, "/api/auth/api-keys", Some(&user), &body);
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
    assert_eq!(created["token_hint"], &token[..18]);
    assert_eq!(created["scope"], "read");
    assert!(created["expires_at"].is_null());
    assert!(created["last_used_at"].is_null());
    assert!(created.get("token_hash").is_none());

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    let items = listed["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], key_id);
    assert_eq!(items[0]["token_hint"], &token[..18]);
    assert!(items[0].get("token").is_none());
    assert!(!listed.to_string().contains(token));

    let token_hash: String = sqlx::query_scalar("SELECT token_hash FROM api_keys WHERE id = $1")
        .bind(Uuid::parse_str(key_id).unwrap())
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(token_hash, hash_api_key_token(token));
    assert_ne!(token_hash, token);

    let raw_matches: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM api_keys WHERE token_hash = $1")
            .bind(token)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(raw_matches, 0);

    let expiring = create_api_key(&router, &user, "Expiring", None, Some(30)).await;
    assert!(expiring["expires_at"].is_string());
}

#[sqlx::test]
async fn api_key_validation_errors_map_to_bad_request(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    for (body, code) in [
        (api_key_body(" ", None, None), "invalid_api_key_name"),
        (
            api_key_body("Scope", Some("write"), None),
            "invalid_api_key_scope",
        ),
        (
            api_key_body("Expiry", None, Some(0)),
            "invalid_api_key_expiry",
        ),
    ] {
        let request = json_request(Method::POST, "/api/auth/api-keys", Some(&user), &body);
        assert_api_error(&router, request, StatusCode::BAD_REQUEST, code).await;
    }
}

#[sqlx::test]
async fn active_key_limit_maps_to_conflict(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    for index in 0..MAX_ACTIVE_API_KEYS {
        create_api_key(&router, &user, &format!("Key {index}"), None, None).await;
    }

    let request = json_request(
        Method::POST,
        "/api/auth/api-keys",
        Some(&user),
        &api_key_body("Overflow", None, None),
    );
    assert_api_error(
        &router,
        request,
        StatusCode::CONFLICT,
        "api_key_limit_reached",
    )
    .await;

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    assert_eq!(
        listed["items"].as_array().unwrap().len(),
        MAX_ACTIVE_API_KEYS
    );
}

#[sqlx::test]
async fn revoke_key_removes_it_and_rejects_token(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let created = create_api_key(&router, &user, "Revocable", None, None).await;
    let token = created["token"].as_str().unwrap().to_string();
    let key_id = created["id"].as_str().unwrap();

    delete_no_content(&router, &format!("/api/auth/api-keys/{key_id}"), &user).await;

    let listed: Value = get_json(&router, "/api/auth/api-keys", &user).await;
    assert!(listed["items"].as_array().unwrap().is_empty());

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-01", &token);
    assert_bearer_error(&router, request, "invalid_api_key").await;
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
async fn malformed_or_invalid_bearer_does_not_fall_back_to_the_cookie(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

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

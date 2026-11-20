use crate::common::*;
use axum::body::Body;
use axum::http::{HeaderName, HeaderValue, Method, Request, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;

const ACCOUNT_HEADER: &str = "x-calco-account-id";

fn expect_account(mut request: Request<Body>, account_id: Option<&str>) -> Request<Body> {
    if let Some(account_id) = account_id {
        request.headers_mut().append(
            HeaderName::from_static(ACCOUNT_HEADER),
            HeaderValue::from_str(account_id).unwrap(),
        );
    }
    request
}

async fn send_with_account(
    router: &axum::Router,
    request: Request<Body>,
    account_id: Option<&str>,
) -> (StatusCode, Value) {
    let (status, _headers, bytes) = send(router, expect_account(request, account_id)).await;
    (status, parse_json::<Value>(&bytes))
}

fn assert_session_account_changed(
    status: StatusCode,
    body: &Value,
    account_a: &str,
    account_b: &str,
) {
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"]["code"], "session_account_changed");
    let serialized = body.to_string();
    assert!(
        !serialized.contains(account_a) && !serialized.contains(account_b),
        "account mismatch response must not leak either profile id"
    );
}

async fn profile_id(router: &axum::Router, cookie: &str) -> String {
    let session: Value = get_json(router, "/api/auth/session", cookie).await;
    session["profile"]["id"].as_str().unwrap().to_string()
}

async fn seed_product(router: &axum::Router, user: &str, name: &str) -> String {
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        user,
        &json!({
            "name": name,
            "categories": ["account-binding"],
            "default_quantity": 1,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
                { "code": "PROTEIN_G", "amount_per_100g": 10 },
                { "code": "CARBS_G", "amount_per_100g": 10 },
                { "code": "FAT_G", "amount_per_100g": 1 }
            ],
            "servings": []
        }),
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().unwrap().to_string()
}

fn batch_item(product_id: &str, slot: &str, date: &str, amount: i64) -> Value {
    json!({
        "log_date": date,
        "meal_slot": slot,
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": amount, "unit": "g" }
    })
}

#[sqlx::test]
async fn expected_account_header_binds_session_and_api_key_principals(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "otherbind", "otherpassword").await;
    let account_a = profile_id(&router, &user_a).await;
    let account_b = profile_id(&router, &user_b).await;
    assert_ne!(account_a, account_b);

    // Legacy setup without the new header remains valid.
    let product_id = seed_product(&router, &user_a, "Binding Food").await;
    let seeded_log: Value = post_json(
        &router,
        "/api/logs",
        &user_a,
        &json!({
            "log_date": "2026-06-10",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 50, "unit": "g" }
        }),
        StatusCode::CREATED,
    )
    .await;
    assert!(seeded_log["id"].is_string());

    for (uri, label) in [
        ("/api/logs?log_date=2026-06-10", "logs"),
        ("/api/foods/search?q=Binding", "catalog"),
        ("/api/meals", "meals"),
        ("/api/goal?date=2026-06-10", "goal"),
        ("/api/diary-preferences", "diary preferences"),
        (
            "/api/nutrition/details?date=2026-06-10",
            "nutrition details",
        ),
        ("/api/ai/food-assistant/status", "assistant"),
        ("/api/capabilities", "capabilities"),
    ] {
        let request = empty_request(Method::GET, uri, Some(&user_b));
        let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
        assert_session_account_changed(status, &body, &account_a, &account_b);

        let request = empty_request(Method::GET, uri, Some(&user_a));
        let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
        assert_eq!(
            status,
            StatusCode::OK,
            "{label} with matching account: {body}"
        );
        if label == "capabilities" {
            assert_eq!(
                body["log_creation_idempotency"]["request_account_binding"],
                ACCOUNT_HEADER
            );
        }
    }

    let request = empty_request(Method::GET, "/api/logs?log_date=2026-06-10", None);
    let (status, _body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "the account header must not authenticate a request without a cookie or key"
    );

    let request = empty_request(Method::GET, "/api/logs?log_date=2026-06-10", Some(&user_a));
    let (status, body) = send_with_account(&router, request, Some("not-a-uuid")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "invalid_account_header");

    let mut duplicate = empty_request(Method::GET, "/api/logs?log_date=2026-06-10", Some(&user_a));
    duplicate.headers_mut().append(
        HeaderName::from_static(ACCOUNT_HEADER),
        HeaderValue::from_str(&account_a).unwrap(),
    );
    duplicate.headers_mut().append(
        HeaderName::from_static(ACCOUNT_HEADER),
        HeaderValue::from_str(&account_a).unwrap(),
    );
    let (status, _headers, bytes) = send(&router, duplicate).await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);

    // A mismatched keyed single log must not reserve the key or write a log.
    let single_payload = json!({
        "log_date": "2026-06-11",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 60, "unit": "g" },
        "idempotency_key": "account-binding-single"
    });
    let request = json_request(Method::POST, "/api/logs", Some(&user_b), &single_payload);
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);
    let mismatch_date_a: Value = get_json(&router, "/api/logs?log_date=2026-06-11", &user_a).await;
    assert!(mismatch_date_a["items"].as_array().unwrap().is_empty());
    let mismatch_date_b: Value = get_json(&router, "/api/logs?log_date=2026-06-11", &user_b).await;
    assert!(mismatch_date_b["items"].as_array().unwrap().is_empty());

    let request = json_request(Method::POST, "/api/logs", Some(&user_a), &single_payload);
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::CREATED, "correct account: {body}");
    let created_single = body["id"].as_str().unwrap().to_string();

    let request = json_request(Method::POST, "/api/logs", Some(&user_a), &single_payload);
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::OK, "idempotent replay: {body}");
    assert_eq!(body["id"], created_single);

    // Ad-hoc mismatch and correct retry.
    let ad_hoc_payload = json!({
        "log_date": "2026-06-12",
        "meal_slot": "snack",
        "device_timezone": "UTC",
        "name": "Binding Ad Hoc",
        "brand": null,
        "quantity": { "amount": 1, "unit": "serving" },
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount": 120, "unit": "kcal" },
            { "code": "PROTEIN_G", "amount": 5, "unit": "g" },
            { "code": "CARBS_G", "amount": 12, "unit": "g" },
            { "code": "FAT_G", "amount": 4, "unit": "g" }
        ],
        "notes": null,
        "idempotency_key": "account-binding-ad-hoc"
    });
    let request = json_request(
        Method::POST,
        "/api/logs/ad-hoc",
        Some(&user_b),
        &ad_hoc_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);
    let ad_hoc_mismatch_a: Value =
        get_json(&router, "/api/logs?log_date=2026-06-12", &user_a).await;
    assert!(ad_hoc_mismatch_a["items"].as_array().unwrap().is_empty());
    let ad_hoc_mismatch_b: Value =
        get_json(&router, "/api/logs?log_date=2026-06-12", &user_b).await;
    assert!(ad_hoc_mismatch_b["items"].as_array().unwrap().is_empty());

    let request = json_request(
        Method::POST,
        "/api/logs/ad-hoc",
        Some(&user_a),
        &ad_hoc_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "correct account ad-hoc: {body}"
    );

    // Batch mismatch and correct retry.
    let batch_payload = json!({
        "idempotency_key": "account-binding-batch",
        "items": [
            batch_item(&product_id, "breakfast", "2026-06-13", 70),
            batch_item(&product_id, "lunch", "2026-06-13", 80)
        ]
    });
    let request = json_request(
        Method::POST,
        "/api/logs/batch",
        Some(&user_b),
        &batch_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);
    let batch_mismatch_a: Value = get_json(&router, "/api/logs?log_date=2026-06-13", &user_a).await;
    assert!(batch_mismatch_a["items"].as_array().unwrap().is_empty());
    let batch_mismatch_b: Value = get_json(&router, "/api/logs?log_date=2026-06-13", &user_b).await;
    assert!(batch_mismatch_b["items"].as_array().unwrap().is_empty());

    let request = json_request(
        Method::POST,
        "/api/logs/batch",
        Some(&user_a),
        &batch_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::CREATED, "correct account batch: {body}");
    assert_eq!(body["items"].as_array().unwrap().len(), 2);

    // Last-used is read-scoped and must be guarded too.
    let last_used_payload = json!({
        "from_date": "2026-06-10",
        "to_date": "2026-06-14",
        "meal_slot": "breakfast",
        "items": [{ "type": "product", "id": product_id }]
    });
    let request = json_request(
        Method::POST,
        "/api/logs/last-used",
        Some(&user_b),
        &last_used_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);

    let request = json_request(
        Method::POST,
        "/api/logs/last-used",
        Some(&user_a),
        &last_used_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::OK, "correct account last-used: {body}");

    // API-key management is session-protected and must be account-bound.
    let keys_b_before: Value = get_json(&router, "/api/auth/api-keys", &user_b).await;
    assert!(keys_b_before["items"].as_array().unwrap().is_empty());
    let create_key_payload = json!({ "name": "Mismatched key", "scope": "read" });
    let request = json_request(
        Method::POST,
        "/api/auth/api-keys",
        Some(&user_b),
        &create_key_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);
    let keys_b_after: Value = get_json(&router, "/api/auth/api-keys", &user_b).await;
    assert!(
        keys_b_after["items"].as_array().unwrap().is_empty(),
        "a rejected API-key creation must not create a key"
    );

    let request = json_request(
        Method::POST,
        "/api/auth/api-keys",
        Some(&user_a),
        &create_key_payload,
    );
    let (status, created_key) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::CREATED, "correct account key creation");
    let read_key = created_key["token"].as_str().unwrap().to_string();

    // API-key identity is its resolved profile, not the supplied header.
    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, body) = send_with_account(&router, request, Some(&account_b)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);

    let request = bearer_empty_request(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, _body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::OK);

    // A header cannot elevate a read-only API key to a write route.
    let request = bearer_json_request(
        Method::POST,
        "/api/logs",
        &read_key,
        &json!({
            "log_date": "2026-06-14",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 50, "unit": "g" }
        }),
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "insufficient_scope");

    // Absent header keeps legacy clients working.
    let legacy_log: Value = post_json(
        &router,
        "/api/logs",
        &user_b,
        &json!({
            "log_date": "2026-06-15",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 50, "unit": "g" }
        }),
        StatusCode::CREATED,
    )
    .await;
    assert!(legacy_log["id"].is_string());
    let legacy_list: Value = get_json(&router, "/api/logs?log_date=2026-06-15", &user_b).await;
    assert_eq!(legacy_list["items"].as_array().unwrap().len(), 1);
}

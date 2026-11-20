use crate::common::*;
use axum::body::Body;
use axum::http::{HeaderName, HeaderValue, Method, Request, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;

fn expect_account(mut request: Request<Body>, account_id: Option<&str>) -> Request<Body> {
    request.headers_mut().remove(ACCOUNT_HEADER);
    if let Some(account_id) = account_id {
        request.headers_mut().insert(
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
    let session: Value = get_json_unbound(router, "/api/auth/session", cookie).await;
    session["profile"]["id"].as_str().unwrap().to_string()
}

async fn seed_product(router: &axum::Router, user: &str, account_id: &str, name: &str) -> String {
    let request = json_request_unbound(
        Method::POST,
        "/api/foods/custom",
        Some(user),
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
    );
    let (status, body) = send_with_account(router, request, Some(account_id)).await;
    assert_eq!(status, StatusCode::CREATED, "seed product: {body}");
    body["id"].as_str().unwrap().to_string()
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
async fn account_header_is_required_and_must_match_the_authenticated_profile(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "otherbind", "otherpassword").await;
    let account_a = profile_id(&router, &user_a).await;
    let account_b = profile_id(&router, &user_b).await;
    assert_ne!(account_a, account_b);

    let product_id = seed_product(&router, &user_a, &account_a, "Binding Food").await;

    // Auth/bootstrap routes remain usable without an expected account.
    let status: Value = get_json_unbound(&router, "/api/auth/session", &user_a).await;
    assert_eq!(status["profile"]["id"], account_a);
    let (status, _headers, bytes) = send(
        &router,
        empty_request_unbound(Method::GET, "/api/auth/bootstrap/status", None),
    )
    .await;
    assert_status(status, StatusCode::OK, &bytes);

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
        ("/api/auth/api-keys", "API keys"),
    ] {
        let request = empty_request_unbound(Method::GET, uri, Some(&user_a));
        let (status, body) = send_with_account(&router, request, None).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "{label} without account header: {body}"
        );
        assert_eq!(body["error"]["code"], "missing_account_header");

        let request = empty_request_unbound(Method::GET, uri, Some(&user_a));
        let (status, body) = send_with_account(&router, request, Some(&account_b)).await;
        assert_session_account_changed(status, &body, &account_a, &account_b);

        let request = empty_request_unbound(Method::GET, uri, Some(&user_a));
        let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
        assert_eq!(
            status,
            StatusCode::OK,
            "{label} with matching account: {body}"
        );
    }

    // A header alone never authenticates a request.
    let request = empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", None);
    let (status, _body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Malformed, blank, and duplicate headers are explicit boundary errors.
    for invalid in ["not-a-uuid", " ", ""] {
        let request =
            empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", Some(&user_a));
        let (status, body) = send_with_account(&router, request, Some(invalid)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_account_header");
    }

    let mut duplicate =
        empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", Some(&user_a));
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
    let body: Value = parse_json(&bytes);
    assert_eq!(body["error"]["code"], "invalid_account_header");

    // A mismatched write is rejected before any side effect.
    let single_payload = json!({
        "log_date": "2026-06-11",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 60, "unit": "g" },
        "idempotency_key": "account-binding-single"
    });
    let request = json_request_unbound(Method::POST, "/api/logs", Some(&user_b), &single_payload);
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);
    let mismatch_date_a: Value = get_json(&router, "/api/logs?log_date=2026-06-11", &user_a).await;
    assert!(mismatch_date_a["items"].as_array().unwrap().is_empty());
    let mismatch_date_b: Value = get_json(&router, "/api/logs?log_date=2026-06-11", &user_b).await;
    assert!(mismatch_date_b["items"].as_array().unwrap().is_empty());

    let request = json_request_unbound(Method::POST, "/api/logs", Some(&user_a), &single_payload);
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::CREATED, "correct account: {body}");
    let created_single = body["id"].as_str().unwrap().to_string();

    let request = json_request_unbound(Method::POST, "/api/logs", Some(&user_a), &single_payload);
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::OK, "idempotent replay: {body}");
    assert_eq!(body["id"], created_single);

    // Ad-hoc and batch creates are bound too.
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
    let request = json_request_unbound(
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

    let request = json_request_unbound(
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

    let batch_payload = json!({
        "idempotency_key": "account-binding-batch",
        "items": [
            batch_item(&product_id, "breakfast", "2026-06-13", 70),
            batch_item(&product_id, "lunch", "2026-06-13", 80)
        ]
    });
    let request = json_request_unbound(
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

    let request = json_request_unbound(
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
    let request = json_request_unbound(
        Method::POST,
        "/api/logs/last-used",
        Some(&user_b),
        &last_used_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);

    let request = json_request_unbound(
        Method::POST,
        "/api/logs/last-used",
        Some(&user_a),
        &last_used_payload,
    );
    let (status, body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::OK, "correct account last-used: {body}");

    // API-key management is session-protected and account-bound.
    let keys_b_before: Value = get_json(&router, "/api/auth/api-keys", &user_b).await;
    assert!(keys_b_before["items"].as_array().unwrap().is_empty());
    let create_key_payload = json!({ "name": "Mismatched key", "scope": "read" });
    let request = json_request_unbound(
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

    let request = json_request_unbound(
        Method::POST,
        "/api/auth/api-keys",
        Some(&user_a),
        &create_key_payload,
    );
    let (status, created_key) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::CREATED, "correct account key creation");
    let read_key = created_key["token"].as_str().unwrap().to_string();

    // API-key identity is its resolved profile, not the supplied header.
    let request =
        bearer_empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, body) = send_with_account(&router, request, Some(&account_b)).await;
    assert_session_account_changed(status, &body, &account_a, &account_b);

    let request =
        bearer_empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, _body) = send_with_account(&router, request, Some(&account_a)).await;
    assert_eq!(status, StatusCode::OK);

    let request =
        bearer_empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, body) = send_with_account(&router, request, None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "missing_account_header");

    // Scope is checked before account binding.
    let request = bearer_json_request_unbound(
        Method::POST,
        "/api/logs",
        &read_key,
        &json!({
            "log_date": "2026-06-14",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 50, "unit": "g" },
            "idempotency_key": "account-binding-read-key-write"
        }),
    );
    let (status, body) = send_with_account(&router, request, Some(&account_b)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "insufficient_scope");

    // User B can still use their own account, and user A's data stays separate.
    let product_b = seed_product(&router, &user_b, &account_b, "Binding Food B").await;
    let created_b: Value = post_json(
        &router,
        "/api/logs",
        &user_b,
        &json!({
            "log_date": "2026-06-15",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_b },
            "quantity": { "amount": 50, "unit": "g" },
            "idempotency_key": "account-binding-user-b"
        }),
        StatusCode::CREATED,
    )
    .await;
    assert!(created_b["id"].is_string());
    let list_a: Value = get_json(&router, "/api/logs?log_date=2026-06-15", &user_a).await;
    assert!(list_a["items"].as_array().unwrap().is_empty());
    let list_b: Value = get_json(&router, "/api/logs?log_date=2026-06-15", &user_b).await;
    assert_eq!(list_b["items"].as_array().unwrap().len(), 1);
}

#[sqlx::test]
async fn api_key_only_client_discovers_own_profile_then_uses_bound_routes(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "discovery-other", "otherpassword").await;
    let account_a = profile_id(&router, &user_a).await;
    let account_b = profile_id(&router, &user_b).await;
    assert_ne!(account_a, account_b);

    let product_id = seed_product(&router, &user_a, &account_a, "Discovery Food").await;

    // A browser session can create a key. Its secret is returned once.
    let created_key: Value = post_json(
        &router,
        "/api/auth/api-keys",
        &user_a,
        &json!({ "name": "Discovery read key", "scope": "read" }),
        StatusCode::CREATED,
    )
    .await;
    let read_key = created_key["token"].as_str().unwrap().to_string();

    // An API-key-only client has no profile UUID yet. Discovery succeeds with
    // only the bearer key and no account-binding header.
    let request = bearer_empty_request_unbound(Method::GET, "/api/auth/identity", &read_key);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::OK, &bytes);
    let discovery: Value = parse_json(&bytes);
    assert_eq!(discovery["profile"]["id"], account_a);
    assert_eq!(discovery["identity"]["username"], "tester");
    assert!(
        !discovery.to_string().contains(&account_b),
        "identity discovery must never disclose another profile"
    );

    // The discovery route is deliberately unbound, so even a stale account
    // header cannot replace the key's own identity.
    let request = bearer_empty_request_unbound(Method::GET, "/api/auth/identity", &read_key);
    let (status, body) = send_with_account(&router, request, Some(&account_b)).await;
    assert_eq!(status, StatusCode::OK, "wrong header on discovery: {body}");
    assert_eq!(body["profile"]["id"], account_a);

    // The discovered UUID bootstraps the normal account-bound route.
    let discovered_id = discovery["profile"]["id"].as_str().unwrap();
    let request =
        bearer_empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, body) = send_with_account(&router, request, Some(discovered_id)).await;
    assert_eq!(status, StatusCode::OK, "bound read after discovery: {body}");

    let request =
        bearer_empty_request_unbound(Method::GET, "/api/logs?log_date=2026-06-10", &read_key);
    let (status, body) = send_with_account(&router, request, None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "missing_account_header");

    // Discovery does not turn API keys into management or session credentials.
    let request = bearer_empty_request_unbound(Method::GET, "/api/auth/api-keys", &read_key);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::UNAUTHORIZED, &bytes);

    let request = bearer_empty_request_unbound(Method::GET, "/api/auth/session", &read_key);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::UNAUTHORIZED, &bytes);

    // The exact key-only write bootstrap: create a read-write key from the
    // browser session, discover its profile, then create a log with that UUID.
    let write_key_response: Value = post_json(
        &router,
        "/api/auth/api-keys",
        &user_a,
        &json!({ "name": "Discovery write key", "scope": "read_write" }),
        StatusCode::CREATED,
    )
    .await;
    let write_key = write_key_response["token"].as_str().unwrap().to_string();

    let request = bearer_empty_request_unbound(Method::GET, "/api/auth/identity", &write_key);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::OK, &bytes);
    let write_discovery: Value = parse_json(&bytes);
    let write_account = write_discovery["profile"]["id"].as_str().unwrap();

    let request = bearer_json_request_unbound(
        Method::POST,
        "/api/logs",
        &write_key,
        &json!({
            "log_date": "2026-06-11",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 60, "unit": "g" },
            "idempotency_key": "discovery-write-bootstrap"
        }),
    );
    let (status, body) = send_with_account(&router, request, Some(write_account)).await;
    assert_eq!(status, StatusCode::CREATED, "key-only write: {body}");
    assert!(body["id"].is_string());
}

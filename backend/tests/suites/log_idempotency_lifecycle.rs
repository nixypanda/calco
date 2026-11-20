use crate::common::*;
use axum::http::{Method, StatusCode};
use calco_backend::capabilities::{CapabilityModule, CapabilityProbe};
use calco_backend::{build_app_state, build_router_from_state};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::collections::HashSet;
use std::sync::Arc;

struct FailingCapabilityProbe;

#[async_trait::async_trait]
impl CapabilityProbe for FailingCapabilityProbe {
    async fn journal_ready(&self) -> Result<bool, sqlx::Error> {
        Err(sqlx::Error::RowNotFound)
    }
}

async fn seed_product(router: &axum::Router, user: &str, name: &str) -> String {
    let payload = json!({
        "name": name,
        "brand": "Retry Lab",
        "categories": ["test"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 10 },
            { "code": "CARBS_G", "amount_per_100g": 10 },
            { "code": "FAT_G", "amount_per_100g": 1 }
        ],
        "servings": []
    });
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().unwrap().to_string()
}

fn batch_item(
    product_id: &str,
    meal_slot: &str,
    amount: Value,
    device_timezone: Option<&str>,
) -> Value {
    json!({
        "log_date": "2026-11-19",
        "meal_slot": meal_slot,
        "device_timezone": device_timezone,
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": amount, "unit": "g" }
    })
}

async fn listed_ids(router: &axum::Router, user: &str, date: &str) -> HashSet<String> {
    let listed: Value = get_json(router, &format!("/api/logs?log_date={date}"), user).await;
    listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect()
}

async fn operation_id_for_key(pool: &PgPool, key: &str) -> uuid::Uuid {
    sqlx::query_scalar("SELECT id FROM food_log_create_operations WHERE idempotency_key = $1")
        .bind(key)
        .fetch_one(pool)
        .await
        .expect("operation row missing")
}

async fn downgrade_operation_log_count(pool: &PgPool) {
    sqlx::query(
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT IF EXISTS food_log_create_operations_log_count",
    )
    .execute(pool)
    .await
    .unwrap();
    sqlx::query("ALTER TABLE food_log_create_operations DROP COLUMN IF EXISTS log_count")
        .execute(pool)
        .await
        .unwrap();
}

async fn apply_initial_and_log_count_migrations(pool: &PgPool) {
    sqlx::raw_sql(include_str!(
        "../../migrations/20261119000000_food_log_create_operations.sql"
    ))
    .execute(pool)
    .await
    .unwrap();
    sqlx::raw_sql(include_str!(
        "../../migrations/20261119000001_food_log_create_operations_log_count.sql"
    ))
    .execute(pool)
    .await
    .unwrap();
}

#[sqlx::test]
async fn keyed_batch_replay_after_lost_response_reuses_one_operation(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Batch Retry Food").await;

    let payload = json!({
        "idempotency_key": "batch-lost-response-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), Some("Asia/Kolkata")),
            batch_item(&product_id, "lunch", json!(80), Some("Asia/Kolkata"))
        ]
    });
    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let created_ids: Vec<String> = created["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(created_ids.len(), 2);

    // A fresh router has no in-memory state. Decimal spelling and timezone
    // whitespace normalize to the same ordered batch request.
    let replay_router = app(pool).await;
    let equivalent = json!({
        "idempotency_key": "batch-lost-response-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70.00), Some("  Asia/Kolkata  ")),
            batch_item(&product_id, "lunch", json!(80.0), Some("Asia/Kolkata"))
        ]
    });
    let replayed: Value = post_json(
        &replay_router,
        "/api/logs/batch",
        &user,
        &equivalent,
        StatusCode::OK,
    )
    .await;
    let replayed_ids: Vec<String> = replayed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(replayed_ids, created_ids, "replay keeps the original order");
    assert_eq!(
        listed_ids(&replay_router, &user, "2026-11-19").await.len(),
        2
    );

    let mut changed = equivalent.clone();
    changed["items"][1]["quantity"]["amount"] = json!(81);
    let conflict: Value = post_json(
        &replay_router,
        "/api/logs/batch",
        &user,
        &changed,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(conflict["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&replay_router, &user, "2026-11-19").await.len(),
        2,
        "a changed payload must not append a second batch"
    );

    let mut reordered = equivalent.clone();
    reordered["items"].as_array_mut().unwrap().reverse();
    let reordered_conflict: Value = post_json(
        &replay_router,
        "/api/logs/batch",
        &user,
        &reordered,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(reordered_conflict["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&replay_router, &user, "2026-11-19").await.len(),
        2,
        "batch order is part of the operation identity"
    );
}

#[sqlx::test]
async fn failed_keyed_batch_leaves_no_partial_writes_or_operation(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Batch Atomic Food").await;
    let missing_product_id = uuid::Uuid::new_v4().to_string();

    let payload = json!({
        "idempotency_key": "batch-partial-failure-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), None),
            batch_item(&missing_product_id, "lunch", json!(80), None)
        ]
    });
    let _: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::NOT_FOUND,
    )
    .await;

    assert!(
        listed_ids(&router, &user, "2026-11-19").await.is_empty(),
        "a failed batch must not persist its valid prefix"
    );
    let operation_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operations WHERE idempotency_key = $1",
    )
    .bind("batch-partial-failure-key")
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        operation_count, 0,
        "a failed batch must not reserve the operation key"
    );

    let corrected = json!({
        "idempotency_key": "batch-partial-failure-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), None),
            batch_item(&product_id, "lunch", json!(80), None)
        ]
    });
    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &corrected,
        StatusCode::CREATED,
    )
    .await;
    assert_eq!(created["items"].as_array().unwrap().len(), 2);
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 2);
}

#[sqlx::test]
async fn concurrent_keyed_batches_create_exactly_one_operation(pool: PgPool) {
    const REQUESTS: usize = 6;

    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Concurrent Batch Food").await;
    let payload = json!({
        "idempotency_key": "batch-concurrent-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(60), None),
            batch_item(&product_id, "dinner", json!(90), None)
        ]
    });

    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(REQUESTS));
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..REQUESTS {
        let router = router.clone();
        let user = user.clone();
        let payload = payload.clone();
        let barrier = barrier.clone();
        tasks.spawn(async move {
            barrier.wait().await;
            let request = json_request(Method::POST, "/api/logs/batch", Some(&user), &payload);
            let (status, _headers, bytes) = send(&router, request).await;
            (status, parse_json::<Value>(&bytes))
        });
    }

    let mut created = 0;
    let mut replayed = 0;
    let mut operation_ids = None;
    while let Some(result) = tasks.join_next().await {
        let (status, body) = result.expect("concurrent request task panicked");
        match status {
            StatusCode::CREATED => created += 1,
            StatusCode::OK => replayed += 1,
            unexpected => panic!("unexpected status {unexpected}: {body}"),
        }
        let ids: Vec<String> = body["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_str().unwrap().to_string())
            .collect();
        match &operation_ids {
            Some(existing) => assert_eq!(&ids, existing),
            None => operation_ids = Some(ids),
        }
    }

    assert_eq!(created, 1);
    assert_eq!(replayed, REQUESTS - 1);
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 2);

    // Different payloads racing for the same new key must produce one winner
    // and one conflict, never a replay of the wrong payload.
    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
    let mut contenders = tokio::task::JoinSet::new();
    for amount in [60, 61] {
        let router = router.clone();
        let user = user.clone();
        let barrier = barrier.clone();
        let mut contender = payload.clone();
        contender["idempotency_key"] = json!("batch-concurrent-conflict-key");
        contender["items"][0]["quantity"]["amount"] = json!(amount);
        contenders.spawn(async move {
            barrier.wait().await;
            let request = json_request(Method::POST, "/api/logs/batch", Some(&user), &contender);
            let (status, _headers, bytes) = send(&router, request).await;
            (status, parse_json::<Value>(&bytes))
        });
    }
    let mut statuses = Vec::new();
    while let Some(result) = contenders.join_next().await {
        let (status, body) = result.expect("concurrent request task panicked");
        if status == StatusCode::CONFLICT {
            assert_eq!(body["error"]["code"], "conflict");
        }
        statuses.push(status);
    }
    statuses.sort();
    assert_eq!(statuses, [StatusCode::CREATED, StatusCode::CONFLICT]);
    assert_eq!(
        listed_ids(&router, &user, "2026-11-19").await.len(),
        4,
        "only the winning conflicting batch may be persisted"
    );
}

#[sqlx::test]
async fn deleted_keyed_batch_cannot_be_recreated_by_replay(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Batch Deletion Food").await;
    let payload = json!({
        "idempotency_key": "batch-deletion-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(55), None),
            batch_item(&product_id, "lunch", json!(65), None)
        ]
    });
    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let created_ids: Vec<String> = created["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();

    delete_no_content(&router, &format!("/api/logs/{}", created_ids[0]), &user).await;
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 1);

    let partial_replay: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(partial_replay["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&router, &user, "2026-11-19").await.len(),
        1,
        "replay must not recreate a deleted batch member"
    );

    delete_no_content(&router, &format!("/api/logs/{}", created_ids[1]), &user).await;
    let empty_replay: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(empty_replay["error"]["code"], "conflict");
    assert!(
        listed_ids(&router, &user, "2026-11-19").await.is_empty(),
        "a fully deleted batch must stay deleted"
    );
}

fn ad_hoc_payload(idempotency_key: &str) -> Value {
    json!({
        "log_date": "2026-11-19",
        "meal_slot": "snack",
        "device_timezone": "Asia/Kolkata",
        "name": "  Ad-hoc retry food  ",
        "brand": null,
        "quantity": { "amount": 1, "unit": "serving" },
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount": 520, "unit": "kcal" },
            { "code": "PROTEIN_G", "amount": 24, "unit": "g" },
            { "code": "CARBS_G", "amount": 48, "unit": "g" },
            { "code": "FAT_G", "amount": 25, "unit": "g" }
        ],
        "notes": "same ad-hoc request",
        "idempotency_key": idempotency_key
    })
}

#[sqlx::test]
async fn keyed_ad_hoc_replay_conflict_and_deletion_behavior(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let payload = ad_hoc_payload("ad-hoc-lost-response-key");

    let created: Value = post_json(
        &router,
        "/api/logs/ad-hoc",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let log_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["item"]["name"], "Ad-hoc retry food");

    let replay_router = app(pool).await;
    let mut equivalent = ad_hoc_payload("ad-hoc-lost-response-key");
    equivalent["device_timezone"] = json!("  Asia/Kolkata  ");
    equivalent["quantity"]["amount"] = json!(1.00);
    equivalent["nutrients"][0]["amount"] = json!(520.00);
    // Nutrients are compared as an order-independent set in the fingerprint.
    equivalent["nutrients"].as_array_mut().unwrap().reverse();
    let replayed: Value = post_json(
        &replay_router,
        "/api/logs/ad-hoc",
        &user,
        &equivalent,
        StatusCode::OK,
    )
    .await;
    assert_eq!(replayed["id"], log_id);
    assert_eq!(
        listed_ids(&replay_router, &user, "2026-11-19").await.len(),
        1
    );

    let mut changed = equivalent.clone();
    changed["notes"] = json!("changed after the lost response");
    let conflict: Value = post_json(
        &replay_router,
        "/api/logs/ad-hoc",
        &user,
        &changed,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(conflict["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&replay_router, &user, "2026-11-19").await.len(),
        1
    );

    delete_no_content(&replay_router, &format!("/api/logs/{log_id}"), &user).await;
    let deleted_replay: Value = post_json(
        &replay_router,
        "/api/logs/ad-hoc",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(deleted_replay["error"]["code"], "conflict");
    assert!(
        listed_ids(&replay_router, &user, "2026-11-19")
            .await
            .is_empty(),
        "replaying a deleted ad-hoc operation must not resurrect the log"
    );

    let replacement = ad_hoc_payload("ad-hoc-replacement-key");
    let created_again: Value = post_json(
        &replay_router,
        "/api/logs/ad-hoc",
        &user,
        &replacement,
        StatusCode::CREATED,
    )
    .await;
    assert_ne!(created_again["id"], log_id);
}

#[sqlx::test]
async fn concurrent_keyed_ad_hoc_requests_create_exactly_one_log(pool: PgPool) {
    const REQUESTS: usize = 6;

    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let payload = ad_hoc_payload("ad-hoc-concurrent-key");

    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(REQUESTS));
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..REQUESTS {
        let router = router.clone();
        let user = user.clone();
        let payload = payload.clone();
        let barrier = barrier.clone();
        tasks.spawn(async move {
            barrier.wait().await;
            let request = json_request(Method::POST, "/api/logs/ad-hoc", Some(&user), &payload);
            let (status, _headers, bytes) = send(&router, request).await;
            (status, parse_json::<Value>(&bytes))
        });
    }

    let mut created = 0;
    let mut replayed = 0;
    let mut log_ids = HashSet::new();
    while let Some(result) = tasks.join_next().await {
        let (status, body) = result.expect("concurrent request task panicked");
        match status {
            StatusCode::CREATED => created += 1,
            StatusCode::OK => replayed += 1,
            unexpected => panic!("unexpected status {unexpected}: {body}"),
        }
        log_ids.insert(body["id"].as_str().unwrap().to_string());
    }

    assert_eq!(created, 1);
    assert_eq!(replayed, REQUESTS - 1);
    assert_eq!(log_ids.len(), 1);
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 1);
}

#[sqlx::test]
async fn idempotency_key_namespace_is_shared_across_logging_paths(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Shared Key Food").await;

    let single = json!({
        "log_date": "2026-11-19",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 50, "unit": "g" },
        "idempotency_key": "shared-log-key"
    });
    let _: Value = post_json(&router, "/api/logs", &user, &single, StatusCode::CREATED).await;

    let batch = json!({
        "idempotency_key": "shared-log-key",
        "items": [batch_item(&product_id, "lunch", json!(60), None)]
    });
    let batch_conflict: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &batch,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(batch_conflict["error"]["code"], "conflict");

    let ad_hoc = ad_hoc_payload("shared-log-key");
    let ad_hoc_conflict: Value = post_json(
        &router,
        "/api/logs/ad-hoc",
        &user,
        &ad_hoc,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(ad_hoc_conflict["error"]["code"], "conflict");
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 1);
}

#[sqlx::test]
async fn capability_endpoint_requires_auth_and_reports_journal_v2(pool: PgPool) {
    let router = app(pool).await;
    let request = empty_request(Method::GET, "/api/capabilities", None);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::UNAUTHORIZED, &bytes);

    let (_admin, user) = bootstrap_and_user(&router).await;
    let capabilities: Value = get_json(&router, "/api/capabilities", &user).await;
    let capability = &capabilities["log_creation_idempotency"];
    assert_eq!(capability["version"], 2);
    assert_eq!(capability["single"], true);
    assert_eq!(capability["ad_hoc"], true);
    assert_eq!(capability["batch"], true);
    assert_eq!(capability["batch_key_location"], "top_level");
    assert_eq!(capability["deleted_operation_replay"], "conflict");
    assert_eq!(
        capability["pre_migration_deleted_keys"],
        "reconciliation_only"
    );
    assert_eq!(capability["request_account_binding"], "x-calco-account-id");

    // Native clients commonly use a read_write API key rather than a browser
    // session. A read key must be enough to discover the capability.
    let created_key: Value = post_json(
        &router,
        "/api/auth/api-keys",
        &user,
        &json!({ "name": "Native capability probe", "scope": "read" }),
        StatusCode::CREATED,
    )
    .await;
    let token = created_key["token"].as_str().unwrap();
    let via_api_key: Value = get_json_bearer(&router, "/api/capabilities", token).await;
    assert_eq!(via_api_key, capabilities);
}

#[sqlx::test]
async fn capability_endpoint_fails_closed_without_journal_migration(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    // Simulate a server running the new binary before the journal migration.
    sqlx::query("DROP TABLE food_log_create_operation_logs")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP TABLE food_log_create_operations")
        .execute(&pool)
        .await
        .unwrap();

    let capabilities: Value = get_json(&router, "/api/capabilities", &user).await;
    let capability = &capabilities["log_creation_idempotency"];
    assert_eq!(capability["version"], 0);
    assert_eq!(capability["single"], false);
    assert_eq!(capability["ad_hoc"], false);
    assert_eq!(capability["batch"], false);
    assert!(capability["batch_key_location"].is_null());
    assert_eq!(capability["deleted_operation_replay"], "unavailable");
    assert_eq!(
        capability["pre_migration_deleted_keys"],
        "reconciliation_only"
    );
    assert!(
        capability["request_account_binding"].is_null(),
        "unsupported schema must not advertise account binding"
    );
}

#[sqlx::test]
async fn capability_probe_failure_returns_503_instead_of_version_zero(pool: PgPool) {
    let mut state = build_app_state(pool, test_config())
        .await
        .expect("build app state");
    state.capabilities = CapabilityModule::new(Arc::new(FailingCapabilityProbe));
    let router = build_router_from_state(state);
    let (_admin, user) = bootstrap_and_user(&router).await;

    let request = empty_request(Method::GET, "/api/capabilities", Some(&user));
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::SERVICE_UNAVAILABLE, &bytes);
    let body: Value = parse_json(&bytes);
    assert_eq!(body["error"]["code"], "capability_unavailable");
    assert!(
        body.get("log_creation_idempotency").is_none(),
        "a transient probe failure must not be reported as an authoritative version 0"
    );
}

#[sqlx::test]
async fn capability_rejects_nonunique_same_name_operation_index(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    sqlx::query("DROP INDEX food_log_create_operations_user_idempotency_key_idx")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "CREATE INDEX food_log_create_operations_user_idempotency_key_idx \
         ON food_log_create_operations (user_id, idempotency_key)",
    )
    .execute(&pool)
    .await
    .unwrap();

    let capabilities: Value = get_json(&router, "/api/capabilities", &user).await;
    assert_eq!(
        capabilities["log_creation_idempotency"]["version"], 0,
        "matching the index name is not enough; it must be unique"
    );
}

#[sqlx::test]
async fn capability_rejects_old_schema_without_log_count(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    downgrade_operation_log_count(&pool).await;

    let capabilities: Value = get_json(&router, "/api/capabilities", &user).await;
    assert_eq!(
        capabilities["log_creation_idempotency"]["version"], 0,
        "an old operation schema without log_count must fail closed"
    );
}

#[sqlx::test]
async fn capability_rejects_missing_child_primary_key(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    sqlx::query(
        "ALTER TABLE food_log_create_operation_logs \
         DROP CONSTRAINT food_log_create_operation_logs_pkey",
    )
    .execute(&pool)
    .await
    .unwrap();

    let capabilities: Value = get_json(&router, "/api/capabilities", &user).await;
    assert_eq!(
        capabilities["log_creation_idempotency"]["version"], 0,
        "a missing child primary key must fail closed"
    );
}

#[sqlx::test]
async fn empty_operation_child_links_are_rejected_without_false_success(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Empty Link Food").await;
    let payload = json!({
        "idempotency_key": "empty-child-links-key",
        "items": [batch_item(&product_id, "breakfast", json!(70), None)]
    });
    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let log_id = created["items"][0]["id"].as_str().unwrap().to_string();
    let operation_id = operation_id_for_key(&pool, "empty-child-links-key").await;

    sqlx::query("DELETE FROM food_log_create_operation_logs WHERE operation_id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();

    let replay: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(replay["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&router, &user, "2026-11-19").await.len(),
        1,
        "a malformed operation must not append logs"
    );
    let (status, _) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::OK);

    let operation_rows: i64 =
        sqlx::query_scalar("SELECT count(*) FROM food_log_create_operations WHERE id = $1")
            .bind(operation_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        operation_rows, 1,
        "operations and tombstones are retained indefinitely"
    );
}

#[sqlx::test]
async fn partial_operation_child_links_are_rejected(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Partial Link Food").await;
    let payload = json!({
        "idempotency_key": "partial-child-links-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), None),
            batch_item(&product_id, "lunch", json!(80), None)
        ]
    });
    let _: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let operation_id = operation_id_for_key(&pool, "partial-child-links-key").await;

    sqlx::query(
        "DELETE FROM food_log_create_operation_logs \
         WHERE operation_id = $1 AND position = 1",
    )
    .bind(operation_id)
    .execute(&pool)
    .await
    .unwrap();

    let replay: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(replay["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&router, &user, "2026-11-19").await.len(),
        2,
        "a partial operation must not replay a valid-looking prefix"
    );

    let links: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operation_logs WHERE operation_id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        links, 1,
        "replay must not silently repair or delete the remaining link"
    );
}

#[sqlx::test]
async fn operation_child_links_cannot_expose_another_users_log(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let other_user = create_user_session(&router, &admin, "othercap", "otherpassword").await;
    let product_id = seed_product(&router, &user, "Owner Link Food").await;
    let other_product_id = seed_product(&router, &other_user, "Other Owner Food").await;

    let payload = json!({
        "idempotency_key": "cross-user-link-key",
        "items": [batch_item(&product_id, "breakfast", json!(70), None)]
    });
    let _: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let operation_id = operation_id_for_key(&pool, "cross-user-link-key").await;

    let other_log: Value = post_json(
        &router,
        "/api/logs",
        &other_user,
        &json!({
            "log_date": "2026-11-19",
            "meal_slot": "lunch",
            "item": { "type": "product", "id": other_product_id },
            "quantity": { "amount": 90, "unit": "g" }
        }),
        StatusCode::CREATED,
    )
    .await;
    let other_log_id = other_log["id"].as_str().unwrap().to_string();

    sqlx::query(
        "UPDATE food_log_create_operation_logs SET food_log_id = $1 \
         WHERE operation_id = $2 AND position = 0",
    )
    .bind(uuid::Uuid::parse_str(&other_log_id).unwrap())
    .bind(operation_id)
    .execute(&pool)
    .await
    .unwrap();

    let replay: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(replay["error"]["code"], "conflict");
    assert!(
        !replay.to_string().contains(&other_log_id),
        "a corrupted link must never disclose another user's log"
    );

    let (status, _) = get_status(&router, &format!("/api/logs/{other_log_id}"), &other_user).await;
    assert_eq!(status, StatusCode::OK);
}

#[sqlx::test]
async fn database_failure_after_partial_batch_insert_rolls_back_everything(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Rollback Food").await;
    let payload = json!({
        "idempotency_key": "rollback-after-first-log-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), None),
            batch_item(&product_id, "lunch", json!(80), None)
        ]
    });

    sqlx::query(
        r#"
        CREATE OR REPLACE FUNCTION calco_test_fail_second_food_log_insert()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
            IF (
                SELECT count(*)
                FROM food_logs
                WHERE user_id = NEW.user_id AND log_date = NEW.log_date
            ) >= 1 THEN
                RAISE EXCEPTION 'forced second food log insert failure';
            END IF;
            RETURN NEW;
        END;
        $$;
        "#,
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        r#"
        CREATE TRIGGER calco_test_fail_second_food_log_insert
        BEFORE INSERT ON food_logs
        FOR EACH ROW
        EXECUTE FUNCTION calco_test_fail_second_food_log_insert();
        "#,
    )
    .execute(&pool)
    .await
    .unwrap();

    let request = json_request(Method::POST, "/api/logs/batch", Some(&user), &payload);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::INTERNAL_SERVER_ERROR, &bytes);
    let failure: Value = parse_json(&bytes);
    assert_eq!(failure["error"]["code"], "internal");

    let log_count: i64 = sqlx::query_scalar("SELECT count(*) FROM food_logs")
        .fetch_one(&pool)
        .await
        .unwrap();
    let nutrient_count: i64 = sqlx::query_scalar("SELECT count(*) FROM food_log_nutrients")
        .fetch_one(&pool)
        .await
        .unwrap();
    let operation_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operations WHERE idempotency_key = $1",
    )
    .bind("rollback-after-first-log-key")
    .fetch_one(&pool)
    .await
    .unwrap();
    let link_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operation_logs link \
         JOIN food_log_create_operations operation ON operation.id = link.operation_id \
         WHERE operation.idempotency_key = $1",
    )
    .bind("rollback-after-first-log-key")
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(log_count, 0, "the first inserted log must roll back");
    assert_eq!(
        nutrient_count, 0,
        "the first log's nutrients must roll back"
    );
    assert_eq!(
        operation_count, 0,
        "the operation row must not survive a failed commit"
    );
    assert_eq!(link_count, 0, "ordered operation links must roll back");

    sqlx::query("DROP TRIGGER calco_test_fail_second_food_log_insert ON food_logs")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP FUNCTION calco_test_fail_second_food_log_insert()")
        .execute(&pool)
        .await
        .unwrap();

    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    assert_eq!(created["items"].as_array().unwrap().len(), 2);
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 2);
}

#[sqlx::test]
async fn migration_backfill_replays_legacy_key_and_keeps_delete_tombstone(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Backfill Food").await;
    let payload = json!({
        "log_date": "2026-11-19",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 70, "unit": "g" },
        "notes": "legacy note",
        "idempotency_key": "legacy-backfill-key"
    });
    let created: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CREATED).await;
    let log_id = created["id"].as_str().unwrap().to_string();
    let operation_id = operation_id_for_key(&pool, "legacy-backfill-key").await;

    // Simulate a pre-migration keyed log: the log keeps its key and
    // fingerprint, but the operation journal does not exist yet.
    sqlx::query("DELETE FROM food_log_create_operations WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    downgrade_operation_log_count(&pool).await;
    apply_initial_and_log_count_migrations(&pool).await;

    let replayed: Value = post_json(&router, "/api/logs", &user, &payload, StatusCode::OK).await;
    assert_eq!(replayed["id"], log_id);
    let operation_id = operation_id_for_key(&pool, "legacy-backfill-key").await;
    let links: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operation_logs WHERE operation_id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(links, 1, "backfill must create the ordered child link");

    delete_no_content(&router, &format!("/api/logs/{log_id}"), &user).await;
    let conflict: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CONFLICT).await;
    assert_eq!(conflict["error"]["code"], "conflict");
    assert!(
        listed_ids(&router, &user, "2026-11-19").await.is_empty(),
        "a backfilled key must not recreate a deleted log"
    );
    let links_after_delete: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operation_logs WHERE operation_id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        links_after_delete, 1,
        "deleting a log must not remove its operation tombstone link"
    );
}

#[sqlx::test]
async fn migration_backfill_without_fingerprint_stays_conflict(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Legacy No Fingerprint Food").await;
    let payload = json!({
        "log_date": "2026-11-19",
        "meal_slot": "lunch",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 60, "unit": "g" },
        "idempotency_key": "legacy-no-fingerprint-key"
    });
    let created: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CREATED).await;
    let log_id = created["id"].as_str().unwrap().to_string();
    let operation_id = operation_id_for_key(&pool, "legacy-no-fingerprint-key").await;

    sqlx::query("DELETE FROM food_log_create_operations WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("UPDATE food_logs SET request_fingerprint = NULL WHERE id = $1")
        .bind(uuid::Uuid::parse_str(&log_id).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    downgrade_operation_log_count(&pool).await;
    apply_initial_and_log_count_migrations(&pool).await;

    let conflict: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CONFLICT).await;
    assert_eq!(conflict["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&router, &user, "2026-11-19").await.len(),
        1,
        "a legacy key without a fingerprint must never create a duplicate"
    );
}

#[sqlx::test]
async fn old_operation_schema_upgrade_derives_log_count_and_replays_batch(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Old Schema Batch Food").await;
    let payload = json!({
        "idempotency_key": "old-schema-batch-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), None),
            batch_item(&product_id, "lunch", json!(80), None)
        ]
    });
    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let created_ids: Vec<String> = created["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    let operation_id = operation_id_for_key(&pool, "old-schema-batch-key").await;
    let links_before: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operation_logs WHERE operation_id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(links_before, 2);

    // Simulate the deployed pre-log_count journal and run only the additive
    // upgrade, as an existing installation would.
    downgrade_operation_log_count(&pool).await;
    sqlx::raw_sql(include_str!(
        "../../migrations/20261119000001_food_log_create_operations_log_count.sql"
    ))
    .execute(&pool)
    .await
    .unwrap();

    let upgraded_count: i32 =
        sqlx::query_scalar("SELECT log_count FROM food_log_create_operations WHERE id = $1")
            .bind(operation_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        upgraded_count, 2,
        "upgrade must derive log_count from existing child links, not default to one"
    );

    let replayed: Value =
        post_json(&router, "/api/logs/batch", &user, &payload, StatusCode::OK).await;
    let replayed_ids: Vec<String> = replayed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(replayed_ids, created_ids);

    delete_no_content(&router, &format!("/api/logs/{}", created_ids[0]), &user).await;
    let conflict: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(conflict["error"]["code"], "conflict");
    let links_after: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operation_logs WHERE operation_id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        links_after, 2,
        "the additive upgrade and deletion must preserve the tombstone links"
    );
}

#[sqlx::test]
async fn corrupted_operation_metadata_returns_conflict_without_writes(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Corrupt Metadata Food").await;
    let payload = json!({
        "idempotency_key": "corrupt-operation-metadata-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(70), None),
            batch_item(&product_id, "lunch", json!(80), None)
        ]
    });
    let _: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    let operation_id = operation_id_for_key(&pool, "corrupt-operation-metadata-key").await;

    sqlx::query(
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_kind",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("UPDATE food_log_create_operations SET operation_kind = 'unknown' WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    let unknown_kind: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(unknown_kind["error"]["code"], "conflict");

    sqlx::query("UPDATE food_log_create_operations SET operation_kind = 'batch' WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_log_count",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("UPDATE food_log_create_operations SET log_count = 0 WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    let invalid_count: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &payload,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(invalid_count["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&router, &user, "2026-11-19").await.len(),
        2,
        "corrupt metadata must fail closed without appending logs"
    );
}

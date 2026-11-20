use crate::common::*;
use axum::http::{Method, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::collections::HashSet;
use std::time::Duration;

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

async fn apply_journal_migration(pool: &PgPool) {
    sqlx::raw_sql(include_str!(
        "../../migrations/20261120000000_food_log_create_operations.sql"
    ))
    .execute(pool)
    .await
    .unwrap();
    apply_shape_migration(pool).await;
}

async fn apply_shape_migration(pool: &PgPool) {
    sqlx::raw_sql(include_str!(
        "../../migrations/20261121000001_food_log_create_operation_shape.sql"
    ))
    .execute(pool)
    .await
    .unwrap();
}

async fn assert_schema_rejected(pool: &PgPool, context: &str) {
    let error = calco_backend::journal::food_log::infra::validate_schema(pool)
        .await
        .err()
        .unwrap_or_else(|| panic!("schema validation unexpectedly passed: {context}"));
    assert!(
        error
            .to_string()
            .contains("database schema is incompatible"),
        "{context}: {error}"
    );
}

async fn execute_test_sql(pool: &PgPool, sql: String) {
    sqlx::query(sqlx::AssertSqlSafe(sql))
        .execute(pool)
        .await
        .unwrap();
}

async fn restore_legacy_key_columns(pool: &PgPool) {
    sqlx::query(
        "ALTER TABLE food_logs \
         ADD COLUMN IF NOT EXISTS idempotency_key TEXT, \
         ADD COLUMN IF NOT EXISTS request_fingerprint TEXT",
    )
    .execute(pool)
    .await
    .unwrap();
}

async fn apply_legacy_cleanup_migration(pool: &PgPool) {
    sqlx::raw_sql(include_str!(
        "../../migrations/20261120000001_drop_food_log_legacy_idempotency.sql"
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
    let (key, fingerprint): (String, String) = sqlx::query_as(
        "SELECT idempotency_key, request_fingerprint \
         FROM food_log_create_operations WHERE id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Simulate a pre-cleanup installation: the surviving log owns the key and
    // fingerprint, and no operation journal row exists yet.
    sqlx::query("DELETE FROM food_log_create_operations WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    restore_legacy_key_columns(&pool).await;
    sqlx::query(
        "UPDATE food_logs SET idempotency_key = $1, request_fingerprint = $2 WHERE id = $3",
    )
    .bind(&key)
    .bind(&fingerprint)
    .bind(uuid::Uuid::parse_str(&log_id).unwrap())
    .execute(&pool)
    .await
    .unwrap();

    apply_legacy_cleanup_migration(&pool).await;
    let legacy_columns: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM information_schema.columns \
         WHERE table_schema = 'public' AND table_name = 'food_logs' \
           AND column_name IN ('idempotency_key', 'request_fingerprint')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(legacy_columns, 0, "cleanup must remove duplicate columns");

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
    restore_legacy_key_columns(&pool).await;
    sqlx::query(
        "UPDATE food_logs \
         SET idempotency_key = 'legacy-no-fingerprint-key', request_fingerprint = NULL \
         WHERE id = $1",
    )
    .bind(uuid::Uuid::parse_str(&log_id).unwrap())
    .execute(&pool)
    .await
    .unwrap();
    apply_legacy_cleanup_migration(&pool).await;

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
    apply_journal_migration(&pool).await;

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
         DROP CONSTRAINT food_log_create_operations_shape",
    )
    .execute(&pool)
    .await
    .unwrap();
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
         DROP CONSTRAINT IF EXISTS food_log_create_operations_log_count",
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

#[sqlx::test]
async fn every_log_create_route_requires_an_idempotency_key(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Required Key Food").await;

    let payloads = [
        (
            "/api/logs",
            json!({
                "log_date": "2026-11-20",
                "meal_slot": "breakfast",
                "item": { "type": "product", "id": product_id },
                "quantity": { "amount": 70, "unit": "g" }
            }),
        ),
        (
            "/api/logs/ad-hoc",
            json!({
                "log_date": "2026-11-20",
                "meal_slot": "lunch",
                "name": "Ad-hoc without key",
                "quantity": { "amount": 1, "unit": "serving" },
                "nutrients": [
                    { "code": "ENERGY_KCAL", "amount": 100, "unit": "kcal" },
                    { "code": "PROTEIN_G", "amount": 1, "unit": "g" },
                    { "code": "CARBS_G", "amount": 1, "unit": "g" },
                    { "code": "FAT_G", "amount": 1, "unit": "g" }
                ]
            }),
        ),
        (
            "/api/logs/batch",
            json!({
                "items": [batch_item(&product_id, "dinner", json!(80), None)]
            }),
        ),
    ];

    for (uri, payload) in payloads {
        let request = json_request(Method::POST, uri, Some(&user), &payload);
        let (status, _headers, bytes) = send(&router, request).await;
        assert_status(status, StatusCode::BAD_REQUEST, &bytes);
        let error: Value = parse_json(&bytes);
        assert_eq!(error["error"]["code"], "validation");
        assert!(
            error["error"]["message"]
                .as_str()
                .unwrap()
                .contains("idempotency_key"),
            "unexpected error: {error}"
        );
    }

    assert!(listed_ids(&router, &user, "2026-11-20").await.is_empty());
    let operations: i64 = sqlx::query_scalar("SELECT count(*) FROM food_log_create_operations")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(operations, 0, "an invalid request must not reserve a key");
}

#[sqlx::test]
async fn invalid_idempotency_keys_are_rejected_before_writes(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Invalid Key Food").await;

    for invalid in [
        json!(""),
        json!("   "),
        json!("line\nbreak"),
        json!("x".repeat(129)),
    ] {
        let payload = json!({
            "log_date": "2026-11-20",
            "meal_slot": "breakfast",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 70, "unit": "g" },
            "idempotency_key": invalid
        });
        let request = json_request(Method::POST, "/api/logs", Some(&user), &payload);
        let (status, _headers, bytes) = send(&router, request).await;
        assert_status(status, StatusCode::BAD_REQUEST, &bytes);
        let error: Value = parse_json(&bytes);
        assert_eq!(error["error"]["code"], "validation");
    }

    let null_key = json!({
        "log_date": "2026-11-20",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 70, "unit": "g" },
        "idempotency_key": null
    });
    let request = json_request(Method::POST, "/api/logs", Some(&user), &null_key);
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);

    assert!(listed_ids(&router, &user, "2026-11-20").await.is_empty());
    let operations: i64 = sqlx::query_scalar("SELECT count(*) FROM food_log_create_operations")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(operations, 0);
}

#[sqlx::test]
async fn fresh_schema_has_no_legacy_key_columns(pool: PgPool) {
    let legacy_columns: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM information_schema.columns \
         WHERE table_schema = 'public' AND table_name = 'food_logs' \
           AND column_name IN ('idempotency_key', 'request_fingerprint')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(legacy_columns, 0);

    let journal_tables: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM information_schema.tables \
         WHERE table_schema = 'public' \
           AND table_name IN ('food_log_create_operations', 'food_log_create_operation_logs')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(journal_tables, 2);
}

#[sqlx::test]
async fn startup_fails_before_serving_an_incomplete_journal_schema(pool: PgPool) {
    sqlx::query("DROP INDEX food_log_create_operations_user_idempotency_key_idx")
        .execute(&pool)
        .await
        .unwrap();

    let error = calco_backend::build_router(pool, test_config())
        .await
        .expect_err("startup must reject a journal without the unique key index");
    assert!(
        error
            .to_string()
            .contains("database schema is incompatible"),
        "unexpected startup error: {error}"
    );
}

#[sqlx::test]
async fn startup_fails_before_serving_without_the_operation_journal(pool: PgPool) {
    sqlx::query("DROP TABLE food_log_create_operation_logs")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP TABLE food_log_create_operations")
        .execute(&pool)
        .await
        .unwrap();

    let error = calco_backend::build_router(pool, test_config())
        .await
        .expect_err("startup must reject a database without the operation journal");
    assert!(
        error
            .to_string()
            .contains("database schema is incompatible"),
        "unexpected startup error: {error}"
    );
}

#[sqlx::test]
async fn legacy_cleanup_waits_for_an_old_writer_before_taking_the_key_snapshot(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Cleanup Lock Food").await;
    let payload = json!({
        "log_date": "2026-11-20",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 70, "unit": "g" },
        "idempotency_key": "cleanup-lock-race-key"
    });
    let created: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CREATED).await;
    let log_id = uuid::Uuid::parse_str(created["id"].as_str().unwrap()).unwrap();
    let operation_id = operation_id_for_key(&pool, "cleanup-lock-race-key").await;
    let fingerprint: String = sqlx::query_scalar(
        "SELECT request_fingerprint FROM food_log_create_operations WHERE id = $1",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Simulate a pre-cleanup installation with a surviving legacy key. The
    // writer below commits its key update while cleanup is waiting to acquire
    // the access-exclusive table lock.
    sqlx::query("DELETE FROM food_log_create_operations WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();
    restore_legacy_key_columns(&pool).await;

    let mut writer = pool.begin().await.unwrap();
    sqlx::query(
        "UPDATE food_logs SET idempotency_key = $1, request_fingerprint = $2 WHERE id = $3",
    )
    .bind("cleanup-lock-race-key")
    .bind(&fingerprint)
    .bind(log_id)
    .execute(&mut *writer)
    .await
    .unwrap();

    let migration_pool = pool.clone();
    let migration = tokio::spawn(async move {
        let script = format!(
            "BEGIN;\n{}\nCOMMIT;",
            include_str!("../../migrations/20261120000001_drop_food_log_legacy_idempotency.sql")
        );
        sqlx::raw_sql(sqlx::AssertSqlSafe(script))
            .execute(&migration_pool)
            .await
    });

    let mut waited_for_lock = false;
    for _ in 0..500 {
        let waiting: bool = sqlx::query_scalar(
            "SELECT EXISTS (\
                SELECT 1 FROM pg_locks lock \
                JOIN pg_class relation ON relation.oid = lock.relation \
                WHERE relation.relname = 'food_logs' \
                  AND lock.mode = 'AccessExclusiveLock' \
                  AND NOT lock.granted\
             )",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        if waiting {
            waited_for_lock = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        waited_for_lock,
        "cleanup must wait for the old writer's row lock before reading candidates"
    );

    writer.commit().await.unwrap();
    migration
        .await
        .expect("cleanup migration task panicked")
        .expect("cleanup migration failed");

    let operation_id = operation_id_for_key(&pool, "cleanup-lock-race-key").await;
    let linked_log_id: uuid::Uuid = sqlx::query_scalar(
        "SELECT food_log_id FROM food_log_create_operation_logs \
         WHERE operation_id = $1 AND position = 0",
    )
    .bind(operation_id)
    .fetch_one(&pool)
    .await
    .expect("a writer that committed before the lock must still be transferred");
    assert_eq!(linked_log_id, log_id);

    let legacy_columns: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM information_schema.columns \
         WHERE table_schema = 'public' AND table_name = 'food_logs' \
           AND column_name IN ('idempotency_key', 'request_fingerprint')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(legacy_columns, 0);

    let replayed: Value = post_json(&router, "/api/logs", &user, &payload, StatusCode::OK).await;
    assert_eq!(replayed["id"], log_id.to_string());
    assert_eq!(listed_ids(&router, &user, "2026-11-20").await.len(), 1);
}

#[sqlx::test]
async fn shape_migration_refuses_to_guess_for_corrupt_operation_shapes(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Corrupt Shape Food").await;
    let payload = json!({
        "idempotency_key": "corrupt-shape-key",
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
    let operation_id = operation_id_for_key(&pool, "corrupt-shape-key").await;

    sqlx::query(
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_shape",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("UPDATE food_log_create_operations SET log_count = 0 WHERE id = $1")
        .bind(operation_id)
        .execute(&pool)
        .await
        .unwrap();

    let error = sqlx::raw_sql(include_str!(
        "../../migrations/20261121000001_food_log_create_operation_shape.sql"
    ))
    .execute(&pool)
    .await
    .expect_err("a corrupt operation shape must abort the forward migration");
    assert!(
        error
            .to_string()
            .contains("cannot enforce food_log_create_operations shape"),
        "unexpected migration error: {error}"
    );

    let count: i32 =
        sqlx::query_scalar("SELECT log_count FROM food_log_create_operations WHERE id = $1")
            .bind(operation_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        count, 0,
        "the migration must not repair or guess corrupt data"
    );
}

#[sqlx::test]
async fn shape_migration_restores_the_missing_constraint_for_valid_data(pool: PgPool) {
    sqlx::query(
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_shape",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert_schema_rejected(&pool, "missing operation shape constraint").await;

    apply_shape_migration(&pool).await;
    calco_backend::journal::food_log::infra::validate_schema(&pool)
        .await
        .expect("forward shape migration must restore readiness");
}

#[sqlx::test]
async fn startup_rejects_nullable_required_journal_columns(pool: PgPool) {
    for (table, column) in [
        ("food_log_create_operations", "user_id"),
        ("food_log_create_operations", "idempotency_key"),
        ("food_log_create_operations", "request_fingerprint"),
        ("food_log_create_operations", "operation_kind"),
        ("food_log_create_operations", "log_count"),
        ("food_log_create_operations", "created_at"),
        ("food_log_create_operation_logs", "food_log_id"),
        ("food_logs", "user_id"),
    ] {
        let drop_not_null = format!("ALTER TABLE {table} ALTER COLUMN {column} DROP NOT NULL");
        execute_test_sql(&pool, drop_not_null).await;
        assert_schema_rejected(&pool, &format!("nullable {table}.{column}")).await;

        let restore = format!("ALTER TABLE {table} ALTER COLUMN {column} SET NOT NULL");
        execute_test_sql(&pool, restore).await;
        calco_backend::journal::food_log::infra::validate_schema(&pool)
            .await
            .unwrap_or_else(|error| panic!("restore {table}.{column} failed: {error}"));
    }
}

#[sqlx::test]
async fn startup_rejects_wrong_required_journal_column_types(pool: PgPool) {
    for (table, column, wrong_type, correct_type) in [
        (
            "food_log_create_operations",
            "idempotency_key",
            "character varying(128)",
            "text",
        ),
        (
            "food_log_create_operations",
            "request_fingerprint",
            "character varying(64)",
            "text",
        ),
        (
            "food_log_create_operations",
            "operation_kind",
            "character varying(16)",
            "text",
        ),
        (
            "food_log_create_operation_logs",
            "food_log_id",
            "character varying(36)",
            "uuid",
        ),
    ] {
        let alter = format!("ALTER TABLE {table} ALTER COLUMN {column} TYPE {wrong_type}");
        execute_test_sql(&pool, alter).await;
        assert_schema_rejected(&pool, &format!("wrong type {table}.{column}")).await;

        let restore = if correct_type == "uuid" {
            format!(
                "ALTER TABLE {table} ALTER COLUMN {column} TYPE {correct_type} USING {column}::uuid"
            )
        } else {
            format!("ALTER TABLE {table} ALTER COLUMN {column} TYPE {correct_type}")
        };
        execute_test_sql(&pool, restore).await;
        calco_backend::journal::food_log::infra::validate_schema(&pool)
            .await
            .unwrap_or_else(|error| panic!("restore {table}.{column} failed: {error}"));
    }
}

#[sqlx::test]
async fn startup_rejects_each_missing_required_check_constraint(pool: PgPool) {
    for (table, constraint) in [
        (
            "food_log_create_operations",
            "food_log_create_operations_key_length",
        ),
        (
            "food_log_create_operations",
            "food_log_create_operations_fingerprint_format",
        ),
        (
            "food_log_create_operations",
            "food_log_create_operations_kind",
        ),
        (
            "food_log_create_operations",
            "food_log_create_operations_shape",
        ),
        (
            "food_log_create_operation_logs",
            "food_log_create_operation_logs_position_check",
        ),
    ] {
        let definition: String = sqlx::query_scalar(
            "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c \
             JOIN pg_class t ON t.oid = c.conrelid \
             JOIN pg_namespace n ON n.oid = t.relnamespace \
             WHERE n.nspname = 'public' AND t.relname = $1 AND c.conname = $2",
        )
        .bind(table)
        .bind(constraint)
        .fetch_one(&pool)
        .await
        .unwrap();
        execute_test_sql(
            &pool,
            format!("ALTER TABLE {table} DROP CONSTRAINT {constraint}"),
        )
        .await;
        assert_schema_rejected(&pool, &format!("missing check {constraint}")).await;

        execute_test_sql(
            &pool,
            format!("ALTER TABLE {table} ADD CONSTRAINT {constraint} {definition}"),
        )
        .await;
        calco_backend::journal::food_log::infra::validate_schema(&pool)
            .await
            .unwrap_or_else(|error| panic!("restore {constraint} failed: {error}"));
    }
}

#[sqlx::test]
async fn startup_rejects_weaker_shape_check(pool: PgPool) {
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_shape"
            .into(),
    )
    .await;
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         ADD CONSTRAINT food_log_create_operations_shape \
         CHECK (operation_kind IN ('single', 'ad_hoc', 'batch') \
            AND log_count >= 1 AND log_count <= 50 \
            AND (log_count = 1 OR log_count >= 2))"
            .into(),
    )
    .await;
    assert_schema_rejected(&pool, "weaker operation shape check").await;
}

#[sqlx::test]
async fn startup_rejects_weaker_key_length_check(pool: PgPool) {
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_key_length"
            .into(),
    )
    .await;
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         ADD CONSTRAINT food_log_create_operations_key_length \
         CHECK (char_length(idempotency_key) >= 1 AND log_count <= 128)"
            .into(),
    )
    .await;
    assert_schema_rejected(&pool, "weaker idempotency key length check").await;
}

#[sqlx::test]
async fn startup_rejects_weaker_fingerprint_check(pool: PgPool) {
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_fingerprint_format"
            .into(),
    )
    .await;
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         ADD CONSTRAINT food_log_create_operations_fingerprint_format \
         CHECK (request_fingerprint ~ '^[0-9a-f]{64}$' OR log_count > 0)"
            .into(),
    )
    .await;
    assert_schema_rejected(&pool, "weaker request fingerprint check").await;
}

#[sqlx::test]
async fn startup_rejects_case_widened_fingerprint_check(pool: PgPool) {
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_fingerprint_format"
            .into(),
    )
    .await;
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         ADD CONSTRAINT food_log_create_operations_fingerprint_format \
         CHECK (request_fingerprint ~ '^[0-9A-Fa-f]{64}$')"
            .into(),
    )
    .await;
    assert_schema_rejected(&pool, "case-widened request fingerprint check").await;
}

#[sqlx::test]
async fn startup_rejects_weaker_position_check(pool: PgPool) {
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operation_logs \
         DROP CONSTRAINT food_log_create_operation_logs_position_check"
            .into(),
    )
    .await;
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operation_logs \
         ADD CONSTRAINT food_log_create_operation_logs_position_check \
         CHECK (position >= 0 OR food_log_id IS NOT NULL)"
            .into(),
    )
    .await;
    assert_schema_rejected(&pool, "weaker child position check").await;
}

#[sqlx::test]
async fn startup_rejects_deferrable_idempotency_unique_index(pool: PgPool) {
    execute_test_sql(
        &pool,
        "DROP INDEX food_log_create_operations_user_idempotency_key_idx".into(),
    )
    .await;
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         ADD CONSTRAINT food_log_create_operations_user_idempotency_key_unique \
         UNIQUE (user_id, idempotency_key) DEFERRABLE INITIALLY DEFERRED"
            .into(),
    )
    .await;
    assert_schema_rejected(&pool, "deferrable idempotency unique arbiter").await;
}

#[sqlx::test]
async fn startup_rejects_deferrable_idempotency_unique_alongside_immediate_index(pool: PgPool) {
    execute_test_sql(
        &pool,
        "ALTER TABLE food_log_create_operations \
         ADD CONSTRAINT food_log_create_operations_deferrable_user_key_unique \
         UNIQUE (user_id, idempotency_key) DEFERRABLE INITIALLY DEFERRED"
            .into(),
    )
    .await;
    assert_schema_rejected(
        &pool,
        "deferrable idempotency unique arbiter with immediate index",
    )
    .await;
}

#[sqlx::test]
async fn startup_rejects_missing_required_foreign_keys(pool: PgPool) {
    for (table, constraint) in [
        (
            "food_log_create_operations",
            "food_log_create_operations_user_id_fkey",
        ),
        (
            "food_log_create_operation_logs",
            "food_log_create_operation_logs_operation_id_fkey",
        ),
    ] {
        let definition: String = sqlx::query_scalar(
            "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c \
             JOIN pg_class t ON t.oid = c.conrelid \
             JOIN pg_namespace n ON n.oid = t.relnamespace \
             WHERE n.nspname = 'public' AND t.relname = $1 AND c.conname = $2",
        )
        .bind(table)
        .bind(constraint)
        .fetch_one(&pool)
        .await
        .unwrap();
        execute_test_sql(
            &pool,
            format!("ALTER TABLE {table} DROP CONSTRAINT {constraint}"),
        )
        .await;
        assert_schema_rejected(&pool, &format!("missing foreign key {constraint}")).await;

        execute_test_sql(
            &pool,
            format!("ALTER TABLE {table} ADD CONSTRAINT {constraint} {definition}"),
        )
        .await;
        calco_backend::journal::food_log::infra::validate_schema(&pool)
            .await
            .unwrap_or_else(|error| panic!("restore {constraint} failed: {error}"));
    }
}

#[sqlx::test]
async fn startup_rejects_legacy_food_log_key_columns(pool: PgPool) {
    sqlx::query("ALTER TABLE food_logs ADD COLUMN idempotency_key TEXT")
        .execute(&pool)
        .await
        .unwrap();
    assert_schema_rejected(&pool, "legacy idempotency key column").await;

    sqlx::query("ALTER TABLE food_logs DROP COLUMN idempotency_key")
        .execute(&pool)
        .await
        .unwrap();
    calco_backend::journal::food_log::infra::validate_schema(&pool)
        .await
        .expect("removing the legacy column must restore readiness");
}

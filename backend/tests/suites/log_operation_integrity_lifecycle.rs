use crate::common::*;
use axum::http::{Method, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::collections::HashSet;

async fn seed_product(router: &axum::Router, user: &str, name: &str) -> String {
    let payload = json!({
        "name": name,
        "brand": "Integrity Lab",
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

fn batch_item(product_id: &str, meal_slot: &str, amount: Value) -> Value {
    json!({
        "log_date": "2026-11-19",
        "meal_slot": meal_slot,
        "device_timezone": null,
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

#[sqlx::test]
async fn renamed_unique_index_is_ready_and_keeps_concurrent_creates_replayable(pool: PgPool) {
    sqlx::query(
        "ALTER INDEX food_log_create_operations_user_idempotency_key_idx \
         RENAME TO food_log_create_operations_user_key_equivalent",
    )
    .execute(&pool)
    .await
    .unwrap();

    calco_backend::journal::food_log::infra::validate_schema(&pool)
        .await
        .expect("an equivalent renamed unique index must satisfy readiness");

    const REQUESTS: usize = 8;
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Renamed Index Food").await;
    let payload = json!({
        "idempotency_key": "renamed-index-concurrent-key",
        "items": [
            batch_item(&product_id, "breakfast", json!(60)),
            batch_item(&product_id, "dinner", json!(90))
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
    while let Some(result) = tasks.join_next().await {
        let (status, body) = result.expect("concurrent request task panicked");
        match status {
            StatusCode::CREATED => created += 1,
            StatusCode::OK => replayed += 1,
            unexpected => panic!("unexpected status {unexpected}: {body}"),
        }
    }
    assert_eq!(created, 1);
    assert_eq!(replayed, REQUESTS - 1);

    let operation_rows: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM food_log_create_operations WHERE idempotency_key = $1",
    )
    .bind("renamed-index-concurrent-key")
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(operation_rows, 1);
    assert_eq!(listed_ids(&router, &user, "2026-11-19").await.len(), 2);
}

#[sqlx::test]
async fn invalid_persisted_fingerprints_return_conflict_without_writes(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Invalid Fingerprint Food").await;
    let payload = json!({
        "log_date": "2026-11-20",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 70, "unit": "g" },
        "idempotency_key": "invalid-persisted-fingerprint-key"
    });
    let _: Value = post_json(&router, "/api/logs", &user, &payload, StatusCode::CREATED).await;
    let operation_id = operation_id_for_key(&pool, "invalid-persisted-fingerprint-key").await;

    sqlx::query(
        "ALTER TABLE food_log_create_operations \
         DROP CONSTRAINT food_log_create_operations_fingerprint_format",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "UPDATE food_log_create_operations SET request_fingerprint = 'not-a-sha256' WHERE id = $1",
    )
    .bind(operation_id)
    .execute(&pool)
    .await
    .unwrap();

    let conflict: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CONFLICT).await;
    assert_eq!(conflict["error"]["code"], "conflict");
    assert_eq!(
        listed_ids(&router, &user, "2026-11-20").await.len(),
        1,
        "a corrupt fingerprint must fail closed without appending a log"
    );
}

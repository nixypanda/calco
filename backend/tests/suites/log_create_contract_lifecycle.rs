use crate::common::*;
use axum::http::{Method, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::collections::HashSet;

async fn seed_product(router: &axum::Router, user: &str, name: &str) -> String {
    let payload = json!({
        "name": name,
        "brand": "Contract Lab",
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
        "log_date": "2026-11-20",
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

#[sqlx::test]
async fn non_string_idempotency_keys_are_validation_errors_on_every_create_route(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Non-string Key Food").await;
    let single = json!({
        "log_date": "2026-11-20",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 70, "unit": "g" }
    });
    let batch = json!({
        "items": [batch_item(&product_id, "lunch", json!(80))]
    });
    let ad_hoc = json!({
        "log_date": "2026-11-20",
        "meal_slot": "snack",
        "name": "Non-string key ad-hoc",
        "quantity": { "amount": 1, "unit": "serving" },
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount": 100, "unit": "kcal" },
            { "code": "PROTEIN_G", "amount": 1, "unit": "g" },
            { "code": "CARBS_G", "amount": 1, "unit": "g" },
            { "code": "FAT_G", "amount": 1, "unit": "g" }
        ]
    });

    for (uri, base) in [
        ("/api/logs", &single),
        ("/api/logs/batch", &batch),
        ("/api/logs/ad-hoc", &ad_hoc),
    ] {
        for invalid in [json!(7), json!(true), json!([]), json!({ "key": "nested" })] {
            let mut payload = base.clone();
            payload["idempotency_key"] = invalid;
            let request = json_request(Method::POST, uri, Some(&user), &payload);
            let (status, _headers, bytes) = send(&router, request).await;
            assert_status(status, StatusCode::BAD_REQUEST, &bytes);
            let error: Value = parse_json(&bytes);
            assert_eq!(
                error["error"]["code"], "validation",
                "unexpected response for {uri}: {error}"
            );
        }
    }

    let mut item_key_payload = batch.clone();
    item_key_payload["idempotency_key"] = json!("valid-batch-key");
    item_key_payload["items"][0]["idempotency_key"] = json!(7);
    let request = json_request(
        Method::POST,
        "/api/logs/batch",
        Some(&user),
        &item_key_payload,
    );
    let (status, _headers, bytes) = send(&router, request).await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);
    let error: Value = parse_json(&bytes);
    assert_eq!(error["error"]["code"], "validation");
    assert!(
        error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("belongs on the batch request")
    );

    assert!(listed_ids(&router, &user, "2026-11-20").await.is_empty());
    let operations: i64 = sqlx::query_scalar("SELECT count(*) FROM food_log_create_operations")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(operations, 0);
}

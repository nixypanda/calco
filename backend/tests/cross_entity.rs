mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

/// Exercises the wiring between catalog → meal → food log → summary:
/// builds a meal from a product, logs both the meal and the bare product
/// on the same day, and asserts the summary sums kcal across entities.
#[sqlx::test]
async fn product_to_meal_to_log_to_summary(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    // ── 1. Create a product with known kcal density ─────────────────────
    let product_payload = json!({
        "name": "Bread",
        "categories": ["bakery"],
        "serving_size_g": 30,
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 250 }
        ],
        "servings": [
            { "label": "slice", "quantity": 1, "unit": "serving", "grams": 30 }
        ]
    });
    let product: Value = post_json(
        &router,
        "/api/foods/custom",
        &user,
        &product_payload,
        StatusCode::CREATED,
    )
    .await;
    let product_id = product["id"].as_str().unwrap().to_string();

    // ── 2. Create a meal that uses 60g of that bread ────────────────────
    // 60g bread = 60 * 250 / 100 = 150 kcal
    let meal_payload = json!({
        "name": "Toast",
        "total_quantity": { "amount": 60, "unit": "g" },
        "components": [
            {
                "item": { "type": "product", "id": product_id },
                "quantity": { "amount": 60, "unit": "g" }
            }
        ]
    });
    let meal: Value =
        post_json(&router, "/api/meals", &user, &meal_payload, StatusCode::CREATED).await;
    let meal_id = meal["id"].as_str().unwrap().to_string();

    // ── 3. Log the meal at lunch ────────────────────────────────────────
    // Logging the meal at 60g of its 60g total → 1 portion → 150 kcal.
    let log_meal_payload = json!({
        "logged_at": "2026-06-01T12:00:00Z",
        "meal_slot": "lunch",
        "item": { "type": "meal", "id": meal_id },
        "quantity": { "amount": 60, "unit": "g" }
    });
    let _: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &log_meal_payload,
        StatusCode::CREATED,
    )
    .await;

    // ── 4. Log the bare product at breakfast ────────────────────────────
    // 40g bread = 40 * 250 / 100 = 100 kcal
    let log_product_payload = json!({
        "logged_at": "2026-06-01T08:00:00Z",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 40, "unit": "g" }
    });
    let _: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &log_product_payload,
        StatusCode::CREATED,
    )
    .await;

    // ── 5. Summary for the day should reflect both entries ─────────────
    let summary: Value = get_json(
        &router,
        "/api/summary?from=2026-06-01&to=2026-06-01&codes=ENERGY_KCAL",
        &user,
    )
    .await;

    let total_kcal: f64 = summary["totals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["code"] == "ENERGY_KCAL")
        .expect("ENERGY_KCAL missing from summary")["amount"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();

    // 150 (meal log) + 100 (product log) = 250 kcal
    assert!(
        (total_kcal - 250.0).abs() < 0.001,
        "expected 250 kcal across both entries, got {total_kcal}"
    );

    // Sanity: listing logs for the day yields both entries
    let logs: Value = get_json(
        &router,
        "/api/logs?from=2026-06-01&to=2026-06-01",
        &user,
    )
    .await;
    assert_eq!(logs["items"].as_array().unwrap().len(), 2);
}

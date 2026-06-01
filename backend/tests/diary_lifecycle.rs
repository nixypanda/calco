mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

async fn seed_product(router: &axum::Router, user: &str) -> String {
    let payload = json!({
        "name": "Diary Test Apple",
        "categories": ["fruit"],
        "serving_size_g": 100,
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 52 },
            { "code": "CARBS_G", "amount_per_100g": 14 }
        ],
        "servings": [
            { "label": "1 apple", "quantity": 1, "unit": "serving", "grams": 100 }
        ]
    });
    let created: Value =
        post_json(router, "/api/foods/custom", user, &payload, StatusCode::CREATED).await;
    created["id"].as_str().unwrap().to_string()
}

#[sqlx::test]
async fn diary_lifecycle_create_read_list_update_delete(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let product_id = seed_product(&router, &user).await;

    // ── Create log ──────────────────────────────────────────────────────
    let create_payload = json!({
        "logged_at": "2026-06-01T08:30:00Z",
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 150, "unit": "g" },
        "notes": "with yogurt"
    });
    let created: Value =
        post_json(&router, "/api/logs", &user, &create_payload, StatusCode::CREATED).await;
    let log_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["item"]["type"], "product");
    assert_eq!(created["item"]["id"], product_id);
    assert_eq!(created["meal_slot"], "breakfast");

    // Nutrient snapshot should include kcal scaled to 150g
    let kcal = created["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["code"] == "ENERGY_KCAL")
        .expect("ENERGY_KCAL snapshot missing");
    // 52 kcal / 100g * 150g = 78
    let kcal_amount: f64 = kcal["amount"].as_str().unwrap().parse().unwrap();
    assert!((kcal_amount - 78.0).abs() < 0.001, "kcal was {kcal_amount}");

    // ── Read by id ──────────────────────────────────────────────────────
    let fetched: Value = get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(fetched["id"], log_id);
    assert_eq!(fetched["notes"], "with yogurt");

    // ── List by date range ──────────────────────────────────────────────
    let list: Value = get_json(
        &router,
        "/api/logs?from=2026-06-01&to=2026-06-01",
        &user,
    )
    .await;
    let items = list["items"].as_array().unwrap();
    assert!(items.iter().any(|l| l["id"] == log_id));

    // ── Update ──────────────────────────────────────────────────────────
    let update_payload = json!({
        "quantity": { "amount": 200, "unit": "g" },
        "notes": "post-workout"
    });
    let updated: Value = put_json(
        &router,
        &format!("/api/logs/{log_id}"),
        &user,
        &update_payload,
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["quantity"]["amount"], "200");
    assert_eq!(updated["notes"], "post-workout");

    // ── Summary ─────────────────────────────────────────────────────────
    let summary: Value = get_json(
        &router,
        "/api/summary?from=2026-06-01&to=2026-06-01&codes=ENERGY_KCAL",
        &user,
    )
    .await;
    let total: f64 = summary["totals"][0]["amount"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    // 52 kcal/100g * 200g = 104
    assert!((total - 104.0).abs() < 0.001, "summary kcal was {total}");

    // ── Delete ──────────────────────────────────────────────────────────
    delete_no_content(&router, &format!("/api/logs/{log_id}"), &user).await;
    let (status, _) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

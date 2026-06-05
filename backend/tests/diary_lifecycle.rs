mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

async fn seed_product(router: &axum::Router, user: &str) -> String {
    let payload = json!({
        "name": "Diary Test Apple",
        "brand": "Orchard Lab",
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

#[sqlx::test]
async fn diary_lifecycle_create_read_list_update_delete(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let product_id = seed_product(&router, &user).await;

    // ── Create log ──────────────────────────────────────────────────────
    let create_payload = json!({
        "log_date": "2026-06-01",
        "meal_slot": "breakfast",
        "device_timezone": "Asia/Kolkata",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 150, "unit": "g" },
        "notes": "with yogurt"
    });
    let created: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &create_payload,
        StatusCode::CREATED,
    )
    .await;
    let log_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["item"]["type"], "product");
    assert_eq!(created["item"]["id"], product_id);
    assert_eq!(created["item"]["name"], "Diary Test Apple");
    assert_eq!(created["item"]["brand"], "Orchard Lab");
    assert!(created.get("item_snapshot").is_none());
    assert!(created.get("logged_at").is_none());
    assert_eq!(created["log_date"], "2026-06-01");
    assert_eq!(created["meal_slot"], "breakfast");
    assert_eq!(created["device_timezone"], "Asia/Kolkata");

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

    let renamed_product_payload = json!({
        "name": "Renamed Apple",
        "brand": "New Brand",
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
    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{product_id}"),
        &user,
        &renamed_product_payload,
        StatusCode::OK,
    )
    .await;
    let fetched_after_product_rename: Value =
        get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(
        fetched_after_product_rename["item"]["name"],
        "Diary Test Apple"
    );
    assert_eq!(fetched_after_product_rename["item"]["brand"], "Orchard Lab");

    // ── List by log date ────────────────────────────────────────────────
    let list: Value = get_json(&router, "/api/logs?log_date=2026-06-01", &user).await;
    let items = list["items"].as_array().unwrap();
    assert!(items.iter().any(|l| l["id"] == log_id));

    let other_day_list: Value = get_json(&router, "/api/logs?log_date=2026-06-02", &user).await;
    assert!(other_day_list["items"].as_array().unwrap().is_empty());

    // ── Update ──────────────────────────────────────────────────────────
    let update_payload = json!({
        "quantity": { "amount": 200, "unit": "g" },
        "notes": "post-workout",
        "device_timezone": null
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
    assert!(updated["device_timezone"].is_null());

    // ── Delete ──────────────────────────────────────────────────────────
    delete_no_content(&router, &format!("/api/logs/{log_id}"), &user).await;
    let (status, _) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

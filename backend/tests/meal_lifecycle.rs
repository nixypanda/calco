mod common;

use axum::http::StatusCode;
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

async fn seed_product(router: &axum::Router, user: &str, name: &str, kcal: i64) -> String {
    let payload = json!({
        "name": name,
        "categories": ["test"],
        "serving_size_g": 100,
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": kcal },
            { "code": "PROTEIN_G", "amount_per_100g": 5 }
        ],
        "servings": [
            { "label": "100g", "quantity": 100, "unit": "g", "grams": 100 }
        ]
    });
    let created: Value =
        post_json(router, "/api/foods/custom", user, &payload, StatusCode::CREATED).await;
    created["id"].as_str().unwrap().to_string()
}

#[sqlx::test]
async fn meal_lifecycle_create_read_list_update_nutrients_delete(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let oats_id = seed_product(&router, &user, "Oats", 380).await;
    let milk_id = seed_product(&router, &user, "Milk", 60).await;

    // ── Create meal ─────────────────────────────────────────────────────
    // Total component weight: 50 + 200 = 250g; set total_quantity to match.
    let create_payload = json!({
        "name": "Porridge",
        "notes": "morning meal",
        "total_quantity": { "amount": 250, "unit": "g" },
        "components": [
            { "item": { "type": "product", "id": oats_id }, "quantity": { "amount": 50, "unit": "g" } },
            { "item": { "type": "product", "id": milk_id }, "quantity": { "amount": 200, "unit": "g" } }
        ]
    });
    let created: Value =
        post_json(&router, "/api/meals", &user, &create_payload, StatusCode::CREATED).await;
    let meal_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["name"], "Porridge");
    assert_eq!(created["components"].as_array().unwrap().len(), 2);

    // ── Read by id ──────────────────────────────────────────────────────
    let fetched: Value = get_json(&router, &format!("/api/meals/{meal_id}"), &user).await;
    assert_eq!(fetched["id"], meal_id);

    // ── List ────────────────────────────────────────────────────────────
    let list: Value = get_json(&router, "/api/meals", &user).await;
    assert!(list["items"].as_array().unwrap().iter().any(|m| m["id"] == meal_id));

    // ── Nutrients for the full 250g portion ─────────────────────────────
    // Oats: 50g * 380 kcal / 100g = 190 kcal
    // Milk: 200g * 60  kcal / 100g = 120 kcal
    // Total at 250g: 310 kcal
    let nutrients: Value = get_json(
        &router,
        &format!("/api/meals/{meal_id}/nutrients?amount=250&unit=g"),
        &user,
    )
    .await;
    let kcal = nutrients["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["code"] == "ENERGY_KCAL")
        .expect("ENERGY_KCAL missing from meal nutrients");
    let kcal_amount: f64 = kcal["amount"].as_str().unwrap().parse().unwrap();
    assert!(
        (kcal_amount - 310.0).abs() < 0.001,
        "expected 310 kcal, got {kcal_amount}"
    );

    // ── Update ──────────────────────────────────────────────────────────
    let update_payload = json!({
        "name": "Oat Porridge",
        "components": [
            { "item": { "type": "product", "id": oats_id }, "quantity": { "amount": 80, "unit": "g" } }
        ]
    });
    let updated: Value = put_json(
        &router,
        &format!("/api/meals/{meal_id}"),
        &user,
        &update_payload,
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["name"], "Oat Porridge");
    assert_eq!(updated["components"].as_array().unwrap().len(), 1);

    // ── Delete ──────────────────────────────────────────────────────────
    delete_no_content(&router, &format!("/api/meals/{meal_id}"), &user).await;
    let (status, _) = get_status(&router, &format!("/api/meals/{meal_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

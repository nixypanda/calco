mod common;

use axum::http::{Method, StatusCode};
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

#[sqlx::test]
async fn product_lifecycle_create_read_update_search_delete(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    // ── Create ──────────────────────────────────────────────────────────
    let create_payload = json!({
        "name": "Test Granola",
        "brand": "BrandCo",
        "categories": ["breakfast", "cereals"],
        "serving_size_g": 50,
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 450 },
            { "code": "PROTEIN_G", "amount_per_100g": 9 },
            { "code": "CARBS_G", "amount_per_100g": 60 },
            { "code": "FAT_G", "amount_per_100g": 15 }
        ],
        "servings": [
            { "label": "1 bowl", "quantity": 1, "unit": "serving", "grams": 50 }
        ]
    });
    let created: Value = post_json(
        &router,
        "/api/foods/custom",
        &user,
        &create_payload,
        StatusCode::CREATED,
    )
    .await;
    let id = created["id"].as_str().expect("id missing").to_string();

    // ── Read ────────────────────────────────────────────────────────────
    let detail: Value = get_json(&router, &format!("/api/foods/{id}"), &user).await;
    assert_eq!(detail["name"], "Test Granola");
    assert_eq!(detail["brand"], "BrandCo");
    assert_eq!(detail["visibility"], "user_private");
    assert_eq!(detail["serving_size_g"], "50");
    assert_eq!(
        detail["nutrition_summary"]["per_100g"]["energy_kcal"],
        "450"
    );
    assert_eq!(detail["nutrition_summary"]["per_100g"]["protein_g"], "9");
    assert_amount(
        &detail["nutrition_summary"]["per_serving"]["energy_kcal"],
        225.0,
    );
    let nutrient_codes: Vec<&str> = detail["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["code"].as_str().unwrap())
        .collect();
    assert!(nutrient_codes.contains(&"ENERGY_KCAL"));
    assert!(nutrient_codes.contains(&"PROTEIN_G"));
    assert_eq!(detail["servings"].as_array().unwrap().len(), 1);

    // ── Update ──────────────────────────────────────────────────────────
    let update_payload = json!({
        "name": "Test Granola (Honey)",
        "brand": "BrandCo",
        "categories": ["breakfast"],
        "serving_size_g": 55,
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 460 },
            { "code": "PROTEIN_G", "amount_per_100g": 10 },
            { "code": "CARBS_G", "amount_per_100g": 62 },
            { "code": "FAT_G", "amount_per_100g": 18 }
        ],
        "servings": [
            { "label": "1 bowl", "quantity": 1, "unit": "serving", "grams": 55 }
        ]
    });
    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{id}"),
        &user,
        &update_payload,
        StatusCode::OK,
    )
    .await;

    let after_update: Value = get_json(&router, &format!("/api/foods/{id}"), &user).await;
    assert_eq!(after_update["name"], "Test Granola (Honey)");
    assert_eq!(after_update["serving_size_g"], "55");
    assert_eq!(after_update["nutrients"].as_array().unwrap().len(), 4);

    // ── Search ──────────────────────────────────────────────────────────
    let search: Value = get_json(&router, "/api/foods/search?q=granola", &user).await;
    let items = search["items"].as_array().expect("items missing");
    assert!(
        items.iter().any(|p| p["id"].as_str() == Some(&id)),
        "search did not return updated product; got: {items:?}"
    );
    let search_item = items
        .iter()
        .find(|p| p["id"].as_str() == Some(&id))
        .expect("updated product missing from search");
    assert_eq!(
        search_item["nutrition_summary"]["per_100g"]["energy_kcal"],
        "460"
    );
    assert_eq!(
        search_item["nutrition_summary"]["per_100g"]["protein_g"],
        "10"
    );
    assert_eq!(search_item["nutrition_summary"]["per_100g"]["fat_g"], "18");

    // ── List custom foods ──────────────────────────────────────────────
    let list: Value = get_json(&router, "/api/foods/custom", &user).await;
    let list_items = list["items"].as_array().expect("list items missing");
    assert_eq!(
        list_items.len(),
        1,
        "expected only the caller's custom food, got: {list_items:?}"
    );
    let listed = &list_items[0];
    assert_eq!(listed["id"], id);
    assert_eq!(listed["name"], "Test Granola (Honey)");
    assert_eq!(listed["brand"], "BrandCo");
    assert_eq!(listed["visibility"], "user_private");
    assert_eq!(listed["source"], "USER");
    assert_eq!(listed["serving_size_g"], "55");
    assert_eq!(
        listed["nutrition_summary"]["per_100g"]["energy_kcal"],
        "460"
    );
    assert_amount(
        &listed["nutrition_summary"]["per_serving"]["energy_kcal"],
        253.0,
    );
    let listed_nutrients = listed["nutrients"].as_array().expect("nutrients");
    assert_eq!(listed_nutrients.len(), 4);
    assert_eq!(listed["servings"].as_array().unwrap().len(), 1);
    let allowed_units = listed["allowed_units"].as_array().expect("allowed_units");
    assert!(
        !allowed_units.is_empty(),
        "allowed_units should not be empty"
    );

    // ── Delete ──────────────────────────────────────────────────────────
    delete_no_content(&router, &format!("/api/foods/custom/{id}"), &user).await;

    let (status, _) = get_status(&router, &format!("/api/foods/{id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let after_delete: Value = get_json(&router, "/api/foods/custom", &user).await;
    assert_eq!(
        after_delete["items"].as_array().unwrap().len(),
        0,
        "deleted custom food should not appear in the listing"
    );
}

fn assert_amount(value: &Value, expected: f64) {
    let actual: f64 = value.as_str().unwrap().parse().unwrap();
    assert!(
        (actual - expected).abs() < 0.001,
        "expected {expected}, got {actual}"
    );
}

#[sqlx::test]
async fn product_endpoints_require_auth(pool: PgPool) {
    let router = app(pool).await;

    let req = common::empty_request(Method::GET, "/api/foods/search?q=anything", None);
    let (status, _h, _b) = common::send(&router, req).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

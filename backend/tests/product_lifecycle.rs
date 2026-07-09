mod common;

use axum::http::{Method, StatusCode};
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

async fn create_custom_product(
    router: &axum::Router,
    user: &str,
    name: &str,
    brand: &str,
    categories: &[&str],
    energy_kcal: i64,
) -> String {
    let payload = json!({
        "name": name,
        "brand": brand,
        "categories": categories,
        "serving_size_g": 100,
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": energy_kcal },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 10 },
            { "code": "FAT_G", "amount_per_100g": 1 }
        ],
        "servings": [
            { "label": "1 serving", "quantity": 1, "unit": "serving", "grams": 100 }
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
    created["id"].as_str().expect("id missing").to_string()
}

async fn log_product(router: &axum::Router, user: &str, product_id: &str, log_date: &str) {
    let payload = json!({
        "log_date": log_date,
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 100, "unit": "g" }
    });
    let _: Value = post_json(router, "/api/logs", user, &payload, StatusCode::CREATED).await;
}

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

#[sqlx::test]
async fn product_search_scopes_filter_and_order_results(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;
    let user = create_user_session(&router, &admin, "scope_user", "testpassword").await;
    let other_user = create_user_session(&router, &admin, "scope_other", "testpassword").await;

    let oats_id = create_custom_product(
        &router,
        &user,
        "Scope Oats",
        "Morning Lab",
        &["breakfast", "grain"],
        390,
    )
    .await;
    let yogurt_id = create_custom_product(
        &router,
        &user,
        "Scope Yogurt",
        "Dairy Lab",
        &["fermented", "dairy"],
        80,
    )
    .await;
    let other_id = create_custom_product(
        &router,
        &other_user,
        "Scope Oats Other",
        "Other Lab",
        &["breakfast"],
        410,
    )
    .await;

    let default_search: Value = get_json(&router, "/api/foods/search?q=scope", &user).await;
    let default_items = default_search["items"].as_array().expect("items missing");
    assert!(default_items.iter().any(|item| item["id"] == oats_id));
    assert!(default_items.iter().any(|item| item["id"] == yogurt_id));
    assert!(
        !default_items.iter().any(|item| item["id"] == other_id),
        "all scope should not include another user's private product"
    );

    let custom_search: Value =
        get_json(&router, "/api/foods/search?q=scope&scope=custom", &user).await;
    let custom_items = custom_search["items"].as_array().expect("items missing");
    assert!(custom_items.iter().any(|item| item["id"] == oats_id));
    assert!(custom_items.iter().any(|item| item["id"] == yogurt_id));
    assert!(!custom_items.iter().any(|item| item["id"] == other_id));
    assert_eq!(
        custom_items
            .iter()
            .find(|item| item["id"] == oats_id)
            .expect("oats missing")["nutrition_summary"]["per_100g"]["energy_kcal"],
        "390"
    );

    let empty_history: Value =
        get_json(&router, "/api/foods/search?q=scope&scope=history", &user).await;
    assert!(empty_history["items"].as_array().unwrap().is_empty());

    log_product(&router, &user, &oats_id, "2026-06-01").await;
    log_product(&router, &user, &yogurt_id, "2026-06-03").await;
    log_product(&router, &user, &oats_id, "2026-06-02").await;

    let history: Value = get_json(&router, "/api/foods/search?q=scope&scope=history", &user).await;
    let history_items = history["items"].as_array().expect("items missing");
    let history_ids: Vec<&str> = history_items
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert_eq!(history_ids, vec![yogurt_id.as_str(), oats_id.as_str()]);

    let category_history: Value =
        get_json(&router, "/api/foods/search?q=dairy&scope=history", &user).await;
    let category_items = category_history["items"].as_array().expect("items missing");
    assert_eq!(category_items.len(), 1);
    assert_eq!(category_items[0]["id"], yogurt_id);

    let unknown_scope_req = common::empty_request(
        Method::GET,
        "/api/foods/search?q=scope&scope=private",
        Some(&user),
    );
    let (status, _headers, body) = common::send(&router, unknown_scope_req).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let error: Value = common::parse_json(&body);
    assert_eq!(error["error"]["code"], "validation");
}

#[sqlx::test]
async fn barcode_lookup_does_not_expose_other_users_private_foods(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin = bootstrap_admin(&router).await;
    let owner = create_user_session(&router, &admin, "barcode_owner", "testpassword").await;
    let other = create_user_session(&router, &admin, "barcode_other", "testpassword").await;

    let product_id = create_custom_product(
        &router,
        &owner,
        "Private Barcode Cereal",
        "Hidden Brand",
        &["breakfast"],
        320,
    )
    .await;
    sqlx::query("UPDATE products SET barcode = $1 WHERE id = $2")
        .bind("private-barcode-123")
        .bind(uuid::Uuid::parse_str(&product_id).expect("product id uuid"))
        .execute(&pool)
        .await
        .expect("set barcode");

    let owner_lookup: Value =
        get_json(&router, "/api/foods/barcode/private-barcode-123", &owner).await;
    assert_eq!(owner_lookup["id"], product_id);
    assert_eq!(
        owner_lookup["nutrition_summary"]["per_100g"]["energy_kcal"],
        "320"
    );

    let (status, body) =
        get_status(&router, "/api/foods/barcode/private-barcode-123", &other).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "not_found");
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

use crate::common;
use crate::common::*;
use axum::http::{Method, StatusCode};
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
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": energy_kcal },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 10 },
            { "code": "FAT_G", "amount_per_100g": 1 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 100 }
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

#[sqlx::test]
async fn product_lifecycle_create_read_update_search_delete(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    // ── Create ──────────────────────────────────────────────────────────
    let create_payload = json!({
        "name": "Test Granola",
        "brand": "BrandCo",
        "categories": ["breakfast", "cereals"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 450 },
            { "code": "PROTEIN_G", "amount_per_100g": 9 },
            { "code": "CARBS_G", "amount_per_100g": 60 },
            { "code": "FAT_G", "amount_per_100g": 15 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 50 }
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
    assert_eq!(detail["visibility"], "global");
    assert_eq!(
        detail["nutrition_summary"]["per_100g"]["energy_kcal"],
        "450"
    );
    assert_eq!(detail["nutrition_summary"]["per_100g"]["protein_g"], "9");
    let nutrient_codes: Vec<&str> = detail["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["code"].as_str().unwrap())
        .collect();
    assert!(nutrient_codes.contains(&"ENERGY_KCAL"));
    assert!(nutrient_codes.contains(&"PROTEIN_G"));
    assert_eq!(
        detail["servings"],
        json!([{ "unit": "serving", "grams_per_unit": "50" }])
    );

    // ── Update ──────────────────────────────────────────────────────────
    let update_payload = json!({
        "name": "Test Granola (Honey)",
        "brand": "BrandCo",
        "categories": ["breakfast"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 460 },
            { "code": "PROTEIN_G", "amount_per_100g": 10 },
            { "code": "CARBS_G", "amount_per_100g": 62 },
            { "code": "FAT_G", "amount_per_100g": 18 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 55 }
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
        "expected the shared custom food, got: {list_items:?}"
    );
    let listed = &list_items[0];
    assert_eq!(listed["id"], id);
    assert_eq!(listed["name"], "Test Granola (Honey)");
    assert_eq!(listed["brand"], "BrandCo");
    assert_eq!(listed["visibility"], "global");
    assert_eq!(listed["source"], "USER");
    assert_eq!(
        listed["nutrition_summary"]["per_100g"]["energy_kcal"],
        "460"
    );
    let listed_nutrients = listed["nutrients"].as_array().expect("nutrients");
    assert_eq!(listed_nutrients.len(), 4);
    assert_eq!(
        listed["servings"],
        json!([{ "unit": "serving", "grams_per_unit": "55" }])
    );
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
async fn database_rejects_barcodes_on_custom_foods(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin = bootstrap_admin(&router).await;
    let owner = create_user_session(&router, &admin, "barcode_owner", "testpassword").await;
    let product_id = create_custom_product(
        &router,
        &owner,
        "Private Barcode Cereal",
        "Hidden Brand",
        &["breakfast"],
        320,
    )
    .await;
    let result = sqlx::query("UPDATE products SET barcode = $1 WHERE id = $2")
        .bind("private-barcode-123")
        .bind(uuid::Uuid::parse_str(&product_id).expect("product id uuid"))
        .execute(&pool)
        .await;

    let error = result.expect_err("custom products must not acquire external identity fields");
    assert_eq!(
        error.as_database_error().and_then(|error| error.code()),
        Some("23514".into())
    );
}

#[sqlx::test]
async fn product_endpoints_require_auth(pool: PgPool) {
    let router = app(pool).await;

    let req = common::empty_request(Method::GET, "/api/foods/search?q=anything", None);
    let (status, _h, _b) = common::send(&router, req).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

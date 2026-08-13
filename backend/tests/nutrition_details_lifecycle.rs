mod common;

use axum::http::{Method, StatusCode};
use common::*;
use rust_decimal::Decimal;
use serde_json::{Value, json};
use sqlx::PgPool;

fn assert_amount(value: &Value, expected: Decimal) {
    assert_eq!(
        value.as_str().unwrap().parse::<Decimal>().unwrap(),
        expected
    );
}

async fn create_product(
    router: &axum::Router,
    cookie: &str,
    name: &str,
    nutrients: Value,
) -> String {
    let payload = json!({
        "name": name,
        "categories": ["test"],
        "nutrients": nutrients,
        "servings": [],
    });
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        cookie,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().unwrap().to_owned()
}

async fn log_product(router: &axum::Router, cookie: &str, product_id: &str, date: &str) {
    let payload = json!({
        "log_date": date,
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 100, "unit": "g" },
    });
    let _: Value = post_json(router, "/api/logs", cookie, &payload, StatusCode::CREATED).await;
}

async fn log_meal(router: &axum::Router, cookie: &str, meal_id: &str, date: &str) {
    let payload = json!({
        "log_date": date,
        "item": { "type": "meal", "id": meal_id },
        "quantity": { "amount": 200, "unit": "g" },
    });
    let _: Value = post_json(router, "/api/logs", cookie, &payload, StatusCode::CREATED).await;
}

#[sqlx::test]
async fn nutrition_details_uses_snapshots_and_user_scoped_logs(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;
    let user = create_user_session(&router, &admin, "nutrient-user", "testpassword").await;
    let other_user = create_user_session(&router, &admin, "other-user", "testpassword").await;

    let nutrient_product = create_product(
        &router,
        &user,
        "Mineral food",
        json!([
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 1 },
            { "code": "FAT_G", "amount_per_100g": 1 },
            { "code": "SODIUM_MG", "amount_per_100g": 2400 },
            { "code": "POTASSIUM_MG", "amount_per_100g": 4700 },
            { "code": "IRON_MG", "amount_per_100g": 0 },
            { "code": "MAGNESIUM_MG", "amount_per_100g": "184.2" },
            { "code": "ADDED_SUGAR_G", "amount_per_100g": 51 }
        ]),
    )
    .await;
    let energy_only_product = create_product(
        &router,
        &user,
        "Energy food",
        json!([
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 1 },
            { "code": "FAT_G", "amount_per_100g": 1 }
        ]),
    )
    .await;
    let other_user_product = create_product(
        &router,
        &other_user,
        "Other user food",
        json!([
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 1 },
            { "code": "FAT_G", "amount_per_100g": 1 },
            { "code": "MAGNESIUM_MG", "amount_per_100g": 500 }
        ]),
    )
    .await;

    log_product(&router, &user, &nutrient_product, "2026-08-14").await;
    log_product(&router, &user, &energy_only_product, "2026-08-14").await;
    log_product(&router, &user, &nutrient_product, "2026-08-13").await;
    log_product(&router, &other_user, &other_user_product, "2026-08-14").await;

    let report: Value = get_json(&router, "/api/nutrition/details?date=2026-08-14", &user).await;

    assert_eq!(report["date"], "2026-08-14");
    assert_eq!(report["logged_items"], 2);
    assert_eq!(report["reference"]["code"], "us_fda_dv_adult_2020");
    assert_eq!(
        report["reference"]["authority"],
        "U.S. Food and Drug Administration"
    );

    let nutrients = report["nutrients"].as_array().unwrap();
    let nutrient = |code: &str| {
        nutrients
            .iter()
            .find(|entry| entry["code"] == code)
            .unwrap()
    };

    let sodium = nutrient("SODIUM_MG");
    assert_amount(&sodium["known_amount"], Decimal::from(2400));
    assert_eq!(sodium["items_with_data"], 1);
    assert_eq!(sodium["coverage"], "partial");
    assert_eq!(sodium["status"], "over_limit");
    assert_eq!(sodium["guidance_kind"], "maximum");
    assert_eq!(sodium["section"], "limits");

    let potassium = nutrient("POTASSIUM_MG");
    assert_amount(&potassium["known_amount"], Decimal::from(4700));
    assert_eq!(potassium["coverage"], "partial");
    assert_eq!(potassium["status"], "met_reference");

    let iron = nutrient("IRON_MG");
    assert_amount(&iron["known_amount"], Decimal::ZERO);
    assert_eq!(iron["items_with_data"], 1);
    assert_eq!(iron["coverage"], "partial");
    assert_eq!(iron["status"], "partial_data");

    let magnesium = nutrient("MAGNESIUM_MG");
    assert_amount(&magnesium["known_amount"], Decimal::new(1842, 1));
    assert_eq!(magnesium["status"], "partial_data");

    let added_sugars = nutrient("ADDED_SUGAR_G");
    assert_amount(&added_sugars["known_amount"], Decimal::from(51));
    assert_eq!(added_sugars["status"], "over_limit");
    assert_eq!(added_sugars["reference_amount"], "50");

    let calcium = nutrient("CALCIUM_MG");
    assert!(calcium["known_amount"].is_null());
    assert_eq!(calcium["items_with_data"], 0);
    assert_eq!(calcium["coverage"], "none");
    assert_eq!(calcium["status"], "no_data");

    let (status, _headers, bytes) = send(
        &router,
        empty_request(
            Method::GET,
            "/api/nutrition/details?date=not-a-date",
            Some(&user),
        ),
    )
    .await;
    assert_status(status, StatusCode::BAD_REQUEST, &bytes);
}

#[sqlx::test]
async fn meal_snapshot_with_mixed_component_data_has_partial_coverage(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;
    let user = create_user_session(&router, &admin, "meal-report-user", "testpassword").await;

    let magnesium_product = create_product(
        &router,
        &user,
        "Magnesium component",
        json!([
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 1 },
            { "code": "FAT_G", "amount_per_100g": 1 },
            { "code": "MAGNESIUM_MG", "amount_per_100g": "184.2" }
        ]),
    )
    .await;
    let component_without_magnesium = create_product(
        &router,
        &user,
        "No magnesium component",
        json!([
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 1 },
            { "code": "FAT_G", "amount_per_100g": 1 }
        ]),
    )
    .await;
    let meal_payload = json!({
        "name": "Mixed component meal",
        "total_quantity": { "amount": 200, "unit": "g" },
        "components": [
            {
                "item": { "type": "product", "id": magnesium_product },
                "quantity": { "amount": 100, "unit": "g" }
            },
            {
                "item": { "type": "product", "id": component_without_magnesium },
                "quantity": { "amount": 100, "unit": "g" }
            }
        ]
    });
    let meal: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &meal_payload,
        StatusCode::CREATED,
    )
    .await;

    log_meal(&router, &user, meal["id"].as_str().unwrap(), "2026-08-14").await;
    let report: Value = get_json(&router, "/api/nutrition/details?date=2026-08-14", &user).await;
    let magnesium = report["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["code"] == "MAGNESIUM_MG")
        .unwrap();

    assert_eq!(report["logged_items"], 1);
    assert_amount(&magnesium["known_amount"], Decimal::new(1842, 1));
    assert_eq!(magnesium["items_with_data"], 1);
    assert_eq!(magnesium["coverage"], "partial");
    assert_eq!(magnesium["status"], "partial_data");
}

use crate::common::*;
use axum::http::{Method, StatusCode};
use rust_decimal::Decimal;
use serde_json::{Value, json};
use sqlx::PgPool;

fn assert_amount(value: &Value, expected: Decimal) {
    assert_eq!(
        value.as_str().unwrap().parse::<Decimal>().unwrap(),
        expected
    );
}

fn product_payload(name: &str, nutrients: Value) -> Value {
    json!({
        "name": name,
        "categories": ["test"],
        "nutrients": nutrients,
        "servings": [],
    })
}

async fn create_product(
    router: &axum::Router,
    cookie: &str,
    name: &str,
    nutrients: Value,
) -> String {
    let payload = product_payload(name, nutrients);
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
            { "code": "MAGNESIUM_MG", "amount_per_100g": "184.2" },
            { "code": "SODIUM_MG", "amount_per_100g": 2400 }
        ]),
    )
    .await;
    let product_without_magnesium = create_product(
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
    log_product(&router, &user, &product_without_magnesium, "2026-08-14").await;
    log_product(&router, &other_user, &other_user_product, "2026-08-14").await;

    let report: Value = get_json(&router, "/api/nutrition/details?date=2026-08-14", &user).await;

    assert_eq!(report["date"], "2026-08-14");
    assert_eq!(report["reference"]["code"], "us_fda_dv_adult_2020");
    assert_eq!(report["logged_items"], 2);
    let magnesium = report["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["code"] == "MAGNESIUM_MG")
        .unwrap();
    assert_amount(&magnesium["known_amount"], Decimal::new(1842, 1));
    assert_eq!(magnesium["items_with_data"], 1);
    assert_eq!(magnesium["coverage"], "partial");
    assert_eq!(magnesium["status"], "partial_data");
    assert_eq!(magnesium["guidance_kind"], "adequacy");
    assert_eq!(magnesium["section"], "vitamins_minerals");
    assert_eq!(magnesium["reference_amount"], "420");

    let sodium = report["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["code"] == "SODIUM_MG")
        .unwrap();
    assert_amount(&sodium["known_amount"], Decimal::from(2400));
    assert_eq!(sodium["status"], "over_limit");
    assert_eq!(sodium["guidance_kind"], "maximum");
    assert_eq!(sodium["section"], "limits");
    assert_eq!(sodium["reference_amount"], "2300");

    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{nutrient_product}"),
        &user,
        &product_payload(
            "Renamed mineral food",
            json!([
                { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
                { "code": "PROTEIN_G", "amount_per_100g": 1 },
                { "code": "CARBS_G", "amount_per_100g": 1 },
                { "code": "FAT_G", "amount_per_100g": 1 },
                { "code": "MAGNESIUM_MG", "amount_per_100g": 999 }
            ]),
        ),
        StatusCode::OK,
    )
    .await;

    let report_after_product_update: Value =
        get_json(&router, "/api/nutrition/details?date=2026-08-14", &user).await;
    let magnesium_after_product_update = report_after_product_update["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["code"] == "MAGNESIUM_MG")
        .unwrap();
    assert_amount(
        &magnesium_after_product_update["known_amount"],
        Decimal::new(1842, 1),
    );

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

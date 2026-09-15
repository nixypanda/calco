use crate::common::*;
use axum::http::{Method, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

fn valid_payload() -> Value {
    json!({
        "log_date": "2026-09-14",
        "meal_slot": "lunch",
        "device_timezone": "Asia/Kolkata",
        "name": "Paneer tikka wrap",
        "brand": null,
        "quantity": { "amount": 1, "unit": "serving" },
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount": 520, "unit": "kcal" },
            { "code": "PROTEIN_G", "amount": 24, "unit": "g" },
            { "code": "CARBS_G", "amount": 48, "unit": "g" },
            { "code": "FAT_G", "amount": 25, "unit": "g" }
        ],
        "notes": null
    })
}

async fn post_status(router: &axum::Router, user: &str, payload: &Value) -> StatusCode {
    let request = json_request(Method::POST, "/api/logs/ad-hoc", Some(user), payload);
    let (status, _, _) = send(router, request).await;
    status
}

fn nutrient_amount<'a>(log: &'a Value, code: &str) -> &'a str {
    log["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|nutrient| nutrient["code"] == code)
        .unwrap()["amount"]
        .as_str()
        .unwrap()
}

#[sqlx::test]
async fn ad_hoc_log_lifecycle_and_history_behavior(pool: PgPool) {
    let database = pool.clone();
    let router = app(pool).await;
    let (_, user) = bootstrap_and_user(&router).await;

    let created: Value = post_json(
        &router,
        "/api/logs/ad-hoc",
        &user,
        &valid_payload(),
        StatusCode::CREATED,
    )
    .await;
    let log_id = created["id"].as_str().unwrap();
    assert_eq!(created["item"]["type"], "ad_hoc");
    assert_eq!(created["item"]["name"], "Paneer tikka wrap");
    assert!(created["item"].get("id").is_none());
    assert_eq!(nutrient_amount(&created, "ENERGY_KCAL"), "520");

    let fetched: Value = get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(fetched["item"]["type"], "ad_hoc");

    let listed: Value = get_json(&router, "/api/logs?log_date=2026-09-14", &user).await;
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let summary: Value = get_json(
        &router,
        "/api/logs/summary?from_date=2026-09-14&to_date=2026-09-14",
        &user,
    )
    .await;
    assert_eq!(summary["days"][0]["energy_kcal"], "520");

    let recent: Value = get_json(
        &router,
        "/api/logs/recent-items?from_date=2026-09-14&to_date=2026-09-14",
        &user,
    )
    .await;
    assert!(recent["items"].as_array().unwrap().is_empty());

    let latest: Value = get_json(
        &router,
        "/api/logs/latest-slots?before=2026-09-15&lookback_days=30",
        &user,
    )
    .await;
    assert!(latest["slots"].as_array().unwrap().is_empty());

    let updated: Value = put_json(
        &router,
        &format!("/api/logs/{log_id}"),
        &user,
        &json!({
            "quantity": { "amount": 2, "unit": "serving" },
            "meal_slot": "dinner",
            "notes": "shared"
        }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(nutrient_amount(&updated, "ENERGY_KCAL"), "1040");
    assert_eq!(nutrient_amount(&updated, "PROTEIN_G"), "48");
    assert_eq!(updated["item"]["name"], "Paneer tikka wrap");

    let request = json_request(
        Method::PUT,
        &format!("/api/logs/{log_id}"),
        Some(&user),
        &json!({ "quantity": { "amount": 2, "unit": "piece" } }),
    );
    let (status, _, _) = send(&router, request).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let product: Value = post_json(
        &router,
        "/api/foods/custom",
        &user,
        &json!({
            "name": "Constraint food",
            "brand": null,
            "categories": [],
            "default_quantity": null,
            "default_unit": null,
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": 1 },
                { "code": "PROTEIN_G", "amount_per_100g": 0 },
                { "code": "CARBS_G", "amount_per_100g": 0 },
                { "code": "FAT_G", "amount_per_100g": 0 }
            ],
            "servings": []
        }),
        StatusCode::CREATED,
    )
    .await;
    let product_id = Uuid::parse_str(product["id"].as_str().unwrap()).unwrap();
    let user_id: Uuid = sqlx::query_scalar(
        "SELECT up.id FROM user_profiles up \
         JOIN identities i ON i.id = up.identity_id WHERE i.username = 'tester'",
    )
    .fetch_one(&database)
    .await
    .unwrap();
    let meal_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO meals (id, user_id, name, created_at, updated_at) \
         VALUES ($1, $2, 'Constraint meal', now(), now())",
    )
    .bind(meal_id)
    .bind(user_id)
    .execute(&database)
    .await
    .unwrap();
    let invalid_both =
        sqlx::query("UPDATE food_logs SET item_product_id = $1, item_meal_id = $2 WHERE id = $3")
            .bind(product_id)
            .bind(meal_id)
            .bind(Uuid::parse_str(log_id).unwrap())
            .execute(&database)
            .await;
    assert!(
        invalid_both.is_err(),
        "both item references must be rejected"
    );

    delete_no_content(&router, &format!("/api/logs/{log_id}"), &user).await;
    let (status, _) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[sqlx::test]
async fn ad_hoc_log_validates_identity_quantity_and_core_nutrients(pool: PgPool) {
    let router = app(pool).await;
    let (_, user) = bootstrap_and_user(&router).await;

    let mut blank_name = valid_payload();
    blank_name["name"] = json!("  ");
    assert_eq!(
        post_status(&router, &user, &blank_name).await,
        StatusCode::BAD_REQUEST
    );

    let mut non_positive_quantity = valid_payload();
    non_positive_quantity["quantity"]["amount"] = json!(0);
    assert_eq!(
        post_status(&router, &user, &non_positive_quantity).await,
        StatusCode::BAD_REQUEST
    );

    let mut missing = valid_payload();
    missing["nutrients"].as_array_mut().unwrap().pop();
    assert_eq!(
        post_status(&router, &user, &missing).await,
        StatusCode::BAD_REQUEST
    );

    let mut duplicate = valid_payload();
    let duplicate_energy = duplicate["nutrients"][0].clone();
    duplicate["nutrients"]
        .as_array_mut()
        .unwrap()
        .push(duplicate_energy);
    assert_eq!(
        post_status(&router, &user, &duplicate).await,
        StatusCode::BAD_REQUEST
    );

    let mut unknown = valid_payload();
    unknown["nutrients"].as_array_mut().unwrap().push(json!({
        "code": "NOT_A_NUTRIENT",
        "amount": 1,
        "unit": "g"
    }));
    assert_eq!(
        post_status(&router, &user, &unknown).await,
        StatusCode::BAD_REQUEST
    );

    let mut wrong_unit = valid_payload();
    wrong_unit["nutrients"][0]["unit"] = json!("g");
    assert_eq!(
        post_status(&router, &user, &wrong_unit).await,
        StatusCode::BAD_REQUEST
    );

    let mut negative = valid_payload();
    negative["nutrients"][1]["amount"] = json!(-1);
    assert_eq!(
        post_status(&router, &user, &negative).await,
        StatusCode::BAD_REQUEST
    );

    let mut with_optional_nutrient = valid_payload();
    with_optional_nutrient["nutrients"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "code": "FIBER_G", "amount": 7, "unit": "g" }));
    assert_eq!(
        post_status(&router, &user, &with_optional_nutrient).await,
        StatusCode::CREATED
    );

    let mut zero = valid_payload();
    for nutrient in zero["nutrients"].as_array_mut().unwrap() {
        nutrient["amount"] = json!(0);
    }
    assert_eq!(
        post_status(&router, &user, &zero).await,
        StatusCode::CREATED
    );
}

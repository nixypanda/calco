use crate::common::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;

/// Exercises the wiring between catalog → meal → food log:
/// builds a meal from a product, logs both the meal and the bare product
/// on the same day, and asserts the returned log snapshots can be summed.
#[sqlx::test]
async fn product_to_meal_to_log(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    // ── 1. Create a product with known kcal density ─────────────────────
    let product_payload = json!({
        "name": "Bread",
        "categories": ["bakery"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 250 },
            { "code": "PROTEIN_G", "amount_per_100g": 9 },
            { "code": "CARBS_G", "amount_per_100g": 49 },
            { "code": "FAT_G", "amount_per_100g": 3 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 30 }
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
    let meal: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &meal_payload,
        StatusCode::CREATED,
    )
    .await;
    let meal_id = meal["id"].as_str().unwrap().to_string();

    // ── 3. Log the meal at lunch ────────────────────────────────────────
    // Logging the meal at 60g of its 60g total → 1 portion → 150 kcal.
    let log_meal_payload = json!({
        "log_date": "2026-06-01",
        "meal_slot": "lunch",
        "item": { "type": "meal", "id": meal_id },
        "quantity": { "amount": 60, "unit": "g" }
    });
    let meal_log: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &log_meal_payload,
        StatusCode::CREATED,
    )
    .await;
    let meal_log_id = meal_log["id"].as_str().unwrap().to_string();
    assert_eq!(meal_log["item"]["type"], "meal");
    assert_eq!(meal_log["item"]["id"], meal_id);
    assert_eq!(meal_log["item"]["name"], "Toast");
    assert!(meal_log.get("item_snapshot").is_none());

    let rename_meal_payload = json!({
        "name": "Renamed Toast"
    });
    let _: Value = put_json(
        &router,
        &format!("/api/meals/{meal_id}"),
        &user,
        &rename_meal_payload,
        StatusCode::OK,
    )
    .await;
    let meal_log_after_rename: Value =
        get_json(&router, &format!("/api/logs/{meal_log_id}"), &user).await;
    assert_eq!(meal_log_after_rename["item"]["name"], "Toast");

    // ── 4. Log the bare product at breakfast ────────────────────────────
    // 40g bread = 40 * 250 / 100 = 100 kcal
    let log_product_payload = json!({
        "log_date": "2026-06-01",
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

    // ── 5. Logs for the day should carry summable nutrient snapshots ───
    let logs: Value = get_json(&router, "/api/logs?log_date=2026-06-01", &user).await;
    let items = logs["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);

    let total_kcal: f64 = items
        .iter()
        .flat_map(|item| item["nutrients"].as_array().unwrap())
        .filter(|nutrient| nutrient["code"] == "ENERGY_KCAL")
        .map(|nutrient| nutrient["amount"].as_str().unwrap().parse::<f64>().unwrap())
        .sum();

    // 150 (meal log) + 100 (product log) = 250 kcal
    assert!(
        (total_kcal - 250.0).abs() < 0.001,
        "expected 250 kcal across both entries, got {total_kcal}"
    );
}

#[sqlx::test]
async fn shared_content_keeps_creator_writes_and_food_logs_private(pool: PgPool) {
    let router = app(pool).await;
    let (admin, creator) = bootstrap_and_user(&router).await;
    let guest = create_user_session(&router, &admin, "shared-content-guest", "testpassword").await;

    let product_payload = json!({
        "name": "Shared Bread",
        "categories": ["shared"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 250 },
            { "code": "PROTEIN_G", "amount_per_100g": 9 },
            { "code": "CARBS_G", "amount_per_100g": 49 },
            { "code": "FAT_G", "amount_per_100g": 3 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 30 }
        ]
    });
    let product: Value = post_json(
        &router,
        "/api/foods/custom",
        &creator,
        &product_payload,
        StatusCode::CREATED,
    )
    .await;
    let product_id = product["id"].as_str().unwrap();

    let shared_product: Value =
        get_json(&router, &format!("/api/foods/{product_id}"), &guest).await;
    assert_eq!(shared_product["visibility"], "global");
    let shared_custom_foods: Value = get_json(&router, "/api/foods/custom", &guest).await;
    assert!(
        shared_custom_foods["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["id"] == product_id)
    );

    let req = json_request(
        axum::http::Method::PUT,
        &format!("/api/foods/custom/{product_id}"),
        Some(&guest),
        &product_payload,
    );
    let (status, _, _) = send(&router, req).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let req = json_request(
        axum::http::Method::DELETE,
        &format!("/api/foods/custom/{product_id}"),
        Some(&guest),
        &Value::Null,
    );
    let (status, _, _) = send(&router, req).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let meal_payload = json!({
        "name": "Shared Toast",
        "total_quantity": { "amount": 30, "unit": "g" },
        "components": [{
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 30, "unit": "g" }
        }]
    });
    let meal: Value = post_json(
        &router,
        "/api/meals",
        &creator,
        &meal_payload,
        StatusCode::CREATED,
    )
    .await;
    let meal_id = meal["id"].as_str().unwrap();

    let shared_meal: Value = get_json(&router, &format!("/api/meals/{meal_id}"), &guest).await;
    assert_eq!(shared_meal["name"], "Shared Toast");
    let shared_meals: Value = get_json(&router, "/api/meals", &guest).await;
    assert!(
        shared_meals["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["id"] == meal_id)
    );

    let req = json_request(
        axum::http::Method::PUT,
        &format!("/api/meals/{meal_id}"),
        Some(&guest),
        &json!({ "name": "Not mine" }),
    );
    let (status, _, _) = send(&router, req).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let req = json_request(
        axum::http::Method::DELETE,
        &format!("/api/meals/{meal_id}"),
        Some(&guest),
        &Value::Null,
    );
    let (status, _, _) = send(&router, req).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    for item in [
        json!({ "type": "product", "id": product_id }),
        json!({ "type": "meal", "id": meal_id }),
    ] {
        let _: Value = post_json(
            &router,
            "/api/logs",
            &guest,
            &json!({
                "log_date": "2026-08-16",
                "item": item,
                "quantity": { "amount": 30, "unit": "g" }
            }),
            StatusCode::CREATED,
        )
        .await;
    }

    let creator_log: Value = post_json(
        &router,
        "/api/logs",
        &creator,
        &json!({
            "log_date": "2026-08-16",
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": 30, "unit": "g" }
        }),
        StatusCode::CREATED,
    )
    .await;
    let creator_log_id = creator_log["id"].as_str().unwrap();

    let (status, _) = get_status(&router, &format!("/api/logs/{creator_log_id}"), &guest).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let req = json_request(
        axum::http::Method::PUT,
        &format!("/api/logs/{creator_log_id}"),
        Some(&guest),
        &json!({ "notes": "not mine" }),
    );
    let (status, _, _) = send(&router, req).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let guest_logs: Value = get_json(&router, "/api/logs?log_date=2026-08-16", &guest).await;
    assert_eq!(guest_logs["items"].as_array().unwrap().len(), 2);

    let req = json_request(
        axum::http::Method::DELETE,
        &format!("/api/logs/{creator_log_id}"),
        Some(&guest),
        &Value::Null,
    );
    let (status, _, _) = send(&router, req).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

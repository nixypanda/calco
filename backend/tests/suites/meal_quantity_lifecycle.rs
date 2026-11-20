use crate::common::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;

async fn seed_product(
    router: &axum::Router,
    user: &str,
    name: &str,
    kcal: i64,
    servings: Value,
) -> String {
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        user,
        &json!({
            "name": name,
            "categories": ["meal-quantity"],
            "default_quantity": 1,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": kcal },
                { "code": "PROTEIN_G", "amount_per_100g": 5 },
                { "code": "CARBS_G", "amount_per_100g": 10 },
                { "code": "FAT_G", "amount_per_100g": 2 }
            ],
            "servings": servings
        }),
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().unwrap().to_string()
}

async fn assert_meal_row_counts(pool: &PgPool, meals: i64, components: i64) {
    let meal_count: i64 = sqlx::query_scalar("SELECT count(*) FROM meals")
        .fetch_one(pool)
        .await
        .unwrap();
    let component_count: i64 = sqlx::query_scalar("SELECT count(*) FROM meal_components")
        .fetch_one(pool)
        .await
        .unwrap();
    assert_eq!(meal_count, meals, "unexpected persisted meal rows");
    assert_eq!(
        component_count, components,
        "unexpected persisted meal component rows"
    );
}

#[sqlx::test]
async fn invalid_meal_create_and_update_are_rejected_before_persistence(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "Plain Food", 100, json!([])).await;

    let product_component = |unit: &str, amount: i64| {
        json!([{
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": amount, "unit": unit }
        }])
    };

    let invalid_payloads = [
        json!({
            "name": "Banana Unit",
            "components": product_component("banana", 100)
        }),
        json!({
            "name": "Blank Unit",
            "components": product_component("", 100)
        }),
        json!({
            "name": "Whitespace Unit",
            "components": product_component("   ", 100)
        }),
        json!({
            "name": "Nonmass Total",
            "total_quantity": { "amount": 1, "unit": "cup" },
            "components": product_component("g", 100)
        }),
        json!({
            "name": "Blank Total Unit",
            "total_quantity": { "amount": 100, "unit": "" },
            "components": product_component("g", 100)
        }),
        json!({
            "name": "Zero Total",
            "total_quantity": { "amount": 0, "unit": "g" },
            "components": product_component("g", 100)
        }),
        json!({
            "name": "Negative Total",
            "total_quantity": { "amount": -1, "unit": "g" },
            "components": product_component("g", 100)
        }),
        json!({
            "name": "Zero Component",
            "components": product_component("g", 0)
        }),
        json!({
            "name": "No Components",
            "components": []
        }),
    ];

    for payload in invalid_payloads {
        let body: Value = post_json(
            &router,
            "/api/meals",
            &user,
            &payload,
            StatusCode::BAD_REQUEST,
        )
        .await;
        assert_eq!(body["error"]["code"], "validation", "{payload}");
        assert_meal_row_counts(&pool, 0, 0).await;

        let meals: Value = get_json(&router, "/api/meals", &user).await;
        assert!(
            meals["items"].as_array().unwrap().is_empty(),
            "an invalid create must not appear in the meal list: {payload}"
        );
    }

    let other = create_user_session(&router, &admin, "meal-other", "otherpassword").await;
    let other_meals: Value = get_json(&router, "/api/meals", &other).await;
    assert!(
        other_meals["items"].as_array().unwrap().is_empty(),
        "one user's invalid writes must not affect another user's list"
    );

    let created: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "Valid Meal",
            "total_quantity": { "amount": 100, "unit": "g" },
            "components": product_component("g", 100)
        }),
        StatusCode::CREATED,
    )
    .await;
    let meal_id = created["id"].as_str().unwrap().to_string();
    assert_meal_row_counts(&pool, 1, 1).await;

    // Invalid updates must leave the previously valid aggregate unchanged.
    let (invalid_total_status, invalid_total_body) = put_status(
        &router,
        &format!("/api/meals/{meal_id}"),
        &user,
        &json!({
            "name": "Should Not Persist",
            "total_quantity": { "amount": 1, "unit": "cup" }
        }),
    )
    .await;
    assert_eq!(invalid_total_status, StatusCode::BAD_REQUEST);
    assert_eq!(invalid_total_body["error"]["code"], "validation");
    assert_meal_row_counts(&pool, 1, 1).await;

    let (invalid_component_status, invalid_component_body) = put_status(
        &router,
        &format!("/api/meals/{meal_id}"),
        &user,
        &json!({
            "name": "Should Not Persist Either",
            "components": product_component("banana", 100)
        }),
    )
    .await;
    assert_eq!(invalid_component_status, StatusCode::BAD_REQUEST);
    assert_eq!(invalid_component_body["error"]["code"], "validation");

    let detail: Value = get_json(&router, &format!("/api/meals/{meal_id}"), &user).await;
    assert_eq!(detail["name"], "Valid Meal");
    assert_eq!(detail["total_quantity"]["amount"], "100");
    assert_eq!(detail["total_quantity"]["unit"], "g");
    assert_eq!(detail["components"].as_array().unwrap().len(), 1);
    assert_eq!(detail["components"][0]["quantity"]["amount"], "100");
    assert_eq!(detail["components"][0]["quantity"]["unit"], "g");
    assert_eq!(detail["nutrition"]["status"], "available");
    assert_meal_row_counts(&pool, 1, 1).await;

    let updated: Value = put_json(
        &router,
        &format!("/api/meals/{meal_id}"),
        &user,
        &json!({
            "name": "Valid Update",
            "total_quantity": { "amount": 200, "unit": "g" }
        }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["name"], "Valid Update");
    assert_eq!(updated["total_quantity"]["amount"], "200");
}

#[sqlx::test]
async fn serving_removal_degrades_meal_reads_then_repair_restores_preview_and_log(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let other = create_user_session(&router, &admin, "serving-other", "otherpassword").await;

    let product_id = seed_product(
        &router,
        &user,
        "Cup Food",
        100,
        json!([{ "unit": "cup", "grams_per_unit": 100 }]),
    )
    .await;

    let created: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "One Cup Meal",
            "total_quantity": { "amount": 100, "unit": "g" },
            "components": [
                {
                    "item": { "type": "product", "id": product_id },
                    "quantity": { "amount": 1, "unit": "cup" }
                }
            ]
        }),
        StatusCode::CREATED,
    )
    .await;
    let meal_id = created["id"].as_str().unwrap().to_string();
    let component_id = created["components"][0]["id"].as_str().unwrap().to_string();
    assert_eq!(created["nutrition"]["status"], "available");
    assert_eq!(created["nutrition"]["summary"]["energy_kcal"], "100");

    // A meal whose components are convertible can still reject a requested
    // scale quantity that has no mass or serving conversion. The failure is a
    // typed conflict with the offending quantity, not a generic 400.
    let (preview_status, preview_body) = get_status(
        &router,
        &format!("/api/meals/{meal_id}/nutrients?amount=1&unit=serving"),
        &user,
    )
    .await;
    assert_eq!(preview_status, StatusCode::CONFLICT);
    assert_eq!(
        preview_body["error"]["code"],
        "meal_quantity_not_convertible"
    );
    assert_eq!(preview_body["error"]["meal_id"], meal_id);
    assert_eq!(preview_body["error"]["quantity"]["amount"], "1");
    assert_eq!(preview_body["error"]["quantity"]["unit"], "serving");
    assert_eq!(preview_body["error"]["reason"], "quantity_not_convertible");

    let (log_status, log_body) = post_status(
        &router,
        "/api/logs",
        &user,
        &json!({
            "log_date": "2026-06-30",
            "meal_slot": "lunch",
            "item": { "type": "meal", "id": meal_id },
            "quantity": { "amount": 1, "unit": "serving" },
            "idempotency_key": "meal-scale-not-convertible"
        }),
    )
    .await;
    assert_eq!(log_status, StatusCode::CONFLICT);
    assert_eq!(log_body["error"]["code"], "meal_quantity_not_convertible");
    assert_eq!(log_body["error"]["quantity"]["unit"], "serving");
    let logs: Value = get_json(&router, "/api/logs?log_date=2026-06-30", &user).await;
    assert!(logs["items"].as_array().unwrap().is_empty());

    // Catalog updates can remove the serving that made the stored component
    // convertible. The historical meal must remain readable.
    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{product_id}"),
        &user,
        &json!({
            "name": "Cup Food",
            "categories": ["meal-quantity"],
            "default_quantity": 1,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
                { "code": "PROTEIN_G", "amount_per_100g": 5 },
                { "code": "CARBS_G", "amount_per_100g": 10 },
                { "code": "FAT_G", "amount_per_100g": 2 }
            ],
            "servings": []
        }),
        StatusCode::OK,
    )
    .await;

    for (label, cookie) in [("owner", &user), ("other user", &other)] {
        let list: Value = get_json(&router, "/api/meals", cookie).await;
        let meal = list["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|meal| meal["id"] == meal_id)
            .unwrap_or_else(|| panic!("{label} meal list omitted the degraded meal"));
        assert_eq!(meal["nutrition"]["status"], "unavailable");
        let unavailable = meal["nutrition"]["unavailable_components"]
            .as_array()
            .unwrap();
        assert_eq!(unavailable.len(), 1);
        assert_eq!(unavailable[0]["component_id"], component_id);
        assert_eq!(unavailable[0]["item"]["type"], "product");
        assert_eq!(unavailable[0]["item"]["id"], product_id);
        assert_eq!(unavailable[0]["quantity"]["amount"], "1");
        assert_eq!(unavailable[0]["quantity"]["unit"], "cup");
        assert_eq!(unavailable[0]["reason"], "quantity_not_convertible");

        let component = meal["components"]
            .as_array()
            .unwrap()
            .iter()
            .find(|component| component["id"] == component_id)
            .unwrap();
        assert_eq!(component["availability"], "unavailable");
        assert_eq!(component["reason"], "quantity_not_convertible");
        assert_eq!(component["item"]["id"], product_id);
        assert_eq!(component["quantity"]["amount"], "1");
        assert_eq!(component["quantity"]["unit"], "cup");
        assert!(component.get("nutrition_summary").is_none());
    }

    let detail: Value = get_json(&router, &format!("/api/meals/{meal_id}"), &user).await;
    assert_eq!(detail["nutrition"]["status"], "unavailable");
    assert_eq!(
        detail["nutrition"]["unavailable_components"][0]["reason"],
        "quantity_not_convertible"
    );

    let (preview_status, preview_body) = get_status(
        &router,
        &format!("/api/meals/{meal_id}/nutrients?amount=100&unit=g"),
        &user,
    )
    .await;
    assert_eq!(preview_status, StatusCode::CONFLICT);
    assert_eq!(preview_body["error"]["code"], "unavailable_components");
    assert_eq!(
        preview_body["error"]["unavailable_components"][0]["reason"],
        "quantity_not_convertible"
    );
    assert_eq!(
        preview_body["error"]["unavailable_components"][0]["quantity"]["unit"],
        "cup"
    );

    let (log_status, log_body) = post_status(
        &router,
        "/api/logs",
        &user,
        &json!({
            "log_date": "2026-07-01",
            "meal_slot": "lunch",
            "item": { "type": "meal", "id": meal_id },
            "quantity": { "amount": 100, "unit": "g" },
            "idempotency_key": "serving-removal-failed-log"
        }),
    )
    .await;
    assert_eq!(log_status, StatusCode::CONFLICT);
    assert_eq!(log_body["error"]["code"], "unavailable_components");
    let logs: Value = get_json(&router, "/api/logs?log_date=2026-07-01", &user).await;
    assert!(logs["items"].as_array().unwrap().is_empty());

    // Repair by replacing the component quantity with a supported mass amount.
    let repaired: Value = put_json(
        &router,
        &format!("/api/meals/{meal_id}"),
        &user,
        &json!({
            "total_quantity": { "amount": 100, "unit": "g" },
            "components": [
                {
                    "item": { "type": "product", "id": product_id },
                    "quantity": { "amount": 100, "unit": "g" }
                }
            ]
        }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(repaired["nutrition"]["status"], "available");
    assert_eq!(repaired["nutrition"]["summary"]["energy_kcal"], "100");

    let preview: Value = get_json(
        &router,
        &format!("/api/meals/{meal_id}/nutrients?amount=100&unit=g"),
        &user,
    )
    .await;
    assert_eq!(preview["nutrition_summary"]["energy_kcal"], "100");

    let logged: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &json!({
            "log_date": "2026-07-02",
            "meal_slot": "lunch",
            "item": { "type": "meal", "id": meal_id },
            "quantity": { "amount": 100, "unit": "g" },
            "idempotency_key": "serving-removal-repaired-log"
        }),
        StatusCode::CREATED,
    )
    .await;
    assert_eq!(logged["item"]["id"], meal_id);
}

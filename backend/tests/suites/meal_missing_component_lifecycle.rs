use crate::common::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;

async fn seed_product(router: &axum::Router, user: &str, name: &str, kcal: i64) -> String {
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        user,
        &json!({
            "name": name,
            "categories": ["test"],
            "default_quantity": 1,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": kcal },
                { "code": "PROTEIN_G", "amount_per_100g": 5 },
                { "code": "CARBS_G", "amount_per_100g": 10 },
                { "code": "FAT_G", "amount_per_100g": 2 }
            ],
            "servings": []
        }),
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().unwrap().to_string()
}

fn component_for_product<'a>(meal: &'a Value, product_id: &str) -> &'a Value {
    meal["components"]
        .as_array()
        .unwrap()
        .iter()
        .find(|component| component["item"]["id"] == product_id)
        .unwrap_or_else(|| panic!("component for product {product_id} missing"))
}

fn assert_amount(value: &Value, expected: f64) {
    let actual: f64 = value.as_str().unwrap().parse().unwrap();
    assert!(
        (actual - expected).abs() < 0.001,
        "expected {expected}, got {actual}"
    );
}

fn assert_nutrient_amount(log: &Value, code: &str, expected: f64) {
    let nutrient = log["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|nutrient| nutrient["code"] == code)
        .unwrap_or_else(|| panic!("{code} missing from log"));
    assert_amount(&nutrient["amount"], expected);
}

fn assert_missing_error(body: &Value, meal_id: &str, component_id: &str, product_id: &str) {
    assert_eq!(body["error"]["code"], "unavailable_components");
    assert_eq!(body["error"]["meal_id"], meal_id);
    let missing = body["error"]["unavailable_components"].as_array().unwrap();
    assert_eq!(missing.len(), 1);
    assert_eq!(missing[0]["component_id"], component_id);
    assert_eq!(missing[0]["item"]["type"], "product");
    assert_eq!(missing[0]["item"]["id"], product_id);
    assert_eq!(missing[0]["quantity"]["amount"], "200");
    assert_eq!(missing[0]["quantity"]["unit"], "g");
    assert_eq!(missing[0]["reason"], "product_unavailable");
    assert!(
        missing[0].get("name").is_none(),
        "the error must not invent a display name for an unavailable product"
    );
}

#[sqlx::test]
async fn deleted_ingredient_degrades_meals_and_repair_restores_preview_and_log(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let oats_id = seed_product(&router, &user, "Oats", 380).await;
    let milk_id = seed_product(&router, &user, "Milk", 60).await;
    let repair_id = seed_product(&router, &user, "Repair Food", 100).await;

    let healthy: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "Healthy Oats",
            "total_quantity": { "amount": 100, "unit": "g" },
            "components": [
                { "item": { "type": "product", "id": oats_id }, "quantity": { "amount": 100, "unit": "g" } }
            ]
        }),
        StatusCode::CREATED,
    )
    .await;
    let healthy_id = healthy["id"].as_str().unwrap().to_string();

    let broken: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "Broken Porridge",
            "notes": "needs milk",
            "total_quantity": { "amount": 250, "unit": "g" },
            "components": [
                { "item": { "type": "product", "id": oats_id }, "quantity": { "amount": 50, "unit": "g" } },
                { "item": { "type": "product", "id": milk_id }, "quantity": { "amount": 200, "unit": "g" } }
            ]
        }),
        StatusCode::CREATED,
    )
    .await;
    let broken_id = broken["id"].as_str().unwrap().to_string();
    let milk_component_id = component_for_product(&broken, &milk_id)["id"]
        .as_str()
        .unwrap()
        .to_string();

    // A separate meal proves deletion still works while the meal is broken.
    let discard: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "Discard Me",
            "total_quantity": { "amount": 100, "unit": "g" },
            "components": [
                { "item": { "type": "product", "id": milk_id }, "quantity": { "amount": 100, "unit": "g" } }
            ]
        }),
        StatusCode::CREATED,
    )
    .await;
    let discard_id = discard["id"].as_str().unwrap().to_string();

    let pre_delete_log: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &json!({
            "log_date": "2026-06-10",
            "meal_slot": "lunch",
            "item": { "type": "meal", "id": broken_id },
            "quantity": { "amount": 250, "unit": "g" },
            "notes": "snapshot before deletion",
            "idempotency_key": "meal-missing-pre-delete-log"
        }),
        StatusCode::CREATED,
    )
    .await;
    let pre_delete_log_id = pre_delete_log["id"].as_str().unwrap().to_string();
    assert_nutrient_amount(&pre_delete_log, "ENERGY_KCAL", 310.0);

    delete_no_content(&router, &format!("/api/foods/custom/{milk_id}"), &user).await;

    delete_no_content(&router, &format!("/api/meals/{discard_id}"), &user).await;

    let meals: Value = get_json(&router, "/api/meals", &user).await;
    let items = meals["items"].as_array().unwrap();
    assert_eq!(
        items.len(),
        2,
        "healthy and broken meals must both be listed"
    );

    let broken_list = items
        .iter()
        .find(|meal| meal["id"] == broken_id)
        .expect("broken meal missing from list");
    let healthy_list = items
        .iter()
        .find(|meal| meal["id"] == healthy_id)
        .expect("healthy meal missing from list");

    assert_eq!(broken_list["nutrition"]["status"], "unavailable");
    let missing_summary = broken_list["nutrition"]["unavailable_components"]
        .as_array()
        .unwrap();
    assert_eq!(missing_summary.len(), 1);
    assert_eq!(missing_summary[0]["reason"], "product_unavailable");
    let missing_component = component_for_product(broken_list, &milk_id);
    assert_eq!(missing_component["availability"], "unavailable");
    assert_eq!(missing_component["reason"], "product_unavailable");
    assert_eq!(missing_component["quantity"]["amount"], "200");
    assert_eq!(missing_component["quantity"]["unit"], "g");
    assert!(missing_component.get("nutrition_summary").is_none());
    let healthy_component = component_for_product(broken_list, &oats_id);
    assert_eq!(healthy_component["availability"], "available");
    assert!(healthy_component["nutrition_summary"].is_object());

    assert_eq!(healthy_list["nutrition"]["status"], "available");
    assert_amount(&healthy_list["nutrition"]["summary"]["energy_kcal"], 380.0);

    let detail: Value = get_json(&router, &format!("/api/meals/{broken_id}"), &user).await;
    assert_eq!(detail["nutrition"]["status"], "unavailable");
    assert_eq!(
        detail["nutrition"]["unavailable_components"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let detail_missing = component_for_product(&detail, &milk_id);
    assert_eq!(detail_missing["availability"], "unavailable");
    assert_eq!(detail_missing["item"]["id"], milk_id);
    assert_eq!(detail_missing["quantity"]["amount"], "200");

    let (preview_status, preview_error) = get_status(
        &router,
        &format!("/api/meals/{broken_id}/nutrients?amount=250&unit=g"),
        &user,
    )
    .await;
    assert_eq!(preview_status, StatusCode::CONFLICT);
    assert_missing_error(&preview_error, &broken_id, &milk_component_id, &milk_id);

    let failed_log: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &json!({
            "log_date": "2026-06-11",
            "meal_slot": "lunch",
            "item": { "type": "meal", "id": broken_id },
            "quantity": { "amount": 250, "unit": "g" },
            "idempotency_key": "meal-missing-failed-log"
        }),
        StatusCode::CONFLICT,
    )
    .await;
    assert_missing_error(&failed_log, &broken_id, &milk_component_id, &milk_id);

    let failed_log_date: Value = get_json(&router, "/api/logs?log_date=2026-06-11", &user).await;
    assert!(
        failed_log_date["items"].as_array().unwrap().is_empty(),
        "a missing-component meal log must not write a false-nutrition log"
    );

    // Existing meal logs are immutable snapshots and survive catalog deletion.
    let existing_log: Value =
        get_json(&router, &format!("/api/logs/{pre_delete_log_id}"), &user).await;
    assert_eq!(existing_log["item"]["type"], "meal");
    assert_eq!(existing_log["item"]["name"], "Broken Porridge");
    assert_nutrient_amount(&existing_log, "ENERGY_KCAL", 310.0);

    // Repair by replacing the missing component; the meal becomes editable and
    // nutrition/logging work again without disturbing the old snapshot.
    let repaired: Value = put_json(
        &router,
        &format!("/api/meals/{broken_id}"),
        &user,
        &json!({
            "name": "Repaired Porridge",
            "total_quantity": { "amount": 250, "unit": "g" },
            "components": [
                { "item": { "type": "product", "id": oats_id }, "quantity": { "amount": 50, "unit": "g" } },
                { "item": { "type": "product", "id": repair_id }, "quantity": { "amount": 200, "unit": "g" } }
            ]
        }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(repaired["nutrition"]["status"], "available");
    assert_amount(&repaired["nutrition"]["summary"]["energy_kcal"], 390.0);

    let repaired_detail: Value = get_json(&router, &format!("/api/meals/{broken_id}"), &user).await;
    assert_eq!(repaired_detail["nutrition"]["status"], "available");
    assert_eq!(repaired_detail["components"].as_array().unwrap().len(), 2);

    let repaired_preview: Value = get_json(
        &router,
        &format!("/api/meals/{broken_id}/nutrients?amount=250&unit=g"),
        &user,
    )
    .await;
    assert_amount(&repaired_preview["nutrition_summary"]["energy_kcal"], 390.0);

    let repaired_log: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &json!({
            "log_date": "2026-06-12",
            "meal_slot": "lunch",
            "item": { "type": "meal", "id": broken_id },
            "quantity": { "amount": 250, "unit": "g" },
            "idempotency_key": "meal-missing-repaired-log"
        }),
        StatusCode::CREATED,
    )
    .await;
    assert_nutrient_amount(&repaired_log, "ENERGY_KCAL", 390.0);

    let old_log_after_repair: Value =
        get_json(&router, &format!("/api/logs/{pre_delete_log_id}"), &user).await;
    assert_eq!(old_log_after_repair["item"]["name"], "Broken Porridge");
    assert_nutrient_amount(&old_log_after_repair, "ENERGY_KCAL", 310.0);
}

#[sqlx::test]
async fn meal_without_declared_total_reports_not_declared_nutrition(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let oats_id = seed_product(&router, &user, "Undeclared Oats", 380).await;

    let created: Value = post_json(
        &router,
        "/api/meals",
        &user,
        &json!({
            "name": "Undeclared Porridge",
            "components": [
                { "item": { "type": "product", "id": oats_id }, "quantity": { "amount": 50, "unit": "g" } }
            ]
        }),
        StatusCode::CREATED,
    )
    .await;

    assert_eq!(created["nutrition"]["status"], "not_declared");
    assert!(created.get("has_missing_components").is_none());
    let component = component_for_product(&created, &oats_id);
    assert_eq!(component["availability"], "available");
    assert_amount(&component["nutrition_summary"]["energy_kcal"], 190.0);
}

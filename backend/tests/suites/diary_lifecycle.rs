use crate::common::*;
use axum::http::{Method, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::collections::HashSet;

async fn seed_product(router: &axum::Router, user: &str) -> String {
    seed_named_product(router, user, "Diary Test Apple").await
}

async fn seed_named_product(router: &axum::Router, user: &str, name: &str) -> String {
    let payload = json!({
        "name": name,
        "brand": "Orchard Lab",
        "categories": ["fruit"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 52 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 14 },
            { "code": "FAT_G", "amount_per_100g": 0 }
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
    created["id"].as_str().unwrap().to_string()
}

async fn post_product_log(
    router: &axum::Router,
    user: &str,
    product_id: &str,
    log_date: &str,
    meal_slot: &str,
    amount: i64,
) -> String {
    let payload = json!({
        "log_date": log_date,
        "meal_slot": meal_slot,
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": amount, "unit": "g" }
    });
    let created: Value = post_json(router, "/api/logs", user, &payload, StatusCode::CREATED).await;
    created["id"].as_str().unwrap().to_string()
}

fn nutrient_amount<'a>(nutrients: &'a Value, code: &str) -> &'a str {
    nutrients
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["code"] == code)
        .unwrap_or_else(|| panic!("{code} snapshot missing"))["amount"]
        .as_str()
        .unwrap()
}

async fn logs_on(router: &axum::Router, user: &str, log_date: &str) -> Vec<Value> {
    let listed: Value = get_json(router, &format!("/api/logs?log_date={log_date}"), user).await;
    listed["items"].as_array().unwrap().clone()
}

#[sqlx::test]
async fn diary_lifecycle_create_read_list_update_delete(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let product_id = seed_product(&router, &user).await;

    // ── Create log ──────────────────────────────────────────────────────
    let create_payload = json!({
        "log_date": "2026-06-01",
        "meal_slot": "breakfast",
        "device_timezone": "Asia/Kolkata",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 150, "unit": "g" },
        "notes": "with yogurt"
    });
    let created: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &create_payload,
        StatusCode::CREATED,
    )
    .await;
    let log_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["item"]["type"], "product");
    assert_eq!(created["item"]["id"], product_id);
    assert_eq!(created["item"]["name"], "Diary Test Apple");
    assert_eq!(created["item"]["brand"], "Orchard Lab");
    assert!(created.get("item_snapshot").is_none());
    assert!(created.get("logged_at").is_none());
    assert_eq!(created["log_date"], "2026-06-01");
    assert_eq!(created["meal_slot"], "breakfast");
    assert_eq!(created["device_timezone"], "Asia/Kolkata");
    assert_eq!(nutrient_amount(&created["nutrients"], "ENERGY_KCAL"), "78");
    assert_eq!(nutrient_amount(&created["nutrients"], "CARBS_G"), "21");
    assert_eq!(nutrient_amount(&created["nutrients"], "PROTEIN_G"), "1.50");
    assert_eq!(nutrient_amount(&created["nutrients"], "FAT_G"), "0");

    // Nutrient snapshot should include kcal scaled to 150g
    let created_nutrients = created["nutrients"].as_array().unwrap();
    assert_eq!(created_nutrients.len(), 4);
    let kcal = created["nutrients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["code"] == "ENERGY_KCAL")
        .expect("ENERGY_KCAL snapshot missing");
    // 52 kcal / 100g * 150g = 78
    let kcal_amount: f64 = kcal["amount"].as_str().unwrap().parse().unwrap();
    assert!((kcal_amount - 78.0).abs() < 0.001, "kcal was {kcal_amount}");

    // ── Read by id ──────────────────────────────────────────────────────
    let fetched: Value = get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(fetched["id"], log_id);
    assert_eq!(fetched["notes"], "with yogurt");

    let renamed_product_payload = json!({
        "name": "Renamed Apple",
        "brand": "New Brand",
        "categories": ["fruit"],
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 52 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 14 },
            { "code": "FAT_G", "amount_per_100g": 0 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 100 }
        ]
    });
    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{product_id}"),
        &user,
        &renamed_product_payload,
        StatusCode::OK,
    )
    .await;
    let fetched_after_product_rename: Value =
        get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(
        fetched_after_product_rename["item"]["name"],
        "Diary Test Apple"
    );
    assert_eq!(fetched_after_product_rename["item"]["brand"], "Orchard Lab");

    // ── List by log date ────────────────────────────────────────────────
    let list: Value = get_json(&router, "/api/logs?log_date=2026-06-01", &user).await;
    let items = list["items"].as_array().unwrap();
    assert!(items.iter().any(|l| l["id"] == log_id));

    let other_day_list: Value = get_json(&router, "/api/logs?log_date=2026-06-02", &user).await;
    assert!(other_day_list["items"].as_array().unwrap().is_empty());

    // ── Update ──────────────────────────────────────────────────────────
    let update_payload = json!({
        "quantity": { "amount": 200, "unit": "g" },
        "notes": "post-workout",
        "device_timezone": null
    });
    let updated: Value = put_json(
        &router,
        &format!("/api/logs/{log_id}"),
        &user,
        &update_payload,
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["quantity"]["amount"], "200");
    assert_eq!(updated["notes"], "post-workout");
    assert!(updated["device_timezone"].is_null());

    // ── Delete ──────────────────────────────────────────────────────────
    delete_no_content(&router, &format!("/api/logs/{log_id}"), &user).await;
    let (status, _) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[sqlx::test]
async fn log_list_orders_by_meal_slot_then_created_at(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let other_user = create_user_session(&router, &admin, "other", "otherpassword").await;
    let product_id = seed_product(&router, &user).await;
    let other_product_id = seed_product(&router, &other_user).await;

    // Create the logs in a deliberately scrambled order. The older breakfast
    // log is created first, so a missing secondary sort or an updated_at sort
    // would put the older one first.
    let dinner = post_product_log(&router, &user, &product_id, "2026-06-01", "dinner", 100).await;
    let older_breakfast =
        post_product_log(&router, &user, &product_id, "2026-06-01", "breakfast", 100).await;
    let snack = post_product_log(&router, &user, &product_id, "2026-06-01", "snack", 100).await;
    let newer_breakfast =
        post_product_log(&router, &user, &product_id, "2026-06-01", "breakfast", 100).await;
    let late_night_snack = post_product_log(
        &router,
        &user,
        &product_id,
        "2026-06-01",
        "late_night_snack",
        100,
    )
    .await;
    let lunch = post_product_log(&router, &user, &product_id, "2026-06-01", "lunch", 100).await;
    let adjacent_date =
        post_product_log(&router, &user, &product_id, "2026-06-02", "breakfast", 100).await;
    let other_user_log = post_product_log(
        &router,
        &other_user,
        &other_product_id,
        "2026-06-01",
        "breakfast",
        100,
    )
    .await;

    for (log_id, created_at) in [
        (&older_breakfast, "2026-06-01 08:00:00+00"),
        (&newer_breakfast, "2026-06-01 09:00:00+00"),
    ] {
        sqlx::query("UPDATE food_logs SET created_at = $1::timestamptz WHERE id = $2")
            .bind(created_at)
            .bind(uuid::Uuid::parse_str(log_id).unwrap())
            .execute(&pool)
            .await
            .expect("set deterministic log created_at");
    }

    for (log_id, updated_at) in [
        (&older_breakfast, "2026-06-01 10:00:00+00"),
        (&newer_breakfast, "2026-06-01 07:00:00+00"),
    ] {
        sqlx::query("UPDATE food_logs SET updated_at = $1::timestamptz WHERE id = $2")
            .bind(updated_at)
            .bind(uuid::Uuid::parse_str(log_id).unwrap())
            .execute(&pool)
            .await
            .expect("set deterministic log updated_at");
    }

    let listed: Value = get_json(&router, "/api/logs?log_date=2026-06-01", &user).await;
    let listed_ids: Vec<String> = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();

    assert_eq!(
        listed_ids,
        vec![
            newer_breakfast,
            older_breakfast,
            lunch,
            dinner,
            snack,
            late_night_snack,
        ],
        "logs must be ordered by meal-slot rank, then newest created_at first"
    );
    assert!(!listed_ids.contains(&adjacent_date));
    assert!(!listed_ids.contains(&other_user_log));
}

#[sqlx::test]
async fn recent_latest_and_last_used_wire_shape(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user).await;
    let log_id =
        post_product_log(&router, &user, &product_id, "2026-06-01", "breakfast", 150).await;

    let recent: Value = get_json(
        &router,
        "/api/logs/recent-items?from_date=2026-06-01&to_date=2026-06-01&meal_slot=breakfast",
        &user,
    )
    .await;
    let recent_items = recent["items"].as_array().unwrap();
    assert_eq!(recent_items.len(), 1);
    let recent_item = &recent_items[0];
    assert_eq!(recent_item["item"]["type"], "product");
    assert_eq!(recent_item["item"]["id"], product_id);
    assert_eq!(recent_item["last_used_date"], "2026-06-01");
    assert_eq!(recent_item["quantity"]["amount"], "150");
    assert_eq!(recent_item["quantity"]["unit"], "g");
    assert_eq!(recent_item["nutrition_summary"]["energy_kcal"], "78");

    let last_used: Value = post_json(
        &router,
        "/api/logs/last-used",
        &user,
        &json!({
            "from_date": "2026-06-01",
            "to_date": "2026-06-01",
            "meal_slot": "breakfast",
            "items": [{ "type": "product", "id": product_id }]
        }),
        StatusCode::OK,
    )
    .await;
    let last_used_items = last_used["items"].as_array().unwrap();
    assert_eq!(last_used_items.len(), 1);
    let last_used_item = &last_used_items[0];
    assert_eq!(last_used_item["item"]["id"], product_id);
    assert_eq!(last_used_item["quantity"]["amount"], "150");
    assert_eq!(last_used_item["quantity"]["unit"], "g");
    assert_eq!(last_used_item["nutrition_summary"]["energy_kcal"], "78");

    let latest: Value = get_json(&router, "/api/logs/latest-slots?before=2026-06-02", &user).await;
    let slots = latest["slots"].as_array().unwrap();
    assert_eq!(slots.len(), 1);
    assert_eq!(slots[0]["meal_slot"], "breakfast");
    assert_eq!(slots[0]["source_date"], "2026-06-01");
    let slot_items = slots[0]["items"].as_array().unwrap();
    assert_eq!(slot_items.len(), 1);
    assert_eq!(slot_items[0]["id"], log_id);
}

#[sqlx::test]
async fn keyed_log_replay_normalizes_and_keeps_the_original_fingerprint(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user).await;

    let original = json!({
        "log_date": "2026-06-03",
        "meal_slot": "breakfast",
        "device_timezone": "Asia/Kolkata",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 150, "unit": "g" },
        "notes": "replay me",
        "idempotency_key": "diary-single-key"
    });
    let created: Value =
        post_json(&router, "/api/logs", &user, &original, StatusCode::CREATED).await;
    let log_id = created["id"].as_str().unwrap().to_string();

    // A fresh router has no in-memory replay state, and decimal spelling and
    // timezone whitespace must normalize to the same request.
    let replay_router = app(pool).await;
    let equivalent = json!({
        "log_date": "2026-06-03",
        "meal_slot": "breakfast",
        "device_timezone": "  Asia/Kolkata  ",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 150.00, "unit": "g" },
        "notes": "replay me",
        "idempotency_key": "diary-single-key"
    });
    let replay: Value = post_json(
        &replay_router,
        "/api/logs",
        &user,
        &equivalent,
        StatusCode::OK,
    )
    .await;
    assert_eq!(replay["id"], log_id);

    let listed = logs_on(&replay_router, &user, "2026-06-03").await;
    assert_eq!(listed.len(), 1, "replay must not create a second log");
    assert_eq!(listed[0]["id"], log_id);

    // Editing the log must not replace the create fingerprint. Replaying the
    // original request returns the edited current row, not a stale copy.
    let edited: Value = put_json(
        &replay_router,
        &format!("/api/logs/{log_id}"),
        &user,
        &json!({
            "quantity": { "amount": 220, "unit": "g" },
            "notes": "edited"
        }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(edited["quantity"]["amount"], "220");

    let replay_after_edit: Value = post_json(
        &replay_router,
        "/api/logs",
        &user,
        &original,
        StatusCode::OK,
    )
    .await;
    assert_eq!(replay_after_edit["id"], log_id);
    assert_eq!(replay_after_edit["quantity"]["amount"], "220");
    assert_eq!(replay_after_edit["notes"], "edited");

    let mut conflicting = original.clone();
    conflicting["quantity"]["amount"] = json!(151);
    let conflict: Value = post_json(
        &replay_router,
        "/api/logs",
        &user,
        &conflicting,
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(conflict["error"]["code"], "conflict");

    let listed = logs_on(&replay_router, &user, "2026-06-03").await;
    assert_eq!(listed.len(), 1, "a conflict must not append a second log");
    assert_eq!(listed[0]["id"], log_id);
    assert_eq!(listed[0]["quantity"]["amount"], "220");
}

#[sqlx::test]
async fn deleted_keyed_log_frees_the_idempotency_key(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user).await;

    let payload = json!({
        "log_date": "2026-06-04",
        "meal_slot": "lunch",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 120, "unit": "g" },
        "idempotency_key": "diary-deleted-key"
    });
    let created: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CREATED).await;
    let log_id = created["id"].as_str().unwrap().to_string();

    delete_no_content(&router, &format!("/api/logs/{log_id}"), &user).await;
    let (status, _) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Deleting the log also deletes its key. A delayed retry can therefore
    // create a fresh log, but it must not resurrect the deleted one.
    let recreated: Value =
        post_json(&router, "/api/logs", &user, &payload, StatusCode::CREATED).await;
    let recreated_id = recreated["id"].as_str().unwrap();
    assert_ne!(recreated_id, log_id.as_str());

    let listed = logs_on(&router, &user, "2026-06-04").await;
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["id"], recreated_id);
}

#[sqlx::test]
async fn idempotency_keys_are_scoped_per_profile(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let other_user = create_user_session(&router, &admin, "other", "otherpassword").await;
    let product_id = seed_product(&router, &user).await;
    let other_product_id = seed_product(&router, &other_user).await;

    let first_payload = json!({
        "log_date": "2026-06-05",
        "meal_slot": "dinner",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 130, "unit": "g" },
        "notes": "same key",
        "idempotency_key": "shared-profile-key"
    });
    let other_payload = json!({
        "log_date": "2026-06-05",
        "meal_slot": "dinner",
        "item": { "type": "product", "id": other_product_id },
        "quantity": { "amount": 130, "unit": "g" },
        "notes": "same key",
        "idempotency_key": "shared-profile-key"
    });

    let first: Value = post_json(
        &router,
        "/api/logs",
        &user,
        &first_payload,
        StatusCode::CREATED,
    )
    .await;
    let other: Value = post_json(
        &router,
        "/api/logs",
        &other_user,
        &other_payload,
        StatusCode::CREATED,
    )
    .await;
    let first_id = first["id"].as_str().unwrap().to_string();
    let other_id = other["id"].as_str().unwrap().to_string();
    assert_ne!(first_id, other_id);

    let first_replay: Value =
        post_json(&router, "/api/logs", &user, &first_payload, StatusCode::OK).await;
    let other_replay: Value = post_json(
        &router,
        "/api/logs",
        &other_user,
        &other_payload,
        StatusCode::OK,
    )
    .await;
    assert_eq!(first_replay["id"], first_id);
    assert_eq!(other_replay["id"], other_id);
}

#[sqlx::test]
async fn concurrent_keyed_creates_yield_one_log(pool: PgPool) {
    const REQUESTS: usize = 6;

    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user).await;
    let payload = json!({
        "log_date": "2026-06-06",
        "meal_slot": "snack",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 90, "unit": "g" },
        "idempotency_key": "diary-concurrent-key"
    });

    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(REQUESTS));
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..REQUESTS {
        let router = router.clone();
        let user = user.clone();
        let payload = payload.clone();
        let barrier = barrier.clone();
        tasks.spawn(async move {
            barrier.wait().await;
            let request = json_request(Method::POST, "/api/logs", Some(&user), &payload);
            let (status, _headers, bytes) = send(&router, request).await;
            (status, parse_json::<Value>(&bytes))
        });
    }

    let mut created = 0;
    let mut replayed = 0;
    let mut ids = HashSet::new();
    while let Some(result) = tasks.join_next().await {
        let (status, body) = result.expect("concurrent request task panicked");
        match status {
            StatusCode::CREATED => created += 1,
            StatusCode::OK => replayed += 1,
            unexpected => panic!("unexpected status {unexpected}: {body}"),
        }
        ids.insert(body["id"].as_str().unwrap().to_string());
    }

    assert_eq!(created, 1);
    assert_eq!(replayed, REQUESTS - 1);
    assert_eq!(ids.len(), 1);

    let log_id = ids.into_iter().next().unwrap();
    let listed = logs_on(&router, &user, "2026-06-06").await;
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["id"], log_id);

    // A different payload racing for the same new key must not be mistaken
    // for a replay of whichever request wins the insert.
    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
    let mut contenders = tokio::task::JoinSet::new();
    for amount in [90, 91] {
        let router = router.clone();
        let user = user.clone();
        let barrier = barrier.clone();
        let mut payload = payload.clone();
        payload["idempotency_key"] = json!("diary-concurrent-conflict");
        payload["quantity"]["amount"] = json!(amount);
        contenders.spawn(async move {
            barrier.wait().await;
            let request = json_request(Method::POST, "/api/logs", Some(&user), &payload);
            let (status, _headers, bytes) = send(&router, request).await;
            (status, parse_json::<Value>(&bytes))
        });
    }
    let mut statuses = Vec::new();
    while let Some(result) = contenders.join_next().await {
        let (status, body) = result.expect("concurrent request task panicked");
        if status == StatusCode::CONFLICT {
            assert_eq!(body["error"]["code"], "conflict");
        }
        statuses.push(status);
    }
    statuses.sort();
    assert_eq!(statuses, [StatusCode::CREATED, StatusCode::CONFLICT]);
    assert_eq!(logs_on(&router, &user, "2026-06-06").await.len(), 2);
}

#[sqlx::test]
async fn batch_log_creation_rejects_item_idempotency_keys(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user).await;

    let item = |meal_slot: &str, amount: i64| {
        json!({
            "log_date": "2026-06-07",
            "meal_slot": meal_slot,
            "item": { "type": "product", "id": product_id },
            "quantity": { "amount": amount, "unit": "g" }
        })
    };
    let breakfast_item = item("breakfast", 70);
    let lunch_item = item("lunch", 80);
    let mut keyed_item = lunch_item.clone();
    keyed_item["idempotency_key"] = json!("batch-item-key");
    let keyed_batch = json!({ "items": [breakfast_item.clone(), keyed_item] });

    let _: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &keyed_batch,
        StatusCode::BAD_REQUEST,
    )
    .await;
    assert!(
        logs_on(&router, &user, "2026-06-07").await.is_empty(),
        "a rejected keyed batch must not partially create logs"
    );

    let mut null_key_item = lunch_item.clone();
    null_key_item["idempotency_key"] = Value::Null;
    let _: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &json!({ "items": [null_key_item] }),
        StatusCode::BAD_REQUEST,
    )
    .await;

    let batch = json!({ "items": [breakfast_item, lunch_item] });
    let created: Value = post_json(
        &router,
        "/api/logs/batch",
        &user,
        &batch,
        StatusCode::CREATED,
    )
    .await;
    assert_eq!(created["items"].as_array().unwrap().len(), 2);
    assert_eq!(logs_on(&router, &user, "2026-06-07").await.len(), 2);
}

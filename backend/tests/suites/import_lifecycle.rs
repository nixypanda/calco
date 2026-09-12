use crate::common::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;

#[sqlx::test]
async fn import_lifecycle_happy_path(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;
    // Need a user too so we can call /api/foods/search later to verify products surfaced.
    let user = create_user_session(&router, &admin, "tester", "testpassword").await;

    // ── 1. Create import job ────────────────────────────────────────────
    let created: Value = post_json(
        &router,
        "/api/imports",
        &admin,
        &json!({ "source": "OFF" }),
        StatusCode::CREATED,
    )
    .await;
    let import_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(created["source"], "OFF");

    // ── 2. Stage foods ──────────────────────────────────────────────────
    let foods_payload = json!({
        "rows": [
            {
                "row_number": 1,
                "source": "OFF",
                "source_id": "111111",
                "barcode": "111111",
                "name": "Imported Yogurt",
                "brand": "ImportCo",
                "categories": ["dairy"],
            },
            {
                "row_number": 2,
                "source": "OFF",
                "source_id": "222222",
                "barcode": "222222",
                "name": "Imported Bar",
                "brand": "ImportCo",
                "categories": ["snacks"],
            }
        ]
    });
    let staged: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/foods"),
        &admin,
        &foods_payload,
        StatusCode::OK,
    )
    .await;
    assert_eq!(staged["accepted"], 2);
    assert_eq!(staged["rejected"], 0);

    // ── 3. Stage nutrients ──────────────────────────────────────────────
    let nutrients_payload = json!({
        "rows": [
            {
                "row_number": 1,
                "source": "OFF",
                "source_id": "111111",
                "nutrient_code": "ENERGY_KCAL",
                "amount_per_100g": 90
            },
            {
                "row_number": 2,
                "source": "OFF",
                "source_id": "222222",
                "nutrient_code": "ENERGY_KCAL",
                "amount_per_100g": 480
            }
        ]
    });
    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/nutrients"),
        &admin,
        &nutrients_payload,
        StatusCode::OK,
    )
    .await;

    // ── 4. Stage servings ───────────────────────────────────────────────
    let servings_payload = json!({
        "rows": [
            {
                "row_number": 1,
                "source": "OFF",
                "source_id": "111111",
                "unit": "cup",
                "grams_per_unit": 245
            }
        ]
    });
    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/servings"),
        &admin,
        &servings_payload,
        StatusCode::OK,
    )
    .await;

    // ── 5. Commit ───────────────────────────────────────────────────────
    let commit: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::OK,
    )
    .await;
    assert_eq!(commit["status"], "committed");
    assert_eq!(commit["products_created"], 2);

    // A lost response can be retried: the persisted canonical result is replayed without
    // applying the catalog batch again.
    let replay: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::OK,
    )
    .await;
    assert_eq!(replay, commit);

    // ── 6. Status reflects committed state ──────────────────────────────
    let status: Value = get_json(&router, &format!("/api/imports/{import_id}"), &admin).await;
    assert_eq!(status["status"], "committed");
    assert!(status["committed_at"].is_string());

    // ── 7. Imported products are surfaced via the catalog barcode lookup ─
    let yogurt: Value = get_json(&router, "/api/foods/barcode/111111", &user).await;
    assert_eq!(yogurt["name"], "Imported Yogurt");
    assert_eq!(yogurt["visibility"], "global");
}

#[sqlx::test]
async fn import_commit_records_errors_for_unknown_nutrient(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;

    let created: Value = post_json(
        &router,
        "/api/imports",
        &admin,
        &json!({ "source": "OFF" }),
        StatusCode::CREATED,
    )
    .await;
    let import_id = created["id"].as_str().unwrap().to_string();

    let foods_payload = json!({
        "rows": [{
            "row_number": 1,
            "source": "OFF",
            "source_id": "333333",
            "name": "Mystery Food",
            "categories": []
        }]
    });
    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/foods"),
        &admin,
        &foods_payload,
        StatusCode::OK,
    )
    .await;

    // Reference a nutrient code that doesn't exist in the catalog
    let bad_nutrients = json!({
        "rows": [{
            "row_number": 1,
            "source": "OFF",
            "source_id": "333333",
            "nutrient_code": "NOT_A_REAL_NUTRIENT",
            "amount_per_100g": 10
        }]
    });
    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/nutrients"),
        &admin,
        &bad_nutrients,
        StatusCode::OK,
    )
    .await;

    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::OK,
    )
    .await;

    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::OK,
    )
    .await;

    let errors: Value =
        get_json(&router, &format!("/api/imports/{import_id}/errors"), &admin).await;
    let items = errors["items"].as_array().expect("errors items missing");
    assert_eq!(items.len(), 1, "retry must not duplicate the import error");
}

#[sqlx::test]
async fn running_import_resumes_and_rejects_further_staging(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin = bootstrap_admin(&router).await;
    let created: Value = post_json(
        &router,
        "/api/imports",
        &admin,
        &json!({ "source": "USDA" }),
        StatusCode::CREATED,
    )
    .await;
    let import_id = created["id"].as_str().unwrap();
    let foods_payload = json!({
        "rows": [{
            "row_number": 1,
            "source": "USDA",
            "source_id": "resume-1",
            "name": "Resumable food",
            "categories": []
        }]
    });
    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/foods"),
        &admin,
        &foods_payload,
        StatusCode::OK,
    )
    .await;
    sqlx::query("UPDATE imports SET status = 'running' WHERE id = $1")
        .bind(uuid::Uuid::parse_str(import_id).unwrap())
        .execute(&pool)
        .await
        .unwrap();

    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/foods"),
        &admin,
        &foods_payload,
        StatusCode::CONFLICT,
    )
    .await;
    let committed: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::OK,
    )
    .await;
    assert_eq!(committed["status"], "committed");
}

#[sqlx::test]
async fn retrying_invalid_staging_does_not_duplicate_errors(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;
    let created: Value = post_json(
        &router,
        "/api/imports",
        &admin,
        &json!({ "source": "USDA" }),
        StatusCode::CREATED,
    )
    .await;
    let import_id = created["id"].as_str().unwrap();
    let invalid_food = json!({
        "rows": [{
            "row_number": null,
            "source": "",
            "source_id": "",
            "name": "",
            "categories": []
        }]
    });

    for _ in 0..2 {
        let staged: Value = post_json(
            &router,
            &format!("/api/imports/{import_id}/foods"),
            &admin,
            &invalid_food,
            StatusCode::OK,
        )
        .await;
        assert_eq!(staged["accepted"], 0);
        assert_eq!(staged["rejected"], 1);
    }

    let errors: Value =
        get_json(&router, &format!("/api/imports/{import_id}/errors"), &admin).await;
    let items = errors["items"].as_array().expect("errors items missing");
    assert_eq!(items.len(), 1);
    assert!(items[0]["row_number"].is_null());
}

#[sqlx::test]
async fn deterministic_catalog_validation_marks_import_failed(pool: PgPool) {
    let router = app(pool).await;
    let admin = bootstrap_admin(&router).await;
    let created: Value = post_json(
        &router,
        "/api/imports",
        &admin,
        &json!({ "source": "OFF" }),
        StatusCode::CREATED,
    )
    .await;
    let import_id = created["id"].as_str().unwrap();
    let duplicate_after_normalization = json!({
        "rows": [
            {
                "row_number": 1,
                "source": "OFF",
                "source_id": "duplicate",
                "name": "First",
                "categories": []
            },
            {
                "row_number": 2,
                "source": "OFF",
                "source_id": " duplicate ",
                "name": "Second",
                "categories": []
            }
        ]
    });
    let staged: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/foods"),
        &admin,
        &duplicate_after_normalization,
        StatusCode::OK,
    )
    .await;
    assert_eq!(staged["accepted"], 2);

    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::BAD_REQUEST,
    )
    .await;
    let status: Value = get_json(&router, &format!("/api/imports/{import_id}"), &admin).await;
    assert_eq!(status["status"], "failed");
    assert!(status["failed_at"].is_string());

    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::CONFLICT,
    )
    .await;
}

#[sqlx::test]
async fn legacy_committed_import_without_result_is_not_replayed_as_zeroes(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin = bootstrap_admin(&router).await;
    let created: Value = post_json(
        &router,
        "/api/imports",
        &admin,
        &json!({ "source": "OFF" }),
        StatusCode::CREATED,
    )
    .await;
    let import_id = created["id"].as_str().unwrap();
    sqlx::query("UPDATE imports SET status = 'committed', committed_at = NOW() WHERE id = $1")
        .bind(uuid::Uuid::parse_str(import_id).unwrap())
        .execute(&pool)
        .await
        .unwrap();

    let _: Value = post_json(
        &router,
        &format!("/api/imports/{import_id}/commit"),
        &admin,
        &json!({}),
        StatusCode::CONFLICT,
    )
    .await;
}

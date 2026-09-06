use crate::common::*;
use axum::http::{Method, StatusCode};
use serde_json::{Value, json};
use sqlx::PgPool;

#[sqlx::test]
async fn diary_preferences_default_replace_and_persist(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let defaults: Value = get_json(&router, "/api/diary-preferences", &user).await;
    assert_eq!(
        defaults["enabled_meal_slots"],
        json!(["breakfast", "lunch", "dinner", "snack"])
    );

    let replacement = json!({
        "enabled_meal_slots": ["late_night_snack", "breakfast", "late_night_snack"]
    });
    let saved: Value = put_json(
        &router,
        "/api/diary-preferences",
        &user,
        &replacement,
        StatusCode::OK,
    )
    .await;
    assert_eq!(
        saved["enabled_meal_slots"],
        json!(["breakfast", "late_night_snack"])
    );

    let fetched: Value = get_json(&router, "/api/diary-preferences", &user).await;
    assert_eq!(fetched, saved);

    let req = json_request(
        Method::PUT,
        "/api/diary-preferences",
        Some(&user),
        &json!({ "enabled_meal_slots": [] }),
    );
    let (status, _, body) = send(&router, req).await;
    assert_status(status, StatusCode::BAD_REQUEST, &body);
}

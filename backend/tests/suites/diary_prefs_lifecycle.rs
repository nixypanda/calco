use crate::common::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;

#[sqlx::test]
async fn diary_prefs_save_and_reload(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let defaults: Value = get_json(&router, "/api/diary-preferences", &user).await;
    assert_eq!(
        defaults["enabled_meal_slots"],
        json!(["breakfast", "lunch", "dinner", "snack"])
    );

    let saved: Value = put_json(
        &router,
        "/api/diary-preferences",
        &user,
        &json!({ "enabled_meal_slots": ["breakfast", "lunch"] }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(saved["enabled_meal_slots"], json!(["breakfast", "lunch"]));

    let fetched: Value = get_json(&router, "/api/diary-preferences", &user).await;
    assert_eq!(fetched["enabled_meal_slots"], json!(["breakfast", "lunch"]));
}

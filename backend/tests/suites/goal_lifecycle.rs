use crate::common;
use crate::common::*;
use axum::http::StatusCode;
use chrono_tz::Tz;
use serde_json::{Value, json};
use sqlx::PgPool;

fn today_in_timezone(timezone: &str) -> String {
    let tz: Tz = timezone.parse().unwrap();
    chrono::Utc::now()
        .with_timezone(&tz)
        .date_naive()
        .format("%Y-%m-%d")
        .to_string()
}

#[sqlx::test]
async fn goal_defaults_and_save_flow(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let timezone = "Asia/Kolkata";
    let today = today_in_timezone(timezone);

    let unauthenticated =
        common::empty_request(axum::http::Method::GET, "/api/goal?date=2026-05-01", None);
    let (status, _headers, _body) = common::send(&router, unauthenticated).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, body) = get_status(&router, "/api/goal?date=2026-05-01", &admin).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "forbidden");

    let defaults: Value = get_json(&router, "/api/goal?date=2026-05-01", &user).await;
    assert_eq!(defaults["source"], "default");
    assert!(defaults["effective_from"].is_null());
    assert_eq!(defaults["calorie_target"], "2100");
    assert_eq!(defaults["protein_target_g"], "150");
    assert_eq!(defaults["carbs_target_g"], "240");
    assert_eq!(defaults["fat_target_g"], "60");

    let create_payload = json!({
        "local_date": today,
        "device_timezone": timezone,
        "calorie_target": 2100,
        "protein_target_g": 150,
        "carbs_target_g": 240,
        "fat_target_g": 60
    });
    let saved: Value = put_json(&router, "/api/goal", &user, &create_payload, StatusCode::OK).await;
    assert_eq!(saved["source"], "saved");
    assert_eq!(saved["effective_from"], today);
    assert_eq!(saved["calorie_target"], "2100");

    let fetched: Value = get_json(&router, &format!("/api/goal?date={today}"), &user).await;
    assert_eq!(fetched["source"], "saved");
    assert_eq!(fetched["effective_from"], today);
    assert_eq!(fetched["protein_target_g"], "150");

    let overwrite_payload = json!({
        "local_date": today,
        "device_timezone": timezone,
        "calorie_target": 2290,
        "protein_target_g": 160,
        "carbs_target_g": 255,
        "fat_target_g": 70
    });
    let overwritten: Value = put_json(
        &router,
        "/api/goal",
        &user,
        &overwrite_payload,
        StatusCode::OK,
    )
    .await;
    assert_eq!(overwritten["calorie_target"], "2290");
    assert_eq!(overwritten["protein_target_g"], "160");
}

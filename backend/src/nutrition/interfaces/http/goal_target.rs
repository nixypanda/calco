use axum::{
    Router,
    extract::{Json, Query, State},
    response::IntoResponse,
    routing::get,
};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::auth::interfaces::http::AuthUser;
use crate::nutrition::domain::error::NutritionError;
use crate::nutrition::domain::goal_target::{GoalTargetSnapshot, GoalTargetSource, GoalTargets};
use crate::nutrition::module::NutritionModule;

pub fn goal_target_routes(state: AppState) -> Router {
    Router::new()
        .route("/goal", get(get_goal_handler).put(put_goal_handler))
        .with_state(state)
}

#[derive(Deserialize)]
pub struct GoalQuery {
    pub date: String,
}

#[derive(Deserialize)]
pub struct PutGoalRequest {
    pub local_date: String,
    pub device_timezone: String,
    pub calorie_target: Decimal,
    pub protein_target_g: Decimal,
    pub carbs_target_g: Decimal,
    pub fat_target_g: Decimal,
}

#[derive(Serialize)]
pub struct GoalResponse {
    pub requested_date: NaiveDate,
    pub effective_from: Option<NaiveDate>,
    pub source: GoalSourceDto,
    pub calorie_target: Decimal,
    pub protein_target_g: Decimal,
    pub carbs_target_g: Decimal,
    pub fat_target_g: Decimal,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GoalSourceDto {
    Default,
    Saved,
}

async fn get_goal_handler(
    auth: AuthUser,
    State(state): State<NutritionModule>,
    Query(query): Query<GoalQuery>,
) -> impl IntoResponse {
    let requested_date = match parse_date(&query.date, "date") {
        Ok(date) => date,
        Err(err) => return err.into_response(),
    };

    match state
        .goal_target_services
        .get_goal_for_date(auth.0.id, requested_date)
        .await
    {
        Ok(snapshot) => Json(goal_snapshot_to_response(snapshot)).into_response(),
        Err(err) => err.into_response(),
    }
}

async fn put_goal_handler(
    auth: AuthUser,
    State(state): State<NutritionModule>,
    Json(request): Json<PutGoalRequest>,
) -> impl IntoResponse {
    let local_date = match parse_date(&request.local_date, "local_date") {
        Ok(date) => date,
        Err(err) => return err.into_response(),
    };
    let device_timezone = match normalize_device_timezone(request.device_timezone) {
        Ok(value) => value,
        Err(err) => return err.into_response(),
    };
    let targets = match GoalTargets::new(
        request.calorie_target,
        request.protein_target_g,
        request.carbs_target_g,
        request.fat_target_g,
    ) {
        Ok(targets) => targets,
        Err(err) => return err.into_response(),
    };

    match state
        .goal_target_services
        .save_goal_for_today(auth.0.id, local_date, &device_timezone, targets)
        .await
    {
        Ok(snapshot) => Json(goal_snapshot_to_response(snapshot)).into_response(),
        Err(err) => err.into_response(),
    }
}

fn parse_date(value: &str, field_name: &str) -> Result<NaiveDate, NutritionError> {
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| NutritionError::Validation(format!("invalid {field_name}")))
}

fn normalize_device_timezone(value: String) -> Result<String, NutritionError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 64
        || !trimmed
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '_' | '-' | '.' | '+'))
    {
        return Err(NutritionError::Validation("invalid device_timezone".into()));
    }
    Ok(trimmed.to_string())
}

fn goal_snapshot_to_response(snapshot: GoalTargetSnapshot) -> GoalResponse {
    GoalResponse {
        requested_date: snapshot.requested_date,
        effective_from: snapshot.effective_from,
        source: match snapshot.source {
            GoalTargetSource::Default => GoalSourceDto::Default,
            GoalTargetSource::Saved => GoalSourceDto::Saved,
        },
        calorie_target: snapshot.targets.calorie_target,
        protein_target_g: snapshot.targets.protein_target_g,
        carbs_target_g: snapshot.targets.carbs_target_g,
        fat_target_g: snapshot.targets.fat_target_g,
    }
}

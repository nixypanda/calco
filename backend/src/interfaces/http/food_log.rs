use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::food_log::*;
use crate::domain::food_log::*;
use crate::interfaces::http::auth::{AppState, AuthUser};

pub fn food_log_routes(state: AppState) -> Router {
    Router::new()
        .route("/logs", post(create_log_handler).get(list_logs_handler))
        .route("/logs/{id}", get(get_log_handler).put(update_log_handler).delete(delete_log_handler))
        .route("/summary", get(summary_handler))
        .with_state(state)
}

#[derive(Deserialize)]
pub struct CreateLogRequest {
    pub logged_at: DateTime<Utc>,
    pub meal_slot: Option<String>,
    pub item: ItemRef,
    pub quantity: QuantityDto,
    pub notes: Option<String>,
}

#[derive(Deserialize)]
pub struct ItemRef {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: Uuid,
}

#[derive(Deserialize, Serialize)]
pub struct QuantityDto {
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize)]
pub struct LogResponse {
    pub id: Uuid,
    pub logged_at: DateTime<Utc>,
    pub meal_slot: Option<String>,
    pub item: ItemResponse,
    pub quantity: QuantityDto,
    pub nutrients: Vec<NutrientSnapshotDto>,
    pub notes: Option<String>,
}

#[derive(Serialize)]
pub struct ItemResponse {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: Uuid,
}

#[derive(Serialize)]
pub struct NutrientSnapshotDto {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize)]
pub struct LogListResponse {
    pub from: String,
    pub to: String,
    pub items: Vec<LogResponse>,
}

#[derive(Deserialize)]
pub struct LogQuery {
    pub from: String,
    pub to: String,
}

#[derive(Deserialize)]
pub struct UpdateLogRequest {
    pub logged_at: Option<DateTime<Utc>>,
    pub meal_slot: Option<Option<String>>,
    pub item: Option<ItemRef>,
    pub quantity: Option<QuantityDto>,
    pub notes: Option<Option<String>>,
}

#[derive(Deserialize)]
pub struct SummaryQuery {
    pub from: String,
    pub to: String,
    pub codes: Option<String>,
}

#[derive(Serialize)]
pub struct SummaryResponse {
    pub from: String,
    pub to: String,
    pub totals: Vec<SummaryEntryDto>,
}

#[derive(Serialize)]
pub struct SummaryEntryDto {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: ErrorBody,
}

#[derive(Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

fn error_response(code: &str, message: String) -> (StatusCode, Json<ErrorResponse>) {
    (
        match code {
            "not_found" => StatusCode::NOT_FOUND,
            "forbidden" => StatusCode::FORBIDDEN,
            "validation" => StatusCode::BAD_REQUEST,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        },
        Json(ErrorResponse {
            error: ErrorBody {
                code: code.to_string(),
                message,
            },
        }),
    )
}

fn internal_error<E: std::fmt::Display>(e: E) -> (StatusCode, Json<ErrorResponse>) {
    tracing::error!(error = %e, "food log request failed");
    error_response("internal", "internal server error".into())
}

fn log_to_response(log: &FoodLog) -> LogResponse {
    let (item_type, item_id) = match &log.item {
        LoggedItem::Product(pid) => ("product", pid.0),
        LoggedItem::Meal(mid) => ("meal", mid.0),
    };

    LogResponse {
        id: log.id.0,
        logged_at: log.logged_at,
        meal_slot: log.meal_slot.as_ref().map(|m| m.as_str().to_string()),
        item: ItemResponse {
            item_type: item_type.to_string(),
            id: item_id,
        },
        quantity: QuantityDto {
            amount: log.quantity_amount,
            unit: log.quantity_unit.0.clone(),
        },
        nutrients: log.nutrient_snapshots.iter().map(|ns| NutrientSnapshotDto {
            code: ns.nutrient_code.0.clone(),
            amount: ns.amount,
            unit: ns.unit.0.clone(),
        }).collect(),
        notes: log.notes.clone(),
    }
}

async fn create_log_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let input = LogFoodInput {
        user_id: auth.0.id,
        logged_at: req.logged_at,
        meal_slot: req.meal_slot,
        item_type: req.item.item_type,
        item_id: req.item.id,
        quantity_amount: req.quantity.amount,
        quantity_unit: req.quantity.unit,
        notes: req.notes,
    };

    let result = if input.item_type == "meal" {
        services.log_meal(input).await
    } else {
        services.log_food(input).await
    };

    match result {
        Ok(log) => {
            let resp = log_to_response(&log);
            (StatusCode::CREATED, Json(resp)).into_response()
        }
        Err(FoodLogError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(FoodLogError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn get_log_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    match services.get_food_log(FoodLogId(id)).await {
        Ok(log) => {
            if !log.is_owned_by(auth.0.id) {
                return error_response("forbidden", "not your food log".into()).into_response();
            }
            let resp = log_to_response(&log);
            Json(resp).into_response()
        }
        Err(FoodLogError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_logs_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<LogQuery>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let from = match chrono::NaiveDate::parse_from_str(&query.from, "%Y-%m-%d") {
        Ok(d) => d.and_hms_opt(0, 0, 0).unwrap().and_utc(),
        Err(_) => return error_response("validation", "invalid from date".into()).into_response(),
    };
    let to = match chrono::NaiveDate::parse_from_str(&query.to, "%Y-%m-%d") {
        Ok(d) => match d.succ_opt().and_then(|next| next.and_hms_opt(0, 0, 0)) {
            Some(dt) => dt.and_utc(),
            None => return error_response("validation", "invalid to date".into()).into_response(),
        },
        Err(_) => return error_response("validation", "invalid to date".into()).into_response(),
    };

    match services.get_logs_for_range(auth.0.id, from, to).await {
        Ok(logs) => {
            let items: Vec<LogResponse> = logs.iter().map(log_to_response).collect();
            Json(LogListResponse {
                from: query.from,
                to: query.to,
                items,
            }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn update_log_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let input = UpdateFoodInput {
        logged_at: req.logged_at,
        meal_slot: req.meal_slot,
        item_type: req.item.as_ref().map(|i| i.item_type.clone()),
        item_id: req.item.as_ref().map(|i| i.id),
        quantity_amount: req.quantity.as_ref().map(|q| q.amount),
        quantity_unit: req.quantity.as_ref().map(|q| q.unit.clone()),
        notes: req.notes,
    };

    match services.update_food_log(FoodLogId(id), auth.0.id, input).await {
        Ok(log) => {
            let resp = log_to_response(&log);
            Json(resp).into_response()
        }
        Err(FoodLogError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(FoodLogError::Forbidden(msg)) => error_response("forbidden", msg).into_response(),
        Err(FoodLogError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn delete_log_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    match services.delete_food_log(FoodLogId(id), auth.0.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(FoodLogError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(FoodLogError::Forbidden(msg)) => error_response("forbidden", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn summary_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<SummaryQuery>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let from = match chrono::NaiveDate::parse_from_str(&query.from, "%Y-%m-%d") {
        Ok(d) => d.and_hms_opt(0, 0, 0).unwrap().and_utc(),
        Err(_) => return error_response("validation", "invalid from date".into()).into_response(),
    };
    let to = match chrono::NaiveDate::parse_from_str(&query.to, "%Y-%m-%d") {
        Ok(d) => match d.succ_opt().and_then(|next| next.and_hms_opt(0, 0, 0)) {
            Some(dt) => dt.and_utc(),
            None => return error_response("validation", "invalid to date".into()).into_response(),
        },
        Err(_) => return error_response("validation", "invalid to date".into()).into_response(),
    };

    let codes = query.codes.map(|c| c.split(',').map(|s| s.trim().to_string()).collect());

    match services.get_summary(auth.0.id, from, to, codes).await {
        Ok(totals) => {
            Json(SummaryResponse {
                from: query.from,
                to: query.to,
                totals: totals.into_iter().map(|e| SummaryEntryDto {
                    code: e.code,
                    amount: e.amount,
                    unit: e.unit,
                }).collect(),
            }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

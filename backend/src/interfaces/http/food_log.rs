use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
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
        .route(
            "/logs/{id}",
            get(get_log_handler)
                .put(update_log_handler)
                .delete(delete_log_handler),
        )
        .route("/summary", get(summary_handler))
        .with_state(state)
}

#[derive(Deserialize)]
pub struct CreateLogRequest {
    pub logged_at: DateTime<Utc>,
    pub meal_slot: Option<String>,
    pub item: ItemRefDto,
    pub quantity: QuantityDto,
    pub notes: Option<String>,
}

#[derive(Deserialize)]
pub struct ItemRefDto {
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
    pub item: ItemDto,
    pub quantity: QuantityDto,
    pub nutrients: Vec<NutrientSnapshotDto>,
    pub notes: Option<String>,
}

#[derive(Serialize)]
pub struct ItemDto {
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
    pub item: Option<ItemRefDto>,
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

async fn create_log_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let input = food_log_create_request_to_input(req, auth.0.id);

    let result = if input.item_type == "meal" {
        services.log_meal(input).await
    } else {
        services.log_food(input).await
    };

    match result {
        Ok(log) => {
            let resp = food_log_to_response(&log);
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
    match state.food_log_repo.find_by_id(FoodLogId(id)).await {
        Ok(Some(log)) => {
            if !log.is_owned_by(auth.0.id) {
                return error_response("forbidden", "not your food log".into()).into_response();
            }
            let resp = food_log_to_response(&log);
            Json(resp).into_response()
        }
        Ok(None) => error_response("not_found", "food log not found".into()).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_logs_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<LogQuery>,
) -> impl IntoResponse {
    let range = match food_log_query_to_range_params(query) {
        Ok(range) => range,
        Err(response) => return response.into_response(),
    };

    match state
        .food_log_repo
        .list_by_user_and_range(auth.0.id, range.from_at, range.to_at)
        .await
    {
        Ok(logs) => Json(food_logs_to_list_response(range, logs)).into_response(),
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

    let input = food_log_update_request_to_input(req);

    match services
        .update_food_log(FoodLogId(id), auth.0.id, input)
        .await
    {
        Ok(log) => {
            let resp = food_log_to_response(&log);
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
    let args = match food_log_summary_query_to_params(query) {
        Ok(args) => args,
        Err(response) => return response.into_response(),
    };

    match state
        .food_log_repo
        .sum_nutrients_by_user_and_range(
            auth.0.id,
            args.range.from_at,
            args.range.to_at,
            args.codes,
        )
        .await
    {
        Ok(totals) => {
            Json(food_log_summary_entries_to_response(args.range, totals)).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

// ─── Conversions ───────────────────────────────────────────────

struct LogRangeParams {
    from: String,
    to: String,
    from_at: DateTime<Utc>,
    to_at: DateTime<Utc>,
}

struct SummaryParams {
    range: LogRangeParams,
    codes: Option<Vec<String>>,
}

fn food_log_create_request_to_input(req: CreateLogRequest, user_id: Uuid) -> LogFoodInput {
    LogFoodInput {
        user_id,
        logged_at: req.logged_at,
        meal_slot: req.meal_slot,
        item_type: req.item.item_type,
        item_id: req.item.id,
        quantity_amount: req.quantity.amount,
        quantity_unit: req.quantity.unit,
        notes: req.notes,
    }
}

fn food_log_update_request_to_input(req: UpdateLogRequest) -> UpdateFoodInput {
    UpdateFoodInput {
        logged_at: req.logged_at,
        meal_slot: req.meal_slot,
        item_type: req.item.as_ref().map(|i| i.item_type.clone()),
        item_id: req.item.as_ref().map(|i| i.id),
        quantity_amount: req.quantity.as_ref().map(|q| q.amount),
        quantity_unit: req.quantity.as_ref().map(|q| q.unit.clone()),
        notes: req.notes,
    }
}

fn food_log_query_to_range_params(
    query: LogQuery,
) -> Result<LogRangeParams, (StatusCode, Json<ErrorResponse>)> {
    query_dates_to_range(query.from, query.to)
}

fn food_log_summary_query_to_params(
    query: SummaryQuery,
) -> Result<SummaryParams, (StatusCode, Json<ErrorResponse>)> {
    let range = query_dates_to_range(query.from, query.to)?;
    Ok(SummaryParams {
        range,
        codes: query.codes.map(codes_string_to_list),
    })
}

fn query_dates_to_range(
    from: String,
    to: String,
) -> Result<LogRangeParams, (StatusCode, Json<ErrorResponse>)> {
    let from_at = match chrono::NaiveDate::parse_from_str(&from, "%Y-%m-%d") {
        Ok(date) => date.and_hms_opt(0, 0, 0).unwrap().and_utc(),
        Err(_) => return Err(error_response("validation", "invalid from date".into())),
    };
    let to_at = match chrono::NaiveDate::parse_from_str(&to, "%Y-%m-%d") {
        Ok(date) => match date.succ_opt().and_then(|next| next.and_hms_opt(0, 0, 0)) {
            Some(date_time) => date_time.and_utc(),
            None => return Err(error_response("validation", "invalid to date".into())),
        },
        Err(_) => return Err(error_response("validation", "invalid to date".into())),
    };

    Ok(LogRangeParams {
        from,
        to,
        from_at,
        to_at,
    })
}

fn codes_string_to_list(codes: String) -> Vec<String> {
    codes
        .split(',')
        .map(|code| code.trim().to_string())
        .collect()
}

fn food_logs_to_list_response(range: LogRangeParams, logs: Vec<FoodLog>) -> LogListResponse {
    LogListResponse {
        from: range.from,
        to: range.to,
        items: logs.iter().map(food_log_to_response).collect(),
    }
}

fn food_log_to_response(log: &FoodLog) -> LogResponse {
    let (item_type, item_id) = logged_item_to_parts(&log.item);

    LogResponse {
        id: log.id.0,
        logged_at: log.logged_at,
        meal_slot: log.meal_slot.as_ref().map(|m| m.as_str().to_string()),
        item: item_parts_to_dto(item_type, item_id),
        quantity: quantity_to_dto(log.quantity_amount, log.quantity_unit.0.clone()),
        nutrients: log
            .nutrient_snapshots
            .iter()
            .map(nutrient_snapshot_to_dto)
            .collect(),
        notes: log.notes.clone(),
    }
}

fn logged_item_to_parts(item: &LoggedItem) -> (&'static str, Uuid) {
    match item {
        LoggedItem::Product(pid) => ("product", pid.0),
        LoggedItem::Meal(mid) => ("meal", mid.0),
    }
}

fn item_parts_to_dto(item_type: &str, id: Uuid) -> ItemDto {
    ItemDto {
        item_type: item_type.to_string(),
        id,
    }
}

fn quantity_to_dto(amount: Decimal, unit: String) -> QuantityDto {
    QuantityDto { amount, unit }
}

fn nutrient_snapshot_to_dto(snapshot: &FoodLogNutrientSnapshot) -> NutrientSnapshotDto {
    NutrientSnapshotDto {
        code: snapshot.nutrient_code.0.clone(),
        amount: snapshot.amount,
        unit: snapshot.unit.0.clone(),
    }
}

fn food_log_summary_entries_to_response(
    range: LogRangeParams,
    entries: Vec<SummaryEntry>,
) -> SummaryResponse {
    SummaryResponse {
        from: range.from,
        to: range.to,
        totals: entries
            .into_iter()
            .map(food_log_summary_entry_to_dto)
            .collect(),
    }
}

fn food_log_summary_entry_to_dto(entry: SummaryEntry) -> SummaryEntryDto {
    SummaryEntryDto {
        code: entry.code,
        amount: entry.amount,
        unit: entry.unit,
    }
}

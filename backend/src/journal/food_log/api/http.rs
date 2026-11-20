use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Deserializer};
use serde_json::Value;
use uuid::Uuid;

use std::str::FromStr;

use crate::AppState;
use crate::auth::api::http::{AccountBoundReadUser, AccountBoundWriteUser};
use crate::catalog::domain::calculation::Quantity;
use crate::catalog::domain::{ProductId, UnitCode};
use crate::journal::error::JournalError;
use crate::journal::food_log::api::dto::{
    BatchLogResponse, LatestSlotsResponse, QuantityDto, RecentItemsResponse,
    food_log_day_summaries_to_response, food_log_to_response, food_logs_to_list_response,
    latest_slot_to_response, recent_item_to_response,
};
use crate::journal::food_log::app::*;
use crate::journal::food_log::domain::*;
use crate::journal::meal::domain::MealId;
use crate::journal::module::FoodLogModule;

pub fn food_log_routes(state: AppState) -> Router {
    Router::new()
        .route("/logs", post(create_log_handler).get(list_logs_handler))
        .route("/logs/ad-hoc", post(create_ad_hoc_log_handler))
        .route("/logs/batch", post(create_logs_batch_handler))
        .route("/logs/last-used", post(last_used_items_handler))
        .route("/logs/recent-items", get(recent_items_handler))
        .route("/logs/latest-slots", get(latest_slots_handler))
        .route("/logs/summary", get(summary_handler))
        .route(
            "/logs/{id}",
            get(get_log_handler)
                .put(update_log_handler)
                .delete(delete_log_handler),
        )
        .with_state(state)
}

#[derive(Deserialize)]
pub struct CreateLogRequest {
    pub log_date: String,
    pub meal_slot: Option<String>,
    pub device_timezone: Option<String>,
    pub item: ItemRefDto,
    pub quantity: QuantityDto,
    pub notes: Option<String>,
    pub idempotency_key: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateLogsBatchRequest {
    pub items: Vec<CreateLogsBatchItemRequest>,
}

#[derive(Deserialize)]
pub struct CreateLogsBatchItemRequest {
    pub log_date: String,
    pub meal_slot: Option<String>,
    pub device_timezone: Option<String>,
    pub item: ItemRefDto,
    pub quantity: QuantityDto,
    pub notes: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_value")]
    pub idempotency_key: Option<Value>,
}

#[derive(Deserialize)]
pub struct CreateAdHocLogRequest {
    pub log_date: String,
    pub meal_slot: Option<String>,
    pub device_timezone: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub quantity: QuantityDto,
    pub nutrients: Vec<NutrientSnapshotRequest>,
    pub notes: Option<String>,
}

#[derive(Deserialize)]
pub struct NutrientSnapshotRequest {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Deserialize)]
pub struct ItemRefDto {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: Uuid,
}

#[derive(Deserialize)]
pub struct LastUsedItemsRequest {
    pub from_date: String,
    pub to_date: String,
    pub meal_slot: Option<String>,
    pub items: Vec<ItemRefDto>,
}

#[derive(Deserialize)]
pub struct LogQuery {
    pub log_date: String,
}

#[derive(Deserialize)]
pub struct LatestSlotsQuery {
    pub before: String,
    pub lookback_days: Option<i64>,
}

#[derive(Deserialize)]
pub struct RecentItemsQuery {
    pub from_date: String,
    pub to_date: String,
    pub meal_slot: Option<String>,
}

#[derive(Deserialize)]
pub struct SummaryQuery {
    pub from_date: String,
    pub to_date: String,
}

#[derive(Deserialize)]
pub struct UpdateLogRequest {
    pub log_date: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_value")]
    pub meal_slot: Option<Value>,
    #[serde(default, deserialize_with = "deserialize_optional_value")]
    pub device_timezone: Option<Value>,
    pub item: Option<ItemRefDto>,
    pub quantity: Option<QuantityDto>,
    #[serde(default, deserialize_with = "deserialize_optional_value")]
    pub notes: Option<Value>,
}

use crate::journal::api::http::{ErrorResponse, error_response, internal_error};

async fn create_log_handler(
    auth: AccountBoundWriteUser,
    State(state): State<FoodLogModule>,
    Json(req): Json<CreateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let (input, idempotency_key) = match food_log_create_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services
        .log_item_idempotent(auth.0.id, input, idempotency_key)
        .await
    {
        Ok(created) => {
            let status = if created.replayed {
                StatusCode::OK
            } else {
                StatusCode::CREATED
            };
            (status, Json(food_log_to_response(&created.log))).into_response()
        }
        Err(e) => e.into_response(),
    }
}

async fn create_ad_hoc_log_handler(
    auth: AccountBoundWriteUser,
    State(state): State<FoodLogModule>,
    Json(req): Json<CreateAdHocLogRequest>,
) -> impl IntoResponse {
    let input = match ad_hoc_log_create_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match state
        .food_log_services
        .log_ad_hoc_food(auth.0.id, input)
        .await
    {
        Ok(log) => (StatusCode::CREATED, Json(food_log_to_response(&log))).into_response(),
        Err(err) => err.into_response(),
    }
}

async fn create_logs_batch_handler(
    auth: AccountBoundWriteUser,
    State(state): State<FoodLogModule>,
    Json(req): Json<CreateLogsBatchRequest>,
) -> impl IntoResponse {
    if req.items.is_empty() {
        return error_response("validation", "batch must contain at least one log".into())
            .into_response();
    }
    if req.items.len() > 50 {
        return error_response(
            "validation",
            "batch cannot contain more than 50 logs".into(),
        )
        .into_response();
    }

    let inputs = match req
        .items
        .into_iter()
        .map(batch_item_request_to_input)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(inputs) => inputs,
        Err(err) => return err.into_response(),
    };

    match state.food_log_services.log_items(auth.0.id, inputs).await {
        Ok(created) => (
            StatusCode::CREATED,
            Json(BatchLogResponse {
                items: created.iter().map(food_log_to_response).collect(),
            }),
        )
            .into_response(),
        Err(err) => err.into_response(),
    }
}

async fn latest_slots_handler(
    auth: AccountBoundReadUser,
    State(state): State<FoodLogModule>,
    Query(query): Query<LatestSlotsQuery>,
) -> impl IntoResponse {
    let before_date = match parse_log_date(&query.before) {
        Ok(date) => date,
        Err(err) => return err.into_response(),
    };
    let lookback_days = query.lookback_days.unwrap_or(30);

    match state
        .food_log_history_services
        .latest_slots_before(auth.0.id, before_date, lookback_days)
        .await
    {
        Ok(slots) => Json(LatestSlotsResponse {
            slots: slots.iter().map(latest_slot_to_response).collect(),
        })
        .into_response(),
        Err(err) => err.into_response(),
    }
}

async fn recent_items_handler(
    auth: AccountBoundReadUser,
    State(state): State<FoodLogModule>,
    Query(query): Query<RecentItemsQuery>,
) -> impl IntoResponse {
    let (from_date, to_date, meal_slot) =
        match parse_recent_item_scope(&query.from_date, &query.to_date, query.meal_slot.as_deref())
        {
            Ok(scope) => scope,
            Err(err) => return err.into_response(),
        };

    match state
        .food_log_history_services
        .list_recent_items(auth.0.id, from_date, to_date, meal_slot)
        .await
    {
        Ok(items) => Json(RecentItemsResponse {
            items: items.iter().map(recent_item_to_response).collect(),
        })
        .into_response(),
        Err(err) => err.into_response(),
    }
}

async fn summary_handler(
    auth: AccountBoundReadUser,
    State(state): State<FoodLogModule>,
    Query(query): Query<SummaryQuery>,
) -> impl IntoResponse {
    let from_date = match parse_log_date(&query.from_date) {
        Ok(date) => date,
        Err(err) => return err.into_response(),
    };
    let to_date = match parse_log_date(&query.to_date) {
        Ok(date) => date,
        Err(err) => return err.into_response(),
    };

    match state
        .food_log_history_services
        .summarize_by_date(auth.0.id, from_date, to_date)
        .await
    {
        Ok(days) => Json(food_log_day_summaries_to_response(days)).into_response(),
        Err(err) => err.into_response(),
    }
}

async fn last_used_items_handler(
    auth: AccountBoundReadUser,
    State(state): State<FoodLogModule>,
    Json(req): Json<LastUsedItemsRequest>,
) -> impl IntoResponse {
    let (from_date, to_date, meal_slot) =
        match parse_recent_item_scope(&req.from_date, &req.to_date, req.meal_slot.as_deref()) {
            Ok(scope) => scope,
            Err(err) => return err.into_response(),
        };
    let items = match req
        .items
        .iter()
        .map(parse_food_log_item_ref)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(items) => items,
        Err(err) => return err.into_response(),
    };

    match state
        .food_log_history_services
        .find_last_used_items(auth.0.id, from_date, to_date, meal_slot, &items)
        .await
    {
        Ok(items) => Json(RecentItemsResponse {
            items: items.iter().map(recent_item_to_response).collect(),
        })
        .into_response(),
        Err(err) => err.into_response(),
    }
}

async fn get_log_handler(
    auth: AccountBoundReadUser,
    State(state): State<FoodLogModule>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    match state
        .food_log_services
        .get_food_log(FoodLogId(id), auth.0.id)
        .await
    {
        Ok(log) => Json(food_log_to_response(&log)).into_response(),
        Err(e) => e.into_response(),
    }
}

async fn list_logs_handler(
    auth: AccountBoundReadUser,
    State(state): State<FoodLogModule>,
    Query(query): Query<LogQuery>,
) -> impl IntoResponse {
    let log_date = match food_log_query_to_date(query) {
        Ok(log_date) => log_date,
        Err(response) => return response.into_response(),
    };

    match state
        .food_log_services
        .list_food_logs(auth.0.id, log_date)
        .await
    {
        Ok(logs) => Json(food_logs_to_list_response(log_date, logs)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn update_log_handler(
    auth: AccountBoundWriteUser,
    State(state): State<FoodLogModule>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let input = match food_log_update_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services
        .update_food_log(FoodLogId(id), auth.0.id, input)
        .await
    {
        Ok(log) => {
            let resp = food_log_to_response(&log);
            Json(resp).into_response()
        }
        Err(e) => e.into_response(),
    }
}

async fn delete_log_handler(
    auth: AccountBoundWriteUser,
    State(state): State<FoodLogModule>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    match services.delete_food_log(FoodLogId(id), auth.0.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

// ─── Conversions ───────────────────────────────────────────────

fn parse_meal_slot(s: &str) -> Result<MealSlot, JournalError> {
    MealSlot::from_str(s).map_err(JournalError::Validation)
}

fn parse_food_log_item_ref(item: &ItemRefDto) -> Result<FoodLogItemRef, JournalError> {
    match item.item_type.as_str() {
        "product" => Ok(FoodLogItemRef::Product(ProductId(item.id))),
        "meal" => Ok(FoodLogItemRef::Meal(MealId(item.id))),
        other => Err(JournalError::Validation(format!(
            "unsupported item type: {other}"
        ))),
    }
}

fn parse_quantity(q: &QuantityDto) -> Result<Quantity, JournalError> {
    Quantity::new(q.amount, UnitCode(q.unit.clone())).map_err(JournalError::from)
}

fn parse_log_date(s: &str) -> Result<NaiveDate, JournalError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| JournalError::Validation("invalid log_date".into()))
}

fn parse_recent_item_scope(
    from_date: &str,
    to_date: &str,
    meal_slot: Option<&str>,
) -> Result<(NaiveDate, NaiveDate, Option<MealSlot>), JournalError> {
    let from_date = parse_log_date(from_date)?;
    let to_date = parse_log_date(to_date)?;
    let meal_slot = meal_slot.map(parse_meal_slot).transpose()?;
    Ok((from_date, to_date, meal_slot))
}

fn normalize_device_timezone(tz: Option<String>) -> Result<Option<String>, JournalError> {
    match tz {
        Some(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                return Ok(None);
            }
            if trimmed.len() > 64
                || !trimmed
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '_' | '-' | '.' | '+'))
            {
                return Err(JournalError::Validation("invalid device_timezone".into()));
            }
            Ok(Some(trimmed.to_string()))
        }
        None => Ok(None),
    }
}

fn parse_clearable_string(value: Value, field_name: &str) -> Result<Option<String>, JournalError> {
    match value {
        Value::Null => Ok(None),
        Value::String(s) => Ok(Some(s)),
        _ => Err(JournalError::Validation(format!("invalid {field_name}"))),
    }
}

fn deserialize_optional_value<'de, D>(deserializer: D) -> Result<Option<Value>, D::Error>
where
    D: Deserializer<'de>,
{
    Value::deserialize(deserializer).map(Some)
}

fn food_log_create_request_to_input(
    req: CreateLogRequest,
) -> Result<(LogFoodInput, Option<IdempotencyKey>), JournalError> {
    let idempotency_key = req.idempotency_key.map(IdempotencyKey::new).transpose()?;
    let input = create_log_input(
        req.log_date,
        req.meal_slot,
        req.device_timezone,
        req.item,
        req.quantity,
        req.notes,
    )?;
    Ok((input, idempotency_key))
}

fn batch_item_request_to_input(
    req: CreateLogsBatchItemRequest,
) -> Result<LogFoodInput, JournalError> {
    if req.idempotency_key.is_some() {
        return Err(JournalError::Validation(
            "idempotency_key is not supported for batch log creation".into(),
        ));
    }
    create_log_input(
        req.log_date,
        req.meal_slot,
        req.device_timezone,
        req.item,
        req.quantity,
        req.notes,
    )
}

fn create_log_input(
    log_date: String,
    meal_slot: Option<String>,
    device_timezone: Option<String>,
    item: ItemRefDto,
    quantity: QuantityDto,
    notes: Option<String>,
) -> Result<LogFoodInput, JournalError> {
    Ok(LogFoodInput {
        log_date: parse_log_date(&log_date)?,
        meal_slot: meal_slot.as_deref().map(parse_meal_slot).transpose()?,
        device_timezone: normalize_device_timezone(device_timezone)?,
        item: parse_food_log_item_ref(&item)?,
        quantity: parse_quantity(&quantity)?,
        notes,
    })
}

fn ad_hoc_log_create_request_to_input(
    req: CreateAdHocLogRequest,
) -> Result<LogAdHocFoodInput, JournalError> {
    Ok(LogAdHocFoodInput {
        log_date: parse_log_date(&req.log_date)?,
        meal_slot: req.meal_slot.as_deref().map(parse_meal_slot).transpose()?,
        device_timezone: normalize_device_timezone(req.device_timezone)?,
        name: req.name,
        brand: req.brand,
        quantity: parse_quantity(&req.quantity)?,
        nutrients: req
            .nutrients
            .into_iter()
            .map(|nutrient| FoodLogNutrientSnapshot {
                nutrient_code: crate::catalog::domain::NutrientCode(nutrient.code),
                amount: nutrient.amount,
                unit: UnitCode(nutrient.unit),
            })
            .collect(),
        notes: req.notes,
    })
}

fn food_log_update_request_to_input(
    req: UpdateLogRequest,
) -> Result<UpdateFoodInput, JournalError> {
    let meal_slot = match req.meal_slot {
        Some(value) => match parse_clearable_string(value, "meal_slot")? {
            Some(s) => Some(Some(parse_meal_slot(&s)?)),
            None => Some(None),
        },
        None => None,
    };
    let device_timezone = match req.device_timezone {
        Some(value) => Some(normalize_device_timezone(parse_clearable_string(
            value,
            "device_timezone",
        )?)?),
        None => None,
    };
    let notes = req
        .notes
        .map(|value| parse_clearable_string(value, "notes"))
        .transpose()?;
    let item = req.item.as_ref().map(parse_food_log_item_ref).transpose()?;
    let quantity = req.quantity.as_ref().map(parse_quantity).transpose()?;
    Ok(UpdateFoodInput {
        log_date: req.log_date.as_deref().map(parse_log_date).transpose()?,
        meal_slot,
        device_timezone,
        item,
        quantity,
        notes,
    })
}

fn food_log_query_to_date(query: LogQuery) -> Result<NaiveDate, (StatusCode, Json<ErrorResponse>)> {
    parse_log_date(&query.log_date)
        .map_err(|_| error_response("validation", "invalid log_date".into()))
}

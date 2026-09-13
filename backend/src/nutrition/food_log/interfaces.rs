use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
};
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use uuid::Uuid;

use std::str::FromStr;

use crate::AppState;
use crate::auth::interfaces::http::AuthUser;
use crate::nutrition::catalog::domain::calculation::Quantity;
use crate::nutrition::catalog::domain::{ProductId, UnitCode};
use crate::nutrition::error::NutritionError;
use crate::nutrition::food_log::application::*;
use crate::nutrition::food_log::domain::*;
use crate::nutrition::meal::domain::MealId;
use crate::nutrition::module::FoodLogModule;

pub fn food_log_routes(state: AppState) -> Router {
    Router::new()
        .route("/logs", post(create_log_handler).get(list_logs_handler))
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
}

#[derive(Deserialize)]
pub struct CreateLogsBatchRequest {
    pub items: Vec<CreateLogRequest>,
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
#[serde(rename_all = "snake_case")]
pub enum MealSlotDto {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
    LateNightSnack,
}

impl From<MealSlot> for MealSlotDto {
    fn from(slot: MealSlot) -> Self {
        match slot {
            MealSlot::Breakfast => MealSlotDto::Breakfast,
            MealSlot::Lunch => MealSlotDto::Lunch,
            MealSlot::Dinner => MealSlotDto::Dinner,
            MealSlot::Snack => MealSlotDto::Snack,
            MealSlot::LateNightSnack => MealSlotDto::LateNightSnack,
        }
    }
}

#[derive(Serialize)]
pub struct LogResponse {
    pub id: Uuid,
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlotDto>,
    pub device_timezone: Option<String>,
    pub item: ItemDto,
    pub quantity: QuantityDto,
    pub nutrients: Vec<NutrientSnapshotDto>,
    pub notes: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ItemDto {
    Product {
        id: Uuid,
        name: String,
        brand: Option<String>,
    },
    Meal {
        id: Uuid,
        name: String,
    },
}

#[derive(Serialize)]
pub struct NutrientSnapshotDto {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize)]
pub struct LogListResponse {
    pub log_date: NaiveDate,
    pub items: Vec<LogResponse>,
}

#[derive(Serialize)]
pub struct LatestSlotResponse {
    pub source_date: NaiveDate,
    pub meal_slot: MealSlotDto,
    pub items: Vec<LogResponse>,
}

#[derive(Serialize)]
pub struct LatestSlotsResponse {
    pub slots: Vec<LatestSlotResponse>,
}

#[derive(Serialize)]
pub struct RecentItemsResponse {
    pub items: Vec<RecentItemResponse>,
}

#[derive(Serialize)]
pub struct LogSummaryResponse {
    pub days: Vec<LogDaySummaryResponse>,
}

#[derive(Serialize)]
pub struct LogDaySummaryResponse {
    pub date: NaiveDate,
    pub energy_kcal: Decimal,
    pub protein_g: Decimal,
    pub carbs_g: Decimal,
    pub fat_g: Decimal,
}

#[derive(Serialize)]
pub struct RecentItemResponse {
    pub item: ItemDto,
    pub last_used_date: NaiveDate,
    pub meal_slot: Option<MealSlotDto>,
    pub quantity: QuantityDto,
    pub nutrition_summary: NutrientSummaryDto,
    pub top_quantities: Vec<QuantityUsageDto>,
}

#[derive(Serialize)]
pub struct QuantityUsageDto {
    pub quantity: QuantityDto,
    pub log_count: u32,
}

#[derive(Deserialize)]
pub struct LastUsedItemsRequest {
    pub from_date: String,
    pub to_date: String,
    pub meal_slot: Option<String>,
    pub items: Vec<ItemRefDto>,
}

#[derive(Serialize)]
pub struct BatchLogResponse {
    pub items: Vec<LogResponse>,
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

use crate::nutrition::interfaces::{
    ErrorResponse, NutrientSummaryDto, error_response, internal_error, is_summary_nutrient_code,
    nutrient_summary_from_entries,
};

async fn create_log_handler(
    auth: AuthUser,
    State(state): State<FoodLogModule>,
    Json(req): Json<CreateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let input = match food_log_create_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services.log_item(auth.0.id, input).await {
        Ok(log) => {
            let resp = food_log_to_response(&log);
            (StatusCode::CREATED, Json(resp)).into_response()
        }
        Err(e) => e.into_response(),
    }
}

async fn create_logs_batch_handler(
    auth: AuthUser,
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
        .map(food_log_create_request_to_input)
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
    auth: AuthUser,
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
    auth: AuthUser,
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
    auth: AuthUser,
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
        Ok(days) => Json(LogSummaryResponse {
            days: days
                .into_iter()
                .map(|summary| LogDaySummaryResponse {
                    date: summary.log_date,
                    energy_kcal: summary.energy_kcal,
                    protein_g: summary.protein_g,
                    carbs_g: summary.carbs_g,
                    fat_g: summary.fat_g,
                })
                .collect(),
        })
        .into_response(),
        Err(err) => err.into_response(),
    }
}

async fn last_used_items_handler(
    auth: AuthUser,
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
    auth: AuthUser,
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
    auth: AuthUser,
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
    auth: AuthUser,
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
    auth: AuthUser,
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

fn parse_meal_slot(s: &str) -> Result<MealSlot, NutritionError> {
    MealSlot::from_str(s).map_err(NutritionError::Validation)
}

fn parse_food_log_item_ref(item: &ItemRefDto) -> Result<FoodLogItemRef, NutritionError> {
    match item.item_type.as_str() {
        "product" => Ok(FoodLogItemRef::Product(ProductId(item.id))),
        "meal" => Ok(FoodLogItemRef::Meal(MealId(item.id))),
        other => Err(NutritionError::Validation(format!(
            "unsupported item type: {other}"
        ))),
    }
}

fn parse_quantity(q: &QuantityDto) -> Result<Quantity, NutritionError> {
    Quantity::new(q.amount, UnitCode(q.unit.clone()))
}

fn parse_log_date(s: &str) -> Result<NaiveDate, NutritionError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| NutritionError::Validation("invalid log_date".into()))
}

fn parse_recent_item_scope(
    from_date: &str,
    to_date: &str,
    meal_slot: Option<&str>,
) -> Result<(NaiveDate, NaiveDate, Option<MealSlot>), NutritionError> {
    let from_date = parse_log_date(from_date)?;
    let to_date = parse_log_date(to_date)?;
    let meal_slot = meal_slot.map(parse_meal_slot).transpose()?;
    Ok((from_date, to_date, meal_slot))
}

fn normalize_device_timezone(tz: Option<String>) -> Result<Option<String>, NutritionError> {
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
                return Err(NutritionError::Validation("invalid device_timezone".into()));
            }
            Ok(Some(trimmed.to_string()))
        }
        None => Ok(None),
    }
}

fn parse_clearable_string(
    value: Value,
    field_name: &str,
) -> Result<Option<String>, NutritionError> {
    match value {
        Value::Null => Ok(None),
        Value::String(s) => Ok(Some(s)),
        _ => Err(NutritionError::Validation(format!("invalid {field_name}"))),
    }
}

fn deserialize_optional_value<'de, D>(deserializer: D) -> Result<Option<Value>, D::Error>
where
    D: Deserializer<'de>,
{
    Value::deserialize(deserializer).map(Some)
}

fn food_log_create_request_to_input(req: CreateLogRequest) -> Result<LogFoodInput, NutritionError> {
    let log_date = parse_log_date(&req.log_date)?;
    let meal_slot = req.meal_slot.as_deref().map(parse_meal_slot).transpose()?;
    let device_timezone = normalize_device_timezone(req.device_timezone)?;
    let item = parse_food_log_item_ref(&req.item)?;
    let quantity = parse_quantity(&req.quantity)?;
    Ok(LogFoodInput {
        log_date,
        meal_slot,
        device_timezone,
        item,
        quantity,
        notes: req.notes,
    })
}

fn food_log_update_request_to_input(
    req: UpdateLogRequest,
) -> Result<UpdateFoodInput, NutritionError> {
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

fn food_logs_to_list_response(log_date: NaiveDate, logs: Vec<FoodLog>) -> LogListResponse {
    LogListResponse {
        log_date,
        items: logs.iter().map(food_log_to_response).collect(),
    }
}

fn food_log_to_response(log: &FoodLog) -> LogResponse {
    LogResponse {
        id: log.id().0,
        log_date: log.log_date(),
        meal_slot: log.meal_slot().map(Into::into),
        device_timezone: log.device_timezone().map(str::to_owned),
        item: item_to_dto(log.item()),
        quantity: quantity_to_dto(log.quantity_amount(), log.quantity_unit().0.clone()),
        nutrients: log
            .nutrient_snapshots()
            .iter()
            .filter(|snapshot| is_summary_nutrient_code(&snapshot.nutrient_code.0))
            .map(nutrient_snapshot_to_dto)
            .collect(),
        notes: log.notes().map(str::to_owned),
        created_at: log.created_at(),
        updated_at: log.updated_at(),
    }
}

fn latest_slot_to_response(slot: &LatestSlotLogs) -> LatestSlotResponse {
    LatestSlotResponse {
        source_date: slot.source_date,
        meal_slot: slot.meal_slot.into(),
        items: slot.logs.iter().map(food_log_to_response).collect(),
    }
}

fn recent_item_to_response(item: &RecentFoodLogItem) -> RecentItemResponse {
    RecentItemResponse {
        item: item_to_dto(&item.item),
        last_used_date: item.log_date,
        meal_slot: item.meal_slot.map(Into::into),
        quantity: quantity_to_dto(item.quantity_amount, item.quantity_unit.0.clone()),
        nutrition_summary: nutrient_summary_from_entries(
            item.nutrient_snapshots
                .iter()
                .map(|snapshot| (snapshot.nutrient_code.0.clone(), snapshot.amount)),
        ),
        top_quantities: item
            .top_quantities
            .iter()
            .map(quantity_usage_to_dto)
            .collect(),
    }
}

fn quantity_usage_to_dto(usage: &QuantityUsage) -> QuantityUsageDto {
    QuantityUsageDto {
        quantity: quantity_to_dto(usage.amount, usage.unit.0.clone()),
        log_count: usage.log_count,
    }
}

fn item_to_dto(item: &FoodLogItemSnapshot) -> ItemDto {
    match item {
        FoodLogItemSnapshot::Product { id, name, brand } => ItemDto::Product {
            id: id.0,
            name: name.clone(),
            brand: brand.clone(),
        },
        FoodLogItemSnapshot::Meal { id, name } => ItemDto::Meal {
            id: id.0,
            name: name.clone(),
        },
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

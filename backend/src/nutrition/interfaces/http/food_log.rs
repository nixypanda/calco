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
use crate::nutrition::application::food_log::*;
use crate::nutrition::domain::calculation::Quantity;
use crate::nutrition::domain::catalog::{ProductId, UnitCode};
use crate::nutrition::domain::error::NutritionError;
use crate::nutrition::domain::food_log::*;
use crate::nutrition::domain::meal::MealId;

pub fn food_log_routes(state: AppState) -> Router {
    Router::new()
        .route("/logs", post(create_log_handler).get(list_logs_handler))
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
}

impl From<MealSlot> for MealSlotDto {
    fn from(slot: MealSlot) -> Self {
        match slot {
            MealSlot::Breakfast => MealSlotDto::Breakfast,
            MealSlot::Lunch => MealSlotDto::Lunch,
            MealSlot::Dinner => MealSlotDto::Dinner,
            MealSlot::Snack => MealSlotDto::Snack,
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
    pub nutrition_summary: NutrientSummaryDto,
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

#[derive(Deserialize)]
pub struct LogQuery {
    pub log_date: String,
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

use crate::nutrition::interfaces::http::{
    ErrorResponse, NutrientSummaryDto, error_response, internal_error, is_summary_nutrient_code,
    nutrient_summary_from_entries,
};

async fn create_log_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateLogRequest>,
) -> impl IntoResponse {
    let services = &state.food_log_services;

    let input = match food_log_create_request_to_input(req, auth.0.id) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services.log_item(input).await {
        Ok(log) => {
            let resp = food_log_to_response(&log);
            (StatusCode::CREATED, Json(resp)).into_response()
        }
        Err(e) => e.into_response(),
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
    let log_date = match food_log_query_to_date(query) {
        Ok(log_date) => log_date,
        Err(response) => return response.into_response(),
    };

    match state
        .food_log_repo
        .list_by_user_and_date(auth.0.id, log_date)
        .await
    {
        Ok(logs) => Json(food_logs_to_list_response(log_date, logs)).into_response(),
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
    State(state): State<AppState>,
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

fn food_log_create_request_to_input(
    req: CreateLogRequest,
    user_id: Uuid,
) -> Result<LogFoodInput, NutritionError> {
    let log_date = parse_log_date(&req.log_date)?;
    let meal_slot = req.meal_slot.as_deref().map(parse_meal_slot).transpose()?;
    let device_timezone = normalize_device_timezone(req.device_timezone)?;
    let item = parse_food_log_item_ref(&req.item)?;
    let quantity = parse_quantity(&req.quantity)?;
    Ok(LogFoodInput {
        user_id,
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
        id: log.id.0,
        log_date: log.log_date,
        meal_slot: log.meal_slot.map(Into::into),
        device_timezone: log.device_timezone.clone(),
        item: item_to_dto(&log.item),
        quantity: quantity_to_dto(log.quantity_amount, log.quantity_unit.0.clone()),
        nutrition_summary: food_log_nutrition_summary(log),
        nutrients: log
            .nutrient_snapshots
            .iter()
            .filter(|snapshot| is_summary_nutrient_code(&snapshot.nutrient_code.0))
            .map(nutrient_snapshot_to_dto)
            .collect(),
        notes: log.notes.clone(),
        created_at: log.created_at,
        updated_at: log.updated_at,
    }
}

fn food_log_nutrition_summary(log: &FoodLog) -> NutrientSummaryDto {
    nutrient_summary_from_entries(
        log.nutrient_snapshots
            .iter()
            .map(|snapshot| (snapshot.nutrient_code.0.clone(), snapshot.amount)),
    )
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

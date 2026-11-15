use chrono::NaiveDate;
use rust_decimal::Decimal;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::journal::api::http::is_summary_nutrient_code;
use crate::journal::error::JournalError;
use crate::journal::food_log::app::FoodLogDaySummary;
use crate::journal::food_log::domain::{
    FoodLog, FoodLogItemSnapshot, FoodLogNutrientSnapshot, MealSlot,
};

#[derive(Serialize, JsonSchema)]
pub struct LogSummaryResponse {
    pub days: Vec<LogDaySummaryResponse>,
}

#[derive(Serialize, JsonSchema)]
pub struct LogDaySummaryResponse {
    pub date: NaiveDate,
    pub energy_kcal: Decimal,
    pub protein_g: Decimal,
    pub carbs_g: Decimal,
    pub fat_g: Decimal,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct QuantityDto {
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize, JsonSchema)]
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

#[derive(Serialize, JsonSchema)]
pub struct LogResponse {
    pub id: Uuid,
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlotDto>,
    pub device_timezone: Option<String>,
    pub item: ItemDto,
    pub quantity: QuantityDto,
    pub nutrients: Vec<NutrientSnapshotDto>,
    pub notes: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize, JsonSchema)]
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
    AdHoc {
        name: String,
        brand: Option<String>,
    },
}

#[derive(Serialize, JsonSchema)]
pub struct NutrientSnapshotDto {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize, JsonSchema)]
pub struct LogListResponse {
    pub log_date: NaiveDate,
    pub items: Vec<LogResponse>,
}

pub(crate) fn food_log_day_summaries_to_response(
    summaries: Vec<FoodLogDaySummary>,
) -> LogSummaryResponse {
    LogSummaryResponse {
        days: summaries
            .into_iter()
            .map(food_log_day_summary_to_dto)
            .collect(),
    }
}

pub(crate) fn food_logs_to_list_response(
    log_date: NaiveDate,
    logs: Vec<FoodLog>,
) -> LogListResponse {
    LogListResponse {
        log_date,
        items: logs.iter().map(food_log_to_response).collect(),
    }
}

pub(crate) fn food_log_to_response(log: &FoodLog) -> LogResponse {
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

pub(crate) fn normalize_device_timezone(
    tz: Option<String>,
) -> Result<Option<String>, JournalError> {
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

pub(crate) fn item_to_dto(item: &FoodLogItemSnapshot) -> ItemDto {
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
        FoodLogItemSnapshot::AdHoc { name, brand } => ItemDto::AdHoc {
            name: name.clone(),
            brand: brand.clone(),
        },
    }
}

pub(crate) fn quantity_to_dto(amount: Decimal, unit: String) -> QuantityDto {
    QuantityDto { amount, unit }
}

fn nutrient_snapshot_to_dto(snapshot: &FoodLogNutrientSnapshot) -> NutrientSnapshotDto {
    NutrientSnapshotDto {
        code: snapshot.nutrient_code.0.clone(),
        amount: snapshot.amount,
        unit: snapshot.unit.0.clone(),
    }
}

fn food_log_day_summary_to_dto(summary: FoodLogDaySummary) -> LogDaySummaryResponse {
    LogDaySummaryResponse {
        date: summary.log_date,
        energy_kcal: summary.energy_kcal,
        protein_g: summary.protein_g,
        carbs_g: summary.carbs_g,
        fat_g: summary.fat_g,
    }
}

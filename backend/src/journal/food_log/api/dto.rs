use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::catalog::api::shared::{
    NutrientSummaryDto, is_summary_nutrient_code, nutrient_summary_from_entries,
};
use crate::journal::food_log::app::{FoodLogDaySummary, LatestSlotLogs};
use crate::journal::food_log::domain::{
    FoodLog, FoodLogItemSnapshot, FoodLogNutrientSnapshot, MealSlot, QuantityUsage,
    RecentFoodLogItem,
};

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
    AdHoc {
        name: String,
        brand: Option<String>,
    },
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

#[derive(Serialize)]
pub struct BatchLogResponse {
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

pub(crate) fn latest_slot_to_response(slot: &LatestSlotLogs) -> LatestSlotResponse {
    LatestSlotResponse {
        source_date: slot.source_date,
        meal_slot: slot.meal_slot.into(),
        items: slot.logs.iter().map(food_log_to_response).collect(),
    }
}

pub(crate) fn recent_item_to_response(item: &RecentFoodLogItem) -> RecentItemResponse {
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
        FoodLogItemSnapshot::AdHoc { name, brand } => ItemDto::AdHoc {
            name: name.clone(),
            brand: brand.clone(),
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

fn food_log_day_summary_to_dto(summary: FoodLogDaySummary) -> LogDaySummaryResponse {
    LogDaySummaryResponse {
        date: summary.log_date,
        energy_kcal: summary.energy_kcal,
        protein_g: summary.protein_g,
        carbs_g: summary.carbs_g,
        fat_g: summary.fat_g,
    }
}

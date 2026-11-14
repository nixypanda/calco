use chrono::NaiveDate;
use rust_decimal::Decimal;
use schemars::JsonSchema;
use serde::Serialize;

use crate::journal::food_log::app::FoodLogDaySummary;

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

fn food_log_day_summary_to_dto(summary: FoodLogDaySummary) -> LogDaySummaryResponse {
    LogDaySummaryResponse {
        date: summary.log_date,
        energy_kcal: summary.energy_kcal,
        protein_g: summary.protein_g,
        carbs_g: summary.carbs_g,
        fat_g: summary.fat_g,
    }
}

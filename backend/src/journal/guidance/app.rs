use std::sync::Arc;

use chrono::NaiveDate;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::journal::error::JournalError;
use crate::journal::food_log::app::FoodLogQueryPort;
use crate::journal::food_log::domain::{FoodLog, FoodLogItemSnapshot};
use crate::journal::guidance::domain::{
    NutrientGuidance, NutrientGuidanceKind, NutrientGuidanceRepo, NutrientGuidanceSet,
};

#[derive(Clone)]
pub struct NutritionDetailsService {
    food_logs: Arc<dyn FoodLogQueryPort>,
    nutrient_guidance_repo: Arc<dyn NutrientGuidanceRepo>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NutrientCoverage {
    None,
    Partial,
    Complete,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NutritionDetailsStatus {
    NoData,
    PartialData,
    Available,
    BelowReference,
    MetReference,
    WithinLimit,
    OverLimit,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NutritionDetailsEntry {
    pub guidance: NutrientGuidance,
    pub known_amount: Option<Decimal>,
    pub items_with_data: usize,
    pub coverage: NutrientCoverage,
    pub status: NutritionDetailsStatus,
}
#[derive(Debug, Clone, PartialEq)]
pub struct NutritionDetails {
    pub date: NaiveDate,
    pub guidance_set: NutrientGuidanceSet,
    pub logged_items: usize,
    pub nutrients: Vec<NutritionDetailsEntry>,
}

impl NutritionDetailsService {
    pub fn new(
        food_logs: Arc<dyn FoodLogQueryPort>,
        nutrient_guidance_repo: Arc<dyn NutrientGuidanceRepo>,
    ) -> Self {
        Self {
            food_logs,
            nutrient_guidance_repo,
        }
    }
    pub async fn get_for_date(
        &self,
        actor_id: Uuid,
        date: NaiveDate,
    ) -> Result<NutritionDetails, JournalError> {
        let logs = self.food_logs.list_logs_for_date(actor_id, date).await?;
        Ok(nutrition_details_from_logs(
            date,
            self.nutrient_guidance_repo.current(),
            logs,
        ))
    }
}

pub fn nutrition_details_from_logs(
    date: NaiveDate,
    guidance_set: NutrientGuidanceSet,
    logs: Vec<FoodLog>,
) -> NutritionDetails {
    let logged_items = logs.len();
    let nutrients = guidance_set
        .guidance()
        .iter()
        .map(|guidance| detail_entry_from_logs(guidance, &logs))
        .collect();
    NutritionDetails {
        date,
        guidance_set,
        logged_items,
        nutrients,
    }
}

fn detail_entry_from_logs(guidance: &NutrientGuidance, logs: &[FoodLog]) -> NutritionDetailsEntry {
    let mut amount = Decimal::ZERO;
    let mut items_with_data = 0;
    for log in logs {
        let mut item_has_data = false;
        for snapshot in log.nutrient_snapshots() {
            if snapshot.nutrient_code == *guidance.nutrient_code()
                && snapshot.unit == *guidance.unit()
            {
                amount += snapshot.amount;
                item_has_data = true;
            }
        }
        if item_has_data {
            items_with_data += 1;
        }
    }
    let has_meal_log = logs
        .iter()
        .any(|log| matches!(log.item(), FoodLogItemSnapshot::Meal { .. }));
    let coverage = match (logs.len(), items_with_data, has_meal_log) {
        (_, 0, _) => NutrientCoverage::None,
        (count, items, false) if count == items => NutrientCoverage::Complete,
        _ => NutrientCoverage::Partial,
    };
    let known_amount = (items_with_data > 0).then_some(amount);
    let status = status_for(guidance, known_amount, coverage);
    NutritionDetailsEntry {
        guidance: guidance.clone(),
        known_amount,
        items_with_data,
        coverage,
        status,
    }
}

fn status_for(
    guidance: &NutrientGuidance,
    known_amount: Option<Decimal>,
    coverage: NutrientCoverage,
) -> NutritionDetailsStatus {
    let Some(amount) = known_amount else {
        return NutritionDetailsStatus::NoData;
    };
    match guidance.kind() {
        NutrientGuidanceKind::Informational if coverage == NutrientCoverage::Complete => {
            NutritionDetailsStatus::Available
        }
        NutrientGuidanceKind::Informational => NutritionDetailsStatus::PartialData,
        NutrientGuidanceKind::Adequacy
            if amount >= guidance.reference_amount().expect("validated guidance") =>
        {
            NutritionDetailsStatus::MetReference
        }
        NutrientGuidanceKind::Adequacy if coverage == NutrientCoverage::Partial => {
            NutritionDetailsStatus::PartialData
        }
        NutrientGuidanceKind::Adequacy => NutritionDetailsStatus::BelowReference,
        NutrientGuidanceKind::Maximum
            if amount > guidance.reference_amount().expect("validated guidance") =>
        {
            NutritionDetailsStatus::OverLimit
        }
        NutrientGuidanceKind::Maximum if coverage == NutrientCoverage::Partial => {
            NutritionDetailsStatus::PartialData
        }
        NutrientGuidanceKind::Maximum => NutritionDetailsStatus::WithinLimit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::domain::{NutrientCode, ProductId, UnitCode};
    use crate::journal::food_log::domain::{
        FoodLogId, FoodLogItemSnapshot, FoodLogNutrientSnapshot,
    };
    use crate::journal::guidance::infra::StaticGuidanceRepo;
    use crate::journal::meal::domain::MealId;
    use chrono::Utc;

    fn date() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 8, 14).unwrap()
    }
    fn log(snapshots: Vec<(&str, Decimal, &str)>) -> FoodLog {
        log_with(
            Uuid::new_v4(),
            FoodLogItemSnapshot::Product {
                id: ProductId::new(),
                name: "Test food".into(),
                brand: None,
            },
            snapshots,
        )
    }

    fn log_with(
        user_id: Uuid,
        item: FoodLogItemSnapshot,
        snapshots: Vec<(&str, Decimal, &str)>,
    ) -> FoodLog {
        let now = Utc::now();
        FoodLog::restore(
            FoodLogId::new(),
            user_id,
            date(),
            None,
            None,
            item,
            Decimal::ONE,
            UnitCode("g".into()),
            snapshots
                .into_iter()
                .map(|(code, amount, unit)| FoodLogNutrientSnapshot {
                    nutrient_code: NutrientCode(code.into()),
                    amount,
                    unit: UnitCode(unit.into()),
                })
                .collect(),
            None,
            now,
            now,
        )
    }
    fn set() -> NutrientGuidanceSet {
        StaticGuidanceRepo::new().current()
    }
    fn entry<'a>(report: &'a NutritionDetails, code: &str) -> &'a NutritionDetailsEntry {
        report
            .nutrients
            .iter()
            .find(|entry| entry.guidance.nutrient_code().0 == code)
            .unwrap()
    }

    #[test]
    fn complete_informational_data_is_available_and_explicit_zero_is_data() {
        let report = nutrition_details_from_logs(
            date(),
            set(),
            vec![log(vec![("SUGAR_G", Decimal::ZERO, "g")])],
        );
        let sugar = entry(&report, "SUGAR_G");
        assert_eq!(sugar.known_amount, Some(Decimal::ZERO));
        assert_eq!(sugar.coverage, NutrientCoverage::Complete);
        assert_eq!(sugar.status, NutritionDetailsStatus::Available);
    }

    #[test]
    fn no_snapshots_report_no_data() {
        let report = nutrition_details_from_logs(date(), set(), vec![log(vec![])]);

        let energy = entry(&report, "ENERGY_KCAL");
        assert_eq!(energy.known_amount, None);
        assert_eq!(energy.coverage, NutrientCoverage::None);
        assert_eq!(energy.status, NutritionDetailsStatus::NoData);
    }

    #[test]
    fn informational_nutrient_with_partial_items_is_partial_data() {
        let report = nutrition_details_from_logs(
            date(),
            set(),
            vec![log(vec![("SUGAR_G", Decimal::from(5), "g")]), log(vec![])],
        );

        let sugar = entry(&report, "SUGAR_G");
        assert_eq!(sugar.known_amount, Some(Decimal::from(5)));
        assert_eq!(sugar.coverage, NutrientCoverage::Partial);
        assert_eq!(sugar.status, NutritionDetailsStatus::PartialData);
    }

    #[test]
    fn adequacy_status_tracks_reference_threshold_with_complete_coverage() {
        let below = nutrition_details_from_logs(
            date(),
            set(),
            vec![log(vec![("FIBER_G", Decimal::from(27), "g")])],
        );
        let fiber = entry(&below, "FIBER_G");
        assert_eq!(fiber.coverage, NutrientCoverage::Complete);
        assert_eq!(fiber.status, NutritionDetailsStatus::BelowReference);

        for amount in [Decimal::from(28), Decimal::from(30)] {
            let report = nutrition_details_from_logs(
                date(),
                set(),
                vec![log(vec![("FIBER_G", amount, "g")])],
            );
            assert_eq!(
                entry(&report, "FIBER_G").status,
                NutritionDetailsStatus::MetReference
            );
        }
    }

    #[test]
    fn adequacy_partial_coverage_status_tracks_amount_threshold() {
        let below = nutrition_details_from_logs(
            date(),
            set(),
            vec![log(vec![("FIBER_G", Decimal::from(10), "g")]), log(vec![])],
        );

        let fiber = entry(&below, "FIBER_G");
        assert_eq!(fiber.known_amount, Some(Decimal::from(10)));
        assert_eq!(fiber.coverage, NutrientCoverage::Partial);
        assert_eq!(fiber.status, NutritionDetailsStatus::PartialData);

        let at_reference = nutrition_details_from_logs(
            date(),
            set(),
            vec![log(vec![("FIBER_G", Decimal::from(28), "g")]), log(vec![])],
        );

        let fiber = entry(&at_reference, "FIBER_G");
        assert_eq!(fiber.coverage, NutrientCoverage::Partial);
        assert_eq!(fiber.status, NutritionDetailsStatus::MetReference);
    }

    #[test]
    fn maximum_status_tracks_reference_threshold_with_complete_coverage() {
        let over = nutrition_details_from_logs(
            date(),
            set(),
            vec![log(vec![("SODIUM_MG", Decimal::from(2301), "mg")])],
        );
        let sodium = entry(&over, "SODIUM_MG");
        assert_eq!(sodium.coverage, NutrientCoverage::Complete);
        assert_eq!(sodium.status, NutritionDetailsStatus::OverLimit);

        for amount in [Decimal::from(2300), Decimal::from(1000)] {
            let report = nutrition_details_from_logs(
                date(),
                set(),
                vec![log(vec![("SODIUM_MG", amount, "mg")])],
            );
            assert_eq!(
                entry(&report, "SODIUM_MG").status,
                NutritionDetailsStatus::WithinLimit
            );
        }
    }

    #[test]
    fn maximum_partial_coverage_status_tracks_amount_threshold() {
        let report = nutrition_details_from_logs(
            date(),
            set(),
            vec![
                log(vec![("SODIUM_MG", Decimal::from(1000), "mg")]),
                log(vec![]),
            ],
        );

        let sodium = entry(&report, "SODIUM_MG");
        assert_eq!(sodium.known_amount, Some(Decimal::from(1000)));
        assert_eq!(sodium.coverage, NutrientCoverage::Partial);
        assert_eq!(sodium.status, NutritionDetailsStatus::PartialData);

        let over = nutrition_details_from_logs(
            date(),
            set(),
            vec![
                log(vec![("SODIUM_MG", Decimal::from(2301), "mg")]),
                log(vec![]),
            ],
        );

        let sodium = entry(&over, "SODIUM_MG");
        assert_eq!(sodium.coverage, NutrientCoverage::Partial);
        assert_eq!(sodium.status, NutritionDetailsStatus::OverLimit);
    }

    #[test]
    fn meal_log_with_complete_item_data_is_still_partial_coverage() {
        let meal_log = log_with(
            Uuid::new_v4(),
            FoodLogItemSnapshot::Meal {
                id: MealId::new(),
                name: "Test meal".into(),
            },
            vec![("SUGAR_G", Decimal::from(5), "g")],
        );
        let report = nutrition_details_from_logs(date(), set(), vec![meal_log]);

        let sugar = entry(&report, "SUGAR_G");
        assert_eq!(sugar.known_amount, Some(Decimal::from(5)));
        assert_eq!(sugar.coverage, NutrientCoverage::Partial);
        assert_eq!(sugar.status, NutritionDetailsStatus::PartialData);
    }
}

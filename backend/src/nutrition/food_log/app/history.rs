use chrono::{Duration, NaiveDate};
use rust_decimal::Decimal;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;

use crate::nutrition::food_log::domain::*;

const MAX_HISTORY_RANGE_DAYS: i64 = 366;
const MAX_TOP_QUANTITIES: usize = 5;

fn ensure_within_max_range(from_date: NaiveDate, to_date: NaiveDate) -> Result<(), NutritionError> {
    if to_date.signed_duration_since(from_date).num_days() > MAX_HISTORY_RANGE_DAYS {
        return Err(NutritionError::Validation(format!(
            "date range cannot exceed {MAX_HISTORY_RANGE_DAYS} days"
        )));
    }
    Ok(())
}

#[derive(Clone)]
pub struct FoodLogHistoryService {
    food_log_repo: Arc<dyn FoodLogRepo>,
}

#[derive(Debug, Clone)]
pub struct LatestSlotLogs {
    pub meal_slot: MealSlot,
    pub source_date: NaiveDate,
    pub logs: Vec<FoodLog>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoodLogDaySummary {
    pub log_date: NaiveDate,
    pub energy_kcal: Decimal,
    pub protein_g: Decimal,
    pub carbs_g: Decimal,
    pub fat_g: Decimal,
}

impl FoodLogHistoryService {
    pub fn new(food_log_repo: Arc<dyn FoodLogRepo>) -> Self {
        Self { food_log_repo }
    }

    pub async fn latest_slots_before(
        &self,
        user_id: Uuid,
        before_date: NaiveDate,
        lookback_days: i64,
    ) -> Result<Vec<LatestSlotLogs>, NutritionError> {
        if !(1..=90).contains(&lookback_days) {
            return Err(NutritionError::Validation(
                "lookback_days must be between 1 and 90".into(),
            ));
        }

        let date_range = DateRange::inclusive_to_exclusive(
            before_date - Duration::days(lookback_days),
            before_date,
        )?;
        let logs = self
            .food_log_repo
            .list_by_filter(FoodLogListFilter {
                user_id,
                date_range,
                meal_slot: None,
                items: Vec::new(),
            })
            .await?;

        Ok(latest_slots_from_logs(logs))
    }

    pub async fn list_recent_items(
        &self,
        user_id: Uuid,
        from_date: NaiveDate,
        to_date: NaiveDate,
        meal_slot: Option<MealSlot>,
    ) -> Result<Vec<RecentFoodLogItem>, NutritionError> {
        ensure_within_max_range(from_date, to_date)?;

        let logs = self
            .food_log_repo
            .list_by_filter(FoodLogListFilter {
                user_id,
                date_range: DateRange::inclusive(from_date, to_date)?,
                meal_slot,
                items: Vec::new(),
            })
            .await?;

        Ok(recent_items_from_logs(logs, to_date))
    }

    pub async fn summarize_by_date(
        &self,
        user_id: Uuid,
        from_date: NaiveDate,
        to_date: NaiveDate,
    ) -> Result<Vec<FoodLogDaySummary>, NutritionError> {
        ensure_within_max_range(from_date, to_date)?;

        let logs = self
            .food_log_repo
            .list_by_filter(FoodLogListFilter {
                user_id,
                date_range: DateRange::inclusive(from_date, to_date)?,
                meal_slot: None,
                items: Vec::new(),
            })
            .await?;

        Ok(summarize_logs_by_date(logs))
    }

    pub async fn find_last_used_items(
        &self,
        user_id: Uuid,
        from_date: NaiveDate,
        to_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        items: &[FoodLogItemRef],
    ) -> Result<Vec<RecentFoodLogItem>, NutritionError> {
        if items.is_empty() {
            return Ok(Vec::new());
        }

        ensure_within_max_range(from_date, to_date)?;

        let logs = self
            .food_log_repo
            .list_by_filter(FoodLogListFilter {
                user_id,
                date_range: DateRange::inclusive(from_date, to_date)?,
                meal_slot,
                items: items.to_vec(),
            })
            .await?;

        Ok(recent_items_from_logs(logs, to_date))
    }
}

/// Slots the user never logged inside the window are absent from the result;
/// callers must not read an empty slot as "logged nothing that day".
fn latest_slots_from_logs(logs: Vec<FoodLog>) -> Vec<LatestSlotLogs> {
    let mut by_slot = BTreeMap::<MealSlot, LatestSlotLogs>::new();

    for log in logs {
        if matches!(log.item(), FoodLogItemSnapshot::AdHoc { .. }) {
            continue;
        }
        let Some(meal_slot) = log.meal_slot() else {
            continue;
        };

        match by_slot.get_mut(&meal_slot) {
            None => {
                by_slot.insert(
                    meal_slot,
                    LatestSlotLogs {
                        meal_slot,
                        source_date: log.log_date(),
                        logs: vec![log],
                    },
                );
            }
            Some(slot) => match log.log_date().cmp(&slot.source_date) {
                Ordering::Greater => {
                    slot.source_date = log.log_date();
                    slot.logs = vec![log];
                }
                Ordering::Equal => slot.logs.push(log),
                Ordering::Less => {}
            },
        }
    }

    for slot in by_slot.values_mut() {
        slot.logs
            .sort_by_key(|log| std::cmp::Reverse(log.created_at()));
    }

    by_slot.into_values().collect()
}

fn summarize_logs_by_date(logs: Vec<FoodLog>) -> Vec<FoodLogDaySummary> {
    let mut summaries = BTreeMap::<NaiveDate, FoodLogDaySummary>::new();

    for log in logs {
        let summary = summaries
            .entry(log.log_date())
            .or_insert_with(|| FoodLogDaySummary {
                log_date: log.log_date(),
                energy_kcal: Decimal::ZERO,
                protein_g: Decimal::ZERO,
                carbs_g: Decimal::ZERO,
                fat_g: Decimal::ZERO,
            });

        for snapshot in log.nutrient_snapshots() {
            match snapshot.nutrient_code.0.as_str() {
                "ENERGY_KCAL" => summary.energy_kcal += snapshot.amount,
                "PROTEIN_G" => summary.protein_g += snapshot.amount,
                "CARBS_G" => summary.carbs_g += snapshot.amount,
                "FAT_G" => summary.fat_g += snapshot.amount,
                _ => {}
            }
        }
    }

    summaries.into_values().collect()
}

fn recent_items_from_logs(
    mut logs: Vec<FoodLog>,
    reference_date: NaiveDate,
) -> Vec<RecentFoodLogItem> {
    logs.sort_by(|left, right| {
        right
            .log_date()
            .cmp(&left.log_date())
            .then_with(|| right.created_at().cmp(&left.created_at()))
    });

    let mut items: Vec<RecentFoodLogItem> = Vec::new();
    for log in logs {
        if matches!(log.item(), FoodLogItemSnapshot::AdHoc { .. }) {
            continue;
        }
        let weight = recency_weight(log.log_date(), reference_date);
        let usage = QuantityUsage {
            amount: log.quantity_amount().normalize(),
            unit: log.quantity_unit().clone(),
            log_count: 1,
            score: weight,
        };
        match items
            .iter_mut()
            .find(|item| same_item_snapshot(&item.item, log.item()))
        {
            Some(item) => {
                item.score += weight;
                record_quantity_usage(&mut item.top_quantities, usage);
            }
            None => {
                // The first log seen for an item is its most recent one, which is
                // what `quantity_amount`/`quantity_unit` must keep reporting.
                let mut item = recent_item_from_log(log);
                item.score = weight;
                record_quantity_usage(&mut item.top_quantities, usage);
                items.push(item);
            }
        }
    }

    for item in &mut items {
        // Logs arrive most-recent-first, so a stable sort leaves equal scores in recency order.
        item.top_quantities
            .sort_by_key(|usage| std::cmp::Reverse(usage.score));
        item.top_quantities.truncate(MAX_TOP_QUANTITIES);
    }

    items.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| right.log_date.cmp(&left.log_date))
            .then_with(|| item_name(&left.item).cmp(item_name(&right.item)))
    });
    items
}

/// Recency buckets as `(minimum age in days, weight)`, oldest first. Halving the
/// weight every few days lets habits the user has dropped sink on their own
/// while still keeping them reachable; retuning the decay is a one-line change.
const RECENCY_WEIGHTS: [(i64, u32); 4] = [(14, 1), (7, 2), (3, 4), (0, 8)];

fn recency_weight(log_date: NaiveDate, reference_date: NaiveDate) -> u32 {
    let age_days = reference_date
        .signed_duration_since(log_date)
        .num_days()
        .max(0);

    RECENCY_WEIGHTS
        .iter()
        .find(|(minimum_age_days, _)| age_days >= *minimum_age_days)
        .map_or(1, |(_, weight)| *weight)
}

fn recent_item_from_log(log: FoodLog) -> RecentFoodLogItem {
    RecentFoodLogItem {
        item: log.item().clone(),
        log_date: log.log_date(),
        meal_slot: log.meal_slot(),
        quantity_amount: log.quantity_amount(),
        quantity_unit: log.quantity_unit().clone(),
        nutrient_snapshots: log.nutrient_snapshots().to_vec(),
        top_quantities: Vec::new(),
        score: 0,
    }
}

fn record_quantity_usage(usages: &mut Vec<QuantityUsage>, usage: QuantityUsage) {
    match usages
        .iter_mut()
        .find(|existing| existing.amount == usage.amount && existing.unit == usage.unit)
    {
        Some(existing) => {
            existing.log_count += 1;
            existing.score += usage.score;
        }
        None => usages.push(usage),
    }
}

fn same_item_snapshot(left: &FoodLogItemSnapshot, right: &FoodLogItemSnapshot) -> bool {
    match (left, right) {
        (
            FoodLogItemSnapshot::Product { id: left_id, .. },
            FoodLogItemSnapshot::Product { id: right_id, .. },
        ) => left_id == right_id,
        (
            FoodLogItemSnapshot::Meal { id: left_id, .. },
            FoodLogItemSnapshot::Meal { id: right_id, .. },
        ) => left_id == right_id,
        _ => false,
    }
}

fn item_name(item: &FoodLogItemSnapshot) -> &str {
    match item {
        FoodLogItemSnapshot::Product { name, .. } => name,
        FoodLogItemSnapshot::Meal { name, .. } => name,
        FoodLogItemSnapshot::AdHoc { name, .. } => name,
    }
}

#[cfg(test)]
mod tests {
    use super::super::test_support::*;
    use super::super::{FoodLogService, LogFoodInput};
    use super::{MAX_TOP_QUANTITIES, item_name, recent_items_from_logs};
    use crate::nutrition::catalog::domain::calculation::Quantity;
    use crate::nutrition::catalog::domain::{ProductId, UnitCode};
    use crate::nutrition::food_log::domain::{
        FoodLog, FoodLogId, FoodLogItemRef, FoodLogItemSnapshot, MealSlot, NutritionError,
        QuantityUsage,
    };
    use chrono::{DateTime, Duration, NaiveDate};
    use rust_decimal::Decimal;
    use std::str::FromStr;
    use uuid::Uuid;

    #[tokio::test]
    async fn latest_slots_before_resolves_every_slot_in_one_call() {
        let (services, history_services) = make_services_and_history(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let friday = NaiveDate::from_ymd_opt(2026, 6, 19).unwrap();
        let sunday = NaiveDate::from_ymd_opt(2026, 6, 21).unwrap();
        let monday = NaiveDate::from_ymd_opt(2026, 6, 22).unwrap();

        log_test_product(&services, user_id, friday, MealSlot::Breakfast, 100).await;
        log_test_product(&services, user_id, friday, MealSlot::Breakfast, 150).await;
        log_test_product(&services, user_id, friday, MealSlot::Lunch, 200).await;
        log_test_product(&services, user_id, sunday, MealSlot::Lunch, 250).await;

        let slots = history_services
            .latest_slots_before(user_id, monday, 30)
            .await
            .unwrap();

        assert_eq!(
            slots
                .iter()
                .map(|slot| (slot.meal_slot, slot.source_date, slot.logs.len()))
                .collect::<Vec<_>>(),
            vec![
                (MealSlot::Breakfast, friday, 2),
                (MealSlot::Lunch, sunday, 1),
            ]
        );
        assert_eq!(slots[1].logs[0].quantity_amount(), Decimal::new(250, 0));
    }

    #[tokio::test]
    async fn latest_slots_before_ignores_the_before_date_itself() {
        let (services, history_services) = make_services_and_history(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let sunday = NaiveDate::from_ymd_opt(2026, 6, 21).unwrap();
        let monday = NaiveDate::from_ymd_opt(2026, 6, 22).unwrap();

        log_test_product(&services, user_id, sunday, MealSlot::Breakfast, 125).await;
        log_test_product(&services, user_id, monday, MealSlot::Breakfast, 150).await;

        let slots = history_services
            .latest_slots_before(user_id, monday, 30)
            .await
            .unwrap();

        assert_eq!(slots.len(), 1);
        assert_eq!(slots[0].source_date, sunday);
        assert_eq!(slots[0].logs[0].quantity_amount(), Decimal::new(125, 0));
    }

    #[tokio::test]
    async fn latest_slots_before_omits_slots_outside_the_lookback_window() {
        let (services, history_services) = make_services_and_history(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let old_date = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();
        let friday = NaiveDate::from_ymd_opt(2026, 6, 19).unwrap();
        let monday = NaiveDate::from_ymd_opt(2026, 6, 22).unwrap();

        log_test_product(&services, user_id, old_date, MealSlot::Breakfast, 100).await;
        log_test_product(&services, user_id, friday, MealSlot::Dinner, 150).await;

        let slots = history_services
            .latest_slots_before(user_id, monday, 7)
            .await
            .unwrap();

        assert_eq!(slots.len(), 1);
        assert_eq!(slots[0].meal_slot, MealSlot::Dinner);
    }

    #[tokio::test]
    async fn history_rejects_invalid_lookback_days() {
        let history_services = empty_history_services();
        let result = history_services
            .latest_slots_before(
                Uuid::new_v4(),
                NaiveDate::from_ymd_opt(2026, 6, 22).unwrap(),
                0,
            )
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[tokio::test]
    async fn history_rejects_recent_items_inverted_date_range() {
        let history_services = empty_history_services();
        let result = history_services
            .list_recent_items(
                Uuid::new_v4(),
                NaiveDate::from_ymd_opt(2026, 6, 22).unwrap(),
                NaiveDate::from_ymd_opt(2026, 6, 21).unwrap(),
                None,
            )
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[tokio::test]
    async fn history_lists_recent_items_through_repository() {
        let (services, history_services) = make_services_and_history(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let friday = NaiveDate::from_ymd_opt(2026, 6, 19).unwrap();
        let monday = NaiveDate::from_ymd_opt(2026, 6, 22).unwrap();

        log_test_product(&services, user_id, friday, MealSlot::Breakfast, 100).await;
        log_test_product(&services, user_id, monday, MealSlot::Dinner, 150).await;

        let recent = history_services
            .list_recent_items(user_id, friday, monday, Some(MealSlot::Breakfast))
            .await
            .unwrap();

        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].meal_slot, Some(MealSlot::Breakfast));
    }

    #[tokio::test]
    async fn history_summarizes_logs_by_date_for_requested_user() {
        let (services, history_services) = make_services_and_history(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let other_user_id = Uuid::new_v4();
        let friday = NaiveDate::from_ymd_opt(2026, 6, 19).unwrap();
        let monday = NaiveDate::from_ymd_opt(2026, 6, 22).unwrap();

        log_test_product(&services, user_id, friday, MealSlot::Breakfast, 100).await;
        log_test_product(&services, user_id, friday, MealSlot::Lunch, 150).await;
        log_test_product(&services, user_id, monday, MealSlot::Dinner, 200).await;
        log_test_product(&services, other_user_id, friday, MealSlot::Breakfast, 500).await;

        let summaries = history_services
            .summarize_by_date(user_id, friday, monday)
            .await
            .unwrap();

        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].log_date, friday);
        assert_eq!(summaries[0].energy_kcal, Decimal::new(250, 0));
        assert_eq!(summaries[1].log_date, monday);
        assert_eq!(summaries[1].energy_kcal, Decimal::new(200, 0));
    }

    #[tokio::test]
    async fn history_rejects_summary_ranges_over_366_days() {
        let history_services = empty_history_services();
        let from_date = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
        let to_date = NaiveDate::from_ymd_opt(2026, 1, 3).unwrap();

        let result = history_services
            .summarize_by_date(Uuid::new_v4(), from_date, to_date)
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[tokio::test]
    async fn history_finds_last_used_items_through_repository() {
        let (services, history_services) = make_services_and_history(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let friday = NaiveDate::from_ymd_opt(2026, 6, 19).unwrap();
        let monday = NaiveDate::from_ymd_opt(2026, 6, 22).unwrap();

        log_test_product(&services, user_id, friday, MealSlot::Breakfast, 100).await;

        let recent = history_services
            .find_last_used_items(
                user_id,
                friday,
                monday,
                None,
                &[FoodLogItemRef::Product(ProductId(Uuid::nil()))],
            )
            .await
            .unwrap();

        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].quantity_amount, Decimal::new(100, 0));
    }

    #[test]
    fn recent_items_rank_top_quantities_by_usage_score() {
        let logs = vec![
            quantity_log(3, "150"),
            quantity_log(2, "100"),
            quantity_log(1, "100"),
            quantity_log(0, "100"),
        ];

        let items = recent_items_from_logs(logs, reference_date());

        assert_eq!(
            items[0].top_quantities,
            vec![usage("100", 3, 24), usage("150", 1, 8)]
        );
    }

    #[test]
    fn recent_items_break_top_quantity_ties_by_most_recent_use() {
        let logs = vec![
            quantity_log(2, "150"),
            quantity_log(1, "200"),
            quantity_log(0, "100"),
        ];

        let items = recent_items_from_logs(logs, reference_date());

        assert_eq!(
            items[0].top_quantities,
            vec![usage("150", 1, 8), usage("200", 1, 8), usage("100", 1, 8)]
        );
    }

    #[test]
    fn recent_items_collapse_top_quantities_with_equivalent_decimals() {
        let logs = vec![quantity_log(1, "100.0"), quantity_log(0, "100")];

        let items = recent_items_from_logs(logs, reference_date());

        assert_eq!(items[0].top_quantities.len(), 1);
        assert_eq!(items[0].top_quantities[0].log_count, 2);
        assert_eq!(items[0].top_quantities[0].amount.to_string(), "100");
    }

    #[test]
    fn recent_items_truncate_top_quantities_to_five() {
        let logs = vec![
            quantity_log(5, "10"),
            quantity_log(4, "20"),
            quantity_log(3, "30"),
            quantity_log(2, "40"),
            quantity_log(1, "50"),
            quantity_log(0, "60"),
        ];

        let items = recent_items_from_logs(logs, reference_date());

        assert_eq!(
            items[0].top_quantities,
            vec![
                usage("10", 1, 8),
                usage("20", 1, 8),
                usage("30", 1, 8),
                usage("40", 1, 8),
                usage("50", 1, 8),
            ]
        );
    }

    #[test]
    fn recent_items_rank_frequent_recent_use_over_more_frequent_stale_use() {
        let mut logs = vec![
            aged_log("Fresh Habit", 1, 0, "100"),
            aged_log("Fresh Habit", 1, 1, "100"),
            aged_log("Fresh Habit", 1, 2, "100"),
        ];
        logs.extend((0..8).map(|_| aged_log("Old Habit", 2, 21, "100")));

        let items = recent_items_from_logs(logs, reference_date());

        assert_eq!(
            items
                .iter()
                .map(|item| item_name(&item.item))
                .collect::<Vec<_>>(),
            vec!["Fresh Habit", "Old Habit"]
        );
        assert_eq!(items[0].score, 24);
        assert_eq!(items[1].score, 8);
    }

    #[test]
    fn recent_items_keep_recent_quantity_ahead_of_more_frequent_stale_quantities() {
        let mut logs = vec![
            aged_log("Test Food", 1, 1, "100"),
            aged_log("Test Food", 1, 2, "100"),
        ];
        for amount in ["10", "20", "30", "40", "50"] {
            logs.extend((0..5).map(|_| aged_log("Test Food", 1, 14, amount)));
        }

        let items = recent_items_from_logs(logs, reference_date());

        assert_eq!(items[0].top_quantities[0], usage("100", 2, 16));
        assert_eq!(items[0].top_quantities.len(), MAX_TOP_QUANTITIES);
    }

    #[test]
    fn recent_items_score_against_the_requested_to_date() {
        let logs = vec![
            aged_log("Once Today", 1, 0, "100"),
            aged_log("Twice Two Weeks Ago", 2, 14, "100"),
            aged_log("Twice Two Weeks Ago", 2, 14, "100"),
        ];

        let scored_today = recent_items_from_logs(logs.clone(), reference_date());
        let scored_later = recent_items_from_logs(logs, reference_date() + Duration::days(14));

        assert_eq!(item_name(&scored_today[0].item), "Once Today");
        assert_eq!(item_name(&scored_later[0].item), "Twice Two Weeks Ago");
    }

    #[test]
    fn recent_items_break_score_ties_by_log_date_then_name() {
        let logs = vec![
            aged_log("Cherry", 3, 1, "100"),
            aged_log("Banana", 2, 0, "100"),
            aged_log("Apple", 1, 0, "100"),
        ];

        let items = recent_items_from_logs(logs, reference_date());

        assert!(items.iter().all(|item| item.score == 8));
        assert_eq!(
            items
                .iter()
                .map(|item| item_name(&item.item))
                .collect::<Vec<_>>(),
            vec!["Apple", "Banana", "Cherry"]
        );
    }

    #[test]
    fn recent_items_report_the_most_recently_logged_quantity_as_last_used() {
        let mut logs = vec![aged_log("Test Food", 1, 0, "250")];
        logs.extend((0..5).map(|_| aged_log("Test Food", 1, 10, "100")));

        let items = recent_items_from_logs(logs, reference_date());

        // The stale quantity outranks the newest one, but last-used prefill still
        // has to report the newest log's quantity.
        assert_eq!(
            items[0].top_quantities[0].amount,
            Decimal::from_str("100").unwrap()
        );
        assert_eq!(items[0].quantity_amount, Decimal::from_str("250").unwrap());
        assert_eq!(items[0].log_date, reference_date());
    }

    fn reference_date() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 6, 19).unwrap()
    }

    fn quantity_log(created_at_offset_secs: i64, amount: &str) -> FoodLog {
        let created_at = DateTime::from_timestamp(created_at_offset_secs, 0).unwrap();
        FoodLog::restore(
            FoodLogId::new(),
            Uuid::nil(),
            reference_date(),
            Some(MealSlot::Breakfast),
            None,
            FoodLogItemSnapshot::Product {
                id: ProductId(Uuid::from_u128(1)),
                name: "Test Food".to_string(),
                brand: None,
            },
            Decimal::from_str(amount).unwrap(),
            UnitCode("g".to_string()),
            Vec::new(),
            None,
            created_at,
            created_at,
        )
    }

    fn aged_log(name: &str, item_id: u128, days_ago: i64, amount: &str) -> FoodLog {
        let log_date = reference_date() - Duration::days(days_ago);
        let created_at = DateTime::from_timestamp(86_400 * (366 - days_ago), 0).unwrap();

        FoodLog::restore(
            FoodLogId::new(),
            Uuid::nil(),
            log_date,
            Some(MealSlot::Breakfast),
            None,
            FoodLogItemSnapshot::Product {
                id: ProductId(Uuid::from_u128(item_id)),
                name: name.to_string(),
                brand: None,
            },
            Decimal::from_str(amount).unwrap(),
            UnitCode("g".to_string()),
            Vec::new(),
            None,
            created_at,
            created_at,
        )
    }

    fn usage(amount: &str, log_count: u32, score: u32) -> QuantityUsage {
        QuantityUsage {
            amount: Decimal::from_str(amount).unwrap(),
            unit: UnitCode("g".to_string()),
            log_count,
            score,
        }
    }

    async fn log_test_product(
        services: &FoodLogService,
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: MealSlot,
        amount_g: i64,
    ) -> FoodLog {
        services
            .log_item(
                user_id,
                LogFoodInput {
                    log_date,
                    device_timezone: None,
                    meal_slot: Some(meal_slot),
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(amount_g, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap()
    }
}

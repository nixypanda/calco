use std::collections::BTreeSet;

use async_trait::async_trait;
use uuid::Uuid;

use crate::nutrition::error::NutritionError;
use crate::nutrition::food_log::domain::MealSlot;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnabledMealSlots(BTreeSet<MealSlot>);

impl EnabledMealSlots {
    pub fn new(slots: impl IntoIterator<Item = MealSlot>) -> Result<Self, NutritionError> {
        let slots = slots.into_iter().collect::<BTreeSet<_>>();
        if slots.is_empty() {
            return Err(NutritionError::Validation(
                "at least one meal slot must be enabled".into(),
            ));
        }
        Ok(Self(slots))
    }

    pub fn defaults() -> Self {
        Self(
            [
                MealSlot::Breakfast,
                MealSlot::Lunch,
                MealSlot::Dinner,
                MealSlot::Snack,
            ]
            .into_iter()
            .collect(),
        )
    }

    pub fn canonical(&self) -> Vec<MealSlot> {
        MealSlot::ALL
            .into_iter()
            .filter(|slot| self.0.contains(slot))
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiaryPreferences {
    pub user_id: Uuid,
    pub enabled_meal_slots: EnabledMealSlots,
}

impl DiaryPreferences {
    pub fn defaults_for(user_id: Uuid) -> Self {
        Self {
            user_id,
            enabled_meal_slots: EnabledMealSlots::defaults(),
        }
    }

    pub fn new(user_id: Uuid, enabled_meal_slots: EnabledMealSlots) -> Self {
        Self {
            user_id,
            enabled_meal_slots,
        }
    }
}

#[async_trait]
pub trait DiaryPreferencesRepository: Send + Sync {
    async fn find_by_user_id(
        &self,
        user_id: Uuid,
    ) -> Result<Option<DiaryPreferences>, NutritionError>;

    async fn save(&self, preferences: &DiaryPreferences) -> Result<(), NutritionError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enabled_slots_reject_an_empty_selection() {
        assert!(matches!(
            EnabledMealSlots::new([]),
            Err(NutritionError::Validation(_))
        ));
    }

    #[test]
    fn enabled_slots_remove_duplicates_and_return_canonical_order() {
        let slots = EnabledMealSlots::new([
            MealSlot::LateNightSnack,
            MealSlot::Breakfast,
            MealSlot::LateNightSnack,
            MealSlot::Snack,
        ])
        .unwrap();

        assert_eq!(
            slots.canonical(),
            vec![
                MealSlot::Breakfast,
                MealSlot::Snack,
                MealSlot::LateNightSnack
            ]
        );
    }

    #[test]
    fn defaults_do_not_enable_late_night_snack() {
        assert_eq!(
            EnabledMealSlots::defaults().canonical(),
            vec![
                MealSlot::Breakfast,
                MealSlot::Lunch,
                MealSlot::Dinner,
                MealSlot::Snack
            ]
        );
    }
}

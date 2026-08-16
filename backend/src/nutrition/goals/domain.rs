use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::nutrition::error::NutritionError;

pub const DEFAULT_CALORIE_TARGET: i64 = 2100;
pub const DEFAULT_PROTEIN_TARGET_G: i64 = 150;
pub const DEFAULT_CARBS_TARGET_G: i64 = 240;
pub const DEFAULT_FAT_TARGET_G: i64 = 60;

#[derive(Clone, Debug, PartialEq)]
pub struct GoalTargets {
    pub calorie_target: Decimal,
    pub protein_target_g: Decimal,
    pub carbs_target_g: Decimal,
    pub fat_target_g: Decimal,
}

impl GoalTargets {
    pub fn new(
        calorie_target: Decimal,
        protein_target_g: Decimal,
        carbs_target_g: Decimal,
        fat_target_g: Decimal,
    ) -> Result<Self, NutritionError> {
        if calorie_target <= Decimal::ZERO {
            return Err(NutritionError::Validation(
                "calorie_target must be greater than 0".into(),
            ));
        }
        if protein_target_g < Decimal::ZERO {
            return Err(NutritionError::Validation(
                "protein_target_g must be greater than or equal to 0".into(),
            ));
        }
        if carbs_target_g < Decimal::ZERO {
            return Err(NutritionError::Validation(
                "carbs_target_g must be greater than or equal to 0".into(),
            ));
        }
        if fat_target_g < Decimal::ZERO {
            return Err(NutritionError::Validation(
                "fat_target_g must be greater than or equal to 0".into(),
            ));
        }

        let expected_calories = protein_target_g * Decimal::from(4)
            + carbs_target_g * Decimal::from(4)
            + fat_target_g * Decimal::from(9);
        if calorie_target != expected_calories {
            return Err(NutritionError::Validation(
                "calorie_target must equal protein_target_g * 4 + carbs_target_g * 4 + fat_target_g * 9".into(),
            ));
        }

        Ok(Self {
            calorie_target,
            protein_target_g,
            carbs_target_g,
            fat_target_g,
        })
    }

    pub fn defaults() -> Self {
        Self {
            calorie_target: Decimal::from(DEFAULT_CALORIE_TARGET),
            protein_target_g: Decimal::from(DEFAULT_PROTEIN_TARGET_G),
            carbs_target_g: Decimal::from(DEFAULT_CARBS_TARGET_G),
            fat_target_g: Decimal::from(DEFAULT_FAT_TARGET_G),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GoalTargetSource {
    Default,
    Saved,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GoalTarget {
    pub id: Uuid,
    pub user_id: Uuid,
    pub effective_from: NaiveDate,
    pub targets: GoalTargets,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl GoalTarget {
    pub fn create(
        user_id: Uuid,
        effective_from: NaiveDate,
        targets: GoalTargets,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            user_id,
            effective_from,
            targets,
            created_at: now,
            updated_at: now,
        }
    }

    pub fn update_targets(&self, targets: GoalTargets, now: DateTime<Utc>) -> Self {
        Self {
            id: self.id,
            user_id: self.user_id,
            effective_from: self.effective_from,
            targets,
            created_at: self.created_at,
            updated_at: now,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GoalTargetSnapshot {
    pub requested_date: NaiveDate,
    pub effective_from: Option<NaiveDate>,
    pub source: GoalTargetSource,
    pub targets: GoalTargets,
}

#[async_trait]
pub trait GoalTargetRepository: Send + Sync {
    async fn find_effective_for_date(
        &self,
        user_id: Uuid,
        requested_date: NaiveDate,
    ) -> Result<Option<GoalTarget>, NutritionError>;
    async fn find_by_user_id_and_effective_from(
        &self,
        user_id: Uuid,
        effective_from: NaiveDate,
    ) -> Result<Option<GoalTarget>, NutritionError>;
    async fn create(&self, goal_target: &GoalTarget) -> Result<(), NutritionError>;
    async fn update(&self, goal_target: &GoalTarget) -> Result<(), NutritionError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn goal_targets_reject_formula_mismatch() {
        let result = GoalTargets::new(
            Decimal::from(100),
            Decimal::from(10),
            Decimal::from(10),
            Decimal::from(10),
        );

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[test]
    fn goal_targets_accept_exact_formula_match() {
        let result = GoalTargets::new(
            Decimal::from(2100),
            Decimal::from(150),
            Decimal::from(240),
            Decimal::from(60),
        );

        assert!(result.is_ok());
    }
}

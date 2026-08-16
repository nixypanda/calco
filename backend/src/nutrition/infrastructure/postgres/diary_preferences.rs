use async_trait::async_trait;
use sqlx::PgPool;
use std::str::FromStr;
use uuid::Uuid;

use crate::nutrition::domain::diary_preferences::{
    DiaryPreferences, DiaryPreferencesRepository, EnabledMealSlots,
};
use crate::nutrition::domain::error::NutritionError;
use crate::nutrition::domain::food_log::MealSlot;

#[derive(Clone)]
pub struct PostgresDiaryPreferencesRepository {
    pool: PgPool,
}

impl PostgresDiaryPreferencesRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl DiaryPreferencesRepository for PostgresDiaryPreferencesRepository {
    async fn find_by_user_id(
        &self,
        user_id: Uuid,
    ) -> Result<Option<DiaryPreferences>, NutritionError> {
        let row = sqlx::query_as::<_, DiaryPreferencesRow>(
            "SELECT user_id, enabled_meal_slots FROM diary_preferences WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;

        row.map(row_to_domain).transpose()
    }

    async fn save(&self, preferences: &DiaryPreferences) -> Result<(), NutritionError> {
        let slots = preferences
            .enabled_meal_slots
            .canonical()
            .into_iter()
            .map(|slot| slot.as_str().to_owned())
            .collect::<Vec<_>>();
        sqlx::query(
            r#"
            INSERT INTO diary_preferences (user_id, enabled_meal_slots)
            VALUES ($1, $2)
            ON CONFLICT (user_id) DO UPDATE
            SET enabled_meal_slots = EXCLUDED.enabled_meal_slots,
                updated_at = NOW()
            "#,
        )
        .bind(preferences.user_id)
        .bind(slots)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

fn row_to_domain(row: DiaryPreferencesRow) -> Result<DiaryPreferences, NutritionError> {
    let slots = row
        .enabled_meal_slots
        .iter()
        .map(|slot| MealSlot::from_str(slot).map_err(NutritionError::Internal))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(DiaryPreferences::new(
        row.user_id,
        EnabledMealSlots::new(slots)?,
    ))
}

#[derive(sqlx::FromRow)]
struct DiaryPreferencesRow {
    user_id: Uuid,
    enabled_meal_slots: Vec<String>,
}

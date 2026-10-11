use async_trait::async_trait;
use sqlx::{PgPool, Postgres, QueryBuilder};
use std::str::FromStr;
use uuid::Uuid;

use crate::nutrition::diary::domain::{
    DiaryPreferences, DiaryPreferencesRepository, EnabledMealSlots,
};
use crate::nutrition::error::NutritionError;
use crate::nutrition::food_log::domain::MealSlot;

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
        let exists: Option<(Uuid,)> =
            sqlx::query_as("SELECT user_id FROM diary_preferences WHERE user_id = $1")
                .bind(user_id)
                .fetch_optional(&self.pool)
                .await?;
        if exists.is_none() {
            return Ok(None);
        }

        let rows: Vec<(String,)> =
            sqlx::query_as("SELECT meal_slot FROM diary_preference_meal_slots WHERE user_id = $1")
                .bind(user_id)
                .fetch_all(&self.pool)
                .await?;
        let slots = rows
            .into_iter()
            .map(|(slot,)| MealSlot::from_str(&slot).map_err(NutritionError::Internal))
            .collect::<Result<Vec<_>, _>>()?;

        Ok(Some(DiaryPreferences::new(
            user_id,
            EnabledMealSlots::new(slots)?,
        )))
    }

    async fn save(&self, preferences: &DiaryPreferences) -> Result<(), NutritionError> {
        let slots = preferences.enabled_meal_slots.canonical();
        let mut tx = self.pool.begin().await?;

        sqlx::query(
            r#"
            INSERT INTO diary_preferences (user_id)
            VALUES ($1)
            ON CONFLICT (user_id) DO UPDATE SET updated_at = CURRENT_TIMESTAMP
            "#,
        )
        .bind(preferences.user_id)
        .execute(&mut *tx)
        .await?;

        sqlx::query("DELETE FROM diary_preference_meal_slots WHERE user_id = $1")
            .bind(preferences.user_id)
            .execute(&mut *tx)
            .await?;

        let mut query = QueryBuilder::<Postgres>::new(
            "INSERT INTO diary_preference_meal_slots (user_id, meal_slot) ",
        );
        query.push_values(slots.iter(), |mut row, slot| {
            row.push_bind(preferences.user_id).push_bind(slot.as_str());
        });
        query.build().execute(&mut *tx).await?;

        tx.commit().await?;
        Ok(())
    }
}

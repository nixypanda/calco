use std::sync::Arc;

use uuid::Uuid;

use crate::nutrition::domain::diary_preferences::{
    DiaryPreferences, DiaryPreferencesRepository, EnabledMealSlots,
};
use crate::nutrition::domain::error::NutritionError;

#[derive(Clone)]
pub struct DiaryPreferencesServices {
    repo: Arc<dyn DiaryPreferencesRepository>,
}

impl DiaryPreferencesServices {
    pub fn new(repo: Arc<dyn DiaryPreferencesRepository>) -> Self {
        Self { repo }
    }

    pub async fn get(&self, user_id: Uuid) -> Result<DiaryPreferences, NutritionError> {
        Ok(self
            .repo
            .find_by_user_id(user_id)
            .await?
            .unwrap_or_else(|| DiaryPreferences::defaults_for(user_id)))
    }

    pub async fn replace(
        &self,
        user_id: Uuid,
        enabled_meal_slots: EnabledMealSlots,
    ) -> Result<DiaryPreferences, NutritionError> {
        let preferences = DiaryPreferences::update(user_id, enabled_meal_slots);
        self.repo.save(&preferences).await?;
        Ok(preferences)
    }
}

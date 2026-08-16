use std::sync::Arc;

use uuid::Uuid;

use crate::nutrition::diary::domain::{
    DiaryPreferences, DiaryPreferencesRepository, EnabledMealSlots,
};
use crate::nutrition::error::NutritionError;

#[derive(Clone)]
pub struct DiaryPreferencesService {
    repo: Arc<dyn DiaryPreferencesRepository>,
}

impl DiaryPreferencesService {
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
        let preferences = DiaryPreferences::new(user_id, enabled_meal_slots);
        self.repo.save(&preferences).await?;
        Ok(preferences)
    }
}

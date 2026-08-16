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

    pub async fn get(&self, actor_id: Uuid) -> Result<DiaryPreferences, NutritionError> {
        Ok(self
            .repo
            .find_by_user_id(actor_id)
            .await?
            .unwrap_or_else(|| DiaryPreferences::defaults_for(actor_id)))
    }

    pub async fn replace(
        &self,
        actor_id: Uuid,
        enabled_meal_slots: EnabledMealSlots,
    ) -> Result<DiaryPreferences, NutritionError> {
        let preferences = DiaryPreferences::new(actor_id, enabled_meal_slots);
        self.repo.save(&preferences).await?;
        Ok(preferences)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use async_trait::async_trait;

    use super::*;
    use crate::nutrition::food_log::domain::MealSlot;

    #[derive(Default)]
    struct MockDiaryPreferencesRepository {
        preferences: Mutex<HashMap<Uuid, DiaryPreferences>>,
    }

    #[async_trait]
    impl DiaryPreferencesRepository for MockDiaryPreferencesRepository {
        async fn find_by_user_id(
            &self,
            user_id: Uuid,
        ) -> Result<Option<DiaryPreferences>, NutritionError> {
            Ok(self.preferences.lock().unwrap().get(&user_id).cloned())
        }

        async fn save(&self, preferences: &DiaryPreferences) -> Result<(), NutritionError> {
            self.preferences
                .lock()
                .unwrap()
                .insert(preferences.user_id, preferences.clone());
            Ok(())
        }
    }

    #[tokio::test]
    async fn get_returns_only_the_authenticated_users_preferences() {
        let first_user = Uuid::new_v4();
        let second_user = Uuid::new_v4();
        let first_preferences = DiaryPreferences::new(
            first_user,
            EnabledMealSlots::new([MealSlot::Breakfast]).unwrap(),
        );
        let second_preferences = DiaryPreferences::new(
            second_user,
            EnabledMealSlots::new([MealSlot::Dinner]).unwrap(),
        );
        let repo = Arc::new(MockDiaryPreferencesRepository::default());
        repo.save(&first_preferences).await.unwrap();
        repo.save(&second_preferences).await.unwrap();
        let service = DiaryPreferencesService::new(repo);

        let result = service.get(first_user).await.unwrap();

        assert_eq!(result, first_preferences);
    }

    #[tokio::test]
    async fn replace_cannot_overwrite_another_users_preferences() {
        let first_user = Uuid::new_v4();
        let second_user = Uuid::new_v4();
        let second_preferences = DiaryPreferences::new(
            second_user,
            EnabledMealSlots::new([MealSlot::Dinner]).unwrap(),
        );
        let repo = Arc::new(MockDiaryPreferencesRepository::default());
        repo.save(&second_preferences).await.unwrap();
        let service = DiaryPreferencesService::new(repo.clone());

        service
            .replace(
                first_user,
                EnabledMealSlots::new([MealSlot::Lunch]).unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            repo.find_by_user_id(second_user).await.unwrap(),
            Some(second_preferences)
        );
    }
}

use std::sync::Arc;

use uuid::Uuid;

use crate::nutrition::diary::domain::{DiaryPrefs, DiaryPrefsRepo, EnabledMealSlots};
use crate::nutrition::error::NutritionError;

#[derive(Clone)]
pub struct DiaryPrefsService {
    repo: Arc<dyn DiaryPrefsRepo>,
}

impl DiaryPrefsService {
    pub fn new(repo: Arc<dyn DiaryPrefsRepo>) -> Self {
        Self { repo }
    }

    pub async fn get(&self, actor_id: Uuid) -> Result<DiaryPrefs, NutritionError> {
        Ok(self
            .repo
            .find_by_user_id(actor_id)
            .await?
            .unwrap_or_else(|| DiaryPrefs::defaults_for(actor_id)))
    }

    pub async fn replace(
        &self,
        actor_id: Uuid,
        enabled_meal_slots: EnabledMealSlots,
    ) -> Result<DiaryPrefs, NutritionError> {
        let prefs = DiaryPrefs::new(actor_id, enabled_meal_slots);
        self.repo.save(&prefs).await?;
        Ok(prefs)
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
    struct MockDiaryPrefsRepo {
        prefs: Mutex<HashMap<Uuid, DiaryPrefs>>,
    }

    #[async_trait]
    impl DiaryPrefsRepo for MockDiaryPrefsRepo {
        async fn find_by_user_id(
            &self,
            user_id: Uuid,
        ) -> Result<Option<DiaryPrefs>, NutritionError> {
            Ok(self.prefs.lock().unwrap().get(&user_id).cloned())
        }

        async fn save(&self, prefs: &DiaryPrefs) -> Result<(), NutritionError> {
            self.prefs
                .lock()
                .unwrap()
                .insert(prefs.user_id, prefs.clone());
            Ok(())
        }
    }

    #[tokio::test]
    async fn get_returns_only_the_authenticated_users_preferences() {
        let first_user = Uuid::new_v4();
        let second_user = Uuid::new_v4();
        let first_prefs = DiaryPrefs::new(
            first_user,
            EnabledMealSlots::new([MealSlot::Breakfast]).unwrap(),
        );
        let second_prefs = DiaryPrefs::new(
            second_user,
            EnabledMealSlots::new([MealSlot::Dinner]).unwrap(),
        );
        let repo = Arc::new(MockDiaryPrefsRepo::default());
        repo.save(&first_prefs).await.unwrap();
        repo.save(&second_prefs).await.unwrap();
        let service = DiaryPrefsService::new(repo);

        let result = service.get(first_user).await.unwrap();

        assert_eq!(result, first_prefs);
    }

    #[tokio::test]
    async fn replace_cannot_overwrite_another_users_preferences() {
        let first_user = Uuid::new_v4();
        let second_user = Uuid::new_v4();
        let second_prefs = DiaryPrefs::new(
            second_user,
            EnabledMealSlots::new([MealSlot::Dinner]).unwrap(),
        );
        let repo = Arc::new(MockDiaryPrefsRepo::default());
        repo.save(&second_prefs).await.unwrap();
        let service = DiaryPrefsService::new(repo.clone());

        service
            .replace(
                first_user,
                EnabledMealSlots::new([MealSlot::Lunch]).unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            repo.find_by_user_id(second_user).await.unwrap(),
            Some(second_prefs)
        );
    }
}

use std::sync::Arc;

use uuid::Uuid;

use crate::journal::diary_prefs::domain::{DiaryPrefs, DiaryPrefsRepo, EnabledMealSlots};
use crate::journal::error::JournalError;

#[derive(Clone)]
pub struct DiaryPrefsService {
    repo: Arc<dyn DiaryPrefsRepo>,
}

impl DiaryPrefsService {
    pub fn new(repo: Arc<dyn DiaryPrefsRepo>) -> Self {
        Self { repo }
    }

    pub async fn get(&self, actor_id: Uuid) -> Result<DiaryPrefs, JournalError> {
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
    ) -> Result<DiaryPrefs, JournalError> {
        let prefs = DiaryPrefs::new(actor_id, enabled_meal_slots);
        self.repo.upsert(&prefs).await?;
        Ok(prefs)
    }
}

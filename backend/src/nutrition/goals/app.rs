use std::sync::Arc;

use chrono::{NaiveDate, Utc};
use chrono_tz::Tz;

use crate::nutrition::error::NutritionError;
use crate::nutrition::goals::domain::{
    GoalTarget, GoalTargetRepo, GoalTargetSnapshot, GoalTargetSource, GoalTargets,
};

#[derive(Clone)]
pub struct GoalTargetService {
    repo: Arc<dyn GoalTargetRepo>,
}

impl GoalTargetService {
    pub fn new(repo: Arc<dyn GoalTargetRepo>) -> Self {
        Self { repo }
    }

    pub async fn get_goal_for_date(
        &self,
        actor_id: uuid::Uuid,
        requested_date: NaiveDate,
    ) -> Result<GoalTargetSnapshot, NutritionError> {
        match self
            .repo
            .find_effective_for_date(actor_id, requested_date)
            .await?
        {
            Some(goal_target) => Ok(GoalTargetSnapshot {
                requested_date,
                effective_from: Some(goal_target.effective_from),
                source: GoalTargetSource::Saved,
                targets: goal_target.targets,
            }),
            None => Ok(GoalTargetSnapshot {
                requested_date,
                effective_from: None,
                source: GoalTargetSource::Default,
                targets: GoalTargets::defaults(),
            }),
        }
    }

    pub async fn save_goal_for_today(
        &self,
        actor_id: uuid::Uuid,
        local_date: NaiveDate,
        device_timezone: &str,
        targets: GoalTargets,
    ) -> Result<GoalTargetSnapshot, NutritionError> {
        let tz: Tz = device_timezone
            .parse()
            .map_err(|_| NutritionError::Validation("invalid device_timezone".into()))?;
        let today_in_timezone = Utc::now().with_timezone(&tz).date_naive();

        if local_date != today_in_timezone {
            return Err(NutritionError::Validation(
                "local_date must match today's date in device_timezone".into(),
            ));
        }

        let goal = GoalTarget::create(actor_id, local_date, targets, Utc::now());
        self.repo.upsert(&goal).await?;

        Ok(GoalTargetSnapshot {
            requested_date: local_date,
            effective_from: Some(goal.effective_from),
            source: GoalTargetSource::Saved,
            targets: goal.targets,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use chrono::{Duration, NaiveDate};
    use rust_decimal::Decimal;
    use std::sync::Mutex;
    use uuid::Uuid;

    use crate::nutrition::goals::domain::GoalTarget;

    struct MockGoalTargetRepo {
        goal_targets: Mutex<Vec<GoalTarget>>,
    }

    impl MockGoalTargetRepo {
        fn new(goal_targets: Vec<GoalTarget>) -> Self {
            Self {
                goal_targets: Mutex::new(goal_targets),
            }
        }
    }

    #[async_trait]
    impl GoalTargetRepo for MockGoalTargetRepo {
        async fn find_effective_for_date(
            &self,
            user_id: Uuid,
            requested_date: NaiveDate,
        ) -> Result<Option<GoalTarget>, NutritionError> {
            let goal_targets = self.goal_targets.lock().unwrap();
            Ok(goal_targets
                .iter()
                .filter(|goal| goal.user_id == user_id && goal.effective_from <= requested_date)
                .max_by_key(|goal| goal.effective_from)
                .cloned())
        }

        async fn upsert(&self, goal_target: &GoalTarget) -> Result<(), NutritionError> {
            let mut goal_targets = self.goal_targets.lock().unwrap();
            match goal_targets.iter_mut().find(|goal| {
                goal.user_id == goal_target.user_id
                    && goal.effective_from == goal_target.effective_from
            }) {
                Some(existing) => {
                    existing.targets = goal_target.targets.clone();
                    existing.updated_at = goal_target.updated_at;
                }
                None => goal_targets.push(goal_target.clone()),
            }
            Ok(())
        }
    }

    impl MockGoalTargetRepo {
        async fn find_by_user_id_and_effective_from(
            &self,
            user_id: Uuid,
            effective_from: NaiveDate,
        ) -> Result<Option<GoalTarget>, NutritionError> {
            let goal_targets = self.goal_targets.lock().unwrap();
            Ok(goal_targets
                .iter()
                .find(|goal| goal.user_id == user_id && goal.effective_from == effective_from)
                .cloned())
        }
    }

    fn sample_targets(calories: i64, protein: i64, carbs: i64, fat: i64) -> GoalTargets {
        GoalTargets::new(
            Decimal::from(calories),
            Decimal::from(protein),
            Decimal::from(carbs),
            Decimal::from(fat),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn multiple_saved_rows_resolve_latest_effective_date() {
        let user_id = Uuid::new_v4();
        let now = Utc::now();
        let services = GoalTargetService::new(Arc::new(MockGoalTargetRepo::new(vec![
            GoalTarget::create(
                user_id,
                NaiveDate::from_ymd_opt(2026, 6, 10).unwrap(),
                sample_targets(2100, 150, 240, 60),
                now,
            ),
            GoalTarget::create(
                user_id,
                NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                sample_targets(2290, 160, 255, 70),
                now,
            ),
        ])));

        let snapshot = services
            .get_goal_for_date(user_id, NaiveDate::from_ymd_opt(2026, 6, 16).unwrap())
            .await
            .unwrap();

        assert_eq!(snapshot.source, GoalTargetSource::Saved);
        assert_eq!(
            snapshot.effective_from,
            Some(NaiveDate::from_ymd_opt(2026, 6, 15).unwrap())
        );
        assert_eq!(snapshot.targets, sample_targets(2290, 160, 255, 70));
    }

    #[tokio::test]
    async fn effective_goal_lookup_does_not_cross_user_boundaries() {
        let actor_id = Uuid::new_v4();
        let other_user_id = Uuid::new_v4();
        let requested_date = NaiveDate::from_ymd_opt(2026, 6, 16).unwrap();
        let other_users_targets = sample_targets(2290, 160, 255, 70);
        let service =
            GoalTargetService::new(Arc::new(MockGoalTargetRepo::new(vec![GoalTarget::create(
                other_user_id,
                NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                other_users_targets,
                Utc::now(),
            )])));

        let snapshot = service
            .get_goal_for_date(actor_id, requested_date)
            .await
            .unwrap();

        assert_eq!(snapshot.source, GoalTargetSource::Default);
        assert_eq!(snapshot.targets, GoalTargets::defaults());
    }

    #[tokio::test]
    async fn save_today_does_not_overwrite_another_users_goal() {
        let actor_id = Uuid::new_v4();
        let other_user_id = Uuid::new_v4();
        let timezone = "Asia/Kolkata";
        let local_date = Utc::now()
            .with_timezone(&timezone.parse::<Tz>().unwrap())
            .date_naive();
        let other_users_targets = sample_targets(2100, 150, 240, 60);
        let repo = Arc::new(MockGoalTargetRepo::new(vec![GoalTarget::create(
            other_user_id,
            local_date,
            other_users_targets.clone(),
            Utc::now() - Duration::days(1),
        )]));
        let service = GoalTargetService::new(repo.clone());

        service
            .save_goal_for_today(
                actor_id,
                local_date,
                timezone,
                sample_targets(2290, 160, 255, 70),
            )
            .await
            .unwrap();

        let other_users_goal = repo
            .find_by_user_id_and_effective_from(other_user_id, local_date)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(other_users_goal.targets, other_users_targets);
        assert_eq!(repo.goal_targets.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn save_rejects_non_today_local_date() {
        let services = GoalTargetService::new(Arc::new(MockGoalTargetRepo::new(vec![])));
        let user_id = Uuid::new_v4();
        let timezone = "Asia/Kolkata";
        let local_date = Utc::now()
            .with_timezone(&timezone.parse::<Tz>().unwrap())
            .date_naive()
            - Duration::days(1);

        let result = services
            .save_goal_for_today(
                user_id,
                local_date,
                timezone,
                sample_targets(2100, 150, 240, 60),
            )
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }
}

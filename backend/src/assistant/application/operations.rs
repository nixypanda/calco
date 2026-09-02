use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

use crate::assistant::application::{
    FoodDraftTelemetryEvent, FoodDraftTelemetryOutcome, FoodDraftTelemetryPort,
    TracingFoodDraftTelemetry,
};
use crate::assistant::domain::AssistantError;

/// Product-owned admission policy for the shared food-assistance provider.
/// These limits deliberately are not deployment configuration: they protect a
/// local model and prevent one account from monopolising it.
pub const MAX_DRAFTS_PER_USER_PER_WINDOW: usize = 5;
pub const DRAFT_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);
pub const MAX_CONCURRENT_DRAFTS: usize = 2;

/// Process-local, per-user rolling-window rate limiter plus a global
/// in-flight-generation limit. A permit is held only for the provider and
/// draft-validation operation, never while multipart data is parsed.
pub struct FoodDraftOperations {
    recent_requests: Mutex<HashMap<Uuid, VecDeque<Instant>>>,
    concurrent_drafts: Arc<Semaphore>,
    per_user_limit: usize,
    window: Duration,
    telemetry: Arc<dyn FoodDraftTelemetryPort>,
}

impl FoodDraftOperations {
    pub fn new() -> Self {
        Self::with_limits(
            MAX_DRAFTS_PER_USER_PER_WINDOW,
            DRAFT_RATE_LIMIT_WINDOW,
            MAX_CONCURRENT_DRAFTS,
        )
    }

    pub fn with_limits(per_user_limit: usize, window: Duration, max_concurrent: usize) -> Self {
        Self::with_limits_and_telemetry(
            per_user_limit,
            window,
            max_concurrent,
            Arc::new(TracingFoodDraftTelemetry),
        )
    }

    pub fn with_limits_and_telemetry(
        per_user_limit: usize,
        window: Duration,
        max_concurrent: usize,
        telemetry: Arc<dyn FoodDraftTelemetryPort>,
    ) -> Self {
        assert!(per_user_limit > 0, "per-user draft limit must be positive");
        assert!(
            !window.is_zero(),
            "draft rate-limit window must be positive"
        );
        assert!(max_concurrent > 0, "global draft limit must be positive");

        Self {
            recent_requests: Mutex::new(HashMap::new()),
            concurrent_drafts: Arc::new(Semaphore::new(max_concurrent)),
            per_user_limit,
            window,
            telemetry,
        }
    }

    /// Reject immediately rather than queueing callers. A queue would retain
    /// transient conversation data and make a small local model appear hung.
    pub fn acquire(
        &self,
        user_id: Uuid,
        image_count: usize,
    ) -> Result<FoodDraftOperationPermit, AssistantError> {
        let permit = self
            .concurrent_drafts
            .clone()
            .try_acquire_owned()
            .map_err(|_| {
                self.record_admission_rejection(
                    user_id,
                    image_count,
                    FoodDraftTelemetryOutcome::Busy,
                );
                AssistantError::Busy
            })?;

        let now = Instant::now();
        let rate_limited = {
            let mut recent_requests = self
                .recent_requests
                .lock()
                .expect("food-draft rate-limit mutex poisoned");
            recent_requests.retain(|_, timestamps| {
                prune_expired(timestamps, now, self.window);
                !timestamps.is_empty()
            });

            let timestamps = recent_requests.entry(user_id).or_default();
            if timestamps.len() >= self.per_user_limit {
                true
            } else {
                timestamps.push_back(now);
                false
            }
        };
        if rate_limited {
            self.record_admission_rejection(
                user_id,
                image_count,
                FoodDraftTelemetryOutcome::RateLimited,
            );
            return Err(AssistantError::RateLimited);
        }

        Ok(FoodDraftOperationPermit { _permit: permit })
    }

    fn record_admission_rejection(
        &self,
        user_id: Uuid,
        image_count: usize,
        outcome: FoodDraftTelemetryOutcome,
    ) {
        self.telemetry.record(FoodDraftTelemetryEvent {
            user_id,
            image_count,
            latency_ms: 0,
            outcome,
            input_tokens: None,
            output_tokens: None,
        });
    }
}

impl Default for FoodDraftOperations {
    fn default() -> Self {
        Self::new()
    }
}

pub struct FoodDraftOperationPermit {
    _permit: OwnedSemaphorePermit,
}

fn prune_expired(timestamps: &mut VecDeque<Instant>, now: Instant, window: Duration) {
    while timestamps
        .front()
        .is_some_and(|timestamp| now.duration_since(*timestamp) >= window)
    {
        timestamps.pop_front();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use uuid::Uuid;

    use crate::assistant::domain::AssistantError;

    use super::FoodDraftOperations;
    use crate::assistant::application::{
        FoodDraftTelemetryEvent, FoodDraftTelemetryOutcome, FoodDraftTelemetryPort,
    };

    #[derive(Default)]
    struct RecordingTelemetry {
        events: Mutex<Vec<FoodDraftTelemetryEvent>>,
    }

    impl FoodDraftTelemetryPort for RecordingTelemetry {
        fn record(&self, event: FoodDraftTelemetryEvent) {
            self.events.lock().unwrap().push(event);
        }
    }

    #[test]
    fn rejects_a_user_after_the_rolling_window_limit() {
        let operations = FoodDraftOperations::with_limits(2, Duration::from_secs(60), 2);
        let user = Uuid::new_v4();
        let first = operations.acquire(user, 0).unwrap();
        drop(first);
        let second = operations.acquire(user, 0).unwrap();
        drop(second);

        assert!(matches!(
            operations.acquire(user, 0),
            Err(AssistantError::RateLimited)
        ));
    }

    #[test]
    fn limits_concurrent_generations_across_users() {
        let operations = FoodDraftOperations::with_limits(5, Duration::from_secs(60), 1);
        let first = operations.acquire(Uuid::new_v4(), 0).unwrap();

        assert!(matches!(
            operations.acquire(Uuid::new_v4(), 0),
            Err(AssistantError::Busy)
        ));
        drop(first);
        assert!(operations.acquire(Uuid::new_v4(), 0).is_ok());
    }

    #[test]
    fn records_content_free_admission_rejections_with_distinct_outcomes() {
        let telemetry = Arc::new(RecordingTelemetry::default());
        let operations = FoodDraftOperations::with_limits_and_telemetry(
            1,
            Duration::from_secs(60),
            1,
            telemetry.clone(),
        );
        let first_user = Uuid::new_v4();
        let permit = operations.acquire(first_user, 2).unwrap();

        assert!(matches!(
            operations.acquire(Uuid::new_v4(), 3),
            Err(AssistantError::Busy)
        ));
        drop(permit);
        assert!(matches!(
            operations.acquire(first_user, 2),
            Err(AssistantError::RateLimited)
        ));

        let events = telemetry.events.lock().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].outcome, FoodDraftTelemetryOutcome::Busy);
        assert_eq!(events[0].image_count, 3);
        assert_eq!(events[0].input_tokens, None);
        assert_eq!(events[1].outcome, FoodDraftTelemetryOutcome::RateLimited);
        assert_eq!(events[1].image_count, 2);
    }
}

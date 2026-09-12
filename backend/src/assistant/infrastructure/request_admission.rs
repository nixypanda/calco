use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

pub(crate) const DEFAULT_REQUESTS_PER_WINDOW: usize = 10;
pub(crate) const DEFAULT_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);
pub(crate) const DEFAULT_MAX_CONCURRENT_REQUESTS: usize = 4;
pub(crate) const DEFAULT_MAX_TRACKED_USERS: usize = 1_024;

pub(crate) struct RequestAdmissionService {
    requests_per_window: usize,
    window: Duration,
    max_tracked_users: usize,
    requests: Mutex<HashMap<Uuid, VecDeque<Instant>>>,
    concurrency: Arc<Semaphore>,
}

#[derive(Debug)]
pub(crate) enum AdmissionRejection {
    RateLimitExceeded { retry_after_seconds: u64 },
    AtCapacity,
    StateUnavailable,
}

impl RequestAdmissionService {
    pub(crate) fn new(
        requests_per_window: usize,
        window: Duration,
        max_concurrent_requests: usize,
        max_tracked_users: usize,
    ) -> Self {
        Self {
            requests_per_window,
            window,
            max_tracked_users,
            requests: Mutex::new(HashMap::new()),
            concurrency: Arc::new(Semaphore::new(max_concurrent_requests)),
        }
    }

    pub(crate) fn try_acquire(
        &self,
        user_id: Uuid,
    ) -> Result<OwnedSemaphorePermit, AdmissionRejection> {
        let now = Instant::now();
        let mut requests = self
            .requests
            .lock()
            .map_err(|_| AdmissionRejection::StateUnavailable)?;
        requests.retain(|_, user_requests| {
            while user_requests
                .front()
                .is_some_and(|at| now.duration_since(*at) >= self.window)
            {
                user_requests.pop_front();
            }
            !user_requests.is_empty()
        });
        // The map is hard-bounded, so both this cleanup scan and all request
        // history work have fixed worst-case cost. At capacity, existing users
        // retain their buckets and new users are deterministically rejected.
        if !requests.contains_key(&user_id) && requests.len() >= self.max_tracked_users {
            return Err(AdmissionRejection::AtCapacity);
        }
        let user_requests = requests.entry(user_id).or_default();
        if user_requests.len() >= self.requests_per_window {
            let elapsed = now.duration_since(*user_requests.front().expect("non-empty queue"));
            let remaining = self.window.saturating_sub(elapsed);
            return Err(AdmissionRejection::RateLimitExceeded {
                retry_after_seconds: remaining.as_secs().max(1),
            });
        }

        let permit = self
            .concurrency
            .clone()
            .try_acquire_owned()
            .map_err(|_| AdmissionRejection::AtCapacity)?;
        user_requests.push_back(now);
        Ok(permit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limit_is_per_user_and_concurrency_is_global() {
        let admission = RequestAdmissionService::new(1, Duration::from_secs(60), 1, 10);
        let first_user = Uuid::new_v4();
        let second_user = Uuid::new_v4();
        let permit = admission.try_acquire(first_user).unwrap();
        assert!(matches!(
            admission.try_acquire(first_user),
            Err(AdmissionRejection::RateLimitExceeded { .. })
        ));
        assert!(matches!(
            admission.try_acquire(second_user),
            Err(AdmissionRejection::AtCapacity)
        ));
        drop(permit);
        assert!(admission.try_acquire(second_user).is_ok());
    }

    #[test]
    fn expired_user_entries_are_pruned() {
        let admission = RequestAdmissionService::new(1, Duration::ZERO, 1, 10);
        for _ in 0..100 {
            drop(admission.try_acquire(Uuid::new_v4()).unwrap());
        }
        assert_eq!(admission.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn tracked_users_are_capped_without_consuming_existing_user_permits() {
        let admission = RequestAdmissionService::new(2, Duration::from_secs(60), 3, 2);
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let rejected = Uuid::new_v4();

        drop(admission.try_acquire(first).unwrap());
        drop(admission.try_acquire(second).unwrap());
        assert!(matches!(
            admission.try_acquire(rejected),
            Err(AdmissionRejection::AtCapacity)
        ));
        assert_eq!(admission.requests.lock().unwrap().len(), 2);

        // Rejection at the cardinality cap does not consume a global permit,
        // and a tracked user can still use its remaining per-user allowance.
        assert!(admission.try_acquire(first).is_ok());
    }

    #[test]
    fn expired_bucket_is_evicted_before_capacity_is_checked() {
        let admission = RequestAdmissionService::new(1, Duration::ZERO, 1, 1);
        drop(admission.try_acquire(Uuid::new_v4()).unwrap());
        assert!(admission.try_acquire(Uuid::new_v4()).is_ok());
        assert_eq!(admission.requests.lock().unwrap().len(), 1);
    }
}

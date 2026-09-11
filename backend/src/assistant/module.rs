use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::FromRef;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

use crate::AppState;
use crate::assistant::application::{FoodDraftService, FoodImageSanitizer};
use crate::assistant::domain::AssistantError;
use crate::assistant::infrastructure::{
    FoodDraftModelAdapter, NutritionCatalogVocabularyAdapter, SafeFoodImageSanitizer,
};
use crate::assistant::llm::{
    Authentication, ChatError, OpenAiCompatibleClient, OpenAiCompatibleConfig,
};
use crate::config::{AssistantAuthentication, AssistantConfig};
use crate::nutrition::module::CatalogModule;

const REQUESTS_PER_WINDOW: usize = 10;
const RATE_WINDOW: Duration = Duration::from_secs(60);
const MAX_IN_FLIGHT: usize = 4;
const MAX_TRACKED_USERS: usize = 1_024;

#[derive(Clone)]
pub struct AssistantModule {
    service: Option<Arc<FoodDraftService>>,
    images: Option<Arc<dyn FoodImageSanitizer>>,
    limits: Arc<AssistantLimits>,
}

struct AssistantLimits {
    requests_per_window: usize,
    window: Duration,
    max_tracked_users: usize,
    requests: Mutex<HashMap<Uuid, VecDeque<Instant>>>,
    in_flight: Arc<Semaphore>,
}

#[derive(Debug)]
pub(crate) enum AdmissionError {
    RateLimited { retry_after_seconds: u64 },
    Busy,
    Internal,
}

impl AssistantModule {
    pub fn build(
        settings: &AssistantConfig,
        catalog: &CatalogModule,
    ) -> Result<Self, AssistantError> {
        let (service, images) = match settings {
            AssistantConfig::Disabled => (None, None),
            AssistantConfig::Enabled(settings) => {
                let authentication = match &settings.authentication {
                    AssistantAuthentication::None => Authentication::None,
                    AssistantAuthentication::Bearer { api_key_file } => {
                        Authentication::BearerFile(api_key_file.clone())
                    }
                    AssistantAuthentication::Header {
                        header_name,
                        api_key_file,
                    } => Authentication::HeaderFile {
                        name: header_name.clone(),
                        path: api_key_file.clone(),
                    },
                };
                let chat = Arc::new(
                    OpenAiCompatibleClient::new(OpenAiCompatibleConfig {
                        endpoint: settings.endpoint.clone(),
                        model: settings.model.as_str().to_owned(),
                        authentication,
                    })
                    .map_err(map_chat_startup_error)?,
                );
                let model = Arc::new(FoodDraftModelAdapter::new(chat));
                let vocabulary = Arc::new(NutritionCatalogVocabularyAdapter::new(
                    catalog.services.clone(),
                ));
                let images = settings.supports_images.then(|| {
                    Arc::new(SafeFoodImageSanitizer::new()) as Arc<dyn FoodImageSanitizer>
                });
                (
                    Some(Arc::new(FoodDraftService::new(model, vocabulary))),
                    images,
                )
            }
        };
        Ok(Self::new(
            service,
            images,
            REQUESTS_PER_WINDOW,
            RATE_WINDOW,
            MAX_IN_FLIGHT,
            MAX_TRACKED_USERS,
        ))
    }

    /// Dependency-injection seam for tests and alternate text-draft providers.
    pub fn from_service(service: Arc<FoodDraftService>) -> Self {
        Self::new(
            Some(service),
            None,
            REQUESTS_PER_WINDOW,
            RATE_WINDOW,
            MAX_IN_FLIGHT,
            MAX_TRACKED_USERS,
        )
    }

    pub fn from_service_with_images(
        service: Arc<FoodDraftService>,
        images: Arc<dyn FoodImageSanitizer>,
    ) -> Self {
        Self::new(
            Some(service),
            Some(images),
            REQUESTS_PER_WINDOW,
            RATE_WINDOW,
            MAX_IN_FLIGHT,
            MAX_TRACKED_USERS,
        )
    }

    pub fn disabled() -> Self {
        Self::new(
            None,
            None,
            REQUESTS_PER_WINDOW,
            RATE_WINDOW,
            MAX_IN_FLIGHT,
            MAX_TRACKED_USERS,
        )
    }

    fn new(
        service: Option<Arc<FoodDraftService>>,
        images: Option<Arc<dyn FoodImageSanitizer>>,
        requests_per_window: usize,
        window: Duration,
        max_in_flight: usize,
        max_tracked_users: usize,
    ) -> Self {
        Self {
            service,
            images,
            limits: Arc::new(AssistantLimits {
                requests_per_window,
                window,
                max_tracked_users,
                requests: Mutex::new(HashMap::new()),
                in_flight: Arc::new(Semaphore::new(max_in_flight)),
            }),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.service.is_some()
    }

    pub fn supports_images(&self) -> bool {
        self.is_enabled() && self.images.is_some()
    }

    pub(crate) fn image_sanitizer(&self) -> Option<Arc<dyn FoodImageSanitizer>> {
        self.images.clone()
    }

    pub(crate) fn service(&self) -> Option<Arc<FoodDraftService>> {
        self.service.clone()
    }

    pub(crate) fn admit(&self, user_id: Uuid) -> Result<OwnedSemaphorePermit, AdmissionError> {
        let now = Instant::now();
        let mut requests = self
            .limits
            .requests
            .lock()
            .map_err(|_| AdmissionError::Internal)?;
        requests.retain(|_, user_requests| {
            while user_requests
                .front()
                .is_some_and(|at| now.duration_since(*at) >= self.limits.window)
            {
                user_requests.pop_front();
            }
            !user_requests.is_empty()
        });
        // The map is hard-bounded, so both this cleanup scan and all request
        // history work have fixed worst-case cost. At capacity, existing users
        // retain their buckets and new users are deterministically rejected.
        if !requests.contains_key(&user_id) && requests.len() >= self.limits.max_tracked_users {
            return Err(AdmissionError::Busy);
        }
        let user_requests = requests.entry(user_id).or_default();
        if user_requests.len() >= self.limits.requests_per_window {
            let elapsed = now.duration_since(*user_requests.front().expect("non-empty queue"));
            let remaining = self.limits.window.saturating_sub(elapsed);
            return Err(AdmissionError::RateLimited {
                retry_after_seconds: remaining.as_secs().max(1),
            });
        }

        let permit = self
            .limits
            .in_flight
            .clone()
            .try_acquire_owned()
            .map_err(|_| AdmissionError::Busy)?;
        user_requests.push_back(now);
        Ok(permit)
    }
}

fn map_chat_startup_error(_error: ChatError) -> AssistantError {
    AssistantError::Internal
}

impl FromRef<AppState> for AssistantModule {
    fn from_ref(app: &AppState) -> Self {
        app.assistant.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limit_is_per_user_and_concurrency_is_global() {
        let module = AssistantModule::new(None, None, 1, Duration::from_secs(60), 1, 10);
        let first_user = Uuid::new_v4();
        let second_user = Uuid::new_v4();
        let permit = module.admit(first_user).unwrap();
        assert!(matches!(
            module.admit(first_user),
            Err(AdmissionError::RateLimited { .. })
        ));
        assert!(matches!(
            module.admit(second_user),
            Err(AdmissionError::Busy)
        ));
        drop(permit);
        assert!(module.admit(second_user).is_ok());
    }

    #[test]
    fn expired_user_entries_are_pruned() {
        let module = AssistantModule::new(None, None, 1, Duration::ZERO, 1, 10);
        for _ in 0..100 {
            drop(module.admit(Uuid::new_v4()).unwrap());
        }
        assert_eq!(module.limits.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn tracked_users_are_capped_without_consuming_existing_user_permits() {
        let module = AssistantModule::new(None, None, 2, Duration::from_secs(60), 3, 2);
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let rejected = Uuid::new_v4();

        drop(module.admit(first).unwrap());
        drop(module.admit(second).unwrap());
        assert!(matches!(module.admit(rejected), Err(AdmissionError::Busy)));
        assert_eq!(module.limits.requests.lock().unwrap().len(), 2);

        // Rejection at the cardinality cap does not consume a global permit,
        // and a tracked user can still use its remaining per-user allowance.
        assert!(module.admit(first).is_ok());
    }

    #[test]
    fn expired_bucket_is_evicted_before_capacity_is_checked() {
        let module = AssistantModule::new(None, None, 1, Duration::ZERO, 1, 1);
        drop(module.admit(Uuid::new_v4()).unwrap());
        assert!(module.admit(Uuid::new_v4()).is_ok());
        assert_eq!(module.limits.requests.lock().unwrap().len(), 1);
    }
}

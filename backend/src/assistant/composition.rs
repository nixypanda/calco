use std::sync::Arc;

use axum::extract::FromRef;

use crate::AppState;
use crate::assistant::application::{AssistantError, FoodDraftService, FoodImageSanitizer};
use crate::assistant::infrastructure::llm::{
    Authentication, ChatError, OpenAiCompatibleClient, OpenAiCompatibleConfig,
};
use crate::assistant::infrastructure::{
    DEFAULT_MAX_CONCURRENT_REQUESTS, DEFAULT_MAX_TRACKED_USERS, DEFAULT_RATE_LIMIT_WINDOW,
    DEFAULT_REQUESTS_PER_WINDOW, FoodDraftLlmAdapter, NutritionCatalogVocabularyAdapter,
    RequestAdmissionService, SafeFoodImageSanitizer,
};
use crate::config::{AssistantAuthentication, AssistantConfig};
use crate::nutrition::module::CatalogModule;

#[derive(Clone)]
pub struct AssistantComponents {
    food_draft_service: Option<Arc<FoodDraftService>>,
    pub(crate) request_admission: Arc<RequestAdmissionService>,
}

impl AssistantComponents {
    pub fn from_config(
        config: &AssistantConfig,
        catalog: &CatalogModule,
    ) -> Result<Self, AssistantError> {
        let food_draft_service = match config {
            AssistantConfig::Disabled => None,
            AssistantConfig::Enabled(config) => {
                let authentication = match &config.authentication {
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
                        endpoint: config.endpoint.clone(),
                        model: config.model.as_str().to_owned(),
                        authentication,
                    })
                    .map_err(map_chat_startup_error)?,
                );
                let model = Arc::new(FoodDraftLlmAdapter::new(chat));
                let vocabulary = Arc::new(NutritionCatalogVocabularyAdapter::new(
                    catalog.services.clone(),
                ));
                let images = config.supports_images.then(|| {
                    Arc::new(SafeFoodImageSanitizer::new()) as Arc<dyn FoodImageSanitizer>
                });
                Some(Arc::new(FoodDraftService::new(
                    model,
                    vocabulary.clone(),
                    vocabulary,
                    images,
                )))
            }
        };
        Ok(Self::new(food_draft_service))
    }

    /// Dependency-injection seam for tests and alternate text-draft providers.
    pub fn from_food_draft_service(food_draft_service: Arc<FoodDraftService>) -> Self {
        Self::new(Some(food_draft_service))
    }

    pub fn disabled() -> Self {
        Self::new(None)
    }

    fn new(food_draft_service: Option<Arc<FoodDraftService>>) -> Self {
        Self {
            food_draft_service,
            request_admission: Arc::new(RequestAdmissionService::new(
                DEFAULT_REQUESTS_PER_WINDOW,
                DEFAULT_RATE_LIMIT_WINDOW,
                DEFAULT_MAX_CONCURRENT_REQUESTS,
                DEFAULT_MAX_TRACKED_USERS,
            )),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.food_draft_service.is_some()
    }

    pub fn supports_images(&self) -> bool {
        self.food_draft_service
            .as_ref()
            .is_some_and(|service| service.image_limits().is_some())
    }

    pub(crate) fn food_draft_service(&self) -> Option<Arc<FoodDraftService>> {
        self.food_draft_service.clone()
    }
}

fn map_chat_startup_error(_error: ChatError) -> AssistantError {
    AssistantError::Internal
}

impl FromRef<AppState> for AssistantComponents {
    fn from_ref(app: &AppState) -> Self {
        app.assistant.clone()
    }
}

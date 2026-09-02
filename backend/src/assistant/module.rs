use std::sync::Arc;

use async_trait::async_trait;
use axum::extract::FromRef;

use crate::AppState;
use crate::assistant::application::{
    FoodDraftPort, FoodDraftRequest, FoodImageLimits, FoodImageSanitizerPort,
};
use crate::assistant::domain::{AssistantError, FoodDraftTurn};
use crate::assistant::infrastructure::{
    NutritionCatalogVocabularyAdapter, OpenAiCompatibleFoodDraftModel, SafeFoodImageSanitizer,
};
use crate::config::AiRuntimeSettings;
use crate::nutrition::catalog::application::CatalogService;

/// Capability data intended for a future status endpoint. It contains no
/// endpoint, model, authentication mode, or credential material.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AssistantStatus {
    pub enabled: bool,
    pub supports_images: bool,
}

impl AssistantStatus {
    pub const fn disabled() -> Self {
        Self {
            enabled: false,
            supports_images: false,
        }
    }

    pub const fn enabled() -> Self {
        Self {
            enabled: true,
            supports_images: false,
        }
    }
}

/// Composition boundary for the assistant context.
///
/// Disabled operation is represented by a concrete use-case port that always
/// returns `AssistantError::Disabled`, rather than an `if enabled` condition
/// spread across future handlers and application code.
#[derive(Clone)]
pub struct AssistantModule {
    pub food_drafts: Arc<dyn FoodDraftPort>,
    pub images: Arc<dyn FoodImageSanitizerPort>,
    pub status: AssistantStatus,
}

impl FromRef<AppState> for AssistantModule {
    fn from_ref(app: &AppState) -> Self {
        app.assistant.clone()
    }
}

impl AssistantModule {
    pub fn disabled() -> Self {
        Self {
            food_drafts: Arc::new(DisabledFoodDraftPort),
            images: Arc::new(DisabledFoodImageSanitizer),
            status: AssistantStatus::disabled(),
        }
    }

    /// Constructs the assistant module from validated deployment settings and
    /// the catalog application seam.
    pub fn build(
        settings: &AiRuntimeSettings,
        catalog: Arc<CatalogService>,
    ) -> Result<Self, AssistantError> {
        let Some(settings) = settings.as_enabled() else {
            return Ok(Self::disabled());
        };

        let model = Arc::new(OpenAiCompatibleFoodDraftModel::new(settings)?);
        let vocabulary = Arc::new(NutritionCatalogVocabularyAdapter::new(catalog));
        let food_drafts = Arc::new(crate::assistant::application::FoodDraftService::new(
            model, vocabulary,
        ));

        Ok(Self {
            food_drafts,
            images: Arc::new(SafeFoodImageSanitizer),
            status: AssistantStatus {
                enabled: true,
                supports_images: settings.supports_images,
            },
        })
    }

    /// Test and alternate-composition seam for a text-only application port.
    pub fn enabled_with_port(food_drafts: Arc<dyn FoodDraftPort>) -> Self {
        Self {
            food_drafts,
            images: Arc::new(DisabledFoodImageSanitizer),
            status: AssistantStatus::enabled(),
        }
    }

    /// Test composition seam for the complete photo pipeline.
    pub fn enabled_with_images(food_drafts: Arc<dyn FoodDraftPort>) -> Self {
        Self {
            food_drafts,
            images: Arc::new(SafeFoodImageSanitizer),
            status: AssistantStatus {
                enabled: true,
                supports_images: true,
            },
        }
    }
}

struct DisabledFoodDraftPort;

struct DisabledFoodImageSanitizer;

#[async_trait]
impl FoodImageSanitizerPort for DisabledFoodImageSanitizer {
    fn limits(&self) -> FoodImageLimits {
        FoodImageLimits {
            max_images: 0,
            max_bytes_per_image: 0,
            max_total_bytes: 0,
        }
    }

    async fn sanitize(
        &self,
        _declared_mime_type: &str,
        _bytes: Vec<u8>,
    ) -> Result<crate::assistant::application::SanitizedFoodPhoto, AssistantError> {
        Err(AssistantError::Disabled)
    }
}

#[async_trait]
impl FoodDraftPort for DisabledFoodDraftPort {
    async fn draft(&self, _request: FoodDraftRequest) -> Result<FoodDraftTurn, AssistantError> {
        Err(AssistantError::Disabled)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::assistant::application::FoodDraftRequest;
    use crate::assistant::domain::{
        AssistantError, Conversation, ConversationRole, ConversationTurn, FoodDraftTurn,
    };

    use super::AssistantModule;

    #[tokio::test]
    async fn disabled_module_advertises_no_capabilities_and_rejects_drafts() {
        let module = AssistantModule::disabled();
        let request = FoodDraftRequest {
            conversation: Conversation::new(vec![
                ConversationTurn::new(ConversationRole::User, "dal rice").unwrap(),
            ])
            .unwrap(),
            photos: vec![],
        };

        assert!(!module.status.enabled);
        assert!(!module.status.supports_images);
        assert!(matches!(
            module.food_drafts.draft(request).await,
            Err(AssistantError::Disabled)
        ));
    }

    #[test]
    fn enabled_module_remains_text_only_until_image_transport_exists() {
        struct UnusedPort;

        #[async_trait::async_trait]
        impl crate::assistant::application::FoodDraftPort for UnusedPort {
            async fn draft(
                &self,
                _request: FoodDraftRequest,
            ) -> Result<FoodDraftTurn, AssistantError> {
                unreachable!("status does not call the food-draft port")
            }
        }

        let module = AssistantModule::enabled_with_port(Arc::new(UnusedPort));

        assert!(module.status.enabled);
        assert!(!module.status.supports_images);
    }
}

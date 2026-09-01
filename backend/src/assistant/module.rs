use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::application::{FoodDraftPort, FoodDraftRequest};
use crate::assistant::domain::{AssistantError, FoodDraftTurn};

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

    pub const fn enabled(supports_images: bool) -> Self {
        Self {
            enabled: true,
            supports_images,
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
    pub status: AssistantStatus,
}

impl AssistantModule {
    pub fn disabled() -> Self {
        Self {
            food_drafts: Arc::new(DisabledFoodDraftPort),
            status: AssistantStatus::disabled(),
        }
    }

    /// Constructs an enabled module only after composition has supplied a
    /// complete application service. The foundation intentionally does not
    /// construct provider adapters or read runtime configuration.
    pub fn enabled(food_drafts: Arc<dyn FoodDraftPort>, supports_images: bool) -> Self {
        Self {
            food_drafts,
            status: AssistantStatus::enabled(supports_images),
        }
    }
}

struct DisabledFoodDraftPort;

#[async_trait]
impl FoodDraftPort for DisabledFoodDraftPort {
    async fn draft(&self, _request: FoodDraftRequest) -> Result<FoodDraftTurn, AssistantError> {
        Err(AssistantError::Disabled)
    }
}

#[cfg(test)]
mod tests {
    use crate::assistant::application::FoodDraftRequest;
    use crate::assistant::domain::{
        AssistantError, Conversation, ConversationRole, ConversationTurn,
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
        };

        assert!(!module.status.enabled);
        assert!(!module.status.supports_images);
        assert!(matches!(
            module.food_drafts.draft(request).await,
            Err(AssistantError::Disabled)
        ));
    }
}

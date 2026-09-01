use async_trait::async_trait;

use crate::assistant::domain::{AssistantError, Conversation, FoodDraftTurn};

/// The user-supplied data for a single text-only custom-food drafting request.
/// Photo input will be added as a distinct transport-safe value in a later
/// slice, rather than making the model port depend on HTTP multipart types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoodDraftRequest {
    pub conversation: Conversation,
}

/// The provider-neutral request sent by the application service to a model.
/// Prompt and response-schema text are code-owned and never supplied by HTTP.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelDraftRequest {
    pub conversation: Conversation,
    pub system_prompt: String,
    pub response_schema: String,
}

/// Provider-neutral response content. Parsing and deterministic validation are
/// intentionally deferred to the application policy slice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelDraftResponse {
    pub content: String,
    pub usage: Option<ModelUsage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

/// Reference data translated from nutrition into assistant-owned terms.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FoodVocabulary {
    pub nutrients: Vec<SupportedNutrient>,
    pub units: Vec<SupportedUnit>,
    pub required_nutrient_codes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupportedNutrient {
    pub code: String,
    pub name: String,
    pub unit: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupportedUnit {
    pub code: String,
    pub name: String,
    pub kind: String,
}

/// Provider seam. Implementations own all remote-protocol and credential
/// details; callers only receive neutral assistant content.
#[async_trait]
pub trait FoodDraftModelPort: Send + Sync {
    async fn generate(
        &self,
        request: ModelDraftRequest,
    ) -> Result<ModelDraftResponse, AssistantError>;
}

/// Nutrition anti-corruption seam. It supplies vocabulary only and exposes no
/// catalog write operation to the assistant context.
#[async_trait]
#[allow(
    dead_code,
    reason = "the nutrition vocabulary adapter and draft service arrive in the next slice"
)]
pub trait FoodVocabularyPort: Send + Sync {
    async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError>;
}

/// Application use-case seam used by HTTP and the module. A future
/// `FoodDraftService` will implement it after prompt/schema validation exists.
#[async_trait]
pub trait FoodDraftPort: Send + Sync {
    async fn draft(&self, request: FoodDraftRequest) -> Result<FoodDraftTurn, AssistantError>;
}

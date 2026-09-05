use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::domain::{AssistantError, Conversation, FoodDraftTurn};

#[derive(Clone, PartialEq, Eq)]
pub struct FoodDraftRequest {
    pub conversation: Conversation,
    pub photos: Vec<SanitizedFoodPhoto>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SanitizedFoodPhoto {
    pub mime_type: FoodPhotoMimeType,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoodPhotoMimeType {
    Jpeg,
    Png,
    Webp,
}

impl FoodPhotoMimeType {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Jpeg => "image/jpeg",
            Self::Png => "image/png",
            Self::Webp => "image/webp",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FoodImageLimits {
    pub max_images: usize,
    pub max_bytes_per_image: usize,
    pub max_total_bytes: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoodImageError {
    Empty,
    UnsupportedType,
    TypeMismatch,
    InvalidData,
    DimensionsTooLarge,
    EncodedTooLarge,
    Internal,
}

#[async_trait]
pub trait FoodImageSanitizer: Send + Sync {
    fn limits(&self) -> FoodImageLimits;

    async fn sanitize(
        &self,
        declared_mime_type: &str,
        bytes: Vec<u8>,
    ) -> Result<SanitizedFoodPhoto, FoodImageError>;
}

#[derive(Clone, PartialEq, Eq)]
pub struct FoodDraftResult {
    pub turn: FoodDraftTurn,
    pub usage: Option<ModelUsage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FoodVocabulary {
    pub nutrients: Vec<SupportedNutrient>,
    pub default_units: Vec<SupportedUnit>,
    pub serving_units: Vec<SupportedUnit>,
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

/// Outbound application boundary for producing a trusted CalCo food draft.
#[async_trait]
pub trait FoodDraftModel: Send + Sync {
    async fn generate(
        &self,
        request: &FoodDraftRequest,
        vocabulary: &FoodVocabulary,
    ) -> Result<FoodDraftResult, AssistantError>;
}

#[async_trait]
pub trait FoodVocabularyPort: Send + Sync {
    async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError>;
}

pub struct FoodDraftService {
    model: Arc<dyn FoodDraftModel>,
    vocabulary: Arc<dyn FoodVocabularyPort>,
}

impl FoodDraftService {
    pub fn new(model: Arc<dyn FoodDraftModel>, vocabulary: Arc<dyn FoodVocabularyPort>) -> Self {
        Self { model, vocabulary }
    }

    pub async fn draft(
        &self,
        request: FoodDraftRequest,
    ) -> Result<FoodDraftResult, AssistantError> {
        let vocabulary = self.vocabulary.supported_vocabulary().await?;
        self.model.generate(&request, &vocabulary).await
    }
}

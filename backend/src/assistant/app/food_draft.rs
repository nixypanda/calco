use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::domain::{
    Conversation, ConversationRole, FoodDraft, FoodDraftPolicy, FoodDraftPurpose, FoodDraftTurn,
};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AssistantError {
    #[error("assistant input is invalid")]
    InvalidInput,
    #[error("assistant model is unavailable")]
    ModelUnavailable,
    #[error("assistant model returned an invalid response")]
    InvalidModelResponse,
    #[error("assistant operation failed")]
    Internal,
}

#[derive(Clone, PartialEq, Eq)]
pub struct FoodDraftRequest {
    pub purpose: FoodDraftPurpose,
    pub conversation: Conversation,
    pub photos: Vec<SanitizedFoodPhoto>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct FoodDraftModelRequest {
    pub purpose: FoodDraftPurpose,
    pub turns: Vec<FoodDraftModelTurn>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct FoodDraftModelTurn {
    pub role: ConversationRole,
    pub text: String,
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
pub enum ImageError {
    NotSupported,
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
    ) -> Result<SanitizedFoodPhoto, ImageError>;
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

impl FoodVocabulary {
    fn draft_policy(&self) -> FoodDraftPolicy {
        FoodDraftPolicy::new(
            self.nutrients
                .iter()
                .map(|nutrient| (nutrient.code.clone(), nutrient.unit.clone())),
            self.serving_units.iter().map(|unit| unit.code.clone()),
            self.required_nutrient_codes.iter().cloned(),
        )
    }
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

/// Outbound application boundary for proposing a CalCo food draft.
///
/// Implementations translate provider output into domain types. The application
/// service remains responsible for validating the proposal against the current
/// CalCo vocabulary before returning it to a caller.
#[async_trait]
pub trait FoodDraftModel: Send + Sync {
    async fn generate(
        &self,
        request: &FoodDraftModelRequest,
        vocabulary: &FoodVocabulary,
    ) -> Result<FoodDraftResult, AssistantError>;
}

#[async_trait]
pub trait FoodVocabularyPort: Send + Sync {
    async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError>;
}

#[async_trait]
pub trait FoodDraftAcceptancePort: Send + Sync {
    async fn validate_draft(&self, draft: &FoodDraft) -> Result<(), AssistantError>;
}

pub struct FoodDraftService {
    model: Arc<dyn FoodDraftModel>,
    vocabulary: Arc<dyn FoodVocabularyPort>,
    acceptance: Arc<dyn FoodDraftAcceptancePort>,
    images: Option<Arc<dyn FoodImageSanitizer>>,
}

impl FoodDraftService {
    pub fn new(
        model: Arc<dyn FoodDraftModel>,
        vocabulary: Arc<dyn FoodVocabularyPort>,
        acceptance: Arc<dyn FoodDraftAcceptancePort>,
        images: Option<Arc<dyn FoodImageSanitizer>>,
    ) -> Self {
        Self {
            model,
            vocabulary,
            acceptance,
            images,
        }
    }

    pub fn image_limits(&self) -> Option<FoodImageLimits> {
        self.images.as_ref().map(|images| images.limits())
    }

    pub async fn sanitize_photo(
        &self,
        declared_mime_type: &str,
        bytes: Vec<u8>,
    ) -> Result<SanitizedFoodPhoto, ImageError> {
        let images = self.images.as_ref().ok_or(ImageError::NotSupported)?;
        images.sanitize(declared_mime_type, bytes).await
    }

    pub async fn draft(
        &self,
        request: FoodDraftRequest,
    ) -> Result<FoodDraftResult, AssistantError> {
        let vocabulary = self.vocabulary.supported_vocabulary().await?;
        let request = prepare_model_request(request)?;
        let result = self.model.generate(&request, &vocabulary).await?;
        if let Err(error) = vocabulary
            .draft_policy()
            .validate(request.purpose, &result.turn)
        {
            tracing::error!(
                purpose = ?request.purpose,
                turn = ?result.turn,
                error = %error,
                "assistant response failed vocabulary validation"
            );
            return Err(AssistantError::InvalidModelResponse);
        }
        if let FoodDraftTurn::DraftReady { draft, .. } = &result.turn {
            self.acceptance.validate_draft(draft).await?;
        }
        Ok(result)
    }
}

fn prepare_model_request(
    request: FoodDraftRequest,
) -> Result<FoodDraftModelRequest, AssistantError> {
    let purpose = request.purpose;
    let mut turns = request
        .conversation
        .turns()
        .iter()
        .map(|turn| FoodDraftModelTurn {
            role: turn.role(),
            text: turn.text().to_owned(),
            photos: vec![],
        })
        .collect::<Vec<_>>();
    if !request.photos.is_empty() {
        let latest_user = turns
            .iter_mut()
            .rfind(|turn| turn.role == ConversationRole::User)
            .ok_or(AssistantError::InvalidInput)?;
        latest_user.photos = request.photos;
    }
    Ok(FoodDraftModelRequest { purpose, turns })
}

#[cfg(test)]
mod tests {
    use rust_decimal::Decimal;

    use super::*;
    use crate::assistant::domain::{DraftNutrient, FoodDraft, FoodDraftBuilder, FoodDraftTurn};

    struct StubModel {
        result: FoodDraftResult,
    }

    #[async_trait]
    impl FoodDraftModel for StubModel {
        async fn generate(
            &self,
            _request: &FoodDraftModelRequest,
            _vocabulary: &FoodVocabulary,
        ) -> Result<FoodDraftResult, AssistantError> {
            Ok(self.result.clone())
        }
    }

    struct StubVocabulary {
        value: FoodVocabulary,
    }

    struct AcceptAllDrafts;

    #[async_trait]
    impl FoodDraftAcceptancePort for AcceptAllDrafts {
        async fn validate_draft(&self, _draft: &FoodDraft) -> Result<(), AssistantError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FoodVocabularyPort for StubVocabulary {
        async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError> {
            Ok(self.value.clone())
        }
    }

    fn request() -> FoodDraftRequest {
        FoodDraftRequest {
            purpose: FoodDraftPurpose::CustomFood,
            conversation: Conversation::new(vec![
                crate::assistant::domain::ConversationTurn::new(
                    crate::assistant::domain::ConversationRole::User,
                    "dal",
                )
                .unwrap(),
            ])
            .unwrap(),
            photos: vec![],
        }
    }

    #[tokio::test]
    async fn ad_hoc_service_rejects_a_draft_without_a_suggested_portion() {
        let draft = FoodDraftBuilder::new("Dal")
            .nutrients([DraftNutrient::new("ENERGY_KCAL".into(), Decimal::ONE).unwrap()])
            .build()
            .unwrap();
        let service = FoodDraftService::new(
            Arc::new(StubModel {
                result: FoodDraftResult {
                    turn: FoodDraftTurn::ready("Review", draft, vec![]).unwrap(),
                    usage: None,
                },
            }),
            Arc::new(StubVocabulary {
                value: FoodVocabulary {
                    nutrients: vec![SupportedNutrient {
                        code: "ENERGY_KCAL".into(),
                        name: "Energy".into(),
                        unit: "kcal".into(),
                    }],
                    required_nutrient_codes: vec!["ENERGY_KCAL".into()],
                    ..FoodVocabulary::default()
                },
            }),
            Arc::new(AcceptAllDrafts),
            None,
        );
        let mut request = request();
        request.purpose = FoodDraftPurpose::AdHocLog;

        assert!(matches!(
            service.draft(request).await,
            Err(AssistantError::InvalidModelResponse)
        ));
    }

    #[test]
    fn model_request_attaches_photos_to_the_latest_user_turn() {
        let conversation = Conversation::new(vec![
            crate::assistant::domain::ConversationTurn::new(ConversationRole::User, "first")
                .unwrap(),
            crate::assistant::domain::ConversationTurn::new(
                ConversationRole::Assistant,
                "question",
            )
            .unwrap(),
            crate::assistant::domain::ConversationTurn::new(ConversationRole::User, "latest")
                .unwrap(),
        ])
        .unwrap();
        let photo = SanitizedFoodPhoto {
            mime_type: FoodPhotoMimeType::Jpeg,
            bytes: vec![1, 2, 3],
        };

        let prepared = prepare_model_request(FoodDraftRequest {
            purpose: FoodDraftPurpose::CustomFood,
            conversation,
            photos: vec![photo.clone()],
        })
        .unwrap();

        assert!(prepared.turns[0].photos.is_empty());
        assert!(prepared.turns[1].photos.is_empty());
        assert_eq!(prepared.turns[2].photos, vec![photo]);
    }
}

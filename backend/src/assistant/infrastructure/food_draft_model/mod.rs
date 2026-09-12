mod model_request_prompt;
mod model_response;
mod model_response_schema;

use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::application::{
    AssistantError, FoodDraftModel, FoodDraftModelRequest, FoodDraftResult, FoodVocabulary,
    ModelUsage,
};
use crate::assistant::domain::ConversationRole;
use crate::assistant::infrastructure::llm::{
    ChatClient, ChatError, ChatImage, ChatMessage, ChatRequest, ChatResponse, ChatRole,
    ResponseFormat, TokenUsage,
};

use model_request_prompt::build_system_prompt;
use model_response::parse_model_turn;
use model_response_schema::food_draft_response_schema;

const MAX_OUTPUT_TOKENS: u32 = 16_384;

pub struct FoodDraftModelAdapter {
    chat: Arc<dyn ChatClient>,
}

impl FoodDraftModelAdapter {
    pub(crate) fn new(chat: Arc<dyn ChatClient>) -> Self {
        Self { chat }
    }
}

#[async_trait]
impl FoodDraftModel for FoodDraftModelAdapter {
    async fn generate(
        &self,
        request: &FoodDraftModelRequest,
        vocabulary: &FoodVocabulary,
    ) -> Result<FoodDraftResult, AssistantError> {
        let mut messages = vec![ChatMessage {
            role: ChatRole::System,
            content: build_system_prompt(vocabulary),
            images: vec![],
        }];
        messages.extend(request.turns.iter().map(|turn| {
            ChatMessage {
                role: match turn.role {
                    ConversationRole::User => ChatRole::User,
                    ConversationRole::Assistant => ChatRole::Assistant,
                },
                content: turn.text.clone(),
                images: turn
                    .photos
                    .iter()
                    .map(|photo| ChatImage {
                        mime_type: photo.mime_type.as_str(),
                        bytes: photo.bytes.clone(),
                    })
                    .collect(),
            }
        }));
        let response: ChatResponse = self
            .chat
            .complete(ChatRequest {
                messages,
                response_format: ResponseFormat::JsonSchema {
                    name: "food_draft_response".into(),
                    schema: food_draft_response_schema(vocabulary),
                },
                max_output_tokens: MAX_OUTPUT_TOKENS,
            })
            .await
            .map_err(map_chat_error)?;
        let turn = parse_model_turn(&response.content).inspect_err(|_| {
            tracing::error!(
                provider_response = %response.content,
                "provider response failed food draft validation"
            );
        })?;
        Ok(FoodDraftResult {
            turn,
            usage: response.usage.map(map_usage),
        })
    }
}

fn map_usage(usage: TokenUsage) -> ModelUsage {
    ModelUsage {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
    }
}

fn map_chat_error(error: ChatError) -> AssistantError {
    match error {
        ChatError::Unavailable => AssistantError::ModelUnavailable,
        ChatError::InvalidResponse => AssistantError::InvalidModelResponse,
        ChatError::Internal => AssistantError::Internal,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::assistant::application::{
        FoodDraftModelTurn, FoodPhotoMimeType, SanitizedFoodPhoto,
    };
    use crate::assistant::application::{SupportedNutrient, SupportedUnit};
    use crate::assistant::domain::FoodDraftTurn;

    struct FakeChat {
        request: Mutex<Option<ChatRequest>>,
    }

    #[async_trait]
    impl ChatClient for FakeChat {
        async fn complete(&self, request: ChatRequest) -> Result<ChatResponse, ChatError> {
            *self.request.lock().unwrap() = Some(request);
            Ok(ChatResponse {
                content: r#"{"assistant_message":"How many grams?","status":"needs_clarification","draft":null,"warnings":[]}"#.into(),
                usage: Some(TokenUsage {
                    input_tokens: Some(11),
                    output_tokens: Some(4),
                }),
            })
        }
    }

    #[tokio::test]
    async fn translates_calco_inputs_and_returns_only_a_trusted_result() {
        let chat = Arc::new(FakeChat {
            request: Mutex::new(None),
        });
        let model = FoodDraftModelAdapter::new(chat.clone());
        let request = FoodDraftModelRequest {
            turns: vec![FoodDraftModelTurn {
                role: ConversationRole::User,
                text: "one bowl of dal".into(),
                photos: vec![],
            }],
        };
        let vocabulary = FoodVocabulary {
            nutrients: vec![SupportedNutrient {
                code: "ENERGY_KCAL".into(),
                name: "Energy".into(),
                unit: "kcal".into(),
            }],
            default_units: vec![SupportedUnit {
                code: "g".into(),
                name: "Gram".into(),
                kind: "mass".into(),
            }],
            serving_units: vec![],
            required_nutrient_codes: vec!["ENERGY_KCAL".into()],
        };

        let result = model.generate(&request, &vocabulary).await.unwrap();

        assert!(matches!(
            result.turn,
            FoodDraftTurn::NeedsClarification { .. }
        ));
        assert_eq!(result.usage.unwrap().input_tokens, Some(11));
        let request = chat.request.lock().unwrap().take().unwrap();
        assert_eq!(request.messages[1].content, "one bowl of dal");
        let ResponseFormat::JsonSchema { schema, .. } = request.response_format;
        assert_eq!(
            schema["properties"]["draft"]["oneOf"][1]["properties"]["default_unit"]["enum"],
            serde_json::json!(["g", null])
        );
    }

    #[tokio::test]
    async fn translates_explicit_turn_photo_attachments() {
        let chat = Arc::new(FakeChat {
            request: Mutex::new(None),
        });
        let model = FoodDraftModelAdapter::new(chat.clone());
        let photo = SanitizedFoodPhoto {
            mime_type: FoodPhotoMimeType::Jpeg,
            bytes: vec![1, 2, 3],
        };
        let request = FoodDraftModelRequest {
            turns: vec![
                FoodDraftModelTurn {
                    role: ConversationRole::User,
                    text: "first description".into(),
                    photos: vec![],
                },
                FoodDraftModelTurn {
                    role: ConversationRole::Assistant,
                    text: "clarifying question".into(),
                    photos: vec![],
                },
                FoodDraftModelTurn {
                    role: ConversationRole::User,
                    text: "this is the pictured plate".into(),
                    photos: vec![photo],
                },
            ],
        };

        model
            .generate(&request, &FoodVocabulary::default())
            .await
            .unwrap();

        let request = chat.request.lock().unwrap().take().unwrap();
        assert!(request.messages[1].images.is_empty());
        assert!(request.messages[2].images.is_empty());
        assert_eq!(request.messages[3].images[0].mime_type, "image/jpeg");
        assert_eq!(request.messages[3].images[0].bytes, vec![1, 2, 3]);
    }
}

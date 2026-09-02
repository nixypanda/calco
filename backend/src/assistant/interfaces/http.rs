//! Authenticated HTTP transport for transient, text-only food drafts.
//!
//! This layer deliberately does not know provider details, prompts, runtime
//! settings, or catalog writes. It parses a tightly bounded multipart request,
//! delegates once to the application port, and serializes a draft for explicit
//! user review in the ordinary custom-food flow.

use axum::{
    Router,
    extract::{DefaultBodyLimit, Multipart, State, multipart::MultipartRejection},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
    routing::{get, post},
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::assistant::application::{FoodDraftRequest, FoodImageLimits};
use crate::assistant::domain::{
    AssistantError, Conversation, ConversationRole, ConversationTurn, DraftStatus, FoodDraft,
    FoodDraftTurn,
};
use crate::assistant::module::{AssistantModule, AssistantStatus};
use crate::auth::interfaces::http::AuthUser;
use crate::nutrition::interfaces::{ErrorBody, ErrorResponse};

/// The aggregate body leaves room for a bounded conversation and multipart
/// envelope in addition to the bounded raw image total.
const MAX_MULTIPART_BODY_BYTES: usize = 13 * 1024 * 1024;
const MAX_CONVERSATION_FIELD_BYTES: usize = 320 * 1024;
const MAX_MULTIPART_FIELDS: usize = 5;

pub fn assistant_routes(state: AppState) -> Router {
    Router::new()
        .route("/ai/food-assistant/status", get(status_handler))
        .route("/ai/custom-food/draft", post(draft_handler))
        .layer(DefaultBodyLimit::max(MAX_MULTIPART_BODY_BYTES))
        .with_state(state)
}

#[derive(Serialize)]
struct AssistantStatusResponse {
    enabled: bool,
    supports_images: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConversationDto {
    turns: Vec<ConversationTurnDto>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConversationTurnDto {
    role: ConversationRoleDto,
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ConversationRoleDto {
    User,
    Assistant,
}

#[derive(Serialize)]
struct FoodDraftTurnResponse {
    assistant_message: String,
    status: DraftStatusDto,
    draft: Option<FoodDraftDto>,
    warnings: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum DraftStatusDto {
    NeedsClarification,
    DraftReady,
}

#[derive(Serialize)]
struct FoodDraftDto {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    serving_size_g: Option<Decimal>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<DraftNutrientDto>,
    servings: Vec<DraftServingDto>,
}

#[derive(Serialize)]
struct DraftNutrientDto {
    code: String,
    amount_per_100g: Decimal,
}

#[derive(Serialize)]
struct DraftServingDto {
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

async fn status_handler(
    _user: AuthUser,
    State(assistant): State<AssistantModule>,
) -> Json<AssistantStatusResponse> {
    Json(status_to_response(assistant.status))
}

async fn draft_handler(
    _user: AuthUser,
    State(assistant): State<AssistantModule>,
    multipart: Result<Multipart, MultipartRejection>,
) -> Result<Json<FoodDraftTurnResponse>, AssistantHttpError> {
    let multipart = multipart.map_err(|_| AssistantHttpError::invalid_multipart())?;
    let request = parse_draft_request(multipart, &assistant).await?;
    let turn = assistant
        .food_drafts
        .draft(request)
        .await
        .map_err(AssistantHttpError::from)?;

    Ok(Json(turn_to_response(turn)))
}

fn status_to_response(status: AssistantStatus) -> AssistantStatusResponse {
    AssistantStatusResponse {
        enabled: status.enabled,
        supports_images: status.supports_images,
    }
}

async fn parse_draft_request(
    mut multipart: Multipart,
    assistant: &AssistantModule,
) -> Result<FoodDraftRequest, AssistantHttpError> {
    let mut fields = 0_usize;
    let mut conversation = None;
    let mut photos = Vec::new();
    let mut raw_photo_bytes = 0_usize;
    let mut sanitized_photo_bytes = 0_usize;
    let photo_limits = assistant.images.limits();

    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(AssistantHttpError::from_multipart)?
    {
        fields += 1;
        if fields > MAX_MULTIPART_FIELDS {
            return Err(AssistantHttpError::validation(
                "exactly one conversation and up to four photo fields are allowed",
            ));
        }

        let field_name = field.name().map(str::to_owned);
        match field_name.as_deref() {
            Some("conversation") if field.file_name().is_none() && conversation.is_none() => {
                conversation = Some(read_conversation_field(&mut field).await?);
            }
            Some("conversation") => {
                return Err(AssistantHttpError::validation(
                    "conversation must appear exactly once and cannot be a file",
                ));
            }
            Some("photos") => {
                if !assistant.status.supports_images {
                    return Err(AssistantHttpError::validation(
                        "photos are unavailable for this food assistant",
                    ));
                }
                if field.file_name().is_none() {
                    return Err(AssistantHttpError::validation("each photo must be a file"));
                }
                if photos.len() == photo_limits.max_images {
                    return Err(AssistantHttpError::validation(
                        "at most four photos are allowed",
                    ));
                }
                let declared_mime_type = field
                    .content_type()
                    .map(ToString::to_string)
                    .ok_or_else(|| AssistantHttpError::validation("photo MIME type is required"))?;
                let bytes =
                    read_photo_field(&mut field, &mut raw_photo_bytes, photo_limits).await?;
                let photo = assistant
                    .images
                    .sanitize(&declared_mime_type, bytes)
                    .await
                    .map_err(AssistantHttpError::from)?;
                if photo.bytes.len()
                    > photo_limits
                        .max_total_bytes
                        .saturating_sub(sanitized_photo_bytes)
                {
                    return Err(AssistantHttpError::payload_too_large());
                }
                sanitized_photo_bytes += photo.bytes.len();
                photos.push(photo);
            }
            _ => {
                return Err(AssistantHttpError::validation(
                    "unknown multipart field in food-draft request",
                ));
            }
        }
    }

    let conversation = conversation.ok_or_else(|| {
        AssistantHttpError::validation("conversation is required in the multipart request")
    })?;
    let conversation: ConversationDto = serde_json::from_slice(&conversation)
        .map_err(|_| AssistantHttpError::validation("conversation must be valid JSON"))?;
    let turns = conversation
        .turns
        .into_iter()
        .map(|turn| {
            ConversationTurn::new(
                match turn.role {
                    ConversationRoleDto::User => ConversationRole::User,
                    ConversationRoleDto::Assistant => ConversationRole::Assistant,
                },
                turn.text,
            )
        })
        .collect::<Result<Vec<_>, _>>()
        .map_err(AssistantHttpError::from)?;

    Ok(FoodDraftRequest {
        conversation: Conversation::new(turns).map_err(AssistantHttpError::from)?,
        photos,
    })
}

async fn read_conversation_field(
    field: &mut axum::extract::multipart::Field<'_>,
) -> Result<Vec<u8>, AssistantHttpError> {
    let mut bytes = Vec::new();
    while let Some(chunk) = field
        .chunk()
        .await
        .map_err(AssistantHttpError::from_multipart)?
    {
        if chunk.len() > MAX_CONVERSATION_FIELD_BYTES.saturating_sub(bytes.len()) {
            return Err(AssistantHttpError::payload_too_large());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn read_photo_field(
    field: &mut axum::extract::multipart::Field<'_>,
    raw_photo_bytes: &mut usize,
    limits: FoodImageLimits,
) -> Result<Vec<u8>, AssistantHttpError> {
    let mut bytes = Vec::new();
    while let Some(chunk) = field
        .chunk()
        .await
        .map_err(AssistantHttpError::from_multipart)?
    {
        if chunk.len() > limits.max_bytes_per_image.saturating_sub(bytes.len())
            || chunk.len() > limits.max_total_bytes.saturating_sub(*raw_photo_bytes)
        {
            return Err(AssistantHttpError::payload_too_large());
        }
        bytes.extend_from_slice(&chunk);
        *raw_photo_bytes += chunk.len();
    }
    if bytes.is_empty() {
        return Err(AssistantHttpError::validation("photo cannot be empty"));
    }
    Ok(bytes)
}

fn turn_to_response(turn: FoodDraftTurn) -> FoodDraftTurnResponse {
    FoodDraftTurnResponse {
        assistant_message: turn.assistant_message,
        status: match turn.status {
            DraftStatus::NeedsClarification => DraftStatusDto::NeedsClarification,
            DraftStatus::DraftReady => DraftStatusDto::DraftReady,
        },
        draft: turn.draft.map(draft_to_response),
        warnings: turn.warnings,
    }
}

fn draft_to_response(draft: FoodDraft) -> FoodDraftDto {
    FoodDraftDto {
        name: draft.name,
        brand: draft.brand,
        categories: draft.categories,
        serving_size_g: draft.serving_size_g,
        default_quantity: draft.default_quantity,
        default_unit: draft.default_unit,
        nutrients: draft
            .nutrients
            .into_iter()
            .map(|nutrient| DraftNutrientDto {
                code: nutrient.code,
                amount_per_100g: nutrient.amount_per_100g,
            })
            .collect(),
        servings: draft
            .servings
            .into_iter()
            .map(|serving| DraftServingDto {
                label: serving.label,
                quantity: serving.quantity,
                unit: serving.unit,
                grams: serving.grams,
            })
            .collect(),
    }
}

struct AssistantHttpError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl AssistantHttpError {
    fn validation(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "validation",
            message: message.into(),
        }
    }

    fn invalid_multipart() -> Self {
        Self::validation("request must use multipart/form-data")
    }

    fn payload_too_large() -> Self {
        Self {
            status: StatusCode::PAYLOAD_TOO_LARGE,
            code: "payload_too_large",
            message: "food-draft request is too large".into(),
        }
    }

    fn from_multipart(error: axum::extract::multipart::MultipartError) -> Self {
        if error.status() == StatusCode::PAYLOAD_TOO_LARGE {
            Self::payload_too_large()
        } else {
            Self::validation("invalid multipart food-draft request")
        }
    }
}

impl From<AssistantError> for AssistantHttpError {
    fn from(error: AssistantError) -> Self {
        match error {
            AssistantError::Disabled => Self {
                status: StatusCode::SERVICE_UNAVAILABLE,
                code: "assistant_disabled",
                message: "food assistant is disabled".into(),
            },
            AssistantError::Validation(message) => Self::validation(message),
            AssistantError::ModelUnavailable => Self {
                status: StatusCode::SERVICE_UNAVAILABLE,
                code: "model_unavailable",
                message: "food assistant is temporarily unavailable; retry later".into(),
            },
            AssistantError::InvalidModelResponse => Self {
                status: StatusCode::BAD_GATEWAY,
                code: "invalid_model_response",
                message: "food assistant returned an invalid response".into(),
            },
            AssistantError::Internal => {
                tracing::error!("food-assistant request failed");
                Self {
                    status: StatusCode::INTERNAL_SERVER_ERROR,
                    code: "internal",
                    message: "internal server error".into(),
                }
            }
        }
    }
}

impl IntoResponse for AssistantHttpError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(ErrorResponse {
                error: ErrorBody {
                    code: self.code.to_owned(),
                    message: self.message,
                },
            }),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assistant_error_mapping_never_exposes_provider_details() {
        let error = AssistantHttpError::from(AssistantError::ModelUnavailable);
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.code, "model_unavailable");
        assert_eq!(
            error.message,
            "food assistant is temporarily unavailable; retry later"
        );
    }

    #[test]
    fn status_response_has_only_ui_capabilities() {
        let response = status_to_response(AssistantStatus::disabled());
        let value = serde_json::to_value(response).unwrap();
        assert_eq!(
            value,
            serde_json::json!({ "enabled": false, "supports_images": false })
        );
    }

    #[test]
    fn http_interface_has_no_catalog_or_provider_write_path() {
        let source = include_str!("http.rs");

        // Keep the source literals split so this test does not trigger on its
        // own assertions.
        for forbidden in [
            concat!("Catalog", "Service"),
            concat!("create_custom", "_food"),
            concat!("Product", "Repository"),
            concat!("req", "west"),
            concat!("build_system", "_prompt"),
        ] {
            assert!(
                !source.contains(forbidden),
                "HTTP interface must not contain {forbidden}"
            );
        }
    }
}

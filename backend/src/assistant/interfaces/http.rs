//! Authenticated HTTP multipart transport for transient food drafts.

use std::time::Instant;

use axum::extract::multipart::{Field, MultipartRejection};
use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::assistant::application::{
    AssistantError, FoodDraftRequest, FoodDraftService, FoodImageError, FoodImageLimits, ModelUsage,
};
use crate::assistant::domain::{
    Conversation, ConversationRole, ConversationTurn, ConversationValidationError, FoodDraft,
    FoodDraftTurn,
};
use crate::assistant::module::{AdmissionError, AssistantModule};
use crate::auth::interfaces::http::AuthUser;

const MAX_REQUEST_BYTES: usize = 41 * 1024 * 1024;
const MAX_CONVERSATION_FIELD_BYTES: usize = 92 * 1024;
const MAX_MULTIPART_FIELDS: usize = 5;

pub fn assistant_routes(state: AppState) -> Router {
    Router::new()
        .route("/ai/food-assistant/status", get(status_handler))
        .route("/ai/custom-food/draft", post(draft_handler))
        .layer(DefaultBodyLimit::max(MAX_REQUEST_BYTES))
        .with_state(state)
}

#[derive(Serialize)]
struct AssistantStatusResponse {
    enabled: bool,
    supports_images: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConversationRequest {
    turns: Vec<ConversationTurnRequest>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConversationTurnRequest {
    role: ConversationRoleRequest,
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ConversationRoleRequest {
    User,
    Assistant,
}

#[derive(Serialize)]
struct AssistantDraftResponse {
    assistant_message: String,
    status: DraftStatusResponse,
    draft: Option<FoodDraftResponse>,
    warnings: Vec<String>,
}

#[derive(Serialize)]
struct FoodDraftResponse {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<DraftNutrientResponse>,
    servings: Vec<DraftServingResponse>,
}

#[derive(Serialize)]
struct DraftNutrientResponse {
    code: String,
    amount_per_100g: Decimal,
}

#[derive(Serialize)]
struct DraftServingResponse {
    unit: String,
    grams_per_unit: Decimal,
}

impl From<FoodDraft> for FoodDraftResponse {
    fn from(draft: FoodDraft) -> Self {
        Self {
            name: draft.name().to_owned(),
            brand: draft.brand().map(str::to_owned),
            categories: draft.categories().to_vec(),
            default_quantity: draft.default_quantity(),
            default_unit: draft.default_unit().map(str::to_owned),
            nutrients: draft
                .nutrients()
                .iter()
                .map(|nutrient| DraftNutrientResponse {
                    code: nutrient.code().to_owned(),
                    amount_per_100g: nutrient.amount_per_100g(),
                })
                .collect(),
            servings: draft
                .servings()
                .iter()
                .map(|serving| DraftServingResponse {
                    unit: serving.unit().to_owned(),
                    grams_per_unit: serving.grams_per_unit(),
                })
                .collect(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum DraftStatusResponse {
    NeedsClarification,
    DraftReady,
}

#[derive(Serialize)]
struct ErrorResponse {
    error: ErrorBody,
}

#[derive(Serialize)]
struct ErrorBody {
    code: &'static str,
    message: &'static str,
}

async fn status_handler(
    _auth: AuthUser,
    State(module): State<AssistantModule>,
) -> Json<AssistantStatusResponse> {
    Json(AssistantStatusResponse {
        enabled: module.is_enabled(),
        supports_images: module.supports_images(),
    })
}

async fn draft_handler(
    AuthUser(user): AuthUser,
    State(module): State<AssistantModule>,
    multipart: Result<Multipart, MultipartRejection>,
) -> Response {
    let started = Instant::now();
    let result = draft(module, user.id, multipart).await;
    if let Some(reason) = result.rejection_reason {
        tracing::warn!(
            user_id = %user.id,
            latency_ms = started.elapsed().as_millis() as u64,
            outcome = result.outcome,
            reason,
            "assistant draft request rejected"
        );
    } else {
        tracing::info!(
            user_id = %user.id,
            latency_ms = started.elapsed().as_millis() as u64,
            outcome = result.outcome,
            input_tokens = result.usage.and_then(|value| value.input_tokens),
            output_tokens = result.usage.and_then(|value| value.output_tokens),
            "assistant draft request completed"
        );
    }
    result.response
}

struct DraftHttpResult {
    response: Response,
    outcome: &'static str,
    usage: Option<ModelUsage>,
    rejection_reason: Option<&'static str>,
}

async fn draft(
    module: AssistantModule,
    user_id: uuid::Uuid,
    multipart: Result<Multipart, MultipartRejection>,
) -> DraftHttpResult {
    let Some(service) = module.service() else {
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "assistant_disabled",
            "assistant is unavailable",
        );
    };

    // Admit immediately after authentication and the enabled check, before
    // buffering attacker-controlled multipart fields.
    let _permit = match module.admit(user_id) {
        Ok(permit) => permit,
        Err(AdmissionError::RateLimited {
            retry_after_seconds,
        }) => return throttled("rate_limited", "too many requests", retry_after_seconds),
        Err(AdmissionError::Busy) => return throttled("assistant_busy", "assistant is busy", 1),
        Err(AdmissionError::Internal) => return assistant_failure(AssistantError::Internal),
    };

    let multipart = match multipart {
        Ok(value) => value,
        Err(error) if error.status() == StatusCode::PAYLOAD_TOO_LARGE => {
            return payload_too_large();
        }
        Err(_) => {
            return rejected(
                StatusCode::BAD_REQUEST,
                "invalid_multipart",
                "request must use multipart/form-data",
                "multipart/form-data extractor rejected request",
            );
        }
    };
    let request = match parse_multipart(multipart, &service).await {
        Ok(value) => value,
        Err(error) => return error,
    };

    match service.draft(request).await {
        Ok(result) => DraftHttpResult {
            response: Json(turn_to_response(result.turn)).into_response(),
            outcome: "success",
            usage: result.usage,
            rejection_reason: None,
        },
        Err(error) => assistant_failure(error),
    }
}

async fn parse_multipart(
    mut multipart: Multipart,
    service: &FoodDraftService,
) -> Result<FoodDraftRequest, DraftHttpResult> {
    let mut fields = 0;
    let mut conversation = None;
    let mut photos = Vec::new();
    let mut raw_photo_bytes = 0;
    let mut sanitized_photo_bytes = 0;
    let image_limits = service.image_limits();

    loop {
        let field = match multipart.next_field().await {
            Ok(Some(field)) => field,
            Ok(None) => break,
            Err(error) if error.status() == StatusCode::PAYLOAD_TOO_LARGE => {
                return Err(payload_too_large());
            }
            Err(_) => return Err(invalid_multipart("could not read multipart field")),
        };
        fields += 1;
        if fields > MAX_MULTIPART_FIELDS {
            if field.name() == Some("photos") {
                return Err(rejected(
                    StatusCode::BAD_REQUEST,
                    "too_many_photos",
                    "only four photos can be attached",
                    "photo count exceeded limit",
                ));
            }
            return Err(rejected(
                StatusCode::BAD_REQUEST,
                "too_many_fields",
                "request contains too many multipart fields",
                "multipart field count exceeded limit",
            ));
        }
        match field.name() {
            Some("conversation") if field.file_name().is_none() && conversation.is_none() => {
                conversation = Some(read_conversation(field).await?);
            }
            Some("photos") => {
                let Some(limits) = image_limits else {
                    return Err(rejected(
                        StatusCode::BAD_REQUEST,
                        "photos_not_supported",
                        "this assistant does not support photos",
                        "photo supplied to text-only assistant",
                    ));
                };
                if field.file_name().is_none() {
                    return Err(rejected(
                        StatusCode::BAD_REQUEST,
                        "photo_file_required",
                        "each photo must be uploaded as a file",
                        "photo part has no filename",
                    ));
                }
                if photos.len() >= limits.max_images {
                    return Err(rejected(
                        StatusCode::BAD_REQUEST,
                        "too_many_photos",
                        "only four photos can be attached",
                        "photo count exceeded limit",
                    ));
                }
                let mime_type = field.content_type().map(str::to_owned).ok_or_else(|| {
                    rejected(
                        StatusCode::BAD_REQUEST,
                        "photo_type_required",
                        "each photo must include a file type",
                        "photo content type is missing",
                    )
                })?;
                let bytes = read_photo(field, &mut raw_photo_bytes, limits).await?;
                let photo = service
                    .sanitize_photo(&mime_type, bytes)
                    .await
                    .map_err(image_failure)?;
                if photo.bytes.len() > limits.max_total_bytes.saturating_sub(sanitized_photo_bytes)
                {
                    return Err(rejected(
                        StatusCode::PAYLOAD_TOO_LARGE,
                        "photos_too_large",
                        "photos together are too large after processing",
                        "sanitized photo total exceeded byte limit",
                    ));
                }
                sanitized_photo_bytes += photo.bytes.len();
                photos.push(photo);
            }
            Some("conversation") => {
                return Err(rejected(
                    StatusCode::BAD_REQUEST,
                    "invalid_conversation_field",
                    "the conversation must be supplied once as a text field",
                    "conversation field is duplicated or has a filename",
                ));
            }
            _ => {
                return Err(rejected(
                    StatusCode::BAD_REQUEST,
                    "unexpected_field",
                    "request contains an unexpected field",
                    "unexpected multipart field",
                ));
            }
        }
    }

    let bytes = conversation.ok_or_else(|| {
        rejected(
            StatusCode::BAD_REQUEST,
            "conversation_required",
            "a conversation is required",
            "conversation multipart field is missing",
        )
    })?;
    let wire: ConversationRequest = serde_json::from_slice(&bytes).map_err(|_| {
        rejected(
            StatusCode::BAD_REQUEST,
            "invalid_conversation",
            "conversation data is malformed",
            "conversation JSON did not match the request schema",
        )
    })?;
    let turns = wire
        .turns
        .into_iter()
        .map(|turn| {
            let role = match turn.role {
                ConversationRoleRequest::User => ConversationRole::User,
                ConversationRoleRequest::Assistant => ConversationRole::Assistant,
            };
            ConversationTurn::new(role, turn.text)
        })
        .collect::<Result<Vec<_>, _>>()
        .map_err(conversation_failure)?;
    Ok(FoodDraftRequest {
        conversation: Conversation::new(turns).map_err(conversation_failure)?,
        photos,
    })
}

async fn read_conversation(mut field: Field<'_>) -> Result<Vec<u8>, DraftHttpResult> {
    let mut bytes = Vec::new();
    loop {
        let chunk = match field.chunk().await {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(error) if error.status() == StatusCode::PAYLOAD_TOO_LARGE => {
                return Err(payload_too_large());
            }
            Err(_) => return Err(invalid_multipart("could not read conversation field")),
        };
        if chunk.len() > MAX_CONVERSATION_FIELD_BYTES.saturating_sub(bytes.len()) {
            return Err(rejected(
                StatusCode::PAYLOAD_TOO_LARGE,
                "conversation_too_large",
                "conversation data is too large",
                "conversation field exceeded byte limit",
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn read_photo(
    mut field: Field<'_>,
    raw_total: &mut usize,
    limits: FoodImageLimits,
) -> Result<Vec<u8>, DraftHttpResult> {
    let mut bytes = Vec::new();
    loop {
        let chunk = match field.chunk().await {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(error) if error.status() == StatusCode::PAYLOAD_TOO_LARGE => {
                return Err(payload_too_large());
            }
            Err(_) => return Err(invalid_multipart("could not read photo field")),
        };
        if chunk.len() > limits.max_bytes_per_image.saturating_sub(bytes.len())
            || chunk.len() > limits.max_total_bytes.saturating_sub(*raw_total)
        {
            return Err(rejected(
                StatusCode::PAYLOAD_TOO_LARGE,
                "photo_too_large",
                "a photo or the combined photos are too large",
                "raw photo byte limit exceeded",
            ));
        }
        *raw_total += chunk.len();
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err(rejected(
            StatusCode::BAD_REQUEST,
            "photo_empty",
            "photos cannot be empty",
            "photo field is empty",
        ));
    }
    Ok(bytes)
}

fn assistant_failure(error: AssistantError) -> DraftHttpResult {
    match error {
        AssistantError::InvalidInput => rejected(
            StatusCode::BAD_REQUEST,
            "invalid_conversation",
            "conversation data is invalid",
            "assistant input validation failed",
        ),
        AssistantError::ModelUnavailable => failure(
            StatusCode::BAD_GATEWAY,
            "provider_unavailable",
            "assistant provider is unavailable",
        ),
        AssistantError::InvalidModelResponse => failure(
            StatusCode::BAD_GATEWAY,
            "invalid_provider_response",
            "assistant provider returned an invalid response",
        ),
        AssistantError::Internal => failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            "assistant_error",
            "assistant request failed",
        ),
    }
}

fn conversation_failure(error: ConversationValidationError) -> DraftHttpResult {
    match error {
        ConversationValidationError::Empty => rejected(
            StatusCode::BAD_REQUEST,
            "conversation_empty",
            "a conversation must contain a message",
            "conversation contains no turns",
        ),
        ConversationValidationError::TooManyTurns => rejected(
            StatusCode::BAD_REQUEST,
            "conversation_too_long",
            "the conversation is full; start a new assistant session",
            "conversation turn count exceeded limit",
        ),
        ConversationValidationError::EmptyMessage => rejected(
            StatusCode::BAD_REQUEST,
            "conversation_message_empty",
            "conversation messages cannot be empty",
            "conversation contains an empty message",
        ),
        ConversationValidationError::MessageTooLong => rejected(
            StatusCode::BAD_REQUEST,
            "conversation_message_too_long",
            "conversation messages must be 4,000 characters or fewer",
            "conversation message exceeded character limit",
        ),
    }
}

fn image_failure(error: FoodImageError) -> DraftHttpResult {
    match error {
        FoodImageError::NotSupported => rejected(
            StatusCode::BAD_REQUEST,
            "photos_not_supported",
            "this assistant does not support photos",
            "photo supplied to text-only assistant",
        ),
        FoodImageError::Empty => rejected(
            StatusCode::BAD_REQUEST,
            "photo_empty",
            "photos cannot be empty",
            "image sanitizer received an empty photo",
        ),
        FoodImageError::UnsupportedType => rejected(
            StatusCode::BAD_REQUEST,
            "photo_unsupported_type",
            "photos must be JPEG, PNG, or WebP",
            "photo declared an unsupported content type",
        ),
        FoodImageError::TypeMismatch => rejected(
            StatusCode::BAD_REQUEST,
            "photo_type_mismatch",
            "a photo's contents do not match its file type",
            "detected photo format did not match declared content type",
        ),
        FoodImageError::InvalidData => rejected(
            StatusCode::BAD_REQUEST,
            "photo_invalid",
            "a photo could not be read; choose a valid JPEG, PNG, or WebP image",
            "photo could not be decoded or normalized",
        ),
        FoodImageError::DimensionsTooLarge => rejected(
            StatusCode::BAD_REQUEST,
            "photo_dimensions_too_large",
            "a photo has too many pixels; use a photo at or below 50 megapixels",
            "photo dimensions exceeded pixel limit",
        ),
        FoodImageError::EncodedTooLarge => rejected(
            StatusCode::PAYLOAD_TOO_LARGE,
            "photo_too_large",
            "a photo is too large after processing",
            "processed photo exceeded byte limit",
        ),
        FoodImageError::Internal => failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            "assistant_error",
            "assistant request failed",
        ),
    }
}

fn invalid_multipart(reason: &'static str) -> DraftHttpResult {
    rejected(
        StatusCode::BAD_REQUEST,
        "invalid_multipart",
        "request upload could not be read",
        reason,
    )
}

fn payload_too_large() -> DraftHttpResult {
    rejected(
        StatusCode::PAYLOAD_TOO_LARGE,
        "payload_too_large",
        "request is too large",
        "request exceeded the HTTP body limit",
    )
}

fn throttled(code: &'static str, message: &'static str, retry_after: u64) -> DraftHttpResult {
    let mut result = failure(StatusCode::TOO_MANY_REQUESTS, code, message);
    result.response.headers_mut().insert(
        header::RETRY_AFTER,
        HeaderValue::from_str(&retry_after.to_string())
            .unwrap_or_else(|_| HeaderValue::from_static("1")),
    );
    result
}

fn failure(status: StatusCode, code: &'static str, message: &'static str) -> DraftHttpResult {
    rejected(status, code, message, message)
}

fn rejected(
    status: StatusCode,
    code: &'static str,
    message: &'static str,
    reason: &'static str,
) -> DraftHttpResult {
    DraftHttpResult {
        response: (
            status,
            Json(ErrorResponse {
                error: ErrorBody { code, message },
            }),
        )
            .into_response(),
        outcome: code,
        usage: None,
        rejection_reason: Some(reason),
    }
}

fn turn_to_response(turn: FoodDraftTurn) -> AssistantDraftResponse {
    match turn {
        FoodDraftTurn::NeedsClarification { assistant_message } => AssistantDraftResponse {
            assistant_message,
            status: DraftStatusResponse::NeedsClarification,
            draft: None,
            warnings: Vec::new(),
        },
        FoodDraftTurn::DraftReady {
            assistant_message,
            draft,
            warnings,
        } => AssistantDraftResponse {
            assistant_message,
            status: DraftStatusResponse::DraftReady,
            draft: Some(draft.into()),
            warnings,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_contract_is_stable_for_clarification() {
        let value = serde_json::to_value(turn_to_response(
            FoodDraftTurn::clarification("How many grams?").unwrap(),
        ))
        .unwrap();
        assert_eq!(
            value,
            serde_json::json!({
                "assistant_message": "How many grams?",
                "status": "needs_clarification",
                "draft": null,
                "warnings": []
            })
        );
    }

    #[test]
    fn response_contract_maps_the_validated_draft_to_http_fields() {
        let draft = FoodDraft::new(
            "Dal".into(),
            None,
            vec!["lentils".into()],
            Some(rust_decimal::Decimal::ONE),
            Some("bowl".into()),
            vec![
                crate::assistant::domain::DraftNutrient::new(
                    "ENERGY_KCAL".into(),
                    rust_decimal::Decimal::new(172_125, 3),
                )
                .unwrap(),
            ],
            vec![
                crate::assistant::domain::DraftServing::new(
                    "bowl".into(),
                    rust_decimal::Decimal::new(35_050, 2),
                )
                .unwrap(),
            ],
        )
        .unwrap();
        let value = serde_json::to_value(turn_to_response(
            FoodDraftTurn::ready("Review this estimate.", draft, vec![]).unwrap(),
        ))
        .unwrap();

        assert_eq!(
            value,
            serde_json::json!({
                "assistant_message": "Review this estimate.",
                "status": "draft_ready",
                "draft": {
                    "name": "Dal",
                    "brand": null,
                    "categories": ["lentils"],
                    "default_quantity": "1",
                    "default_unit": "bowl",
                    "nutrients": [{
                        "code": "ENERGY_KCAL",
                        "amount_per_100g": "172.125"
                    }],
                    "servings": [{
                        "unit": "bowl",
                        "grams_per_unit": "350.50"
                    }]
                },
                "warnings": []
            })
        );
    }

    #[test]
    fn conversation_wire_rejects_unknown_photo_data() {
        let value = serde_json::json!({
            "turns": [{"role": "user", "text": "dal", "photo": "bytes"}]
        });
        assert!(serde_json::from_value::<ConversationRequest>(value).is_err());
    }

    #[test]
    fn status_serializes_image_support() {
        let value = serde_json::to_value(AssistantStatusResponse {
            enabled: true,
            supports_images: true,
        })
        .unwrap();
        assert_eq!(
            value,
            serde_json::json!({"enabled": true, "supports_images": true})
        );
    }
}

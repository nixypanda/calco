//! Authenticated multipart transport for transient food drafts.

use std::time::Instant;

use axum::extract::multipart::{Field, MultipartRejection};
use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::assistant::application::{FoodDraftRequest, FoodImageLimits, ModelUsage};
use crate::assistant::domain::{
    AssistantError, Conversation, ConversationRole, ConversationTurn, FoodDraft, FoodDraftTurn,
};
use crate::assistant::module::{AdmissionError, AssistantModule};
use crate::auth::interfaces::http::AuthUser;

const MAX_REQUEST_BYTES: usize = 13 * 1024 * 1024;
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
    draft: Option<FoodDraft>,
    warnings: Vec<String>,
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
    tracing::info!(
        user_id = %user.id,
        latency_ms = started.elapsed().as_millis() as u64,
        outcome = result.outcome,
        input_tokens = result.usage.and_then(|value| value.input_tokens),
        output_tokens = result.usage.and_then(|value| value.output_tokens),
        "assistant draft request completed"
    );
    result.response
}

struct DraftHttpResult {
    response: Response,
    outcome: &'static str,
    usage: Option<ModelUsage>,
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
            return failure(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "request must use multipart/form-data",
            );
        }
    };
    let request = match parse_multipart(multipart, &module).await {
        Ok(value) => value,
        Err(error) => return error,
    };

    match service.draft(request).await {
        Ok(result) => DraftHttpResult {
            response: Json(turn_to_response(result.turn)).into_response(),
            outcome: "success",
            usage: result.usage,
        },
        Err(error) => assistant_failure(error),
    }
}

async fn parse_multipart(
    mut multipart: Multipart,
    module: &AssistantModule,
) -> Result<FoodDraftRequest, DraftHttpResult> {
    let mut fields = 0;
    let mut conversation = None;
    let mut photos = Vec::new();
    let mut raw_photo_bytes = 0;
    let mut sanitized_photo_bytes = 0;
    let image_sanitizer = module.image_sanitizer();
    let image_limits = image_sanitizer.as_ref().map(|sanitizer| sanitizer.limits());

    loop {
        let field = match multipart.next_field().await {
            Ok(Some(field)) => field,
            Ok(None) => break,
            Err(error) if error.status() == StatusCode::PAYLOAD_TOO_LARGE => {
                return Err(payload_too_large());
            }
            Err(_) => return Err(invalid_request()),
        };
        fields += 1;
        if fields > MAX_MULTIPART_FIELDS {
            return Err(invalid_request());
        }
        match field.name() {
            Some("conversation") if field.file_name().is_none() && conversation.is_none() => {
                conversation = Some(read_conversation(field).await?);
            }
            Some("photos") => {
                let (Some(sanitizer), Some(limits)) = (&image_sanitizer, image_limits) else {
                    return Err(invalid_request());
                };
                if field.file_name().is_none() || photos.len() >= limits.max_images {
                    return Err(invalid_request());
                }
                let mime_type = field
                    .content_type()
                    .map(str::to_owned)
                    .ok_or_else(invalid_request)?;
                let bytes = read_photo(field, &mut raw_photo_bytes, limits).await?;
                let photo = sanitizer
                    .sanitize(&mime_type, bytes)
                    .await
                    .map_err(assistant_failure)?;
                if photo.bytes.len() > limits.max_total_bytes.saturating_sub(sanitized_photo_bytes)
                {
                    return Err(payload_too_large());
                }
                sanitized_photo_bytes += photo.bytes.len();
                photos.push(photo);
            }
            _ => return Err(invalid_request()),
        }
    }

    let bytes = conversation.ok_or_else(invalid_request)?;
    let wire: ConversationRequest =
        serde_json::from_slice(&bytes).map_err(|_| invalid_request())?;
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
        .map_err(assistant_failure)?;
    Ok(FoodDraftRequest {
        conversation: Conversation::new(turns).map_err(assistant_failure)?,
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
            Err(_) => return Err(invalid_request()),
        };
        if chunk.len() > MAX_CONVERSATION_FIELD_BYTES.saturating_sub(bytes.len()) {
            return Err(payload_too_large());
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
            Err(_) => return Err(invalid_request()),
        };
        if chunk.len() > limits.max_bytes_per_image.saturating_sub(bytes.len())
            || chunk.len() > limits.max_total_bytes.saturating_sub(*raw_total)
        {
            return Err(payload_too_large());
        }
        *raw_total += chunk.len();
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err(invalid_request());
    }
    Ok(bytes)
}

fn assistant_failure(error: AssistantError) -> DraftHttpResult {
    match error {
        AssistantError::Disabled => failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "assistant_disabled",
            "assistant is unavailable",
        ),
        AssistantError::InvalidInput => invalid_request(),
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

fn invalid_request() -> DraftHttpResult {
    failure(
        StatusCode::BAD_REQUEST,
        "invalid_request",
        "invalid request",
    )
}

fn payload_too_large() -> DraftHttpResult {
    failure(
        StatusCode::PAYLOAD_TOO_LARGE,
        "payload_too_large",
        "request is too large",
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
            draft: Some(draft),
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
    fn response_contract_serializes_the_validated_draft_directly() {
        let draft = FoodDraft::new(
            "Dal".into(),
            None,
            vec!["lentils".into()],
            Some(rust_decimal::Decimal::new(35_050, 2)),
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
                    "one bowl".into(),
                    rust_decimal::Decimal::ONE,
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
                    "serving_size_g": "350.50",
                    "default_quantity": "1",
                    "default_unit": "bowl",
                    "nutrients": [{
                        "code": "ENERGY_KCAL",
                        "amount_per_100g": "172.125"
                    }],
                    "servings": [{
                        "label": "one bowl",
                        "quantity": "1",
                        "unit": "bowl",
                        "grams": "350.50"
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

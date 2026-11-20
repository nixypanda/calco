use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use rust_decimal::Decimal;
use serde::Serialize;
use uuid::Uuid;

use crate::journal::error::{JournalError, MissingMealComponent};

pub use crate::catalog::api::shared::{
    ErrorBody, ErrorResponse, NutrientSummaryDto, SUMMARY_NUTRIENT_CODES, error_response,
    internal_error, is_summary_nutrient_code, nutrient_summary_from_entries,
};

fn conflict_error_response(message: String) -> Response {
    (
        StatusCode::CONFLICT,
        Json(ErrorResponse {
            error: ErrorBody {
                code: "conflict".into(),
                message,
            },
        }),
    )
        .into_response()
}

#[derive(Serialize)]
struct MissingComponentsErrorResponse {
    error: MissingComponentsErrorBody,
}

#[derive(Serialize)]
struct MissingComponentsErrorBody {
    code: &'static str,
    message: &'static str,
    meal_id: Uuid,
    missing_components: Vec<MissingComponentDto>,
}

#[derive(Serialize)]
struct MissingComponentDto {
    component_id: Uuid,
    item: MissingComponentItemDto,
    quantity: MissingComponentQuantityDto,
    name: &'static str,
    missing_reason: &'static str,
}

#[derive(Serialize)]
struct MissingComponentItemDto {
    #[serde(rename = "type")]
    item_type: &'static str,
    id: Uuid,
}

#[derive(Serialize)]
struct MissingComponentQuantityDto {
    amount: Decimal,
    unit: String,
}

fn missing_components_error_response(
    meal_id: Uuid,
    components: Vec<MissingMealComponent>,
) -> Response {
    let missing_components = components
        .into_iter()
        .map(|component| MissingComponentDto {
            component_id: component.component_id,
            item: MissingComponentItemDto {
                item_type: "product",
                id: component.product_id,
            },
            quantity: MissingComponentQuantityDto {
                amount: component.quantity_amount,
                unit: component.quantity_unit,
            },
            name: "Unavailable food",
            missing_reason: "product_unavailable",
        })
        .collect();
    (
        StatusCode::CONFLICT,
        Json(MissingComponentsErrorResponse {
            error: MissingComponentsErrorBody {
                code: "missing_components",
                message: "meal has components that are no longer available; replace them before previewing or logging",
                meal_id,
                missing_components,
            },
        }),
    )
        .into_response()
}

impl IntoResponse for JournalError {
    fn into_response(self) -> Response {
        match self {
            JournalError::NotFound(msg) => error_response("not_found", msg).into_response(),
            JournalError::Forbidden(msg) => error_response("forbidden", msg).into_response(),
            JournalError::Validation(msg) => error_response("validation", msg).into_response(),
            JournalError::Conflict(msg) => conflict_error_response(msg),
            JournalError::MissingMealComponents {
                meal_id,
                components,
            } => missing_components_error_response(meal_id, components),
            JournalError::DuplicateIdempotencyKey => conflict_error_response(
                "idempotency key was already used for another request".into(),
            ),
            JournalError::ExternalUnavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ErrorResponse {
                    error: ErrorBody {
                        code: "external_unavailable".into(),
                        message: "external food catalog is temporarily unavailable".into(),
                    },
                }),
            )
                .into_response(),
            JournalError::ExternalInvalidResponse => (
                StatusCode::BAD_GATEWAY,
                Json(ErrorResponse {
                    error: ErrorBody {
                        code: "external_invalid_response".into(),
                        message: "external food catalog returned unusable product data".into(),
                    },
                }),
            )
                .into_response(),
            JournalError::Database(_) | JournalError::Internal(_) => {
                internal_error(self).into_response()
            }
        }
    }
}

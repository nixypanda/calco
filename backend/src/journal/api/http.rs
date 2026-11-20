use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use rust_decimal::Decimal;
use serde::Serialize;
use uuid::Uuid;

use crate::journal::error::{
    JournalError, MealComponentUnavailableReason, MealQuantityUnavailableReason,
    UnavailableMealComponent, UnavailableMealComponents,
};

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
struct UnavailableComponentsErrorResponse {
    error: UnavailableComponentsErrorBody,
}

#[derive(Serialize)]
struct UnavailableComponentsErrorBody {
    code: &'static str,
    message: &'static str,
    meal_id: Uuid,
    unavailable_components: Vec<UnavailableMealComponentDto>,
}

#[derive(Serialize)]
struct UnavailableMealComponentDto {
    component_id: Uuid,
    item: UnavailableMealComponentItemDto,
    quantity: UnavailableMealComponentQuantityDto,
    reason: MealComponentUnavailableReason,
}

impl From<&UnavailableMealComponent> for UnavailableMealComponentDto {
    fn from(component: &UnavailableMealComponent) -> Self {
        Self {
            component_id: component.component_id,
            item: UnavailableMealComponentItemDto {
                item_type: "product",
                id: component.product_id,
            },
            quantity: UnavailableMealComponentQuantityDto {
                amount: component.quantity_amount,
                unit: component.quantity_unit.clone(),
            },
            reason: component.reason,
        }
    }
}

#[derive(Serialize)]
struct UnavailableMealComponentItemDto {
    #[serde(rename = "type")]
    item_type: &'static str,
    id: Uuid,
}

#[derive(Serialize)]
struct UnavailableMealComponentQuantityDto {
    amount: Decimal,
    unit: String,
}

#[derive(Serialize)]
struct MealQuantityErrorResponse {
    error: MealQuantityErrorBody,
}

#[derive(Serialize)]
struct MealQuantityErrorBody {
    code: &'static str,
    message: &'static str,
    meal_id: Uuid,
    quantity: UnavailableMealComponentQuantityDto,
    reason: MealQuantityUnavailableReason,
}

fn unavailable_components_error_response(
    meal_id: Uuid,
    unavailable: UnavailableMealComponents,
) -> Response {
    let unavailable_components = unavailable
        .as_slice()
        .iter()
        .map(UnavailableMealComponentDto::from)
        .collect();
    (
        StatusCode::CONFLICT,
        Json(UnavailableComponentsErrorResponse {
            error: UnavailableComponentsErrorBody {
                code: "unavailable_components",
                message: "meal has components that cannot be used; repair them before previewing or logging",
                meal_id,
                unavailable_components,
            },
        }),
    )
        .into_response()
}

fn meal_quantity_error_response(
    meal_id: Uuid,
    amount: Decimal,
    unit: String,
    reason: MealQuantityUnavailableReason,
) -> Response {
    (
        StatusCode::CONFLICT,
        Json(MealQuantityErrorResponse {
            error: MealQuantityErrorBody {
                code: "meal_quantity_not_convertible",
                message: "meal quantity cannot be converted to grams; use a supported mass or serving quantity",
                meal_id,
                quantity: UnavailableMealComponentQuantityDto { amount, unit },
                reason,
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
            JournalError::UnavailableMealComponents {
                meal_id,
                unavailable,
            } => unavailable_components_error_response(meal_id, unavailable),
            JournalError::MealQuantityNotConvertible {
                meal_id,
                amount,
                unit,
                reason,
            } => meal_quantity_error_response(meal_id, amount, unit, reason),
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

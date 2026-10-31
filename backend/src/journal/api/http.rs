use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};

use crate::journal::error::JournalError;

pub use crate::catalog::api::shared::{
    ErrorBody, ErrorResponse, NutrientSummaryDto, SUMMARY_NUTRIENT_CODES, error_response,
    internal_error, is_summary_nutrient_code, nutrient_summary_from_entries,
};

impl IntoResponse for JournalError {
    fn into_response(self) -> Response {
        match self {
            JournalError::NotFound(msg) => error_response("not_found", msg).into_response(),
            JournalError::Forbidden(msg) => error_response("forbidden", msg).into_response(),
            JournalError::Validation(msg) => error_response("validation", msg).into_response(),
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

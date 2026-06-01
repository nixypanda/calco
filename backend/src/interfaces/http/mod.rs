pub mod auth;
pub mod catalog;
pub mod food_log;
pub mod import;
pub mod meal;

use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use serde::Serialize;

use crate::domain::nutrition::NutritionError;

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: ErrorBody,
}

#[derive(Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

pub fn error_response(code: &str, message: String) -> (StatusCode, Json<ErrorResponse>) {
    (
        match code {
            "not_found" => StatusCode::NOT_FOUND,
            "forbidden" => StatusCode::FORBIDDEN,
            "validation" => StatusCode::BAD_REQUEST,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        },
        Json(ErrorResponse {
            error: ErrorBody {
                code: code.to_string(),
                message,
            },
        }),
    )
}

pub fn internal_error<E: std::fmt::Display>(e: E) -> (StatusCode, Json<ErrorResponse>) {
    tracing::error!(error = %e, "request failed");
    error_response("internal", "internal server error".into())
}

impl IntoResponse for NutritionError {
    fn into_response(self) -> Response {
        match self {
            NutritionError::NotFound(msg) => error_response("not_found", msg).into_response(),
            NutritionError::Forbidden(msg) => error_response("forbidden", msg).into_response(),
            NutritionError::Validation(msg) => error_response("validation", msg).into_response(),
            NutritionError::Database(_) | NutritionError::Internal(_) => {
                internal_error(self).into_response()
            }
        }
    }
}

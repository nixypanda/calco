pub mod catalog;
pub mod food_log;
pub mod goal_target;
pub mod meal;

use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use rust_decimal::Decimal;
use serde::Serialize;

use crate::nutrition::domain::error::NutritionError;

pub const SUMMARY_NUTRIENT_CODES: [&str; 5] =
    ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G"];

#[derive(Serialize, Clone, Default)]
pub struct NutrientSummaryDto {
    pub energy_kcal: Option<Decimal>,
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
}

pub fn is_summary_nutrient_code(code: &str) -> bool {
    SUMMARY_NUTRIENT_CODES.contains(&code)
}

pub fn nutrient_summary_from_entries<I>(entries: I) -> NutrientSummaryDto
where
    I: IntoIterator<Item = (String, Decimal)>,
{
    let mut summary = NutrientSummaryDto::default();
    for (code, amount) in entries {
        match code.as_str() {
            "ENERGY_KCAL" => summary.energy_kcal = Some(amount),
            "PROTEIN_G" => summary.protein_g = Some(amount),
            "CARBS_G" => summary.carbs_g = Some(amount),
            "FAT_G" => summary.fat_g = Some(amount),
            "FIBER_G" => summary.fiber_g = Some(amount),
            _ => {}
        }
    }
    summary
}

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

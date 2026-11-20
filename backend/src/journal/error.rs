use rust_decimal::Decimal;
use uuid::Uuid;

use crate::catalog::error::CatalogError;

#[derive(Debug, Clone)]
pub struct MissingMealComponent {
    pub component_id: Uuid,
    pub product_id: Uuid,
    pub quantity_amount: Decimal,
    pub quantity_unit: String,
}

#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    #[error("not_found: {0}")]
    NotFound(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("validation: {0}")]
    Validation(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("meal {meal_id} has missing components")]
    MissingMealComponents {
        meal_id: Uuid,
        components: Vec<MissingMealComponent>,
    },
    #[error("idempotency key already exists")]
    DuplicateIdempotencyKey,
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error("external food catalog unavailable")]
    ExternalUnavailable,
    #[error("external food catalog returned invalid product data")]
    ExternalInvalidResponse,
    #[error("internal: {0}")]
    Internal(String),
}

impl From<CatalogError> for JournalError {
    fn from(err: CatalogError) -> Self {
        match err {
            CatalogError::NotFound(msg) => JournalError::NotFound(msg),
            CatalogError::Forbidden(msg) => JournalError::Forbidden(msg),
            CatalogError::Validation(msg) => JournalError::Validation(msg),
            CatalogError::Database(e) => JournalError::Database(e),
            CatalogError::ExternalUnavailable => JournalError::ExternalUnavailable,
            CatalogError::ExternalInvalidResponse => JournalError::ExternalInvalidResponse,
            CatalogError::Internal(msg) => JournalError::Internal(msg),
        }
    }
}

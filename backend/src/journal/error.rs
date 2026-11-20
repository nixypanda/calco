use rust_decimal::Decimal;
use serde::Serialize;
use uuid::Uuid;

use crate::catalog::error::CatalogError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MealComponentUnavailableReason {
    ProductUnavailable,
    QuantityNotConvertible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MealQuantityUnavailableReason {
    QuantityNotConvertible,
}

#[derive(Debug, Clone)]
pub struct UnavailableMealComponent {
    pub component_id: Uuid,
    pub product_id: Uuid,
    pub quantity_amount: Decimal,
    pub quantity_unit: String,
    pub reason: MealComponentUnavailableReason,
}

/// Non-empty set of meal components that cannot be used.
#[derive(Debug, Clone)]
pub struct UnavailableMealComponents(Vec<UnavailableMealComponent>);

impl UnavailableMealComponents {
    pub fn new(components: Vec<UnavailableMealComponent>) -> Option<Self> {
        (!components.is_empty()).then_some(Self(components))
    }

    pub fn as_slice(&self) -> &[UnavailableMealComponent] {
        &self.0
    }

    pub fn into_vec(self) -> Vec<UnavailableMealComponent> {
        self.0
    }
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
    #[error("meal {meal_id} has unavailable components")]
    UnavailableMealComponents {
        meal_id: Uuid,
        unavailable: UnavailableMealComponents,
    },
    #[error("meal {meal_id} quantity cannot be converted to grams")]
    MealQuantityNotConvertible {
        meal_id: Uuid,
        amount: Decimal,
        unit: String,
        reason: MealQuantityUnavailableReason,
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

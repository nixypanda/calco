use crate::catalog::error::CatalogError;

#[derive(Debug, thiserror::Error)]
pub enum NutritionError {
    #[error("not_found: {0}")]
    NotFound(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("validation: {0}")]
    Validation(String),
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error("external food catalog unavailable")]
    ExternalUnavailable,
    #[error("external food catalog returned invalid product data")]
    ExternalInvalidResponse,
    #[error("internal: {0}")]
    Internal(String),
}

impl From<CatalogError> for NutritionError {
    fn from(err: CatalogError) -> Self {
        match err {
            CatalogError::NotFound(msg) => NutritionError::NotFound(msg),
            CatalogError::Forbidden(msg) => NutritionError::Forbidden(msg),
            CatalogError::Validation(msg) => NutritionError::Validation(msg),
            CatalogError::Database(e) => NutritionError::Database(e),
            CatalogError::ExternalUnavailable => NutritionError::ExternalUnavailable,
            CatalogError::ExternalInvalidResponse => NutritionError::ExternalInvalidResponse,
            CatalogError::Internal(msg) => NutritionError::Internal(msg),
        }
    }
}

use crate::catalog::error::CatalogError;

#[derive(Debug, thiserror::Error)]
pub enum JournalError {
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

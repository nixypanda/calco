#[derive(Debug, thiserror::Error)]
pub enum CatalogError {
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

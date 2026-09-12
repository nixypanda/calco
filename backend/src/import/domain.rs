use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json;
use std::str::FromStr;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ImportId(pub Uuid);

impl Default for ImportId {
    fn default() -> Self {
        Self::new()
    }
}

impl ImportId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl From<Uuid> for ImportId {
    fn from(id: Uuid) -> Self {
        Self(id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportStatus {
    Pending,
    Running,
    Committed,
    Failed,
}

impl ImportStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            ImportStatus::Pending => "pending",
            ImportStatus::Running => "running",
            ImportStatus::Committed => "committed",
            ImportStatus::Failed => "failed",
        }
    }
}

impl FromStr for ImportStatus {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "pending" => Ok(ImportStatus::Pending),
            "running" => Ok(ImportStatus::Running),
            "committed" => Ok(ImportStatus::Committed),
            "failed" => Ok(ImportStatus::Failed),
            _ => Err(format!("invalid import status: {s}")),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ImportJob {
    pub id: ImportId,
    pub source: String,
    pub status: ImportStatus,
    pub created_by: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub committed_at: Option<DateTime<Utc>>,
    pub failed_at: Option<DateTime<Utc>>,
}

impl ImportJob {
    pub fn new(source: String, created_by: Option<Uuid>) -> Self {
        Self {
            id: ImportId::new(),
            source,
            status: ImportStatus::Pending,
            created_by,
            created_at: Utc::now(),
            committed_at: None,
            failed_at: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct StagedImportProduct {
    pub source: String,
    pub source_id: String,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub raw_payload: Option<serde_json::Value>,
    pub row_number: Option<i32>,
}

#[derive(Debug, Clone)]
pub struct StagedImportServing {
    pub source: String,
    pub source_id: String,
    pub unit: String,
    pub grams_per_unit: rust_decimal::Decimal,
    pub raw_payload: Option<serde_json::Value>,
    pub row_number: Option<i32>,
}

#[derive(Debug, Clone)]
pub struct StagedImportNutrient {
    pub source: String,
    pub source_id: String,
    pub nutrient_code: String,
    pub amount_per_100g: rust_decimal::Decimal,
    pub raw_payload: Option<serde_json::Value>,
    pub row_number: Option<i32>,
}

#[derive(Debug, Clone)]
pub struct ImportErrorRecord {
    pub row_number: Option<i32>,
    pub error: String,
    pub raw_payload: Option<serde_json::Value>,
}

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("not_found: {0}")]
    NotFound(String),
    #[error("invalid_status: {0}")]
    InvalidStatus(String),
    #[error("validation: {0}")]
    Validation(String),
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error("catalog: {0}")]
    Catalog(String),
}

#[derive(Debug, Clone)]
pub struct ImportCommitResult {
    pub products_created: i64,
    pub products_updated: i64,
    pub nutrients_inserted: i64,
    pub servings_inserted: i64,
    pub errors_logged: i64,
}

#[derive(Debug, Clone, Default)]
pub struct StagedImportBatch {
    pub products: Vec<StagedImportProduct>,
    pub nutrients: Vec<StagedImportNutrient>,
    pub servings: Vec<StagedImportServing>,
}

#[derive(Debug, Clone)]
pub enum ImportCommitStart {
    Ready(StagedImportBatch),
    Completed(ImportCommitResult),
}

#[async_trait]
pub trait ImportRepository: Send + Sync {
    async fn create_job(&self, job: &ImportJob) -> Result<(), ImportError>;
    async fn find_job(&self, id: ImportId) -> Result<Option<ImportJob>, ImportError>;
    async fn stage_foods(
        &self,
        import_id: ImportId,
        foods: &[StagedImportProduct],
        errors: &[ImportErrorRecord],
    ) -> Result<(), ImportError>;
    async fn stage_nutrients(
        &self,
        import_id: ImportId,
        nutrients: &[StagedImportNutrient],
        errors: &[ImportErrorRecord],
    ) -> Result<(), ImportError>;
    async fn stage_servings(
        &self,
        import_id: ImportId,
        servings: &[StagedImportServing],
        errors: &[ImportErrorRecord],
    ) -> Result<(), ImportError>;
    async fn begin_commit(&self, import_id: ImportId) -> Result<ImportCommitStart, ImportError>;
    async fn complete_commit(
        &self,
        import_id: ImportId,
        result: &ImportCommitResult,
        errors: &[ImportErrorRecord],
    ) -> Result<ImportCommitResult, ImportError>;
    async fn fail_commit(&self, import_id: ImportId) -> Result<(), ImportError>;
    async fn get_errors(&self, import_id: ImportId) -> Result<Vec<ImportErrorRecord>, ImportError>;
}

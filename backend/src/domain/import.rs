use chrono::{DateTime, Utc};
use serde_json;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ImportId(pub Uuid);

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportSource(pub String);

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

    pub fn from_str(s: &str) -> Result<Self, String> {
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

    pub fn mark_committed(&mut self) {
        self.status = ImportStatus::Committed;
        self.committed_at = Some(Utc::now());
    }

    pub fn mark_failed(&mut self) {
        self.status = ImportStatus::Failed;
        self.failed_at = Some(Utc::now());
    }
}

#[derive(Debug, Clone)]
pub struct StagedImportProduct {
    pub source: String,
    pub source_id: String,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub category: Option<String>,
    pub serving_size_g: Option<rust_decimal::Decimal>,
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

#[derive(Debug)]
pub enum ImportDomainError {
    InvalidStatus(String),
    Validation(String),
}

impl std::fmt::Display for ImportDomainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImportDomainError::InvalidStatus(msg) => write!(f, "invalid status: {msg}"),
            ImportDomainError::Validation(msg) => write!(f, "validation: {msg}"),
        }
    }
}

impl std::error::Error for ImportDomainError {}

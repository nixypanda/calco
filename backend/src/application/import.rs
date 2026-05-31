use async_trait::async_trait;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::import::*;

#[async_trait]
pub trait ImportRepository: Send + Sync {
    async fn create_job(&self, job: &ImportJob) -> Result<(), ImportError>;
    async fn find_job(&self, id: ImportId) -> Result<Option<ImportJob>, ImportError>;
    async fn stage_foods(&self, import_id: ImportId, foods: &[StagedImportProduct]) -> Result<(), ImportError>;
    async fn stage_nutrients(&self, import_id: ImportId, nutrients: &[StagedImportNutrient]) -> Result<(), ImportError>;
    async fn stage_servings(&self, import_id: ImportId, servings: &[StagedImportServing]) -> Result<(), ImportError>;
    async fn add_error(&self, import_id: ImportId, error: &ImportErrorRecord) -> Result<(), ImportError>;
    async fn count_staged_foods(&self, import_id: ImportId) -> Result<i64, ImportError>;
    async fn commit_import(&self, import_id: ImportId) -> Result<ImportCommitResult, ImportError>;
    async fn get_errors(&self, import_id: ImportId) -> Result<Vec<ImportErrorRecord>, ImportError>;
}

#[derive(Debug, Clone)]
pub struct ImportCommitResult {
    pub products_created: i64,
    pub products_updated: i64,
    pub nutrients_inserted: i64,
    pub servings_inserted: i64,
    pub errors_logged: i64,
}

pub struct ImportServices {
    repo: Arc<dyn ImportRepository>,
}

impl Clone for ImportServices {
    fn clone(&self) -> Self {
        Self { repo: self.repo.clone() }
    }
}

impl ImportServices {
    pub fn new(repo: Arc<dyn ImportRepository>) -> Self {
        Self { repo }
    }

    pub async fn create_job(&self, source: String, created_by: Option<Uuid>) -> Result<ImportJob, ImportError> {
        let job = ImportJob::new(source, created_by);
        self.repo.create_job(&job).await?;
        Ok(job)
    }

    pub async fn stage_foods(&self, import_id: ImportId, foods: Vec<StagedImportProduct>) -> Result<StageResult, ImportError> {
        let job = self.repo.find_job(import_id).await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus("can only stage foods on a pending import".into()));
        }

        let mut accepted = 0i64;
        let mut rejected = 0i64;
        let mut errors = Vec::new();

        for food in &foods {
            if food.source.is_empty() || food.source_id.is_empty() || food.name.is_empty() {
                rejected += 1;
                errors.push(ImportErrorRecord {
                    row_number: food.row_number,
                    error: "source, source_id, and name are required".into(),
                    raw_payload: food.raw_payload.clone(),
                });
                continue;
            }
            accepted += 1;
        }

        let valid_foods: Vec<StagedImportProduct> = foods.into_iter()
            .filter(|f| !f.source.is_empty() && !f.source_id.is_empty() && !f.name.is_empty())
            .collect();

        if !valid_foods.is_empty() {
            self.repo.stage_foods(import_id, &valid_foods).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult { accepted, rejected })
    }

    pub async fn stage_nutrients(&self, import_id: ImportId, nutrients: Vec<StagedImportNutrient>) -> Result<StageResult, ImportError> {
        let job = self.repo.find_job(import_id).await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus("can only stage nutrients on a pending import".into()));
        }

        let mut accepted = 0i64;
        let mut rejected = 0i64;
        let mut errors = Vec::new();

        for nutrient in &nutrients {
            if nutrient.nutrient_code.is_empty() || nutrient.source.is_empty() || nutrient.source_id.is_empty() {
                rejected += 1;
                errors.push(ImportErrorRecord {
                    row_number: nutrient.row_number,
                    error: "source, source_id, nutrient_code, and amount_per_100g are required".into(),
                    raw_payload: nutrient.raw_payload.clone(),
                });
                continue;
            }
            accepted += 1;
        }

        let valid: Vec<StagedImportNutrient> = nutrients.into_iter()
            .filter(|n| !n.nutrient_code.is_empty() && !n.source.is_empty() && !n.source_id.is_empty())
            .collect();

        if !valid.is_empty() {
            self.repo.stage_nutrients(import_id, &valid).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult { accepted, rejected })
    }

    pub async fn stage_servings(&self, import_id: ImportId, servings: Vec<StagedImportServing>) -> Result<StageResult, ImportError> {
        let job = self.repo.find_job(import_id).await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus("can only stage servings on a pending import".into()));
        }

        let mut accepted = 0i64;
        let mut rejected = 0i64;
        let mut errors = Vec::new();

        for s in &servings {
            let invalid = s.source.is_empty()
                || s.source_id.is_empty()
                || s.label.is_empty()
                || s.unit.is_empty()
                || s.quantity <= rust_decimal::Decimal::ZERO
                || s.grams <= rust_decimal::Decimal::ZERO;
            if invalid {
                rejected += 1;
                errors.push(ImportErrorRecord {
                    row_number: s.row_number,
                    error: "source, source_id, label, unit, positive quantity and positive grams are required".into(),
                    raw_payload: s.raw_payload.clone(),
                });
                continue;
            }
            accepted += 1;
        }

        let valid: Vec<StagedImportServing> = servings.into_iter()
            .filter(|s| !s.source.is_empty()
                && !s.source_id.is_empty()
                && !s.label.is_empty()
                && !s.unit.is_empty()
                && s.quantity > rust_decimal::Decimal::ZERO
                && s.grams > rust_decimal::Decimal::ZERO)
            .collect();

        if !valid.is_empty() {
            self.repo.stage_servings(import_id, &valid).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult { accepted, rejected })
    }

    pub async fn commit_job(&self, import_id: ImportId) -> Result<ImportCommitResult, ImportError> {
        let job = self.repo.find_job(import_id).await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus("can only commit a pending import".into()));
        }

        let food_count = self.repo.count_staged_foods(import_id).await?;
        if food_count == 0 {
            return Err(ImportError::Validation("no staged foods to commit".into()));
        }

        self.repo.commit_import(import_id).await
    }

    pub async fn get_job(&self, import_id: ImportId) -> Result<ImportJob, ImportError> {
        self.repo.find_job(import_id).await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))
    }

    pub async fn get_errors(&self, import_id: ImportId) -> Result<Vec<ImportErrorRecord>, ImportError> {
        self.repo.get_errors(import_id).await
    }
}

#[derive(Debug, Clone)]
pub struct StageResult {
    pub accepted: i64,
    pub rejected: i64,
}

#[derive(Debug)]
pub enum ImportError {
    NotFound(String),
    InvalidStatus(String),
    Validation(String),
    Database(String),
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImportError::NotFound(msg) => write!(f, "not found: {msg}"),
            ImportError::InvalidStatus(msg) => write!(f, "invalid status: {msg}"),
            ImportError::Validation(msg) => write!(f, "validation: {msg}"),
            ImportError::Database(msg) => write!(f, "database: {msg}"),
        }
    }
}

impl std::error::Error for ImportError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct MockImportRepo {
        jobs: Mutex<Vec<ImportJob>>,
        foods: Mutex<Vec<StagedImportProduct>>,
        nutrients: Mutex<Vec<StagedImportNutrient>>,
        servings: Mutex<Vec<StagedImportServing>>,
        errors: Mutex<Vec<ImportErrorRecord>>,
        commit_result: Mutex<Option<ImportCommitResult>>,
    }

    impl MockImportRepo {
        fn new() -> Self {
            Self {
                jobs: Mutex::new(vec![]),
                foods: Mutex::new(vec![]),
                nutrients: Mutex::new(vec![]),
                servings: Mutex::new(vec![]),
                errors: Mutex::new(vec![]),
                commit_result: Mutex::new(None),
            }
        }

        fn with_commit_result(result: ImportCommitResult) -> Self {
            Self {
                jobs: Mutex::new(vec![]),
                foods: Mutex::new(vec![]),
                nutrients: Mutex::new(vec![]),
                servings: Mutex::new(vec![]),
                errors: Mutex::new(vec![]),
                commit_result: Mutex::new(Some(result)),
            }
        }
    }

    #[async_trait]
    impl ImportRepository for MockImportRepo {
        async fn create_job(&self, job: &ImportJob) -> Result<(), ImportError> {
            self.jobs.lock().unwrap().push(job.clone());
            Ok(())
        }

        async fn find_job(&self, id: ImportId) -> Result<Option<ImportJob>, ImportError> {
            let jobs = self.jobs.lock().unwrap();
            Ok(jobs.iter().find(|j| j.id == id).cloned())
        }

        async fn stage_foods(&self, _import_id: ImportId, foods: &[StagedImportProduct]) -> Result<(), ImportError> {
            self.foods.lock().unwrap().extend(foods.iter().cloned());
            Ok(())
        }

        async fn stage_nutrients(&self, _import_id: ImportId, nutrients: &[StagedImportNutrient]) -> Result<(), ImportError> {
            self.nutrients.lock().unwrap().extend(nutrients.iter().cloned());
            Ok(())
        }

        async fn stage_servings(&self, _import_id: ImportId, servings: &[StagedImportServing]) -> Result<(), ImportError> {
            self.servings.lock().unwrap().extend(servings.iter().cloned());
            Ok(())
        }

        async fn add_error(&self, _import_id: ImportId, error: &ImportErrorRecord) -> Result<(), ImportError> {
            self.errors.lock().unwrap().push(error.clone());
            Ok(())
        }

        async fn count_staged_foods(&self, _import_id: ImportId) -> Result<i64, ImportError> {
            Ok(self.foods.lock().unwrap().len() as i64)
        }

        async fn commit_import(&self, _import_id: ImportId) -> Result<ImportCommitResult, ImportError> {
            self.commit_result.lock().unwrap().clone().ok_or_else(|| ImportError::Database("no result set".into()))
        }

        async fn get_errors(&self, _import_id: ImportId) -> Result<Vec<ImportErrorRecord>, ImportError> {
            Ok(self.errors.lock().unwrap().clone())
        }
    }

    fn make_services() -> ImportServices {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepository>;
        ImportServices::new(repo)
    }

    fn make_services_with_result(result: ImportCommitResult) -> ImportServices {
        let repo = Arc::new(MockImportRepo::with_commit_result(result)) as Arc<dyn ImportRepository>;
        ImportServices::new(repo)
    }

    #[tokio::test]
    async fn test_create_job_success() {
        let services = make_services();
        let job = services.create_job("USDA".into(), None).await.unwrap();
        assert_eq!(job.source, "USDA");
        assert_eq!(job.status, ImportStatus::Pending);
        assert!(job.created_by.is_none());
    }

    #[tokio::test]
    async fn test_stage_foods_success() {
        let services = make_services();
        let job = services.create_job("OFF".into(), None).await.unwrap();

        let result = services.stage_foods(job.id, vec![
            StagedImportProduct {
                source: "OFF".into(),
                source_id: "123".into(),
                barcode: Some("8901234567890".into()),
                name: "Test Product".into(),
                brand: Some("Test Brand".into()),
                category: Some("Snacks".into()),
                serving_size_g: Some(rust_decimal::Decimal::new(100, 0)),
                raw_payload: None,
                row_number: Some(1),
            },
            StagedImportProduct {
                source: "OFF".into(),
                source_id: "456".into(),
                barcode: None,
                name: "Another Product".into(),
                brand: None,
                category: None,
                serving_size_g: None,
                raw_payload: None,
                row_number: Some(2),
            },
        ]).await.unwrap();

        assert_eq!(result.accepted, 2);
        assert_eq!(result.rejected, 0);
    }

    #[tokio::test]
    async fn test_stage_foods_rejects_invalid() {
        let services = make_services();
        let job = services.create_job("OFF".into(), None).await.unwrap();

        let result = services.stage_foods(job.id, vec![
            StagedImportProduct {
                source: String::new(),
                source_id: String::new(),
                barcode: None,
                name: String::new(),
                brand: None,
                category: None,
                serving_size_g: None,
                raw_payload: None,
                row_number: Some(1),
            },
        ]).await.unwrap();

        assert_eq!(result.accepted, 0);
        assert_eq!(result.rejected, 1);
    }

    #[tokio::test]
    async fn test_stage_nutrients_success() {
        let services = make_services();
        let job = services.create_job("USDA".into(), None).await.unwrap();

        let result = services.stage_nutrients(job.id, vec![
            StagedImportNutrient {
                source: "USDA".into(),
                source_id: "123".into(),
                nutrient_code: "ENERGY_KCAL".into(),
                amount_per_100g: rust_decimal::Decimal::new(250, 0),
                raw_payload: None,
                row_number: Some(1),
            },
        ]).await.unwrap();

        assert_eq!(result.accepted, 1);
        assert_eq!(result.rejected, 0);
    }

    #[tokio::test]
    async fn test_stage_nutrients_rejects_invalid() {
        let services = make_services();
        let job = services.create_job("USDA".into(), None).await.unwrap();

        let result = services.stage_nutrients(job.id, vec![
            StagedImportNutrient {
                source: String::new(),
                source_id: String::new(),
                nutrient_code: String::new(),
                amount_per_100g: rust_decimal::Decimal::ZERO,
                raw_payload: None,
                row_number: Some(1),
            },
        ]).await.unwrap();

        assert_eq!(result.accepted, 0);
        assert_eq!(result.rejected, 1);
    }

    #[tokio::test]
    async fn test_commit_job_success() {
        let services = make_services_with_result(ImportCommitResult {
            products_created: 2,
            products_updated: 0,
            nutrients_inserted: 4,
            servings_inserted: 0,
            errors_logged: 0,
        });
        let job = services.create_job("IFCT".into(), None).await.unwrap();

        services.stage_foods(job.id, vec![
            StagedImportProduct {
                source: "IFCT".into(),
                source_id: "A001".into(),
                barcode: None,
                name: "Rice".into(),
                brand: None,
                category: Some("Cereals".into()),
                serving_size_g: None,
                raw_payload: None,
                row_number: Some(1),
            },
        ]).await.unwrap();

        let result = services.commit_job(job.id).await.unwrap();
        assert_eq!(result.products_created, 2);
        assert_eq!(result.products_updated, 0);
        assert_eq!(result.nutrients_inserted, 4);
        assert_eq!(result.errors_logged, 0);
    }

    #[tokio::test]
    async fn test_commit_fails_when_no_foods_staged() {
        let services = make_services();
        let job = services.create_job("USDA".into(), None).await.unwrap();

        let err = services.commit_job(job.id).await.unwrap_err();
        match err {
            ImportError::Validation(msg) => assert!(msg.contains("no staged foods")),
            _ => panic!("expected validation error"),
        }
    }

    #[tokio::test]
    async fn test_get_job_not_found() {
        let services = make_services();
        let err = services.get_job(ImportId(uuid::Uuid::nil())).await.unwrap_err();
        match err {
            ImportError::NotFound(_) => {} // expected
            _ => panic!("expected not found error"),
        }
    }

    #[tokio::test]
    async fn test_stage_foods_fails_on_non_pending_job() {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepository>;

        let mut job = ImportJob::new("OFF".into(), None);
        job.status = ImportStatus::Committed;
        repo.create_job(&job).await.unwrap();

        let services = ImportServices::new(repo);

        let err = services.stage_foods(job.id, vec![
            StagedImportProduct {
                source: "OFF".into(),
                source_id: "123".into(),
                barcode: None,
                name: "Product".into(),
                brand: None,
                category: None,
                serving_size_g: None,
                raw_payload: None,
                row_number: None,
            },
        ]).await.unwrap_err();

        match err {
            ImportError::InvalidStatus(_) => {} // expected
            _ => panic!("expected invalid status error"),
        }
    }

    #[tokio::test]
    async fn test_get_errors_returns_staged_errors() {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepository>;

        let job = ImportJob::new("USDA".into(), None);
        repo.create_job(&job).await.unwrap();

        repo.add_error(job.id, &ImportErrorRecord {
            row_number: Some(5),
            error: "Unknown nutrient code: UNKNOWN_X".into(),
            raw_payload: None,
        }).await.unwrap();

        let services = ImportServices::new(repo);
        let errors = services.get_errors(job.id).await.unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].row_number, Some(5));
        assert!(errors[0].error.contains("UNKNOWN_X"));
    }

    #[tokio::test]
    async fn test_commit_job_with_errors() {
        let services = make_services_with_result(ImportCommitResult {
            products_created: 1,
            products_updated: 0,
            nutrients_inserted: 2,
            servings_inserted: 0,
            errors_logged: 1,
        });
        let job = services.create_job("USDA".into(), None).await.unwrap();

        services.stage_foods(job.id, vec![
            StagedImportProduct {
                source: "USDA".into(),
                source_id: "999".into(),
                barcode: None,
                name: "Test".into(),
                brand: None,
                category: None,
                serving_size_g: None,
                raw_payload: None,
                row_number: Some(1),
            },
        ]).await.unwrap();

        let result = services.commit_job(job.id).await.unwrap();
        assert_eq!(result.products_created, 1);
        assert_eq!(result.errors_logged, 1);
    }
}

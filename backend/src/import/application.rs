use std::str::FromStr;
use std::sync::Arc;

use crate::import::domain::*;
use crate::nutrition::catalog::domain::{AmountPer100g, Source};

fn validate_staged_food(food: &StagedImportProduct) -> Result<(), String> {
    Source::from_str(&food.source)?;
    if food.source_id.is_empty() {
        return Err("source_id is required".into());
    }
    if food.name.is_empty() {
        return Err("name is required".into());
    }
    Ok(())
}

fn validate_staged_nutrient(nutrient: &StagedImportNutrient) -> Result<(), String> {
    Source::from_str(&nutrient.source)?;
    if nutrient.source_id.is_empty() {
        return Err("source_id is required".into());
    }
    if nutrient.nutrient_code.is_empty() {
        return Err("nutrient_code is required".into());
    }
    AmountPer100g::new(nutrient.amount_per_100g).map_err(|e| e.to_string())?;
    Ok(())
}

fn validate_staged_serving(serving: &StagedImportServing) -> Result<(), String> {
    Source::from_str(&serving.source)?;
    if serving.source_id.is_empty() {
        return Err("source_id is required".into());
    }
    if serving.label.is_empty() {
        return Err("label is required".into());
    }
    if serving.unit.is_empty() {
        return Err("unit is required".into());
    }
    if serving.quantity <= rust_decimal::Decimal::ZERO {
        return Err("quantity must be positive".into());
    }
    if serving.grams <= rust_decimal::Decimal::ZERO {
        return Err("grams must be positive".into());
    }
    Ok(())
}

#[derive(Clone)]
pub struct ImportService {
    repo: Arc<dyn ImportRepository>,
}

impl ImportService {
    pub fn new(repo: Arc<dyn ImportRepository>) -> Self {
        Self { repo }
    }

    pub async fn stage_foods(
        &self,
        import_id: ImportId,
        foods: Vec<StagedImportProduct>,
    ) -> Result<StageResult, ImportError> {
        let job = self
            .repo
            .find_job(import_id)
            .await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus(
                "can only stage foods on a pending import".into(),
            ));
        }

        let mut valid_foods = Vec::new();
        let mut errors = Vec::new();

        for food in foods {
            match validate_staged_food(&food) {
                Ok(()) => valid_foods.push(food),
                Err(error) => errors.push(ImportErrorRecord {
                    row_number: food.row_number,
                    error,
                    raw_payload: food.raw_payload.clone(),
                }),
            }
        }

        if !valid_foods.is_empty() {
            self.repo.stage_foods(import_id, &valid_foods).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult {
            accepted: valid_foods.len() as i64,
            rejected: errors.len() as i64,
        })
    }

    pub async fn stage_nutrients(
        &self,
        import_id: ImportId,
        nutrients: Vec<StagedImportNutrient>,
    ) -> Result<StageResult, ImportError> {
        let job = self
            .repo
            .find_job(import_id)
            .await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus(
                "can only stage nutrients on a pending import".into(),
            ));
        }

        let mut valid = Vec::new();
        let mut errors = Vec::new();

        for nutrient in nutrients {
            match validate_staged_nutrient(&nutrient) {
                Ok(()) => valid.push(nutrient),
                Err(error) => errors.push(ImportErrorRecord {
                    row_number: nutrient.row_number,
                    error,
                    raw_payload: nutrient.raw_payload.clone(),
                }),
            }
        }

        if !valid.is_empty() {
            self.repo.stage_nutrients(import_id, &valid).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult {
            accepted: valid.len() as i64,
            rejected: errors.len() as i64,
        })
    }

    pub async fn stage_servings(
        &self,
        import_id: ImportId,
        servings: Vec<StagedImportServing>,
    ) -> Result<StageResult, ImportError> {
        let job = self
            .repo
            .find_job(import_id)
            .await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus(
                "can only stage servings on a pending import".into(),
            ));
        }

        let mut valid = Vec::new();
        let mut errors = Vec::new();

        for serving in servings {
            match validate_staged_serving(&serving) {
                Ok(()) => valid.push(serving),
                Err(error) => errors.push(ImportErrorRecord {
                    row_number: serving.row_number,
                    error,
                    raw_payload: serving.raw_payload.clone(),
                }),
            }
        }

        if !valid.is_empty() {
            self.repo.stage_servings(import_id, &valid).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult {
            accepted: valid.len() as i64,
            rejected: errors.len() as i64,
        })
    }

    pub async fn commit_job(&self, import_id: ImportId) -> Result<ImportCommitResult, ImportError> {
        let job = self
            .repo
            .find_job(import_id)
            .await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;

        if job.status != ImportStatus::Pending {
            return Err(ImportError::InvalidStatus(
                "can only commit a pending import".into(),
            ));
        }

        // Foods are the primary entity — nutrients and servings attach to them, so an
        // import with zero foods has nothing to commit even if other rows were staged.
        let food_count = self.repo.count_staged_foods(import_id).await?;
        if food_count == 0 {
            return Err(ImportError::Validation("no staged foods to commit".into()));
        }

        self.repo.commit_import(import_id).await
    }
}

#[derive(Debug, Clone)]
pub struct StageResult {
    pub accepted: i64,
    pub rejected: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
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

        async fn stage_foods(
            &self,
            _import_id: ImportId,
            foods: &[StagedImportProduct],
        ) -> Result<(), ImportError> {
            self.foods.lock().unwrap().extend(foods.iter().cloned());
            Ok(())
        }

        async fn stage_nutrients(
            &self,
            _import_id: ImportId,
            nutrients: &[StagedImportNutrient],
        ) -> Result<(), ImportError> {
            self.nutrients
                .lock()
                .unwrap()
                .extend(nutrients.iter().cloned());
            Ok(())
        }

        async fn stage_servings(
            &self,
            _import_id: ImportId,
            servings: &[StagedImportServing],
        ) -> Result<(), ImportError> {
            self.servings
                .lock()
                .unwrap()
                .extend(servings.iter().cloned());
            Ok(())
        }

        async fn add_error(
            &self,
            _import_id: ImportId,
            error: &ImportErrorRecord,
        ) -> Result<(), ImportError> {
            self.errors.lock().unwrap().push(error.clone());
            Ok(())
        }

        async fn count_staged_foods(&self, _import_id: ImportId) -> Result<i64, ImportError> {
            Ok(self.foods.lock().unwrap().len() as i64)
        }

        async fn commit_import(
            &self,
            _import_id: ImportId,
        ) -> Result<ImportCommitResult, ImportError> {
            self.commit_result
                .lock()
                .unwrap()
                .clone()
                .ok_or(ImportError::Database(sqlx::Error::RowNotFound))
        }

        async fn get_errors(
            &self,
            _import_id: ImportId,
        ) -> Result<Vec<ImportErrorRecord>, ImportError> {
            Ok(self.errors.lock().unwrap().clone())
        }
    }

    fn make_services() -> ImportService {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepository>;
        ImportService::new(repo)
    }

    fn make_services_with_result(result: ImportCommitResult) -> ImportService {
        let repo =
            Arc::new(MockImportRepo::with_commit_result(result)) as Arc<dyn ImportRepository>;
        ImportService::new(repo)
    }

    async fn make_pending_job(services: &ImportService, source: &str) -> ImportJob {
        let job = ImportJob::new(source.into(), None);
        services.repo.create_job(&job).await.unwrap();
        job
    }

    #[tokio::test]
    async fn test_stage_foods_success() {
        let services = make_services();
        let job = make_pending_job(&services, "OFF").await;

        let result = services
            .stage_foods(
                job.id,
                vec![
                    StagedImportProduct {
                        source: "OFF".into(),
                        source_id: "123".into(),
                        barcode: Some("8901234567890".into()),
                        name: "Test Product".into(),
                        brand: Some("Test Brand".into()),
                        categories: vec!["snacks".into()],
                        raw_payload: None,
                        row_number: Some(1),
                    },
                    StagedImportProduct {
                        source: "OFF".into(),
                        source_id: "456".into(),
                        barcode: None,
                        name: "Another Product".into(),
                        brand: None,
                        categories: vec![],
                        raw_payload: None,
                        row_number: Some(2),
                    },
                ],
            )
            .await
            .unwrap();

        assert_eq!(result.accepted, 2);
        assert_eq!(result.rejected, 0);
    }

    #[tokio::test]
    async fn test_stage_foods_rejects_invalid() {
        let services = make_services();
        let job = make_pending_job(&services, "OFF").await;

        let result = services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: String::new(),
                    source_id: String::new(),
                    barcode: None,
                    name: String::new(),
                    brand: None,
                    categories: vec![],
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        assert_eq!(result.accepted, 0);
        assert_eq!(result.rejected, 1);
    }

    #[tokio::test]
    async fn test_stage_nutrients_success() {
        let services = make_services();
        let job = make_pending_job(&services, "USDA").await;

        let result = services
            .stage_nutrients(
                job.id,
                vec![StagedImportNutrient {
                    source: "USDA".into(),
                    source_id: "123".into(),
                    nutrient_code: "ENERGY_KCAL".into(),
                    amount_per_100g: rust_decimal::Decimal::new(250, 0),
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        assert_eq!(result.accepted, 1);
        assert_eq!(result.rejected, 0);
    }

    #[tokio::test]
    async fn test_stage_nutrients_rejects_invalid() {
        let services = make_services();
        let job = make_pending_job(&services, "USDA").await;

        let result = services
            .stage_nutrients(
                job.id,
                vec![StagedImportNutrient {
                    source: String::new(),
                    source_id: String::new(),
                    nutrient_code: String::new(),
                    amount_per_100g: rust_decimal::Decimal::ZERO,
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

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
        let job = make_pending_job(&services, "IFCT").await;

        services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: "IFCT".into(),
                    source_id: "A001".into(),
                    barcode: None,
                    name: "Rice".into(),
                    brand: None,
                    categories: vec!["cereals".into()],
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        let result = services.commit_job(job.id).await.unwrap();
        assert_eq!(result.products_created, 2);
        assert_eq!(result.products_updated, 0);
        assert_eq!(result.nutrients_inserted, 4);
        assert_eq!(result.errors_logged, 0);
    }

    #[tokio::test]
    async fn test_commit_job_success_indb() {
        let services = make_services_with_result(ImportCommitResult {
            products_created: 2,
            products_updated: 0,
            nutrients_inserted: 4,
            servings_inserted: 0,
            errors_logged: 0,
        });
        let job = make_pending_job(&services, "INDB").await;

        services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: "INDB".into(),
                    source_id: "ASC001".into(),
                    barcode: None,
                    name: "Hot tea (Garam Chai)".into(),
                    brand: None,
                    categories: vec![],
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        let result = services.commit_job(job.id).await.unwrap();
        assert_eq!(result.products_created, 2);
        assert_eq!(result.products_updated, 0);
        assert_eq!(result.nutrients_inserted, 4);
        assert_eq!(result.errors_logged, 0);
    }

    #[tokio::test]
    async fn test_commit_fails_when_no_foods_staged() {
        let services = make_services();
        let job = make_pending_job(&services, "USDA").await;

        let err = services.commit_job(job.id).await.unwrap_err();
        match err {
            ImportError::Validation(_) => {}
            _ => panic!("expected validation error"),
        }
    }

    #[tokio::test]
    async fn test_stage_foods_fails_on_non_pending_job() {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepository>;

        let mut job = ImportJob::new("OFF".into(), None);
        job.status = ImportStatus::Committed;
        repo.create_job(&job).await.unwrap();

        let services = ImportService::new(repo);

        let err = services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: "OFF".into(),
                    source_id: "123".into(),
                    barcode: None,
                    name: "Product".into(),
                    brand: None,
                    categories: vec![],
                    raw_payload: None,
                    row_number: None,
                }],
            )
            .await
            .unwrap_err();

        match err {
            ImportError::InvalidStatus(_) => {} // expected
            _ => panic!("expected invalid status error"),
        }
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
        let job = make_pending_job(&services, "USDA").await;

        services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: "USDA".into(),
                    source_id: "999".into(),
                    barcode: None,
                    name: "Test".into(),
                    brand: None,
                    categories: vec![],
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        let result = services.commit_job(job.id).await.unwrap();
        assert_eq!(result.products_created, 1);
        assert_eq!(result.errors_logged, 1);
    }
}

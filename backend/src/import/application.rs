use std::sync::Arc;

use crate::import::domain::*;

pub struct ImportServices {
    repo: Arc<dyn ImportRepository>,
}

impl Clone for ImportServices {
    fn clone(&self) -> Self {
        Self {
            repo: self.repo.clone(),
        }
    }
}

impl ImportServices {
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

        let valid_foods: Vec<StagedImportProduct> = foods
            .into_iter()
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

        let mut accepted = 0i64;
        let mut rejected = 0i64;
        let mut errors = Vec::new();

        for nutrient in &nutrients {
            if nutrient.nutrient_code.is_empty()
                || nutrient.source.is_empty()
                || nutrient.source_id.is_empty()
            {
                rejected += 1;
                errors.push(ImportErrorRecord {
                    row_number: nutrient.row_number,
                    error: "source, source_id, nutrient_code, and amount_per_100g are required"
                        .into(),
                    raw_payload: nutrient.raw_payload.clone(),
                });
                continue;
            }
            accepted += 1;
        }

        let valid: Vec<StagedImportNutrient> = nutrients
            .into_iter()
            .filter(|n| {
                !n.nutrient_code.is_empty() && !n.source.is_empty() && !n.source_id.is_empty()
            })
            .collect();

        if !valid.is_empty() {
            self.repo.stage_nutrients(import_id, &valid).await?;
        }

        for err in &errors {
            self.repo.add_error(import_id, err).await?;
        }

        Ok(StageResult { accepted, rejected })
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

        let valid: Vec<StagedImportServing> = servings
            .into_iter()
            .filter(|s| {
                !s.source.is_empty()
                    && !s.source_id.is_empty()
                    && !s.label.is_empty()
                    && !s.unit.is_empty()
                    && s.quantity > rust_decimal::Decimal::ZERO
                    && s.grams > rust_decimal::Decimal::ZERO
            })
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

    fn make_services() -> ImportServices {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepository>;
        ImportServices::new(repo)
    }

    fn make_services_with_result(result: ImportCommitResult) -> ImportServices {
        let repo =
            Arc::new(MockImportRepo::with_commit_result(result)) as Arc<dyn ImportRepository>;
        ImportServices::new(repo)
    }

    async fn make_pending_job(services: &ImportServices, source: &str) -> ImportJob {
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
                        categories: vec![],
                        serving_size_g: None,
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
                    serving_size_g: None,
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
                    serving_size_g: None,
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

        let services = ImportServices::new(repo);

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
                    serving_size_g: None,
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
                    serving_size_g: None,
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

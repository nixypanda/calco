use std::collections::BTreeMap;
use std::str::FromStr;
use std::sync::Arc;

use crate::import::domain::*;
use crate::nutrition::catalog::app::{ExternalProductWritePort, NutrientCatalogReadPort};
use crate::nutrition::catalog::domain::{
    AmountPer100g, ExternalProductBuilder, ExternalSource, NutrientCatalog, Product,
    ProductNutrientInput, ProductServingInput,
};
use crate::nutrition::error::NutritionError;

fn validate_staged_food(food: &StagedImportProduct) -> Result<(), String> {
    ExternalSource::from_str(&food.source)?;
    if food.source_id.trim().is_empty() {
        return Err("source_id is required".into());
    }
    if food.name.trim().is_empty() {
        return Err("name is required".into());
    }
    Ok(())
}

fn validate_staged_nutrient(nutrient: &StagedImportNutrient) -> Result<(), String> {
    ExternalSource::from_str(&nutrient.source)?;
    if nutrient.source_id.trim().is_empty() {
        return Err("source_id is required".into());
    }
    if nutrient.nutrient_code.trim().is_empty() {
        return Err("nutrient_code is required".into());
    }
    AmountPer100g::new(nutrient.amount_per_100g).map_err(|e| e.to_string())?;
    Ok(())
}

fn validate_staged_serving(serving: &StagedImportServing) -> Result<(), String> {
    ExternalSource::from_str(&serving.source)?;
    if serving.source_id.trim().is_empty() {
        return Err("source_id is required".into());
    }
    if serving.unit.trim().is_empty() {
        return Err("unit is required".into());
    }
    if serving.grams_per_unit <= rust_decimal::Decimal::ZERO {
        return Err("grams_per_unit must be positive".into());
    }
    Ok(())
}

#[derive(Clone)]
pub struct ImportService {
    repo: Arc<dyn ImportRepo>,
    external_product_writer: Arc<dyn ExternalProductWritePort>,
    nutrient_catalog_reader: Arc<dyn NutrientCatalogReadPort>,
}

impl ImportService {
    pub fn new(
        repo: Arc<dyn ImportRepo>,
        external_product_writer: Arc<dyn ExternalProductWritePort>,
        nutrient_catalog_reader: Arc<dyn NutrientCatalogReadPort>,
    ) -> Self {
        Self {
            repo,
            external_product_writer,
            nutrient_catalog_reader,
        }
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

        self.repo
            .stage_foods(import_id, &valid_foods, &errors)
            .await?;

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

        self.repo
            .stage_nutrients(import_id, &valid, &errors)
            .await?;

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

        self.repo.stage_servings(import_id, &valid, &errors).await?;

        Ok(StageResult {
            accepted: valid.len() as i64,
            rejected: errors.len() as i64,
        })
    }

    pub async fn commit_job(&self, import_id: ImportId) -> Result<ImportCommitResult, ImportError> {
        let batch = self.repo.prepare_commit(import_id).await?;

        let nutrient_catalog = match self.nutrient_catalog_reader.nutrient_catalog().await {
            Ok(catalog) => catalog,
            Err(NutritionError::Validation(message)) => {
                self.repo
                    .finish_commit(import_id, ImportCommitOutcome::Failed)
                    .await?;
                return Err(ImportError::Validation(message));
            }
            Err(error) => return Err(import_product_error(error)),
        };
        let (products, errors) = match assemble_products(batch, &nutrient_catalog) {
            Ok(assembled) => assembled,
            Err(error) => {
                self.repo
                    .finish_commit(import_id, ImportCommitOutcome::Failed)
                    .await?;
                return Err(error);
            }
        };
        let written = match self
            .external_product_writer
            .upsert_external_many(products)
            .await
        {
            Ok(written) => written,
            Err(NutritionError::Validation(message)) => {
                self.repo
                    .finish_commit(import_id, ImportCommitOutcome::Failed)
                    .await?;
                return Err(ImportError::Validation(message));
            }
            Err(error) => return Err(import_product_error(error)),
        };
        let result = ImportCommitResult {
            products_created: written.created,
            products_updated: written.updated,
            nutrients_written: written.nutrients_written,
            servings_written: written.servings_written,
            errors_logged: errors.len() as i64,
        };

        self.repo
            .finish_commit(
                import_id,
                ImportCommitOutcome::Committed {
                    result: result.clone(),
                    errors,
                },
            )
            .await?;
        Ok(result)
    }
}

type ProductKey = (String, String);

fn product_key(source: &str, source_id: &str) -> ProductKey {
    (source.to_owned(), source_id.trim().to_owned())
}

fn assemble_products(
    batch: StagedImportBatch,
    nutrient_catalog: &NutrientCatalog,
) -> Result<(Vec<Product>, Vec<ImportErrorRecord>), ImportError> {
    let mut nutrients_by_product: BTreeMap<ProductKey, Vec<StagedImportNutrient>> = BTreeMap::new();
    for nutrient in batch.nutrients {
        nutrients_by_product
            .entry(product_key(&nutrient.source, &nutrient.source_id))
            .or_default()
            .push(nutrient);
    }

    let mut servings_by_product: BTreeMap<ProductKey, Vec<StagedImportServing>> = BTreeMap::new();
    for serving in batch.servings {
        servings_by_product
            .entry(product_key(&serving.source, &serving.source_id))
            .or_default()
            .push(serving);
    }

    let mut products = Vec::with_capacity(batch.products.len());
    let mut errors = Vec::new();

    for staged in batch.products {
        let key = product_key(&staged.source, &staged.source_id);
        let source = ExternalSource::from_str(&staged.source).map_err(ImportError::Validation)?;
        let confidence = source.default_nutrient_confidence().as_str().to_string();
        let mut nutrient_inputs = Vec::new();

        for nutrient in nutrients_by_product.remove(&key).unwrap_or_default() {
            let nutrient_code = nutrient.nutrient_code.trim();
            if nutrient_catalog.get(nutrient_code).is_none() {
                errors.push(ImportErrorRecord {
                    row_number: nutrient.row_number,
                    error: format!("Unknown nutrient code: {}", nutrient.nutrient_code),
                    raw_payload: nutrient.raw_payload,
                });
                continue;
            }
            nutrient_inputs.push(ProductNutrientInput {
                code: nutrient_code.to_owned(),
                amount_per_100g: nutrient.amount_per_100g,
                source: Some(staged.source.clone()),
                confidence: Some(confidence.clone()),
            });
        }

        let serving_inputs = servings_by_product
            .remove(&key)
            .unwrap_or_default()
            .into_iter()
            .map(|serving| ProductServingInput {
                unit: serving.unit.trim().to_owned(),
                grams_per_unit: serving.grams_per_unit,
            })
            .collect();

        products.push(
            Product::new_external(
                source,
                ExternalProductBuilder::new(staged.source_id, staged.name)
                    .barcode(staged.barcode)
                    .brand(staged.brand)
                    .categories(staged.categories)
                    .nutrients(nutrient_inputs)
                    .servings(serving_inputs),
                nutrient_catalog,
            )
            .map_err(import_product_error)?,
        );
    }

    for (_, orphaned) in nutrients_by_product {
        for nutrient in orphaned {
            errors.push(ImportErrorRecord {
                row_number: nutrient.row_number,
                error: format!(
                    "No staged product for nutrient code {}: {}/{}",
                    nutrient.nutrient_code, nutrient.source, nutrient.source_id
                ),
                raw_payload: nutrient.raw_payload,
            });
        }
    }
    for (_, orphaned) in servings_by_product {
        for serving in orphaned {
            errors.push(ImportErrorRecord {
                row_number: serving.row_number,
                error: format!(
                    "No staged product for serving unit {}: {}/{}",
                    serving.unit, serving.source, serving.source_id
                ),
                raw_payload: serving.raw_payload,
            });
        }
    }

    Ok((products, errors))
}

fn import_product_error(error: NutritionError) -> ImportError {
    match error {
        NutritionError::Validation(message) => ImportError::Validation(message),
        other => ImportError::Catalog(other.to_string()),
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

    use crate::nutrition::catalog::domain::*;

    struct MockImportRepo {
        jobs: Mutex<Vec<ImportJob>>,
        foods: Mutex<Vec<StagedImportProduct>>,
        nutrients: Mutex<Vec<StagedImportNutrient>>,
        servings: Mutex<Vec<StagedImportServing>>,
        errors: Mutex<Vec<ImportErrorRecord>>,
    }

    impl MockImportRepo {
        fn new() -> Self {
            Self {
                jobs: Mutex::new(vec![]),
                foods: Mutex::new(vec![]),
                nutrients: Mutex::new(vec![]),
                servings: Mutex::new(vec![]),
                errors: Mutex::new(vec![]),
            }
        }
    }

    #[async_trait]
    impl ImportRepo for MockImportRepo {
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
            errors: &[ImportErrorRecord],
        ) -> Result<(), ImportError> {
            self.foods.lock().unwrap().extend(foods.iter().cloned());
            self.errors.lock().unwrap().extend(errors.iter().cloned());
            Ok(())
        }

        async fn stage_nutrients(
            &self,
            _import_id: ImportId,
            nutrients: &[StagedImportNutrient],
            errors: &[ImportErrorRecord],
        ) -> Result<(), ImportError> {
            self.nutrients
                .lock()
                .unwrap()
                .extend(nutrients.iter().cloned());
            self.errors.lock().unwrap().extend(errors.iter().cloned());
            Ok(())
        }

        async fn stage_servings(
            &self,
            _import_id: ImportId,
            servings: &[StagedImportServing],
            errors: &[ImportErrorRecord],
        ) -> Result<(), ImportError> {
            self.servings
                .lock()
                .unwrap()
                .extend(servings.iter().cloned());
            self.errors.lock().unwrap().extend(errors.iter().cloned());
            Ok(())
        }

        async fn prepare_commit(
            &self,
            import_id: ImportId,
        ) -> Result<StagedImportBatch, ImportError> {
            let mut jobs = self.jobs.lock().unwrap();
            let job = jobs
                .iter_mut()
                .find(|job| job.id == import_id)
                .ok_or_else(|| ImportError::NotFound("import job not found".into()))?;
            if job.status == ImportStatus::Committed {
                return Err(ImportError::InvalidStatus(
                    "cannot commit an already committed import".into(),
                ));
            }
            if !matches!(job.status, ImportStatus::Pending | ImportStatus::Running) {
                return Err(ImportError::InvalidStatus("cannot commit import".into()));
            }
            let products = self.foods.lock().unwrap().clone();
            if products.is_empty() {
                return Err(ImportError::Validation("no staged foods to commit".into()));
            }
            job.status = ImportStatus::Running;
            Ok(StagedImportBatch {
                products,
                nutrients: self.nutrients.lock().unwrap().clone(),
                servings: self.servings.lock().unwrap().clone(),
            })
        }

        async fn finish_commit(
            &self,
            import_id: ImportId,
            outcome: ImportCommitOutcome,
        ) -> Result<(), ImportError> {
            let mut jobs = self.jobs.lock().unwrap();
            let job = jobs.iter_mut().find(|job| job.id == import_id).unwrap();
            if job.status != ImportStatus::Running {
                return Err(ImportError::InvalidStatus("import is not running".into()));
            }
            match outcome {
                ImportCommitOutcome::Committed { errors, .. } => {
                    self.errors.lock().unwrap().extend(errors);
                    job.status = ImportStatus::Committed;
                }
                ImportCommitOutcome::Failed => job.status = ImportStatus::Failed,
            }
            Ok(())
        }

        async fn get_errors(
            &self,
            _import_id: ImportId,
        ) -> Result<Vec<ImportErrorRecord>, ImportError> {
            Ok(self.errors.lock().unwrap().clone())
        }
    }

    struct MockExternalProductWriter {
        result: ProductUpsertResult,
        upserted: Mutex<Vec<Product>>,
    }

    #[async_trait]
    impl ExternalProductWritePort for MockExternalProductWriter {
        async fn upsert_external_many(
            &self,
            products: Vec<Product>,
        ) -> Result<ProductUpsertResult, NutritionError> {
            self.upserted.lock().unwrap().extend(products);
            Ok(self.result)
        }
    }

    struct FailingExternalProductWriter {
        error_is_validation: bool,
    }

    #[async_trait]
    impl ExternalProductWritePort for FailingExternalProductWriter {
        async fn upsert_external_many(
            &self,
            _products: Vec<Product>,
        ) -> Result<ProductUpsertResult, NutritionError> {
            if self.error_is_validation {
                Err(NutritionError::Validation(
                    "deterministic catalog validation failure".into(),
                ))
            } else {
                Err(NutritionError::ExternalUnavailable)
            }
        }
    }

    struct MockNutrientCatalogReader;

    fn energy_nutrient() -> Nutrient {
        Nutrient {
            code: NutrientCode("ENERGY_KCAL".into()),
            name: "Energy".into(),
            unit: UnitCode("kcal".into()),
            category: "macro".into(),
        }
    }

    #[async_trait]
    impl NutrientCatalogReadPort for MockNutrientCatalogReader {
        async fn nutrient_catalog(&self) -> Result<NutrientCatalog, NutritionError> {
            Ok(vec![energy_nutrient()].into_iter().collect())
        }
    }

    fn make_services() -> ImportService {
        let repo = Arc::new(MockImportRepo::new()) as Arc<dyn ImportRepo>;
        ImportService::new(
            repo,
            Arc::new(MockExternalProductWriter {
                result: ProductUpsertResult::default(),
                upserted: Mutex::new(vec![]),
            }),
            Arc::new(MockNutrientCatalogReader),
        )
    }

    async fn make_pending_job(services: &ImportService, source: &str) -> ImportJob {
        let job = ImportJob::new(source.into(), None);
        services.repo.create_job(&job).await.unwrap();
        job
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
    async fn commit_assembles_authoritative_product_and_filters_unknown_nutrients() {
        let import_repo = Arc::new(MockImportRepo::new());
        let product_writer = Arc::new(MockExternalProductWriter {
            result: ProductUpsertResult {
                created: 1,
                updated: 0,
                nutrients_written: 1,
                servings_written: 1,
            },
            upserted: Mutex::new(vec![]),
        });
        let services = ImportService::new(
            import_repo.clone(),
            product_writer.clone(),
            Arc::new(MockNutrientCatalogReader),
        );
        let job = make_pending_job(&services, "OFF").await;
        services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: "OFF".into(),
                    source_id: "food-1".into(),
                    barcode: None,
                    name: "Food".into(),
                    brand: None,
                    categories: vec![],
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();
        services
            .stage_nutrients(
                job.id,
                vec![
                    StagedImportNutrient {
                        source: "OFF".into(),
                        source_id: "food-1".into(),
                        nutrient_code: "ENERGY_KCAL".into(),
                        amount_per_100g: rust_decimal::Decimal::new(100, 0),
                        raw_payload: None,
                        row_number: Some(1),
                    },
                    StagedImportNutrient {
                        source: "OFF".into(),
                        source_id: "food-1".into(),
                        nutrient_code: "UNKNOWN".into(),
                        amount_per_100g: rust_decimal::Decimal::ONE,
                        raw_payload: Some(serde_json::json!({ "code": "UNKNOWN" })),
                        row_number: Some(2),
                    },
                ],
            )
            .await
            .unwrap();
        services
            .stage_servings(
                job.id,
                vec![StagedImportServing {
                    source: "OFF".into(),
                    source_id: "food-1".into(),
                    unit: "piece".into(),
                    grams_per_unit: rust_decimal::Decimal::new(25, 0),
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        let result = services.commit_job(job.id).await.unwrap();

        assert_eq!(result.errors_logged, 1);
        let upserted = product_writer.upserted.lock().unwrap();
        assert_eq!(upserted.len(), 1);
        assert_eq!(upserted[0].nutrients.len(), 1);
        assert_eq!(upserted[0].servings.len(), 1);
        assert_eq!(
            upserted[0].nutrients[0].confidence,
            Some(NutrientConfidence::Derived)
        );
        let errors = import_repo.errors.lock().unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].row_number, Some(2));
        assert_eq!(errors[0].error, "Unknown nutrient code: UNKNOWN");
    }

    #[tokio::test]
    async fn transient_catalog_failure_leaves_import_running() {
        let import_repo = Arc::new(MockImportRepo::new());
        let services = ImportService::new(
            import_repo.clone(),
            Arc::new(FailingExternalProductWriter {
                error_is_validation: false,
            }),
            Arc::new(MockNutrientCatalogReader),
        );
        let job = make_pending_job(&services, "USDA").await;
        services
            .stage_foods(
                job.id,
                vec![StagedImportProduct {
                    source: "USDA".into(),
                    source_id: "food-1".into(),
                    barcode: None,
                    name: "Food".into(),
                    brand: None,
                    categories: vec![],
                    raw_payload: None,
                    row_number: Some(1),
                }],
            )
            .await
            .unwrap();

        let error = services.commit_job(job.id).await.unwrap_err();

        assert!(matches!(error, ImportError::Catalog(_)));
        assert_eq!(
            import_repo.find_job(job.id).await.unwrap().unwrap().status,
            ImportStatus::Running
        );
    }

    #[test]
    fn aggregate_assembly_reports_children_without_a_staged_product() {
        let batch = StagedImportBatch {
            products: vec![StagedImportProduct {
                source: "OFF".into(),
                source_id: "present".into(),
                barcode: None,
                name: "Present food".into(),
                brand: None,
                categories: vec![],
                raw_payload: None,
                row_number: Some(1),
            }],
            nutrients: vec![StagedImportNutrient {
                source: "OFF".into(),
                source_id: "missing".into(),
                nutrient_code: "ENERGY_KCAL".into(),
                amount_per_100g: rust_decimal::Decimal::ONE,
                raw_payload: None,
                row_number: Some(2),
            }],
            servings: vec![StagedImportServing {
                source: "OFF".into(),
                source_id: "missing".into(),
                unit: "cup".into(),
                grams_per_unit: rust_decimal::Decimal::ONE,
                raw_payload: None,
                row_number: Some(3),
            }],
        };

        let (products, errors) =
            assemble_products(batch, &vec![energy_nutrient()].into_iter().collect()).unwrap();

        assert_eq!(products.len(), 1);
        assert_eq!(errors.len(), 2);
        assert!(errors[0].error.contains("No staged product"));
        assert!(errors[1].error.contains("No staged product"));
    }
}

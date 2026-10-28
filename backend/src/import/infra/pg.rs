use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::import::domain::*;

pub struct PgImportRepo {
    pool: PgPool,
}

impl PgImportRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ImportRepo for PgImportRepo {
    async fn create_job(&self, job: &ImportJob) -> Result<(), ImportError> {
        sqlx::query(
            r#"INSERT INTO imports (id, source, status, created_by, created_at)
               VALUES ($1, $2, $3, $4, $5)"#,
        )
        .bind(job.id.0)
        .bind(&job.source)
        .bind(job.status.as_str())
        .bind(job.created_by)
        .bind(job.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn find_job(&self, id: ImportId) -> Result<Option<ImportJob>, ImportError> {
        let row = sqlx::query_as::<_, ImportRow>(
            r#"SELECT id, source, status, created_by, created_at, committed_at, failed_at
               FROM imports WHERE id = $1"#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(import_row_to_job))
    }

    async fn stage_foods(
        &self,
        import_id: ImportId,
        foods: &[StagedImportProduct],
        errors: &[ImportErrorRecord],
    ) -> Result<(), ImportError> {
        let mut tx = self.pool.begin().await?;
        self.lock_pending_job(&mut tx, import_id).await?;

        for food in foods {
            sqlx::query(
                r#"INSERT INTO staging_products (import_id, source, source_id, barcode, name, brand, categories, raw_payload, row_number)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                   ON CONFLICT (import_id, source, source_id) DO UPDATE SET
                       barcode = EXCLUDED.barcode, name = EXCLUDED.name, brand = EXCLUDED.brand,
                       categories = EXCLUDED.categories,
                       raw_payload = EXCLUDED.raw_payload, row_number = EXCLUDED.row_number"#,
            )
            .bind(import_id.0)
            .bind(&food.source)
            .bind(&food.source_id)
            .bind(&food.barcode)
            .bind(&food.name)
            .bind(&food.brand)
            .bind(&food.categories)
            .bind(&food.raw_payload)
            .bind(food.row_number)
            .execute(&mut *tx)
            .await?;
        }
        for error in errors {
            self.add_error_in_tx(&mut tx, import_id, error).await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn stage_nutrients(
        &self,
        import_id: ImportId,
        nutrients: &[StagedImportNutrient],
        errors: &[ImportErrorRecord],
    ) -> Result<(), ImportError> {
        let mut tx = self.pool.begin().await?;
        self.lock_pending_job(&mut tx, import_id).await?;

        for nutrient in nutrients {
            sqlx::query(
                r#"INSERT INTO staging_product_nutrients (import_id, source, source_id, nutrient_code, amount_per_100g, raw_payload, row_number)
                   VALUES ($1, $2, $3, $4, $5, $6, $7)
                   ON CONFLICT (import_id, source, source_id, nutrient_code) DO UPDATE SET
                       amount_per_100g = EXCLUDED.amount_per_100g,
                       raw_payload = EXCLUDED.raw_payload, row_number = EXCLUDED.row_number"#,
            )
            .bind(import_id.0)
            .bind(&nutrient.source)
            .bind(&nutrient.source_id)
            .bind(&nutrient.nutrient_code)
            .bind(nutrient.amount_per_100g)
            .bind(&nutrient.raw_payload)
            .bind(nutrient.row_number)
            .execute(&mut *tx)
            .await?;
        }
        for error in errors {
            self.add_error_in_tx(&mut tx, import_id, error).await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn stage_servings(
        &self,
        import_id: ImportId,
        servings: &[StagedImportServing],
        errors: &[ImportErrorRecord],
    ) -> Result<(), ImportError> {
        let mut tx = self.pool.begin().await?;
        self.lock_pending_job(&mut tx, import_id).await?;

        for s in servings {
            sqlx::query(
                r#"INSERT INTO staging_product_servings (import_id, source, source_id, unit, grams_per_unit, raw_payload, row_number)
                   VALUES ($1, $2, $3, $4, $5, $6, $7)
                   ON CONFLICT (import_id, source, source_id, unit) DO UPDATE SET
                       grams_per_unit = EXCLUDED.grams_per_unit,
                       raw_payload = EXCLUDED.raw_payload,
                       row_number = EXCLUDED.row_number"#,
            )
            .bind(import_id.0)
            .bind(&s.source)
            .bind(&s.source_id)
            .bind(&s.unit)
            .bind(s.grams_per_unit)
            .bind(&s.raw_payload)
            .bind(s.row_number)
            .execute(&mut *tx)
            .await?;
        }
        for error in errors {
            self.add_error_in_tx(&mut tx, import_id, error).await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn prepare_commit(&self, import_id: ImportId) -> Result<StagedImportBatch, ImportError> {
        let mut tx = self.pool.begin().await?;
        let status = self.lock_job_status(&mut tx, import_id).await?;
        match status.parse().unwrap_or(ImportStatus::Failed) {
            ImportStatus::Pending | ImportStatus::Running => {
                let has_foods: (bool,) = sqlx::query_as(
                    "SELECT EXISTS(SELECT 1 FROM staging_products WHERE import_id = $1)",
                )
                .bind(import_id.0)
                .fetch_one(&mut *tx)
                .await?;
                if !has_foods.0 {
                    return Err(ImportError::Validation("no staged foods to commit".into()));
                }

                if status == ImportStatus::Pending.as_str() {
                    sqlx::query("UPDATE imports SET status = 'running' WHERE id = $1")
                        .bind(import_id.0)
                        .execute(&mut *tx)
                        .await?;
                }

                let products = sqlx::query_as::<_, StagedProductRow>(
                    r#"SELECT source, source_id, barcode, name, brand, categories, raw_payload, row_number
                       FROM staging_products WHERE import_id = $1
                       ORDER BY source, source_id"#,
                )
                .bind(import_id.0)
                .fetch_all(&mut *tx)
                .await?
                .into_iter()
                .map(Into::into)
                .collect();
                let nutrients = sqlx::query_as::<_, StagedNutrientRow>(
                    r#"SELECT source, source_id, nutrient_code, amount_per_100g, raw_payload, row_number
                       FROM staging_product_nutrients WHERE import_id = $1
                       ORDER BY source, source_id, row_number NULLS LAST, nutrient_code"#,
                )
                .bind(import_id.0)
                .fetch_all(&mut *tx)
                .await?
                .into_iter()
                .map(Into::into)
                .collect();
                let servings = sqlx::query_as::<_, StagedServingRow>(
                    r#"SELECT source, source_id, unit, grams_per_unit, raw_payload, row_number
                       FROM staging_product_servings WHERE import_id = $1
                       ORDER BY source, source_id, row_number NULLS LAST, unit"#,
                )
                .bind(import_id.0)
                .fetch_all(&mut *tx)
                .await?
                .into_iter()
                .map(Into::into)
                .collect();

                tx.commit().await?;
                Ok(StagedImportBatch {
                    products,
                    nutrients,
                    servings,
                })
            }
            ImportStatus::Failed => Err(ImportError::InvalidStatus(
                "cannot commit a failed import".into(),
            )),
            ImportStatus::Committed => Err(ImportError::InvalidStatus(
                "cannot commit an already committed import".into(),
            )),
        }
    }

    async fn finish_commit(
        &self,
        import_id: ImportId,
        outcome: ImportCommitOutcome,
    ) -> Result<(), ImportError> {
        let mut tx = self.pool.begin().await?;
        let status = self.lock_job_status(&mut tx, import_id).await?;
        if status != ImportStatus::Running.as_str() {
            return Err(ImportError::InvalidStatus(
                "can only finish a running import".into(),
            ));
        }

        match outcome {
            ImportCommitOutcome::Committed { result, errors } => {
                for error in errors {
                    self.add_error_in_tx(&mut tx, import_id, &error).await?;
                }
                sqlx::query(
                    r#"UPDATE imports
                       SET status = 'committed', committed_at = NOW(),
                           products_created = $2, products_updated = $3,
                           nutrients_written = $4, servings_written = $5,
                           errors_logged = $6
                       WHERE id = $1"#,
                )
                .bind(import_id.0)
                .bind(result.products_created)
                .bind(result.products_updated)
                .bind(result.nutrients_written)
                .bind(result.servings_written)
                .bind(result.errors_logged)
                .execute(&mut *tx)
                .await?;
            }
            ImportCommitOutcome::Failed => {
                sqlx::query(
                    "UPDATE imports SET status = 'failed', failed_at = NOW() WHERE id = $1",
                )
                .bind(import_id.0)
                .execute(&mut *tx)
                .await?;
            }
        }

        tx.commit().await?;
        Ok(())
    }

    async fn get_errors(&self, import_id: ImportId) -> Result<Vec<ImportErrorRecord>, ImportError> {
        let rows = sqlx::query_as::<_, ImportErrorRow>(
            r#"SELECT row_number, error, raw_payload FROM import_errors WHERE import_id = $1 ORDER BY created_at"#,
        )
        .bind(import_id.0)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().map(import_error_row_to_record).collect())
    }
}

impl PgImportRepo {
    async fn lock_pending_job(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        import_id: ImportId,
    ) -> Result<(), ImportError> {
        let row: Option<(String,)> =
            sqlx::query_as("SELECT status FROM imports WHERE id = $1 FOR UPDATE")
                .bind(import_id.0)
                .fetch_optional(&mut **tx)
                .await?;
        let Some((status,)) = row else {
            return Err(ImportError::NotFound("import job not found".into()));
        };
        if status != ImportStatus::Pending.as_str() {
            return Err(ImportError::InvalidStatus(
                "can only stage rows on a pending import".into(),
            ));
        }
        Ok(())
    }

    async fn lock_job_status(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        import_id: ImportId,
    ) -> Result<String, ImportError> {
        sqlx::query_scalar("SELECT status FROM imports WHERE id = $1 FOR UPDATE")
            .bind(import_id.0)
            .fetch_optional(&mut **tx)
            .await?
            .ok_or_else(|| ImportError::NotFound("import job not found".into()))
    }

    async fn add_error_in_tx(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        import_id: ImportId,
        error: &ImportErrorRecord,
    ) -> Result<(), ImportError> {
        sqlx::query(
            r#"INSERT INTO import_errors (id, import_id, row_number, error, raw_payload, created_at)
               SELECT $1, $2, $3, $4, $5, $6
               WHERE NOT EXISTS (
                   SELECT 1 FROM import_errors
                   WHERE import_id = $2
                     AND row_number IS NOT DISTINCT FROM $3
                     AND error = $4
                     AND raw_payload IS NOT DISTINCT FROM $5
               )"#,
        )
        .bind(Uuid::new_v4())
        .bind(import_id.0)
        .bind(error.row_number)
        .bind(&error.error)
        .bind(&error.raw_payload)
        .bind(Utc::now())
        .execute(&mut **tx)
        .await?;
        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct StagedProductRow {
    source: String,
    source_id: String,
    barcode: Option<String>,
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    raw_payload: Option<serde_json::Value>,
    row_number: Option<i32>,
}

impl From<StagedProductRow> for StagedImportProduct {
    fn from(row: StagedProductRow) -> Self {
        Self {
            source: row.source,
            source_id: row.source_id,
            barcode: row.barcode,
            name: row.name,
            brand: row.brand,
            categories: row.categories,
            raw_payload: row.raw_payload,
            row_number: row.row_number,
        }
    }
}

#[derive(sqlx::FromRow)]
struct StagedNutrientRow {
    source: String,
    source_id: String,
    nutrient_code: String,
    amount_per_100g: Decimal,
    raw_payload: Option<serde_json::Value>,
    row_number: Option<i32>,
}

impl From<StagedNutrientRow> for StagedImportNutrient {
    fn from(row: StagedNutrientRow) -> Self {
        Self {
            source: row.source,
            source_id: row.source_id,
            nutrient_code: row.nutrient_code,
            amount_per_100g: row.amount_per_100g,
            raw_payload: row.raw_payload,
            row_number: row.row_number,
        }
    }
}

#[derive(sqlx::FromRow)]
struct StagedServingRow {
    source: String,
    source_id: String,
    unit: String,
    grams_per_unit: Decimal,
    raw_payload: Option<serde_json::Value>,
    row_number: Option<i32>,
}

impl From<StagedServingRow> for StagedImportServing {
    fn from(row: StagedServingRow) -> Self {
        Self {
            source: row.source,
            source_id: row.source_id,
            unit: row.unit,
            grams_per_unit: row.grams_per_unit,
            raw_payload: row.raw_payload,
            row_number: row.row_number,
        }
    }
}

#[derive(sqlx::FromRow)]
struct ImportRow {
    id: Uuid,
    source: String,
    status: String,
    created_by: Option<Uuid>,
    created_at: DateTime<Utc>,
    committed_at: Option<DateTime<Utc>>,
    failed_at: Option<DateTime<Utc>>,
}

fn import_row_to_job(row: ImportRow) -> ImportJob {
    ImportJob {
        id: ImportId(row.id),
        source: row.source,
        status: row.status.parse().unwrap_or(ImportStatus::Failed),
        created_by: row.created_by,
        created_at: row.created_at,
        committed_at: row.committed_at,
        failed_at: row.failed_at,
    }
}

#[derive(sqlx::FromRow)]
struct ImportErrorRow {
    row_number: Option<i32>,
    error: String,
    raw_payload: Option<serde_json::Value>,
}

fn import_error_row_to_record(row: ImportErrorRow) -> ImportErrorRecord {
    ImportErrorRecord {
        row_number: row.row_number,
        error: row.error,
        raw_payload: row.raw_payload,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[sqlx::test]
    async fn failed_commit_records_failed_at_and_cannot_be_recommitted(pool: PgPool) {
        let repository = PgImportRepo::new(pool.clone());
        let job = ImportJob::new("OFF".to_owned(), None);
        repository
            .create_job(&job)
            .await
            .expect("create import job");

        sqlx::query("UPDATE imports SET status = 'running' WHERE id = $1")
            .bind(job.id.0)
            .execute(&pool)
            .await
            .expect("mark import running");

        repository
            .finish_commit(job.id, ImportCommitOutcome::Failed)
            .await
            .expect("finish failed commit");

        let (status, failed_at): (String, Option<DateTime<Utc>>) =
            sqlx::query_as("SELECT status, failed_at FROM imports WHERE id = $1")
                .bind(job.id.0)
                .fetch_one(&pool)
                .await
                .expect("load import state");
        assert_eq!(status, ImportStatus::Failed.as_str());
        assert!(failed_at.is_some(), "failed commit must record failed_at");

        assert!(matches!(
            repository.prepare_commit(job.id).await,
            Err(ImportError::InvalidStatus(_))
        ));
    }
}

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use sqlx::{Postgres, QueryBuilder};
use std::collections::HashMap;
use uuid::Uuid;

use crate::import::domain::*;

pub struct PostgresImportRepository {
    pool: PgPool,
}

impl PostgresImportRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ImportRepository for PostgresImportRepository {
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
                r#"INSERT INTO staging_products (import_id, source, source_id, barcode, name, brand, raw_payload, row_number)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                   ON CONFLICT (import_id, source, source_id) DO UPDATE SET
                       barcode = EXCLUDED.barcode, name = EXCLUDED.name, brand = EXCLUDED.brand,
                       raw_payload = EXCLUDED.raw_payload, row_number = EXCLUDED.row_number"#,
            )
            .bind(import_id.0)
            .bind(&food.source)
            .bind(&food.source_id)
            .bind(&food.barcode)
            .bind(&food.name)
            .bind(&food.brand)
            .bind(payload_to_text(&food.raw_payload))
            .bind(food.row_number)
            .execute(&mut *tx)
            .await?;

            sqlx::query(
                "DELETE FROM staging_product_categories \
                 WHERE import_id = $1 AND source = $2 AND source_id = $3",
            )
            .bind(import_id.0)
            .bind(&food.source)
            .bind(&food.source_id)
            .execute(&mut *tx)
            .await?;

            if !food.categories.is_empty() {
                let mut query = QueryBuilder::<Postgres>::new(
                    "INSERT INTO staging_product_categories (import_id, source, source_id, category) ",
                );
                query.push_values(food.categories.iter(), |mut row, category| {
                    row.push_bind(import_id.0)
                        .push_bind(&food.source)
                        .push_bind(&food.source_id)
                        .push_bind(category);
                });
                query.push(" ON CONFLICT (import_id, source, source_id, category) DO NOTHING");
                query.build().execute(&mut *tx).await?;
            }
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
            .bind(payload_to_text(&nutrient.raw_payload))
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
            .bind(payload_to_text(&s.raw_payload))
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

                let product_rows = sqlx::query_as::<_, StagedProductRow>(
                    r#"SELECT source, source_id, barcode, name, brand, raw_payload, row_number
                       FROM staging_products WHERE import_id = $1
                       ORDER BY source, source_id"#,
                )
                .bind(import_id.0)
                .fetch_all(&mut *tx)
                .await?;
                let category_rows = sqlx::query_as::<_, (String, String, String)>(
                    r#"SELECT source, source_id, category FROM staging_product_categories
                       WHERE import_id = $1
                       ORDER BY source, source_id, category"#,
                )
                .bind(import_id.0)
                .fetch_all(&mut *tx)
                .await?;
                let mut categories_by_product: HashMap<(String, String), Vec<String>> =
                    HashMap::new();
                for (source, source_id, category) in category_rows {
                    categories_by_product
                        .entry((source, source_id))
                        .or_default()
                        .push(category);
                }
                let products = product_rows
                    .into_iter()
                    .map(|row| {
                        let categories = categories_by_product
                            .get(&(row.source.clone(), row.source_id.clone()))
                            .cloned()
                            .unwrap_or_default();
                        StagedImportProduct {
                            source: row.source,
                            source_id: row.source_id,
                            barcode: row.barcode,
                            name: row.name,
                            brand: row.brand,
                            categories,
                            raw_payload: payload_from_text(row.raw_payload),
                            row_number: row.row_number,
                        }
                    })
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
                       SET status = 'committed', committed_at = CURRENT_TIMESTAMP,
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
                    "UPDATE imports SET status = 'failed', failed_at = CURRENT_TIMESTAMP WHERE id = $1",
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

impl PostgresImportRepository {
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
                     AND (row_number = $3 OR (row_number IS NULL AND $3 IS NULL))
                     AND error = $4
                     AND (raw_payload = $5 OR (raw_payload IS NULL AND $5 IS NULL))
               )"#,
        )
        .bind(Uuid::new_v4())
        .bind(import_id.0)
        .bind(error.row_number)
        .bind(&error.error)
        .bind(payload_to_text(&error.raw_payload))
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
    raw_payload: Option<String>,
    row_number: Option<i32>,
}

#[derive(sqlx::FromRow)]
struct StagedNutrientRow {
    source: String,
    source_id: String,
    nutrient_code: String,
    amount_per_100g: Decimal,
    raw_payload: Option<String>,
    row_number: Option<i32>,
}

impl From<StagedNutrientRow> for StagedImportNutrient {
    fn from(row: StagedNutrientRow) -> Self {
        Self {
            source: row.source,
            source_id: row.source_id,
            nutrient_code: row.nutrient_code,
            amount_per_100g: row.amount_per_100g,
            raw_payload: payload_from_text(row.raw_payload),
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
    raw_payload: Option<String>,
    row_number: Option<i32>,
}

impl From<StagedServingRow> for StagedImportServing {
    fn from(row: StagedServingRow) -> Self {
        Self {
            source: row.source,
            source_id: row.source_id,
            unit: row.unit,
            grams_per_unit: row.grams_per_unit,
            raw_payload: payload_from_text(row.raw_payload),
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
    raw_payload: Option<String>,
}

fn import_error_row_to_record(row: ImportErrorRow) -> ImportErrorRecord {
    ImportErrorRecord {
        row_number: row.row_number,
        error: row.error,
        raw_payload: payload_from_text(row.raw_payload),
    }
}

fn payload_to_text(payload: &Option<serde_json::Value>) -> Option<String> {
    payload
        .as_ref()
        .and_then(|value| serde_json::to_string(value).ok())
}

fn payload_from_text(payload: Option<String>) -> Option<serde_json::Value> {
    payload.and_then(|text| serde_json::from_str(&text).ok())
}

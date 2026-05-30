use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::application::import::{ImportCommitResult, ImportError, ImportRepository};
use crate::domain::import::*;

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
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(())
    }

    async fn find_job(&self, id: ImportId) -> Result<Option<ImportJob>, ImportError> {
        let row = sqlx::query_as::<_, ImportRow>(
            r#"SELECT id, source, status, created_by, created_at, committed_at, failed_at
               FROM imports WHERE id = $1"#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;

        Ok(row.map(|r| r.into_job()))
    }

    async fn update_job_status(&self, id: ImportId, status: &ImportStatus) -> Result<(), ImportError> {
        let (status_str, committed_at, failed_at) = match status {
            ImportStatus::Committed => (status.as_str(), Some(Utc::now()), None),
            ImportStatus::Failed => (status.as_str(), None, Some(Utc::now())),
            _ => (status.as_str(), None::<DateTime<Utc>>, None::<DateTime<Utc>>),
        };

        sqlx::query(
            r#"UPDATE imports SET status = $1, committed_at = COALESCE($2, committed_at), failed_at = COALESCE($3, failed_at) WHERE id = $4"#,
        )
        .bind(status_str)
        .bind(committed_at)
        .bind(failed_at)
        .bind(id.0)
        .execute(&self.pool)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(())
    }

    async fn stage_foods(&self, import_id: ImportId, foods: &[StagedImportProduct]) -> Result<(), ImportError> {
        if foods.is_empty() {
            return Ok(());
        }

        let mut tx = self.pool.begin().await
            .map_err(|e| ImportError::Database(e.to_string()))?;

        for food in foods {
            sqlx::query(
                r#"INSERT INTO staging_products (import_id, source, source_id, barcode, name, brand, category, serving_size_g, raw_payload, row_number)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                   ON CONFLICT (import_id, source, source_id) DO UPDATE SET
                       barcode = EXCLUDED.barcode, name = EXCLUDED.name, brand = EXCLUDED.brand,
                       category = EXCLUDED.category, serving_size_g = EXCLUDED.serving_size_g,
                       raw_payload = EXCLUDED.raw_payload, row_number = EXCLUDED.row_number"#,
            )
            .bind(import_id.0)
            .bind(&food.source)
            .bind(&food.source_id)
            .bind(&food.barcode)
            .bind(&food.name)
            .bind(&food.brand)
            .bind(&food.category)
            .bind(food.serving_size_g)
            .bind(&food.raw_payload)
            .bind(food.row_number)
            .execute(&mut *tx)
            .await
            .map_err(|e| ImportError::Database(e.to_string()))?;
        }

        tx.commit().await
            .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(())
    }

    async fn stage_nutrients(&self, import_id: ImportId, nutrients: &[StagedImportNutrient]) -> Result<(), ImportError> {
        if nutrients.is_empty() {
            return Ok(());
        }

        let mut tx = self.pool.begin().await
            .map_err(|e| ImportError::Database(e.to_string()))?;

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
            .await
            .map_err(|e| ImportError::Database(e.to_string()))?;
        }

        tx.commit().await
            .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(())
    }

    async fn add_error(&self, import_id: ImportId, error: &ImportErrorRecord) -> Result<(), ImportError> {
        sqlx::query(
            r#"INSERT INTO import_errors (id, import_id, row_number, error, raw_payload, created_at)
               VALUES ($1, $2, $3, $4, $5, $6)"#,
        )
        .bind(Uuid::new_v4())
        .bind(import_id.0)
        .bind(error.row_number)
        .bind(&error.error)
        .bind(&error.raw_payload)
        .bind(Utc::now())
        .execute(&self.pool)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(())
    }

    async fn count_staged_foods(&self, import_id: ImportId) -> Result<i64, ImportError> {
        let row: (i64,) = sqlx::query_as(
            r#"SELECT COUNT(*)::BIGINT FROM staging_products WHERE import_id = $1"#,
        )
        .bind(import_id.0)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(row.0)
    }

    async fn commit_import(&self, import_id: ImportId) -> Result<ImportCommitResult, ImportError> {
        let mut tx = self.pool.begin().await
            .map_err(|e| ImportError::Database(e.to_string()))?;

        self.update_job_status_in_tx(&mut tx, import_id, &ImportStatus::Running).await?;

        let created: (i64,) = sqlx::query_as(
            r#"WITH inserted AS (
                   INSERT INTO products (id, source, source_id, barcode, name, brand, category, serving_size_g, visibility, created_at, updated_at)
                   SELECT gen_random_uuid(), sp.source, sp.source_id, sp.barcode, sp.name, sp.brand, sp.category, sp.serving_size_g, 'global', NOW(), NOW()
                   FROM staging_products sp
                   WHERE sp.import_id = $1
                     AND NOT EXISTS (SELECT 1 FROM products p WHERE p.source = sp.source AND p.source_id = sp.source_id)
                   RETURNING 1 AS flag
               )
               SELECT COALESCE(COUNT(*)::BIGINT, 0) FROM inserted"#,
        )
        .bind(import_id.0)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;

        let updated: (i64,) = sqlx::query_as(
            r#"WITH updated AS (
                   UPDATE products p SET
                       barcode = sp.barcode, name = sp.name, brand = sp.brand,
                       category = sp.category, serving_size_g = sp.serving_size_g, updated_at = NOW()
                   FROM staging_products sp
                   WHERE sp.import_id = $1
                     AND p.source = sp.source AND p.source_id = sp.source_id
                   RETURNING 1 AS flag
               )
               SELECT COALESCE(COUNT(*)::BIGINT, 0) FROM updated"#,
        )
        .bind(import_id.0)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;

        let nutrients: (i64,) = sqlx::query_as(
            r#"WITH inserted AS (
                   INSERT INTO product_nutrients (product_id, nutrient_id, amount_per_100g, created_at, updated_at)
                   SELECT p.id, n.id, sn.amount_per_100g, NOW(), NOW()
                   FROM staging_product_nutrients sn
                   JOIN products p ON p.source = sn.source AND p.source_id = sn.source_id
                   JOIN nutrients n ON n.code = sn.nutrient_code
                   WHERE sn.import_id = $1
                   ON CONFLICT (product_id, nutrient_id) DO UPDATE SET
                       amount_per_100g = EXCLUDED.amount_per_100g, updated_at = NOW()
                   RETURNING 1 AS flag
               )
               SELECT COALESCE(COUNT(*)::BIGINT, 0) FROM inserted"#,
        )
        .bind(import_id.0)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;

        let errors: (i64,) = sqlx::query_as(
            r#"WITH errs AS (
                   INSERT INTO import_errors (id, import_id, row_number, error, raw_payload, created_at)
                   SELECT gen_random_uuid(), $1, sn.row_number,
                          'Unknown nutrient code: ' || sn.nutrient_code,
                          sn.raw_payload, NOW()
                   FROM staging_product_nutrients sn
                   WHERE sn.import_id = $1
                     AND sn.nutrient_code NOT IN (SELECT code FROM nutrients)
                   RETURNING 1 AS flag
               )
               SELECT COALESCE(COUNT(*)::BIGINT, 0) FROM errs"#,
        )
        .bind(import_id.0)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;

        self.update_job_status_in_tx(&mut tx, import_id, &ImportStatus::Committed).await?;

        tx.commit().await
            .map_err(|e| ImportError::Database(e.to_string()))?;

        Ok(ImportCommitResult {
            products_created: created.0,
            products_updated: updated.0,
            nutrients_inserted: nutrients.0,
            errors_logged: errors.0,
        })
    }

    async fn get_errors(&self, import_id: ImportId) -> Result<Vec<ImportErrorRecord>, ImportError> {
        let rows = sqlx::query_as::<_, ErrorRow>(
            r#"SELECT row_number, error, raw_payload FROM import_errors WHERE import_id = $1 ORDER BY created_at"#,
        )
        .bind(import_id.0)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;

        Ok(rows.into_iter().map(|r| r.into_record()).collect())
    }
}

impl PostgresImportRepository {
    async fn update_job_status_in_tx(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        id: ImportId,
        status: &ImportStatus,
    ) -> Result<(), ImportError> {
        let (status_str, committed_at, failed_at) = match status {
            ImportStatus::Committed => (status.as_str(), Some(Utc::now()), None::<DateTime<Utc>>),
            ImportStatus::Failed => (status.as_str(), None::<DateTime<Utc>>, Some(Utc::now())),
            _ => (status.as_str(), None::<DateTime<Utc>>, None::<DateTime<Utc>>),
        };

        sqlx::query(
            r#"UPDATE imports SET status = $1, committed_at = COALESCE($2, committed_at), failed_at = COALESCE($3, failed_at) WHERE id = $4"#,
        )
        .bind(status_str)
        .bind(committed_at)
        .bind(failed_at)
        .bind(id.0)
        .execute(&mut **tx)
        .await
        .map_err(|e| ImportError::Database(e.to_string()))?;
        Ok(())
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

impl ImportRow {
    fn into_job(self) -> ImportJob {
        ImportJob {
            id: ImportId(self.id),
            source: self.source,
            status: ImportStatus::from_str(&self.status).unwrap_or(ImportStatus::Failed),
            created_by: self.created_by,
            created_at: self.created_at,
            committed_at: self.committed_at,
            failed_at: self.failed_at,
        }
    }
}

#[derive(sqlx::FromRow)]
struct ErrorRow {
    row_number: Option<i32>,
    error: String,
    raw_payload: Option<serde_json::Value>,
}

impl ErrorRow {
    fn into_record(self) -> ImportErrorRecord {
        ImportErrorRecord {
            row_number: self.row_number,
            error: self.error,
            raw_payload: self.raw_payload,
        }
    }
}

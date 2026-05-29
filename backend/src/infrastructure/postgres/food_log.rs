use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::application::food_log::*;
use crate::domain::catalog::*;
use crate::domain::food_log::*;

#[derive(Clone)]
pub struct PostgresFoodLogRepository {
    pool: PgPool,
}

impl PostgresFoodLogRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_snapshots(&self, food_log_id: Uuid) -> Result<Vec<FoodLogNutrientSnapshot>, FoodLogError> {
        let rows = sqlx::query_as::<_, NutrientSnapshotRow>(
            r#"
            SELECT fln.amount, fln.unit, n.code
            FROM food_log_nutrients fln
            JOIN nutrients n ON n.id = fln.nutrient_id
            WHERE fln.food_log_id = $1
            "#,
        )
        .bind(food_log_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| FoodLogNutrientSnapshot {
                nutrient_code: NutrientCode(r.code),
                amount: r.amount,
                unit: UnitCode(r.unit),
            })
            .collect())
    }

    fn row_to_food_log(&self, r: FoodLogRow, snapshots: Vec<FoodLogNutrientSnapshot>) -> Result<FoodLog, FoodLogError> {
        Ok(FoodLog {
            id: FoodLogId(r.id),
            user_id: r.user_id,
            logged_at: r.logged_at,
            meal_slot: r.meal_slot.and_then(|s| MealSlot::from_str(&s).ok()),
            item: LoggedItem::Product(ProductId(
                r.item_product_id.ok_or_else(|| FoodLogError::Internal("missing product_id".into()))?
            )),
            quantity_amount: r.quantity,
            quantity_unit: UnitCode(r.unit),
            nutrient_snapshots: snapshots,
            notes: r.notes,
        })
    }
}

#[async_trait]
impl FoodLogRepository for PostgresFoodLogRepository {
    async fn create(&self, log: &FoodLog) -> Result<(), FoodLogError> {
        let mut tx = self.pool.begin().await.map_err(|e| FoodLogError::Database(e.to_string()))?;

        let product_id = match &log.item {
            LoggedItem::Product(pid) => pid.0,
        };

        sqlx::query(
            r#"
            INSERT INTO food_logs (id, user_id, logged_at, meal_slot, item_product_id, quantity, unit, notes)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            "#,
        )
        .bind(log.id.0)
        .bind(log.user_id)
        .bind(log.logged_at)
        .bind(log.meal_slot.as_ref().map(|m| m.as_str()))
        .bind(product_id)
        .bind(log.quantity_amount)
        .bind(&log.quantity_unit.0)
        .bind(&log.notes)
        .execute(&mut *tx)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        for snap in &log.nutrient_snapshots {
            let row: Option<(i32,)> =
                sqlx::query_as("SELECT id FROM nutrients WHERE code = $1")
                    .bind(&snap.nutrient_code.0)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(|e| FoodLogError::Database(e.to_string()))?;

            if let Some((nid,)) = row {
                sqlx::query(
                    "INSERT INTO food_log_nutrients (food_log_id, nutrient_id, amount, unit) VALUES ($1, $2, $3, $4)",
                )
                .bind(log.id.0)
                .bind(nid)
                .bind(snap.amount)
                .bind(&snap.unit.0)
                .execute(&mut *tx)
                .await
                .map_err(|e| FoodLogError::Database(e.to_string()))?;
            }
        }

        tx.commit().await.map_err(|e| FoodLogError::Database(e.to_string()))?;
        Ok(())
    }

    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, FoodLogError> {
        let row = sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, logged_at, meal_slot, item_product_id, item_meal_id,
                   quantity, unit, notes, created_at, updated_at
            FROM food_logs WHERE id = $1
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        match row {
            Some(r) => {
                let snapshots = self.load_snapshots(r.id).await?;
                Ok(Some(self.row_to_food_log(r, snapshots)?))
            }
            None => Ok(None),
        }
    }

    async fn find_by_user_and_range(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<FoodLog>, FoodLogError> {
        let rows = sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, logged_at, meal_slot, item_product_id, item_meal_id,
                   quantity, unit, notes, created_at, updated_at
            FROM food_logs
            WHERE user_id = $1 AND logged_at >= $2 AND logged_at < $3
            ORDER BY logged_at DESC
            "#,
        )
        .bind(user_id)
        .bind(from)
        .bind(to)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        let mut results = Vec::new();
        for r in rows {
            let snapshots = self.load_snapshots(r.id).await?;
            results.push(self.row_to_food_log(r, snapshots)?);
        }
        Ok(results)
    }

    async fn update(&self, log: &FoodLog) -> Result<(), FoodLogError> {
        let mut tx = self.pool.begin().await.map_err(|e| FoodLogError::Database(e.to_string()))?;

        let product_id = match &log.item {
            LoggedItem::Product(pid) => pid.0,
        };

        sqlx::query(
            r#"
            UPDATE food_logs SET logged_at=$2, meal_slot=$3, item_product_id=$4,
                                 quantity=$5, unit=$6, notes=$7, updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(log.id.0)
        .bind(log.logged_at)
        .bind(log.meal_slot.as_ref().map(|m| m.as_str()))
        .bind(product_id)
        .bind(log.quantity_amount)
        .bind(&log.quantity_unit.0)
        .bind(&log.notes)
        .execute(&mut *tx)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        sqlx::query("DELETE FROM food_log_nutrients WHERE food_log_id = $1")
            .bind(log.id.0)
            .execute(&mut *tx)
            .await
            .map_err(|e| FoodLogError::Database(e.to_string()))?;

        for snap in &log.nutrient_snapshots {
            let row: Option<(i32,)> =
                sqlx::query_as("SELECT id FROM nutrients WHERE code = $1")
                    .bind(&snap.nutrient_code.0)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(|e| FoodLogError::Database(e.to_string()))?;

            if let Some((nid,)) = row {
                sqlx::query(
                    "INSERT INTO food_log_nutrients (food_log_id, nutrient_id, amount, unit) VALUES ($1, $2, $3, $4)",
                )
                .bind(log.id.0)
                .bind(nid)
                .bind(snap.amount)
                .bind(&snap.unit.0)
                .execute(&mut *tx)
                .await
                .map_err(|e| FoodLogError::Database(e.to_string()))?;
            }
        }

        tx.commit().await.map_err(|e| FoodLogError::Database(e.to_string()))?;
        Ok(())
    }

    async fn delete(&self, id: FoodLogId) -> Result<(), FoodLogError> {
        sqlx::query("DELETE FROM food_logs WHERE id = $1")
            .bind(id.0)
            .execute(&self.pool)
            .await
            .map_err(|e| FoodLogError::Database(e.to_string()))?;
        Ok(())
    }
}

#[async_trait]
impl ProductLookup for PostgresFoodLogRepository {
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, FoodLogError> {
        let row = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   category, default_quantity, default_unit, serving_size_g, deleted_at,
                   created_at, updated_at
            FROM products WHERE id = $1 AND deleted_at IS NULL
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        match row {
            Some(r) => {
                let nutrients = self.load_product_nutrients(r.id).await?;
                let servings = self.load_product_servings(r.id).await?;
                Ok(Some(self.row_to_product(r, nutrients, servings)?))
            }
            None => Ok(None),
        }
    }
}

impl PostgresFoodLogRepository {
    async fn load_product_nutrients(&self, product_id: Uuid) -> Result<Vec<ProductNutrient>, FoodLogError> {
        let rows = sqlx::query_as::<_, ProductNutrientRow>(
            r#"
            SELECT pn.amount_per_100g, pn.source, pn.confidence, n.code
            FROM product_nutrients pn
            JOIN nutrients n ON n.id = pn.nutrient_id
            WHERE pn.product_id = $1
            "#,
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| ProductNutrient {
                nutrient_code: NutrientCode(r.code),
                amount_per_100g: AmountPer100g(r.amount_per_100g),
                source: r.source,
                confidence: r.confidence.and_then(|c| NutrientConfidence::from_str(&c).ok()),
            })
            .collect())
    }

    async fn load_product_servings(&self, product_id: Uuid) -> Result<Vec<ProductServing>, FoodLogError> {
        let rows = sqlx::query_as::<_, ProductServingRow>(
            "SELECT label, quantity, unit, grams FROM product_servings WHERE product_id = $1 ORDER BY created_at",
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| FoodLogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| ProductServing {
                label: ServingLabel(r.label),
                quantity: r.quantity,
                unit: UnitCode(r.unit),
                grams: r.grams,
            })
            .collect())
    }

    fn row_to_product(
        &self,
        r: ProductRow,
        nutrients: Vec<ProductNutrient>,
        servings: Vec<ProductServing>,
    ) -> Result<Product, FoodLogError> {
        Ok(Product {
            id: ProductId(r.id),
            source: Source::from_str(&r.source).map_err(|e| FoodLogError::Internal(e))?,
            source_id: r.source_id,
            user_id: r.user_id,
            visibility: ProductVisibility::from_str(&r.visibility)
                .map_err(|e| FoodLogError::Internal(e))?,
            barcode: r.barcode.map(Barcode),
            name: ProductName(r.name),
            brand: r.brand.map(Brand),
            category: r.category.map(Category),
            default_quantity: r.default_quantity,
            default_unit: r.default_unit.map(UnitCode),
            serving_size_g: r.serving_size_g,
            nutrients,
            servings,
            deleted_at: r.deleted_at,
        })
    }
}

#[derive(Clone)]
pub struct PostgresSummaryRepository {
    pool: PgPool,
}

impl PostgresSummaryRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl SummaryRepository for PostgresSummaryRepository {
    async fn get_summary(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        codes: Option<Vec<String>>,
    ) -> Result<Vec<SummaryEntry>, FoodLogError> {
        let rows = if let Some(ref code_list) = codes {
            sqlx::query_as::<_, SummaryRow>(
                r#"
                SELECT n.code, SUM(fln.amount) AS amount, n.unit
                FROM food_log_nutrients fln
                JOIN nutrients n ON n.id = fln.nutrient_id
                JOIN food_logs fl ON fl.id = fln.food_log_id
                WHERE fl.user_id = $1
                  AND fl.logged_at >= $2
                  AND fl.logged_at < $3
                  AND n.code = ANY($4)
                GROUP BY n.code, n.unit
                "#,
            )
            .bind(user_id)
            .bind(from)
            .bind(to)
            .bind(code_list)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| FoodLogError::Database(e.to_string()))?
        } else {
            sqlx::query_as::<_, SummaryRow>(
                r#"
                SELECT n.code, SUM(fln.amount) AS amount, n.unit
                FROM food_log_nutrients fln
                JOIN nutrients n ON n.id = fln.nutrient_id
                JOIN food_logs fl ON fl.id = fln.food_log_id
                WHERE fl.user_id = $1
                  AND fl.logged_at >= $2
                  AND fl.logged_at < $3
                GROUP BY n.code, n.unit
                "#,
            )
            .bind(user_id)
            .bind(from)
            .bind(to)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| FoodLogError::Database(e.to_string()))?
        };

        Ok(rows
            .into_iter()
            .map(|r| SummaryEntry {
                code: r.code,
                amount: r.amount.unwrap_or(Decimal::ZERO),
                unit: r.unit,
            })
            .collect())
    }
}

#[derive(sqlx::FromRow)]
struct FoodLogRow {
    id: Uuid,
    user_id: Uuid,
    logged_at: DateTime<Utc>,
    meal_slot: Option<String>,
    item_product_id: Option<Uuid>,
    item_meal_id: Option<Uuid>,
    quantity: Decimal,
    unit: String,
    notes: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct NutrientSnapshotRow {
    amount: Decimal,
    unit: String,
    code: String,
}

#[derive(sqlx::FromRow)]
struct ProductRow {
    id: Uuid,
    source: String,
    source_id: Option<String>,
    user_id: Option<Uuid>,
    visibility: String,
    barcode: Option<String>,
    name: String,
    brand: Option<String>,
    category: Option<String>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    serving_size_g: Option<Decimal>,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct ProductNutrientRow {
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
}

#[derive(sqlx::FromRow)]
struct ProductServingRow {
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

#[derive(sqlx::FromRow)]
struct SummaryRow {
    code: String,
    amount: Option<Decimal>,
    unit: String,
}

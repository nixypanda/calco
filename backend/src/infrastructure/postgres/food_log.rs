use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::food_log::*;
use crate::domain::meal::{Meal, MealComponent, MealComponentItem, MealId, MealName, MealNotes};

#[derive(Clone)]
pub struct PostgresFoodLogRepository {
    pool: PgPool,
}

impl PostgresFoodLogRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_snapshots(
        &self,
        food_log_id: Uuid,
    ) -> Result<Vec<FoodLogNutrientSnapshot>, FoodLogError> {
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
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| FoodLogNutrientSnapshot {
                nutrient_code: NutrientCode(r.code),
                amount: r.amount,
                unit: UnitCode(r.unit),
            })
            .collect())
    }
}

fn food_log_row_to_food_log(
    row: FoodLogRow,
    snapshots: Vec<FoodLogNutrientSnapshot>,
) -> Result<FoodLog, FoodLogError> {
    let item = if let Some(pid) = row.item_product_id {
        LoggedItem::Product(ProductId(pid))
    } else if let Some(mid) = row.item_meal_id {
        LoggedItem::Meal(MealId(mid))
    } else {
        return Err(FoodLogError::Internal(
            "food log has no item reference".into(),
        ));
    };

    Ok(FoodLog {
        id: FoodLogId(row.id),
        user_id: row.user_id,
        logged_at: row.logged_at,
        meal_slot: row.meal_slot.and_then(|s| s.parse().ok()),
        item,
        quantity_amount: row.quantity,
        quantity_unit: UnitCode(row.unit),
        nutrient_snapshots: snapshots,
        notes: row.notes,
    })
}

#[async_trait]
impl FoodLogRepository for PostgresFoodLogRepository {
    async fn create(&self, log: &FoodLog) -> Result<(), FoodLogError> {
        let mut tx = self.pool.begin().await?;

        let (product_id, meal_id) = match &log.item {
            LoggedItem::Product(pid) => (Some(pid.0), None),
            LoggedItem::Meal(mid) => (None, Some(mid.0)),
        };

        sqlx::query(
            r#"
            INSERT INTO food_logs (id, user_id, logged_at, meal_slot, item_product_id, item_meal_id, quantity, unit, notes)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            "#,
        )
        .bind(log.id.0)
        .bind(log.user_id)
        .bind(log.logged_at)
        .bind(log.meal_slot.as_ref().map(|m| m.as_str()))
        .bind(product_id)
        .bind(meal_id)
        .bind(log.quantity_amount)
        .bind(&log.quantity_unit.0)
        .bind(&log.notes)
        .execute(&mut *tx)
        .await?;

        insert_food_log_nutrients(&mut tx, log.id.0, &log.nutrient_snapshots).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, FoodLogError> {
        let row = sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, logged_at, meal_slot, item_product_id, item_meal_id,
                   quantity, unit, notes
            FROM food_logs WHERE id = $1
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        match row {
            Some(r) => {
                let snapshots = self.load_snapshots(r.id).await?;
                Ok(Some(food_log_row_to_food_log(r, snapshots)?))
            }
            None => Ok(None),
        }
    }

    async fn list_by_user_and_range(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<FoodLog>, FoodLogError> {
        let rows = sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, logged_at, meal_slot, item_product_id, item_meal_id,
                   quantity, unit, notes
            FROM food_logs
            WHERE user_id = $1 AND logged_at >= $2 AND logged_at < $3
            ORDER BY logged_at DESC
            "#,
        )
        .bind(user_id)
        .bind(from)
        .bind(to)
        .fetch_all(&self.pool)
        .await?;

        if rows.is_empty() {
            return Ok(Vec::new());
        }

        let ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
        let snapshot_rows = sqlx::query_as::<_, FoodLogSnapshotJoinRow>(
            r#"
            SELECT fln.food_log_id, fln.amount, fln.unit, n.code
            FROM food_log_nutrients fln
            JOIN nutrients n ON n.id = fln.nutrient_id
            WHERE fln.food_log_id = ANY($1)
            "#,
        )
        .bind(&ids)
        .fetch_all(&self.pool)
        .await?;

        let mut snapshots_by_log: std::collections::HashMap<Uuid, Vec<FoodLogNutrientSnapshot>> =
            std::collections::HashMap::new();
        for s in snapshot_rows {
            snapshots_by_log
                .entry(s.food_log_id)
                .or_default()
                .push(FoodLogNutrientSnapshot {
                    nutrient_code: NutrientCode(s.code),
                    amount: s.amount,
                    unit: UnitCode(s.unit),
                });
        }

        let mut results = Vec::with_capacity(rows.len());
        for r in rows {
            let snapshots = snapshots_by_log.remove(&r.id).unwrap_or_default();
            results.push(food_log_row_to_food_log(r, snapshots)?);
        }
        Ok(results)
    }

    async fn update(&self, log: &FoodLog) -> Result<(), FoodLogError> {
        let mut tx = self.pool.begin().await?;

        let (product_id, meal_id) = match &log.item {
            LoggedItem::Product(pid) => (Some(pid.0), None),
            LoggedItem::Meal(mid) => (None, Some(mid.0)),
        };

        sqlx::query(
            r#"
            UPDATE food_logs SET logged_at=$2, meal_slot=$3, item_product_id=$4, item_meal_id=$5,
                                 quantity=$6, unit=$7, notes=$8, updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(log.id.0)
        .bind(log.logged_at)
        .bind(log.meal_slot.as_ref().map(|m| m.as_str()))
        .bind(product_id)
        .bind(meal_id)
        .bind(log.quantity_amount)
        .bind(&log.quantity_unit.0)
        .bind(&log.notes)
        .execute(&mut *tx)
        .await?;

        sqlx::query("DELETE FROM food_log_nutrients WHERE food_log_id = $1")
            .bind(log.id.0)
            .execute(&mut *tx)
            .await?;

        insert_food_log_nutrients(&mut tx, log.id.0, &log.nutrient_snapshots).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: FoodLogId) -> Result<(), FoodLogError> {
        sqlx::query("DELETE FROM food_logs WHERE id = $1")
            .bind(id.0)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn sum_nutrients_by_user_and_range(
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
            .await?
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
            .await?
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

#[async_trait]
impl ProductLookup for PostgresFoodLogRepository {
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, FoodLogError> {
        let row = sqlx::query_as::<_, ProductLookupRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit, serving_size_g
            FROM products WHERE id = $1 AND deleted_at IS NULL
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        match row {
            Some(r) => {
                let nutrients = self.load_product_nutrients(r.id).await?;
                let servings = self.load_product_servings(r.id).await?;
                Ok(Some(product_lookup_row_to_product(r, nutrients, servings)?))
            }
            None => Ok(None),
        }
    }
}

#[async_trait]
impl MealLookup for PostgresFoodLogRepository {
    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, FoodLogError> {
        let row = sqlx::query_as::<_, MealLookupRow>(
            r#"
            SELECT id, user_id, name, notes, total_quantity_amount, total_quantity_unit,
                   created_at, updated_at
            FROM meals WHERE id = $1
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        match row {
            Some(r) => {
                let component_rows = sqlx::query_as::<_, MealComponentLookupRow>(
                    r#"
                    SELECT id, component_product_id, quantity, unit
                    FROM meal_components WHERE meal_id = $1 ORDER BY created_at
                    "#,
                )
                .bind(id.0)
                .fetch_all(&self.pool)
                .await?;

                let mut components = Vec::new();
                for c in component_rows {
                    let item = if let Some(pid) = c.component_product_id {
                        MealComponentItem::Product(ProductId(pid))
                    } else {
                        continue;
                    };
                    components.push(MealComponent {
                        id: c.id,
                        item,
                        quantity_amount: c.quantity,
                        quantity_unit: crate::domain::catalog::UnitCode(c.unit),
                    });
                }

                Ok(Some(Meal {
                    id: MealId(r.id),
                    user_id: r.user_id,
                    name: MealName(r.name),
                    notes: r.notes.map(MealNotes),
                    total_quantity_amount: r.total_quantity_amount,
                    total_quantity_unit: r
                        .total_quantity_unit
                        .map(crate::domain::catalog::UnitCode),
                    components,
                    created_at: r.created_at,
                    updated_at: r.updated_at,
                }))
            }
            None => Ok(None),
        }
    }
}

impl PostgresFoodLogRepository {
    async fn load_product_nutrients(
        &self,
        product_id: Uuid,
    ) -> Result<Vec<ProductNutrient>, FoodLogError> {
        let rows = sqlx::query_as::<_, ProductNutrientLookupRow>(
            r#"
            SELECT pn.amount_per_100g, pn.source, pn.confidence, n.code, n.unit
            FROM product_nutrients pn
            JOIN nutrients n ON n.id = pn.nutrient_id
            WHERE pn.product_id = $1
            "#,
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| ProductNutrient {
                nutrient_code: NutrientCode(r.code),
                amount_per_100g: AmountPer100g(r.amount_per_100g),
                unit: UnitCode(r.unit),
                source: r.source,
                confidence: r.confidence.and_then(|c| c.parse().ok()),
            })
            .collect())
    }

    async fn load_product_servings(
        &self,
        product_id: Uuid,
    ) -> Result<Vec<ProductServing>, FoodLogError> {
        let rows = sqlx::query_as::<_, ProductServingLookupRow>(
            "SELECT label, quantity, unit, grams FROM product_servings WHERE product_id = $1 ORDER BY created_at",
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await?;

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
}

#[derive(sqlx::FromRow)]
struct NutrientSnapshotRow {
    amount: Decimal,
    unit: String,
    code: String,
}

#[derive(sqlx::FromRow)]
struct FoodLogSnapshotJoinRow {
    food_log_id: Uuid,
    amount: Decimal,
    unit: String,
    code: String,
}

#[derive(sqlx::FromRow)]
struct ProductLookupRow {
    id: Uuid,
    source: String,
    source_id: Option<String>,
    user_id: Option<Uuid>,
    visibility: String,
    barcode: Option<String>,
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    serving_size_g: Option<Decimal>,
}

#[derive(sqlx::FromRow)]
struct ProductNutrientLookupRow {
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct ProductServingLookupRow {
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

fn product_lookup_row_to_product(
    row: ProductLookupRow,
    nutrients: Vec<ProductNutrient>,
    servings: Vec<ProductServing>,
) -> Result<Product, FoodLogError> {
    Ok(Product {
        id: ProductId(row.id),
        source: row
            .source
            .parse::<Source>()
            .map_err(FoodLogError::Internal)?,
        source_id: row.source_id,
        user_id: row.user_id,
        visibility: row
            .visibility
            .parse::<ProductVisibility>()
            .map_err(FoodLogError::Internal)?,
        barcode: row.barcode.map(Barcode),
        name: ProductName(row.name),
        brand: row.brand.map(Brand),
        categories: row.categories.into_iter().map(Category).collect(),
        default_quantity: row.default_quantity,
        default_unit: row.default_unit.map(UnitCode),
        serving_size_g: row.serving_size_g,
        nutrients,
        servings,
    })
}

#[derive(sqlx::FromRow)]
struct SummaryRow {
    code: String,
    amount: Option<Decimal>,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct MealLookupRow {
    id: Uuid,
    user_id: Uuid,
    name: String,
    notes: Option<String>,
    total_quantity_amount: Option<Decimal>,
    total_quantity_unit: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct MealComponentLookupRow {
    id: Uuid,
    component_product_id: Option<Uuid>,
    quantity: Decimal,
    unit: String,
}

async fn insert_food_log_nutrients(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    food_log_id: Uuid,
    snapshots: &[FoodLogNutrientSnapshot],
) -> Result<(), FoodLogError> {
    if snapshots.is_empty() {
        return Ok(());
    }

    let codes: Vec<String> = snapshots
        .iter()
        .map(|s| s.nutrient_code.0.clone())
        .collect();
    let amounts: Vec<Decimal> = snapshots.iter().map(|s| s.amount).collect();
    let units: Vec<String> = snapshots.iter().map(|s| s.unit.0.clone()).collect();

    let inserted: i64 = sqlx::query_scalar(
        r#"
        WITH ins AS (
            INSERT INTO food_log_nutrients (food_log_id, nutrient_id, amount, unit)
            SELECT $1, n.id, v.amount, v.unit
            FROM UNNEST($2::text[], $3::numeric[], $4::text[]) AS v(code, amount, unit)
            JOIN nutrients n ON n.code = v.code
            RETURNING 1
        )
        SELECT COUNT(*) FROM ins
        "#,
    )
    .bind(food_log_id)
    .bind(&codes)
    .bind(&amounts)
    .bind(&units)
    .fetch_one(&mut **tx)
    .await?;

    if (inserted as usize) != snapshots.len() {
        return Err(FoodLogError::Validation(format!(
            "unknown nutrient code in food log snapshot (expected {} rows, inserted {})",
            snapshots.len(),
            inserted
        )));
    }
    Ok(())
}

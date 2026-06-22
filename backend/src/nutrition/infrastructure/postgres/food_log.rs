use async_trait::async_trait;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::nutrition::domain::catalog::*;
use crate::nutrition::domain::food_log::*;
use crate::nutrition::domain::meal::MealId;

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
    ) -> Result<Vec<FoodLogNutrientSnapshot>, NutritionError> {
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

    async fn rows_to_food_logs(
        &self,
        rows: Vec<FoodLogRow>,
    ) -> Result<Vec<FoodLog>, NutritionError> {
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

    async fn load_latest_slot_before(
        &self,
        user_id: Uuid,
        meal_slot: MealSlot,
        before_date: NaiveDate,
        lookback_days: i64,
    ) -> Result<Option<(NaiveDate, Vec<FoodLog>)>, NutritionError> {
        let cutoff_date = before_date - Duration::days(lookback_days);
        let rows = sqlx::query_as::<_, FoodLogRow>(
            r#"
            WITH latest AS (
                SELECT log_date
                FROM food_logs
                WHERE user_id = $1
                  AND meal_slot = $2
                  AND log_date < $3
                  AND log_date >= $4
                GROUP BY log_date
                ORDER BY log_date DESC
                LIMIT 1
            )
            SELECT fl.id, fl.user_id, fl.log_date, fl.meal_slot, fl.device_timezone,
                   fl.item_product_id, fl.item_meal_id, fl.item_name, fl.item_brand,
                   fl.quantity, fl.unit, fl.notes, fl.created_at, fl.updated_at
            FROM food_logs fl
            JOIN latest ON latest.log_date = fl.log_date
            WHERE fl.user_id = $1 AND fl.meal_slot = $2
            ORDER BY fl.created_at DESC
            "#,
        )
        .bind(user_id)
        .bind(meal_slot.as_str())
        .bind(before_date)
        .bind(cutoff_date)
        .fetch_all(&self.pool)
        .await?;

        if rows.is_empty() {
            return Ok(None);
        }

        let source_date = rows[0].log_date;
        Ok(Some((source_date, self.rows_to_food_logs(rows).await?)))
    }
}

fn food_log_row_to_food_log(
    row: FoodLogRow,
    snapshots: Vec<FoodLogNutrientSnapshot>,
) -> Result<FoodLog, NutritionError> {
    let item = if let Some(pid) = row.item_product_id {
        let product_id = ProductId(pid);
        FoodLogItemSnapshot::Product {
            id: product_id,
            name: row.item_name,
            brand: row.item_brand,
        }
    } else if let Some(mid) = row.item_meal_id {
        let meal_id = MealId(mid);
        FoodLogItemSnapshot::Meal {
            id: meal_id,
            name: row.item_name,
        }
    } else {
        return Err(NutritionError::Internal(
            "food log has no item reference".into(),
        ));
    };

    Ok(FoodLog {
        id: FoodLogId(row.id),
        user_id: row.user_id,
        log_date: row.log_date,
        meal_slot: row.meal_slot.and_then(|s| s.parse().ok()),
        device_timezone: row.device_timezone,
        item,
        quantity_amount: row.quantity,
        quantity_unit: UnitCode(row.unit),
        nutrient_snapshots: snapshots,
        notes: row.notes,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

#[async_trait]
impl FoodLogRepository for PostgresFoodLogRepository {
    async fn create(&self, log: &FoodLog) -> Result<(), NutritionError> {
        self.create_many(std::slice::from_ref(log)).await
    }

    async fn create_many(&self, logs: &[FoodLog]) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        for log in logs {
            let (product_id, meal_id, item_name, item_brand) = item_to_columns(&log.item);

            sqlx::query(
                r#"
                INSERT INTO food_logs (id, user_id, log_date, meal_slot, device_timezone, item_product_id, item_meal_id, item_name, item_brand, quantity, unit, notes, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
                "#,
            )
            .bind(log.id.0)
            .bind(log.user_id)
            .bind(log.log_date)
            .bind(log.meal_slot.as_ref().map(|m| m.as_str()))
            .bind(&log.device_timezone)
            .bind(product_id)
            .bind(meal_id)
            .bind(item_name)
            .bind(item_brand)
            .bind(log.quantity_amount)
            .bind(&log.quantity_unit.0)
            .bind(&log.notes)
            .bind(log.created_at)
            .bind(log.updated_at)
            .execute(&mut *tx)
            .await?;

            insert_food_log_nutrients(&mut tx, log.id.0, &log.nutrient_snapshots).await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, NutritionError> {
        let row = sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, log_date, meal_slot, device_timezone, item_product_id, item_meal_id,
                   item_name, item_brand, quantity, unit, notes, created_at, updated_at
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

    async fn list_by_user_and_date(
        &self,
        user_id: Uuid,
        log_date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        let rows = sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, log_date, meal_slot, device_timezone, item_product_id, item_meal_id,
                   item_name, item_brand, quantity, unit, notes, created_at, updated_at
            FROM food_logs
            WHERE user_id = $1 AND log_date = $2
            ORDER BY CASE meal_slot
                WHEN 'breakfast' THEN 1
                WHEN 'lunch' THEN 2
                WHEN 'dinner' THEN 3
                WHEN 'snack' THEN 4
                ELSE 5
            END, created_at DESC
            "#,
        )
        .bind(user_id)
        .bind(log_date)
        .fetch_all(&self.pool)
        .await?;

        self.rows_to_food_logs(rows).await
    }

    async fn find_latest_slot_before(
        &self,
        user_id: Uuid,
        meal_slot: MealSlot,
        before_date: NaiveDate,
        lookback_days: i64,
    ) -> Result<Option<(NaiveDate, Vec<FoodLog>)>, NutritionError> {
        self.load_latest_slot_before(user_id, meal_slot, before_date, lookback_days)
            .await
    }

    async fn update(&self, log: &FoodLog) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        let (product_id, meal_id, item_name, item_brand) = item_to_columns(&log.item);

        sqlx::query(
            r#"
            UPDATE food_logs SET log_date=$2, meal_slot=$3, device_timezone=$4,
                                 item_product_id=$5, item_meal_id=$6,
                                 item_name=$7, item_brand=$8, quantity=$9, unit=$10, notes=$11,
                                 updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(log.id.0)
        .bind(log.log_date)
        .bind(log.meal_slot.as_ref().map(|m| m.as_str()))
        .bind(&log.device_timezone)
        .bind(product_id)
        .bind(meal_id)
        .bind(item_name)
        .bind(item_brand)
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

    async fn delete(&self, id: FoodLogId) -> Result<(), NutritionError> {
        sqlx::query("DELETE FROM food_logs WHERE id = $1")
            .bind(id.0)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct FoodLogRow {
    id: Uuid,
    user_id: Uuid,
    log_date: NaiveDate,
    meal_slot: Option<String>,
    device_timezone: Option<String>,
    item_product_id: Option<Uuid>,
    item_meal_id: Option<Uuid>,
    item_name: String,
    item_brand: Option<String>,
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
struct FoodLogSnapshotJoinRow {
    food_log_id: Uuid,
    amount: Decimal,
    unit: String,
    code: String,
}

fn item_to_columns(item: &FoodLogItemSnapshot) -> (Option<Uuid>, Option<Uuid>, &str, Option<&str>) {
    match item {
        FoodLogItemSnapshot::Product { id, name, brand } => {
            (Some(id.0), None, name.as_str(), brand.as_deref())
        }
        FoodLogItemSnapshot::Meal { id, name } => (None, Some(id.0), name.as_str(), None),
    }
}

async fn insert_food_log_nutrients(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    food_log_id: Uuid,
    snapshots: &[FoodLogNutrientSnapshot],
) -> Result<(), NutritionError> {
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
        return Err(NutritionError::Validation(format!(
            "unknown nutrient code in food log snapshot (expected {} rows, inserted {})",
            snapshots.len(),
            inserted
        )));
    }
    Ok(())
}

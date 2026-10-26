use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use sea_query::extension::postgres::PgExpr;
use sea_query::{
    Condition, Expr, ExprTrait, Iden, Order, PostgresQueryBuilder, Query, SelectStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;
#[cfg(test)]
use sqlx::{Postgres, QueryBuilder};
use std::ops::Bound;
use uuid::Uuid;

use crate::nutrition::catalog::domain::*;
use crate::nutrition::food_log::domain::*;
use crate::nutrition::meal::domain::MealId;

#[derive(Iden)]
enum FoodLogs {
    Table,
    Id,
    UserId,
    LogDate,
    MealSlot,
    DeviceTimezone,
    ItemProductId,
    ItemMealId,
    ItemName,
    ItemBrand,
    Quantity,
    Unit,
    Notes,
    CreatedAt,
    UpdatedAt,
}

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
                amount: r.amount.normalize(),
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
                    amount: s.amount.normalize(),
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
}

fn food_log_filter_query(filter: FoodLogListFilter) -> SelectStatement {
    let FoodLogListFilter {
        user_id,
        date_range,
        meal_slot,
        items,
    } = filter;

    let product_ids: Vec<Uuid> = items
        .iter()
        .filter_map(|item| match item {
            FoodLogItemRef::Product(id) => Some(id.0),
            FoodLogItemRef::Meal(_) => None,
        })
        .collect();
    let meal_ids: Vec<Uuid> = items
        .iter()
        .filter_map(|item| match item {
            FoodLogItemRef::Product(_) => None,
            FoodLogItemRef::Meal(id) => Some(id.0),
        })
        .collect();

    let mut query = Query::select();
    query
        .columns([
            FoodLogs::Id,
            FoodLogs::UserId,
            FoodLogs::LogDate,
            FoodLogs::MealSlot,
            FoodLogs::DeviceTimezone,
            FoodLogs::ItemProductId,
            FoodLogs::ItemMealId,
            FoodLogs::ItemName,
            FoodLogs::ItemBrand,
            FoodLogs::Quantity,
            FoodLogs::Unit,
            FoodLogs::Notes,
            FoodLogs::CreatedAt,
            FoodLogs::UpdatedAt,
        ])
        .from(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::UserId).eq(user_id));

    push_date_bound(&mut query, &date_range.start, true);
    push_date_bound(&mut query, &date_range.end, false);

    if let Some(slot) = meal_slot {
        query.and_where(Expr::col(FoodLogs::MealSlot).eq(slot.as_str()));
    }

    if !items.is_empty() {
        let mut item_condition = Condition::any();

        if !product_ids.is_empty() {
            item_condition =
                item_condition.add(Expr::col(FoodLogs::ItemProductId).eq_any(product_ids));
        }

        if !meal_ids.is_empty() {
            item_condition = item_condition.add(Expr::col(FoodLogs::ItemMealId).eq_any(meal_ids));
        }

        query.cond_where(item_condition);
    }

    query
        .order_by(FoodLogs::LogDate, Order::Desc)
        .order_by(FoodLogs::CreatedAt, Order::Desc);

    query
}

fn push_date_bound(query: &mut SelectStatement, bound: &Bound<NaiveDate>, is_start: bool) {
    match bound {
        Bound::Included(date) => {
            let expression = if is_start {
                Expr::col(FoodLogs::LogDate).gte(*date)
            } else {
                Expr::col(FoodLogs::LogDate).lte(*date)
            };
            query.and_where(expression);
        }
        Bound::Excluded(date) => {
            let expression = if is_start {
                Expr::col(FoodLogs::LogDate).gt(*date)
            } else {
                Expr::col(FoodLogs::LogDate).lt(*date)
            };
            query.and_where(expression);
        }
        Bound::Unbounded => {}
    }
}

#[cfg(test)]
fn legacy_food_log_filter_query(filter: FoodLogListFilter) -> QueryBuilder<Postgres> {
    let FoodLogListFilter {
        user_id,
        date_range,
        meal_slot,
        items,
    } = filter;

    let product_ids: Vec<Uuid> = items
        .iter()
        .filter_map(|item| match item {
            FoodLogItemRef::Product(id) => Some(id.0),
            FoodLogItemRef::Meal(_) => None,
        })
        .collect();
    let meal_ids: Vec<Uuid> = items
        .iter()
        .filter_map(|item| match item {
            FoodLogItemRef::Product(_) => None,
            FoodLogItemRef::Meal(id) => Some(id.0),
        })
        .collect();

    let mut query = QueryBuilder::<Postgres>::new(
        r#"
        SELECT id, user_id, log_date, meal_slot, device_timezone,
               item_product_id, item_meal_id, item_name, item_brand,
               quantity, unit, notes, created_at, updated_at
        FROM food_logs
        WHERE user_id =
        "#,
    );
    query.push_bind(user_id);

    legacy_push_date_bound(&mut query, "log_date", &date_range.start, true);
    legacy_push_date_bound(&mut query, "log_date", &date_range.end, false);

    if let Some(slot) = meal_slot {
        query.push(" AND meal_slot = ");
        query.push_bind(slot.as_str());
    }

    if !items.is_empty() {
        query.push(" AND (");
        let mut has_previous_item_predicate = false;

        if !product_ids.is_empty() {
            query.push("item_product_id = ANY(");
            query.push_bind(product_ids);
            query.push(")");
            has_previous_item_predicate = true;
        }

        if !meal_ids.is_empty() {
            if has_previous_item_predicate {
                query.push(" OR ");
            }
            query.push("item_meal_id = ANY(");
            query.push_bind(meal_ids);
            query.push(")");
        }

        query.push(")");
    }

    query.push(" ORDER BY log_date DESC, created_at DESC");
    query
}

#[cfg(test)]
fn legacy_push_date_bound(
    query: &mut QueryBuilder<Postgres>,
    column: &str,
    bound: &Bound<NaiveDate>,
    is_start: bool,
) {
    match bound {
        Bound::Included(date) => {
            query.push(" AND ");
            query.push(column);
            query.push(if is_start { " >= " } else { " <= " });
            query.push_bind(*date);
        }
        Bound::Excluded(date) => {
            query.push(" AND ");
            query.push(column);
            query.push(if is_start { " > " } else { " < " });
            query.push_bind(*date);
        }
        Bound::Unbounded => {}
    }
}

fn food_log_row_to_food_log(
    row: FoodLogRow,
    snapshots: Vec<FoodLogNutrientSnapshot>,
) -> Result<FoodLog, NutritionError> {
    let item = match (row.item_product_id, row.item_meal_id) {
        (Some(_), Some(_)) => {
            return Err(NutritionError::Internal(
                "food log has both item references".into(),
            ));
        }
        (Some(pid), None) => FoodLogItemSnapshot::Product {
            id: ProductId(pid),
            name: row.item_name,
            brand: row.item_brand,
        },
        (None, Some(mid)) => FoodLogItemSnapshot::Meal {
            id: MealId(mid),
            name: row.item_name,
        },
        (None, None) => FoodLogItemSnapshot::AdHoc {
            name: row.item_name,
            brand: row.item_brand,
        },
    };

    Ok(FoodLog::restore(
        FoodLogId(row.id),
        row.user_id,
        row.log_date,
        row.meal_slot.and_then(|s| s.parse().ok()),
        row.device_timezone,
        item,
        row.quantity,
        UnitCode(row.unit),
        snapshots,
        row.notes,
        row.created_at,
        row.updated_at,
    ))
}

#[async_trait]
impl FoodLogRepository for PostgresFoodLogRepository {
    async fn create(&self, log: &FoodLog) -> Result<(), NutritionError> {
        self.create_many(std::slice::from_ref(log)).await
    }

    async fn create_many(&self, logs: &[FoodLog]) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        for log in logs {
            let (product_id, meal_id, item_name, item_brand) = item_to_columns(log.item());

            sqlx::query(
                r#"
                INSERT INTO food_logs (id, user_id, log_date, meal_slot, device_timezone, item_product_id, item_meal_id, item_name, item_brand, quantity, unit, notes, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
                "#,
            )
            .bind(log.id().0)
            .bind(log.user_id())
            .bind(log.log_date())
            .bind(log.meal_slot().map(|m| m.as_str()))
            .bind(log.device_timezone())
            .bind(product_id)
            .bind(meal_id)
            .bind(item_name)
            .bind(item_brand)
            .bind(log.quantity_amount())
            .bind(&log.quantity_unit().0)
            .bind(log.notes())
            .bind(log.created_at())
            .bind(log.updated_at())
            .execute(&mut *tx)
            .await?;

            insert_food_log_nutrients(&mut tx, log.id().0, log.nutrient_snapshots()).await?;
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
                WHEN 'late_night_snack' THEN 5
                ELSE 6
            END, created_at DESC
            "#,
        )
        .bind(user_id)
        .bind(log_date)
        .fetch_all(&self.pool)
        .await?;

        self.rows_to_food_logs(rows).await
    }

    async fn list_by_filter(
        &self,
        filter: FoodLogListFilter,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        let statement = food_log_filter_query(filter);
        let (sql, values) = statement.build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, FoodLogRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;
        self.rows_to_food_logs(rows).await
    }

    async fn update(&self, log: &FoodLog) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        let (product_id, meal_id, item_name, item_brand) = item_to_columns(log.item());

        sqlx::query(
            r#"
            UPDATE food_logs SET log_date=$2, meal_slot=$3, device_timezone=$4,
                                 item_product_id=$5, item_meal_id=$6,
                                 item_name=$7, item_brand=$8, quantity=$9, unit=$10, notes=$11,
                                 updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(log.id().0)
        .bind(log.log_date())
        .bind(log.meal_slot().map(|m| m.as_str()))
        .bind(log.device_timezone())
        .bind(product_id)
        .bind(meal_id)
        .bind(item_name)
        .bind(item_brand)
        .bind(log.quantity_amount())
        .bind(&log.quantity_unit().0)
        .bind(log.notes())
        .execute(&mut *tx)
        .await?;

        sqlx::query("DELETE FROM food_log_nutrients WHERE food_log_id = $1")
            .bind(log.id().0)
            .execute(&mut *tx)
            .await?;

        insert_food_log_nutrients(&mut tx, log.id().0, log.nutrient_snapshots()).await?;

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

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
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
        FoodLogItemSnapshot::AdHoc { name, brand } => (None, None, name.as_str(), brand.as_deref()),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    fn base_filter(date_range: DateRange) -> FoodLogListFilter {
        FoodLogListFilter {
            user_id: Uuid::nil(),
            date_range,
            meal_slot: None,
            items: Vec::new(),
        }
    }

    fn filter_sql(filter: FoodLogListFilter) -> String {
        let (sql, _values) = food_log_filter_query(filter).build_sqlx(PostgresQueryBuilder);
        normalize_sql(&sql)
    }

    fn normalize_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    fn expected_filter_sql(where_tail: &str) -> String {
        format!(
            "SELECT \"id\", \"user_id\", \"log_date\", \"meal_slot\", \"device_timezone\", \
             \"item_product_id\", \"item_meal_id\", \"item_name\", \"item_brand\", \"quantity\", \
             \"unit\", \"notes\", \"created_at\", \"updated_at\" FROM \"food_logs\" \
             WHERE \"user_id\" = $1 {where_tail} \
             ORDER BY \"log_date\" DESC, \"created_at\" DESC"
        )
    }

    #[test]
    fn filter_query_uses_inclusive_date_bounds() {
        let sql = filter_sql(base_filter(
            DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap(),
        ));

        assert_eq!(
            sql,
            expected_filter_sql("AND \"log_date\" >= $2 AND \"log_date\" <= $3")
        );
    }

    #[test]
    fn filter_query_uses_exclusive_end_date_bound() {
        let sql = filter_sql(base_filter(
            DateRange::inclusive_to_exclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap(),
        ));

        assert_eq!(
            sql,
            expected_filter_sql("AND \"log_date\" >= $2 AND \"log_date\" < $3")
        );
    }

    #[test]
    fn filter_query_adds_meal_slot_predicate() {
        let mut filter =
            base_filter(DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap());
        filter.meal_slot = Some(MealSlot::Breakfast);

        let sql = filter_sql(filter);

        assert_eq!(
            sql,
            expected_filter_sql(
                "AND \"log_date\" >= $2 AND \"log_date\" <= $3 AND \"meal_slot\" = $4"
            )
        );
    }

    #[test]
    fn filter_query_adds_product_item_predicate() {
        let mut filter =
            base_filter(DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap());
        filter
            .items
            .push(FoodLogItemRef::Product(ProductId(Uuid::nil())));

        let sql = filter_sql(filter);

        assert_eq!(
            sql,
            expected_filter_sql(
                "AND \"log_date\" >= $2 AND \"log_date\" <= $3 AND \
                 \"item_product_id\" = ANY($4)"
            )
        );
    }

    #[test]
    fn filter_query_adds_meal_item_predicate() {
        let mut filter =
            base_filter(DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap());
        filter.items.push(FoodLogItemRef::Meal(MealId(Uuid::nil())));

        let sql = filter_sql(filter);

        assert_eq!(
            sql,
            expected_filter_sql(
                "AND \"log_date\" >= $2 AND \"log_date\" <= $3 AND \
                 \"item_meal_id\" = ANY($4)"
            )
        );
    }

    #[test]
    fn filter_query_adds_mixed_item_predicates() {
        let mut filter =
            base_filter(DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap());
        filter
            .items
            .push(FoodLogItemRef::Product(ProductId(Uuid::nil())));
        filter.items.push(FoodLogItemRef::Meal(MealId(Uuid::nil())));

        let sql = filter_sql(filter);

        assert_eq!(
            sql,
            expected_filter_sql(
                "AND \"log_date\" >= $2 AND \"log_date\" <= $3 AND \
                 (\"item_product_id\" = ANY($4) OR \"item_meal_id\" = ANY($5))"
            )
        );
    }

    #[test]
    fn filter_query_uses_exclusive_start_date_bound() {
        let sql = filter_sql(base_filter(DateRange {
            start: Bound::Excluded(date(2026, 6, 1)),
            end: Bound::Included(date(2026, 6, 3)),
        }));

        assert_eq!(
            sql,
            expected_filter_sql("AND \"log_date\" > $2 AND \"log_date\" <= $3")
        );
    }

    #[test]
    fn filter_query_omits_unbounded_start_date_bound() {
        let sql = filter_sql(base_filter(DateRange {
            start: Bound::Unbounded,
            end: Bound::Included(date(2026, 6, 3)),
        }));

        assert_eq!(sql, expected_filter_sql("AND \"log_date\" <= $2"));
    }

    #[test]
    fn filter_query_omits_unbounded_end_date_bound() {
        let sql = filter_sql(base_filter(DateRange {
            start: Bound::Included(date(2026, 6, 1)),
            end: Bound::Unbounded,
        }));

        assert_eq!(sql, expected_filter_sql("AND \"log_date\" >= $2"));
    }

    fn timestamp(day: NaiveDate, hour: u32) -> DateTime<Utc> {
        day.and_hms_opt(hour, 0, 0).unwrap().and_utc()
    }

    async fn seed_identity_and_profile(pool: &PgPool, label: &str) -> Uuid {
        let identity_id = Uuid::new_v4();
        let user_id = Uuid::new_v4();

        sqlx::query(
            r#"
            INSERT INTO identities (
                id, username, password_hash, role, status, created_at, updated_at,
                session_security_stamp
            )
            VALUES ($1, $2, 'test-password-hash', 'user', 'active', now(), now(), $3)
            "#,
        )
        .bind(identity_id)
        .bind(format!("{label}-{identity_id}"))
        .bind(Uuid::new_v4())
        .execute(pool)
        .await
        .expect("seed identity");

        sqlx::query(
            r#"
            INSERT INTO user_profiles (id, identity_id, display_name, created_at, updated_at)
            VALUES ($1, $2, $3, now(), now())
            "#,
        )
        .bind(user_id)
        .bind(identity_id)
        .bind(label)
        .execute(pool)
        .await
        .expect("seed user profile");

        user_id
    }

    async fn seed_product(pool: &PgPool, user_id: Uuid, name: &str) -> Uuid {
        let product_id = Uuid::new_v4();

        sqlx::query(
            r#"
            INSERT INTO products (id, source, user_id, visibility, name, created_at, updated_at)
            VALUES ($1, 'USER', $2, 'global', $3, now(), now())
            "#,
        )
        .bind(product_id)
        .bind(user_id)
        .bind(name)
        .execute(pool)
        .await
        .expect("seed product");

        product_id
    }

    struct LogSeed<'a> {
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<&'a str>,
        product_id: Option<Uuid>,
        meal_id: Option<Uuid>,
        item_name: &'a str,
        created_at: DateTime<Utc>,
    }

    async fn seed_food_log(pool: &PgPool, seed: LogSeed<'_>) -> Uuid {
        let food_log_id = Uuid::new_v4();

        sqlx::query(
            r#"
            INSERT INTO food_logs (
                id, user_id, log_date, meal_slot, device_timezone,
                item_product_id, item_meal_id, item_name, item_brand,
                quantity, unit, notes, created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, 'UTC', $5, $6, $7, NULL, 100, 'g', NULL, $8, $8)
            "#,
        )
        .bind(food_log_id)
        .bind(seed.user_id)
        .bind(seed.log_date)
        .bind(seed.meal_slot)
        .bind(seed.product_id)
        .bind(seed.meal_id)
        .bind(seed.item_name)
        .bind(seed.created_at)
        .execute(pool)
        .await
        .expect("seed food log");

        food_log_id
    }

    async fn sea_filter_rows(pool: &PgPool, filter: FoodLogListFilter) -> Vec<FoodLogRow> {
        let (sql, values) = food_log_filter_query(filter).build_sqlx(PostgresQueryBuilder);
        sqlx::query_as_with::<_, FoodLogRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_all(pool)
            .await
            .expect("sea-query filter query")
    }

    #[sqlx::test]
    async fn sea_query_filter_matches_legacy_query(pool: PgPool) {
        let user_a = seed_identity_and_profile(&pool, "filter-equivalence-a").await;
        let user_b = seed_identity_and_profile(&pool, "filter-equivalence-b").await;
        let product_a_id = seed_product(&pool, user_a, "Filter Equivalence Apple").await;
        let product_b_id = seed_product(&pool, user_a, "Filter Equivalence Bread").await;
        let meal_a_id = Uuid::new_v4();
        let meal_b_id = Uuid::new_v4();

        let june_1_product_breakfast = seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 1),
                meal_slot: Some("breakfast"),
                product_id: Some(product_a_id),
                meal_id: None,
                item_name: "Apple",
                created_at: timestamp(date(2026, 6, 1), 8),
            },
        )
        .await;
        let june_1_product_b_lunch = seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 1),
                meal_slot: Some("lunch"),
                product_id: Some(product_b_id),
                meal_id: None,
                item_name: "Bread",
                created_at: timestamp(date(2026, 6, 1), 13),
            },
        )
        .await;
        let june_2_meal_lunch = seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 2),
                meal_slot: Some("lunch"),
                product_id: None,
                meal_id: Some(meal_a_id),
                item_name: "Lunch meal",
                created_at: timestamp(date(2026, 6, 2), 12),
            },
        )
        .await;
        let june_2_meal_b_lunch = seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 2),
                meal_slot: Some("lunch"),
                product_id: None,
                meal_id: Some(meal_b_id),
                item_name: "Second lunch meal",
                created_at: timestamp(date(2026, 6, 2), 13),
            },
        )
        .await;
        let june_3_ad_hoc_breakfast = seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 3),
                meal_slot: Some("breakfast"),
                product_id: None,
                meal_id: None,
                item_name: "Ad-hoc breakfast",
                created_at: timestamp(date(2026, 6, 3), 8),
            },
        )
        .await;
        let june_2_product_breakfast = seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 2),
                meal_slot: Some("breakfast"),
                product_id: Some(product_a_id),
                meal_id: None,
                item_name: "Apple",
                created_at: timestamp(date(2026, 6, 2), 9),
            },
        )
        .await;
        seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 5, 31),
                meal_slot: Some("breakfast"),
                product_id: Some(product_a_id),
                meal_id: None,
                item_name: "Apple",
                created_at: timestamp(date(2026, 5, 31), 8),
            },
        )
        .await;
        seed_food_log(
            &pool,
            LogSeed {
                user_id: user_a,
                log_date: date(2026, 6, 4),
                meal_slot: Some("breakfast"),
                product_id: Some(product_a_id),
                meal_id: None,
                item_name: "Apple",
                created_at: timestamp(date(2026, 6, 4), 8),
            },
        )
        .await;
        seed_food_log(
            &pool,
            LogSeed {
                user_id: user_b,
                log_date: date(2026, 6, 2),
                meal_slot: Some("breakfast"),
                product_id: Some(product_a_id),
                meal_id: None,
                item_name: "Other user's apple",
                created_at: timestamp(date(2026, 6, 2), 9),
            },
        )
        .await;

        let inclusive_range = DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap();
        let inclusive_to_exclusive_range =
            DateRange::inclusive_to_exclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap();
        let unbounded_range = DateRange {
            start: Bound::Unbounded,
            end: Bound::Unbounded,
        };
        let excluded_start_range = DateRange {
            start: Bound::Excluded(date(2026, 6, 1)),
            end: Bound::Included(date(2026, 6, 3)),
        };
        let unbounded_start_range = DateRange {
            start: Bound::Unbounded,
            end: Bound::Included(date(2026, 6, 2)),
        };
        let unbounded_end_range = DateRange {
            start: Bound::Included(date(2026, 6, 2)),
            end: Bound::Unbounded,
        };

        let mut inclusive_filter = base_filter(inclusive_range.clone());
        inclusive_filter.user_id = user_a;

        let mut inclusive_to_exclusive_filter = base_filter(inclusive_to_exclusive_range.clone());
        inclusive_to_exclusive_filter.user_id = user_a;

        let mut meal_slot_filter = base_filter(inclusive_range.clone());
        meal_slot_filter.user_id = user_a;
        meal_slot_filter.meal_slot = Some(MealSlot::Breakfast);

        let mut lunch_slot_filter = base_filter(inclusive_range.clone());
        lunch_slot_filter.user_id = user_a;
        lunch_slot_filter.meal_slot = Some(MealSlot::Lunch);

        let mut product_item_filter = base_filter(inclusive_range.clone());
        product_item_filter.user_id = user_a;
        product_item_filter
            .items
            .push(FoodLogItemRef::Product(ProductId(product_a_id)));

        let mut meal_item_filter = base_filter(inclusive_range.clone());
        meal_item_filter.user_id = user_a;
        meal_item_filter
            .items
            .push(FoodLogItemRef::Meal(MealId(meal_a_id)));

        let mut mixed_items_filter = base_filter(inclusive_range.clone());
        mixed_items_filter.user_id = user_a;
        mixed_items_filter
            .items
            .push(FoodLogItemRef::Product(ProductId(product_a_id)));
        mixed_items_filter
            .items
            .push(FoodLogItemRef::Meal(MealId(meal_a_id)));

        let mut combined_breakfast_product_filter = base_filter(inclusive_range.clone());
        combined_breakfast_product_filter.user_id = user_a;
        combined_breakfast_product_filter.meal_slot = Some(MealSlot::Breakfast);
        combined_breakfast_product_filter
            .items
            .push(FoodLogItemRef::Product(ProductId(product_a_id)));

        let mut multi_product_filter = base_filter(inclusive_range.clone());
        multi_product_filter.user_id = user_a;
        multi_product_filter
            .items
            .push(FoodLogItemRef::Product(ProductId(product_a_id)));
        multi_product_filter
            .items
            .push(FoodLogItemRef::Product(ProductId(product_b_id)));

        let mut multi_meal_filter = base_filter(inclusive_range);
        multi_meal_filter.user_id = user_a;
        multi_meal_filter
            .items
            .push(FoodLogItemRef::Meal(MealId(meal_a_id)));
        multi_meal_filter
            .items
            .push(FoodLogItemRef::Meal(MealId(meal_b_id)));

        let mut unbounded_filter = base_filter(unbounded_range);
        unbounded_filter.user_id = user_a;

        let mut excluded_start_filter = base_filter(excluded_start_range);
        excluded_start_filter.user_id = user_a;

        let mut unbounded_start_filter = base_filter(unbounded_start_range);
        unbounded_start_filter.user_id = user_a;

        let mut unbounded_end_filter = base_filter(unbounded_end_range);
        unbounded_end_filter.user_id = user_a;

        let variants = vec![
            ("inclusive range", inclusive_filter, 6),
            (
                "inclusive_to_exclusive range",
                inclusive_to_exclusive_filter,
                5,
            ),
            ("meal slot breakfast", meal_slot_filter, 3),
            ("meal slot lunch", lunch_slot_filter.clone(), 3),
            ("product item", product_item_filter, 2),
            ("meal item", meal_item_filter, 1),
            ("mixed items", mixed_items_filter, 3),
            (
                "meal slot + product item",
                combined_breakfast_product_filter.clone(),
                2,
            ),
            ("multiple product items", multi_product_filter.clone(), 3),
            ("multiple meal items", multi_meal_filter.clone(), 2),
            ("unbounded range", unbounded_filter, 8),
            ("excluded start range", excluded_start_filter.clone(), 4),
            ("unbounded start, inclusive end", unbounded_start_filter, 6),
            ("inclusive start, unbounded end", unbounded_end_filter, 5),
        ];

        let mut saw_non_empty = false;
        for (name, filter, expected_len) in variants {
            let legacy_rows = legacy_food_log_filter_query(filter.clone())
                .build_query_as::<FoodLogRow>()
                .fetch_all(&pool)
                .await
                .unwrap_or_else(|error| panic!("legacy query failed for {name}: {error}"));

            let (sql, values) = food_log_filter_query(filter).build_sqlx(PostgresQueryBuilder);
            let sea_rows =
                sqlx::query_as_with::<_, FoodLogRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                    .fetch_all(&pool)
                    .await
                    .unwrap_or_else(|error| panic!("sea-query failed for {name}: {error}"));

            assert_eq!(
                sea_rows.len(),
                expected_len,
                "{name} returned an unexpected number of rows"
            );
            assert_eq!(
                sea_rows, legacy_rows,
                "{name} diverged from the legacy query"
            );
            assert!(
                sea_rows.iter().all(|row| row.user_id == user_a),
                "{name} leaked another user's food logs"
            );
            saw_non_empty |= !sea_rows.is_empty();
        }

        assert!(
            saw_non_empty,
            "the equivalence test must exercise at least one non-empty result"
        );

        let lunch_rows = sea_filter_rows(&pool, lunch_slot_filter).await;
        assert_eq!(lunch_rows.len(), 3);
        assert!(
            lunch_rows
                .iter()
                .all(|row| row.meal_slot.as_deref() == Some("lunch")),
            "lunch filter must not match breakfast rows"
        );

        let combined_rows = sea_filter_rows(&pool, combined_breakfast_product_filter).await;
        assert_eq!(combined_rows.len(), 2);
        assert!(
            combined_rows
                .iter()
                .all(|row| row.meal_slot.as_deref() == Some("breakfast")),
            "combined filter must apply the slot with AND"
        );
        assert!(
            combined_rows
                .iter()
                .all(|row| row.item_product_id == Some(product_a_id)),
            "combined filter must apply the item with AND"
        );

        let multi_product_rows = sea_filter_rows(&pool, multi_product_filter).await;
        assert_eq!(multi_product_rows.len(), 3);
        assert!(
            multi_product_rows
                .iter()
                .any(|row| row.item_product_id == Some(product_a_id)),
            "multi-product filter must include the first product"
        );
        assert!(
            multi_product_rows
                .iter()
                .any(|row| row.item_product_id == Some(product_b_id)),
            "multi-product filter must include the second product"
        );

        let multi_meal_rows = sea_filter_rows(&pool, multi_meal_filter).await;
        assert_eq!(multi_meal_rows.len(), 2);
        assert!(
            multi_meal_rows
                .iter()
                .any(|row| row.item_meal_id == Some(meal_a_id)),
            "multi-meal filter must include the first meal"
        );
        assert!(
            multi_meal_rows
                .iter()
                .any(|row| row.item_meal_id == Some(meal_b_id)),
            "multi-meal filter must include the second meal"
        );

        let excluded_start_rows = sea_filter_rows(&pool, excluded_start_filter).await;
        assert_eq!(excluded_start_rows.len(), 4);
        assert!(
            excluded_start_rows
                .iter()
                .all(|row| row.log_date > date(2026, 6, 1)),
            "exclusive start must exclude the boundary row"
        );

        let inclusive_ids: Vec<Uuid> = sea_filter_rows(
            &pool,
            inclusive_filter_for(user_a, date(2026, 6, 1), date(2026, 6, 3)),
        )
        .await
        .into_iter()
        .map(|row| row.id)
        .collect();
        assert_eq!(
            inclusive_ids,
            vec![
                june_3_ad_hoc_breakfast,
                june_2_meal_b_lunch,
                june_2_meal_lunch,
                june_2_product_breakfast,
                june_1_product_b_lunch,
                june_1_product_breakfast,
            ],
            "inclusive range must be ordered by log_date DESC, created_at DESC"
        );
    }

    fn inclusive_filter_for(user_id: Uuid, start: NaiveDate, end: NaiveDate) -> FoodLogListFilter {
        let mut filter = base_filter(DateRange::inclusive(start, end).unwrap());
        filter.user_id = user_id;
        filter
    }
}

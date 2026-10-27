use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use sea_query::extension::postgres::PgExpr;
use sea_query::{
    CaseStatement, Condition, DeleteStatement, Expr, ExprTrait, Iden, InsertStatement, JoinType,
    Order, PostgresQueryBuilder, Query, SelectStatement, UpdateStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;
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

#[derive(Iden)]
enum FoodLogNutrients {
    Table,
    FoodLogId,
    NutrientId,
    Amount,
    Unit,
}

#[derive(Iden)]
enum Nutrients {
    Table,
    Id,
    Code,
}

fn food_log_columns() -> [FoodLogs; 14] {
    [
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
    ]
}

fn load_snapshots_statement(food_log_id: Uuid) -> SelectStatement {
    Query::select()
        .column((FoodLogNutrients::Table, FoodLogNutrients::Amount))
        .column((FoodLogNutrients::Table, FoodLogNutrients::Unit))
        .column((Nutrients::Table, Nutrients::Code))
        .from(FoodLogNutrients::Table)
        .join(
            JoinType::InnerJoin,
            Nutrients::Table,
            Expr::col((Nutrients::Table, Nutrients::Id))
                .equals((FoodLogNutrients::Table, FoodLogNutrients::NutrientId)),
        )
        .and_where(
            Expr::col((FoodLogNutrients::Table, FoodLogNutrients::FoodLogId)).eq(food_log_id),
        )
        .to_owned()
}

fn snapshot_join_statement(ids: Vec<Uuid>) -> SelectStatement {
    Query::select()
        .column((FoodLogNutrients::Table, FoodLogNutrients::FoodLogId))
        .column((FoodLogNutrients::Table, FoodLogNutrients::Amount))
        .column((FoodLogNutrients::Table, FoodLogNutrients::Unit))
        .column((Nutrients::Table, Nutrients::Code))
        .from(FoodLogNutrients::Table)
        .join(
            JoinType::InnerJoin,
            Nutrients::Table,
            Expr::col((Nutrients::Table, Nutrients::Id))
                .equals((FoodLogNutrients::Table, FoodLogNutrients::NutrientId)),
        )
        .and_where(Expr::col((FoodLogNutrients::Table, FoodLogNutrients::FoodLogId)).eq_any(ids))
        .to_owned()
}

fn find_food_log_statement(id: Uuid) -> SelectStatement {
    Query::select()
        .columns(food_log_columns())
        .from(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::Id).eq(id))
        .to_owned()
}

fn list_by_user_and_date_statement(user_id: Uuid, log_date: NaiveDate) -> SelectStatement {
    let slot_rank = CaseStatement::new()
        .case(
            Expr::col(FoodLogs::MealSlot).eq(MealSlot::Breakfast.as_str()),
            1_i32,
        )
        .case(
            Expr::col(FoodLogs::MealSlot).eq(MealSlot::Lunch.as_str()),
            2_i32,
        )
        .case(
            Expr::col(FoodLogs::MealSlot).eq(MealSlot::Dinner.as_str()),
            3_i32,
        )
        .case(
            Expr::col(FoodLogs::MealSlot).eq(MealSlot::Snack.as_str()),
            4_i32,
        )
        .case(
            Expr::col(FoodLogs::MealSlot).eq(MealSlot::LateNightSnack.as_str()),
            5_i32,
        )
        .finally(6_i32);

    Query::select()
        .columns(food_log_columns())
        .from(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::UserId).eq(user_id))
        .and_where(Expr::col(FoodLogs::LogDate).eq(log_date))
        .order_by_expr(slot_rank.into(), Order::Asc)
        .order_by(FoodLogs::CreatedAt, Order::Desc)
        .to_owned()
}

fn insert_food_log_statement(log: &FoodLog) -> InsertStatement {
    let (product_id, meal_id, item_name, item_brand) = item_to_columns(log.item());

    Query::insert()
        .into_table(FoodLogs::Table)
        .columns(food_log_columns())
        .values_panic([
            log.id().0.into(),
            log.user_id().into(),
            log.log_date().into(),
            log.meal_slot().map(|slot| slot.as_str()).into(),
            log.device_timezone().into(),
            product_id.into(),
            meal_id.into(),
            item_name.into(),
            item_brand.into(),
            log.quantity_amount().into(),
            log.quantity_unit().0.as_str().into(),
            log.notes().into(),
            log.created_at().into(),
            log.updated_at().into(),
        ])
        .to_owned()
}

fn update_food_log_statement(log: &FoodLog) -> UpdateStatement {
    let (product_id, meal_id, item_name, item_brand) = item_to_columns(log.item());

    Query::update()
        .table(FoodLogs::Table)
        .value(FoodLogs::LogDate, log.log_date())
        .value(
            FoodLogs::MealSlot,
            log.meal_slot().map(|slot| slot.as_str()),
        )
        .value(FoodLogs::DeviceTimezone, log.device_timezone())
        .value(FoodLogs::ItemProductId, product_id)
        .value(FoodLogs::ItemMealId, meal_id)
        .value(FoodLogs::ItemName, item_name)
        .value(FoodLogs::ItemBrand, item_brand)
        .value(FoodLogs::Quantity, log.quantity_amount())
        .value(FoodLogs::Unit, log.quantity_unit().0.as_str())
        .value(FoodLogs::Notes, log.notes())
        .value(FoodLogs::UpdatedAt, Expr::current_timestamp())
        .and_where(Expr::col(FoodLogs::Id).eq(log.id().0))
        .to_owned()
}

fn delete_food_log_statement(id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::Id).eq(id))
        .to_owned()
}

fn delete_food_log_nutrients_statement(food_log_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(FoodLogNutrients::Table)
        .and_where(Expr::col(FoodLogNutrients::FoodLogId).eq(food_log_id))
        .to_owned()
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
        let (sql, values) = load_snapshots_statement(food_log_id).build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, NutrientSnapshotRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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
        let (sql, values) = snapshot_join_statement(ids).build_sqlx(PostgresQueryBuilder);
        let snapshot_rows = sqlx::query_as_with::<_, FoodLogSnapshotJoinRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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
            let (sql, values) = insert_food_log_statement(log).build_sqlx(PostgresQueryBuilder);
            sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .execute(&mut *tx)
                .await?;

            insert_food_log_nutrients(&mut tx, log.id().0, log.nutrient_snapshots()).await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, NutritionError> {
        let (sql, values) = find_food_log_statement(id.0).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, FoodLogRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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
        let (sql, values) =
            list_by_user_and_date_statement(user_id, log_date).build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, FoodLogRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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

        let (sql, values) = update_food_log_statement(log).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) =
            delete_food_log_nutrients_statement(log.id().0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        insert_food_log_nutrients(&mut tx, log.id().0, log.nutrient_snapshots()).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: FoodLogId) -> Result<(), NutritionError> {
        let (sql, values) = delete_food_log_statement(id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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
        FoodLogItemSnapshot::AdHoc { name, brand } => (None, None, name.as_str(), brand.as_deref()),
    }
}

/// Postgres-specific bulk snapshot insert.
///
/// This intentionally stays as raw SQL: `UNNEST` turns the three snapshot
/// arrays into a single set-based insert, and the returned row count is the
/// validation that every nutrient code resolved. sea-query cannot express
/// either the array unnest or the count validation more clearly than this.
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

    fn sql_contains(sql: &str, needle: &str) -> bool {
        str::contains(sql, needle)
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

    fn snapshot(code: &str, amount: i64, unit: &str) -> FoodLogNutrientSnapshot {
        FoodLogNutrientSnapshot {
            nutrient_code: NutrientCode(code.to_owned()),
            amount: Decimal::from(amount),
            unit: UnitCode(unit.to_owned()),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn log_fixture(
        id: Uuid,
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<&str>,
        item: FoodLogItemSnapshot,
        quantity_amount: Decimal,
        quantity_unit: &str,
        snapshots: Vec<FoodLogNutrientSnapshot>,
        notes: Option<&str>,
        created_at: DateTime<Utc>,
    ) -> FoodLog {
        FoodLog::restore(
            FoodLogId(id),
            user_id,
            log_date,
            meal_slot,
            device_timezone.map(str::to_owned),
            item,
            quantity_amount,
            UnitCode(quantity_unit.to_owned()),
            snapshots,
            notes.map(str::to_owned),
            created_at,
            created_at,
        )
    }

    #[test]
    fn list_by_user_and_date_statement_orders_slots_then_created_at() {
        let (sql, values) = list_by_user_and_date_statement(Uuid::nil(), date(2026, 6, 2))
            .build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql_contains(&sql, "CASE WHEN"),
            "meal slots must be ranked with a CASE expression: {sql}"
        );
        assert!(
            sql_contains(&sql, "ELSE") && sql_contains(&sql, "END"),
            "meal slot ranking must preserve ELSE 6: {sql}"
        );
        let expected_order_tail = r#"ORDER BY (CASE WHEN ("meal_slot" = $3) THEN $4 WHEN ("meal_slot" = $5) THEN $6 WHEN ("meal_slot" = $7) THEN $8 WHEN ("meal_slot" = $9) THEN $10 WHEN ("meal_slot" = $11) THEN $12 ELSE $13 END) ASC, "created_at" DESC"#;
        assert!(
            sql.ends_with(expected_order_tail),
            "meal slot order must end with the exact CASE/created_at tail: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            13,
            "expected user_id, log_date, five slot values, five ranks, and ELSE rank: {sql}"
        );
        assert!(
            values
                .0
                .iter()
                .any(|value| matches!(value, sea_query::Value::Int(Some(6)))),
            "ELSE rank must be 6: {sql}"
        );
    }

    #[test]
    fn snapshot_join_statement_uses_one_uuid_array_bind() {
        let ids = vec![Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];
        let (sql, values) = snapshot_join_statement(ids).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql_contains(&sql, "ANY("),
            "snapshot join must use a Postgres ANY array predicate: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            1,
            "snapshot join must bind one uuid[] array: {sql}"
        );
        assert!(
            matches!(
                values.0.iter().next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::Uuid,
                    Some(ids)
                )) if ids.len() == 3
            ),
            "snapshot join must bind a single uuid[] value: {sql}"
        );
    }

    #[test]
    fn update_statement_uses_current_timestamp_without_extra_bind() {
        let log = log_fixture(
            Uuid::nil(),
            Uuid::nil(),
            date(2026, 6, 1),
            Some(MealSlot::Breakfast),
            Some("UTC"),
            FoodLogItemSnapshot::AdHoc {
                name: "Timestamp".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![],
            None,
            timestamp(date(2026, 6, 1), 8),
        );
        let (sql, values) = update_food_log_statement(&log).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql_contains(&sql, r#""updated_at" = CURRENT_TIMESTAMP"#),
            "update must use CURRENT_TIMESTAMP: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            11,
            "update must bind the ten editable columns and id only: {sql}"
        );
        assert!(
            sql.ends_with(r#"WHERE "id" = $11"#),
            "update must target exactly one food log by id: {sql}"
        );
    }

    #[test]
    fn insert_statement_binds_all_fourteen_columns() {
        let log = log_fixture(
            Uuid::nil(),
            Uuid::nil(),
            date(2026, 6, 1),
            None,
            None,
            FoodLogItemSnapshot::AdHoc {
                name: "Insert".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![snapshot("FAT_G", 2, "g")],
            None,
            timestamp(date(2026, 6, 1), 8),
        );
        let (sql, values) = insert_food_log_statement(&log).build_sqlx(PostgresQueryBuilder);

        assert_eq!(
            values.0.iter().count(),
            14,
            "insert must bind every food_logs column: {sql}"
        );
    }
}

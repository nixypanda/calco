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

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
struct NutrientSnapshotRow {
    amount: Decimal,
    unit: String,
    code: String,
}

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
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
fn nutrient_snapshot_from_row(row: NutrientSnapshotRow) -> FoodLogNutrientSnapshot {
    FoodLogNutrientSnapshot {
        nutrient_code: NutrientCode(row.code),
        amount: row.amount.normalize(),
        unit: UnitCode(row.unit),
    }
}

#[cfg(test)]
async fn legacy_load_snapshots(
    pool: &PgPool,
    food_log_id: Uuid,
) -> Result<Vec<FoodLogNutrientSnapshot>, sqlx::Error> {
    let rows = sqlx::query_as::<_, NutrientSnapshotRow>(
        r#"
        SELECT fln.amount, fln.unit, n.code
        FROM food_log_nutrients fln
        JOIN nutrients n ON n.id = fln.nutrient_id
        WHERE fln.food_log_id = $1
        "#,
    )
    .bind(food_log_id)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(nutrient_snapshot_from_row).collect())
}

#[cfg(test)]
async fn legacy_rows_to_food_logs(
    pool: &PgPool,
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
    .fetch_all(pool)
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

#[cfg(test)]
async fn legacy_find_by_id(
    pool: &PgPool,
    id: FoodLogId,
) -> Result<Option<FoodLog>, NutritionError> {
    let row = sqlx::query_as::<_, FoodLogRow>(
        r#"
        SELECT id, user_id, log_date, meal_slot, device_timezone, item_product_id, item_meal_id,
               item_name, item_brand, quantity, unit, notes, created_at, updated_at
        FROM food_logs WHERE id = $1
        "#,
    )
    .bind(id.0)
    .fetch_optional(pool)
    .await?;

    match row {
        Some(r) => {
            let snapshots = legacy_load_snapshots(pool, r.id).await?;
            Ok(Some(food_log_row_to_food_log(r, snapshots)?))
        }
        None => Ok(None),
    }
}

#[cfg(test)]
async fn legacy_list_by_user_and_date(
    pool: &PgPool,
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
    .fetch_all(pool)
    .await?;

    legacy_rows_to_food_logs(pool, rows).await
}

#[cfg(test)]
async fn legacy_create_many(pool: &PgPool, logs: &[FoodLog]) -> Result<(), NutritionError> {
    let mut tx = pool.begin().await?;

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

#[cfg(test)]
async fn legacy_update(pool: &PgPool, log: &FoodLog) -> Result<(), NutritionError> {
    let mut tx = pool.begin().await?;

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

#[cfg(test)]
async fn legacy_delete(pool: &PgPool, id: FoodLogId) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM food_logs WHERE id = $1")
        .bind(id.0)
        .execute(pool)
        .await?;
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

    fn snapshot(code: &str, amount: i64, unit: &str) -> FoodLogNutrientSnapshot {
        FoodLogNutrientSnapshot {
            nutrient_code: NutrientCode(code.to_owned()),
            amount: Decimal::from(amount),
            unit: UnitCode(unit.to_owned()),
        }
    }

    fn snapshot_shapes(snapshots: &[FoodLogNutrientSnapshot]) -> Vec<(String, Decimal, String)> {
        let mut shapes: Vec<_> = snapshots
            .iter()
            .map(|snapshot| {
                (
                    snapshot.nutrient_code.0.clone(),
                    snapshot.amount,
                    snapshot.unit.0.clone(),
                )
            })
            .collect();
        shapes.sort();
        shapes
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

    fn assert_same_log_contents_except_updated_at(left: &FoodLog, right: &FoodLog, label: &str) {
        assert_eq!(left.log_date(), right.log_date(), "{label}: log_date");
        assert_eq!(left.meal_slot(), right.meal_slot(), "{label}: meal_slot");
        assert_eq!(
            left.device_timezone(),
            right.device_timezone(),
            "{label}: device_timezone"
        );
        assert_eq!(left.item(), right.item(), "{label}: item");
        assert_eq!(
            left.quantity_amount(),
            right.quantity_amount(),
            "{label}: quantity"
        );
        assert_eq!(left.quantity_unit(), right.quantity_unit(), "{label}: unit");
        assert_eq!(left.notes(), right.notes(), "{label}: notes");
        assert_eq!(left.created_at(), right.created_at(), "{label}: created_at");
        assert_eq!(
            snapshot_shapes(left.nutrient_snapshots()),
            snapshot_shapes(right.nutrient_snapshots()),
            "{label}: nutrient snapshots"
        );
    }

    fn assert_same_log_contents(left: &FoodLog, right: &FoodLog, label: &str) {
        assert_same_log_contents_except_updated_at(left, right, label);
        assert_eq!(left.updated_at(), right.updated_at(), "{label}: updated_at");
    }

    async fn fetch_food_log_row(pool: &PgPool, id: Uuid) -> Option<FoodLogRow> {
        sqlx::query_as::<_, FoodLogRow>(
            r#"
            SELECT id, user_id, log_date, meal_slot, device_timezone, item_product_id, item_meal_id,
                   item_name, item_brand, quantity, unit, notes, created_at, updated_at
            FROM food_logs WHERE id = $1
            "#,
        )
        .bind(id)
        .fetch_optional(pool)
        .await
        .expect("fetch food log row")
    }

    async fn seed_meal_row(pool: &PgPool, user_id: Uuid, name: &str) -> Uuid {
        let meal_id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO meals (id, user_id, name, created_at, updated_at)
            VALUES ($1, $2, $3, now(), now())
            "#,
        )
        .bind(meal_id)
        .bind(user_id)
        .bind(name)
        .execute(pool)
        .await
        .expect("seed meal row");
        meal_id
    }

    async fn seed_snapshot(pool: &PgPool, food_log_id: Uuid, code: &str, amount: i64, unit: &str) {
        sqlx::query(
            r#"
            INSERT INTO food_log_nutrients (food_log_id, nutrient_id, amount, unit)
            SELECT $1, id, $2, $3 FROM nutrients WHERE code = $4
            "#,
        )
        .bind(food_log_id)
        .bind(Decimal::from(amount))
        .bind(unit)
        .bind(code)
        .execute(pool)
        .await
        .expect("seed food log nutrient");
    }

    fn assert_recent(timestamp: DateTime<Utc>, label: &str) {
        let age = Utc::now().signed_duration_since(timestamp);
        assert!(
            age.num_seconds().abs() < 300,
            "{label} updated_at should be current, got {timestamp}"
        );
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

    #[sqlx::test]
    async fn create_many_matches_legacy_including_snapshots(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "food-log-create-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "food-log-create-sea").await;
        let product_id = seed_product(&pool, legacy_user_id, "Create Oats").await;
        let meal_id = seed_meal_row(&pool, legacy_user_id, "Create Meal").await;
        let created_at = timestamp(date(2026, 6, 1), 8);

        let legacy_logs = vec![
            log_fixture(
                Uuid::new_v4(),
                legacy_user_id,
                date(2026, 6, 1),
                Some(MealSlot::Breakfast),
                Some("Asia/Kolkata"),
                FoodLogItemSnapshot::Product {
                    id: ProductId(product_id),
                    name: "Create Oats".into(),
                    brand: Some("Acme".into()),
                },
                Decimal::from(80),
                "g",
                vec![
                    snapshot("ENERGY_KCAL", 312, "kcal"),
                    snapshot("PROTEIN_G", 12, "g"),
                ],
                Some("legacy product log"),
                created_at,
            ),
            log_fixture(
                Uuid::new_v4(),
                legacy_user_id,
                date(2026, 6, 1),
                Some(MealSlot::Lunch),
                None,
                FoodLogItemSnapshot::AdHoc {
                    name: "Mystery stew".into(),
                    brand: Some("Homemade".into()),
                },
                Decimal::from(1),
                "serving",
                vec![
                    snapshot("ENERGY_KCAL", 420, "kcal"),
                    snapshot("FAT_G", 9, "g"),
                ],
                None,
                created_at,
            ),
        ];
        let sea_logs = vec![
            log_fixture(
                Uuid::new_v4(),
                sea_user_id,
                date(2026, 6, 1),
                Some(MealSlot::Breakfast),
                Some("Asia/Kolkata"),
                FoodLogItemSnapshot::Product {
                    id: ProductId(product_id),
                    name: "Create Oats".into(),
                    brand: Some("Acme".into()),
                },
                Decimal::from(80),
                "g",
                vec![
                    snapshot("ENERGY_KCAL", 312, "kcal"),
                    snapshot("PROTEIN_G", 12, "g"),
                ],
                Some("legacy product log"),
                created_at,
            ),
            log_fixture(
                Uuid::new_v4(),
                sea_user_id,
                date(2026, 6, 1),
                Some(MealSlot::Lunch),
                None,
                FoodLogItemSnapshot::AdHoc {
                    name: "Mystery stew".into(),
                    brand: Some("Homemade".into()),
                },
                Decimal::from(1),
                "serving",
                vec![
                    snapshot("ENERGY_KCAL", 420, "kcal"),
                    snapshot("FAT_G", 9, "g"),
                ],
                None,
                created_at,
            ),
        ];

        legacy_create_many(&pool, &legacy_logs)
            .await
            .expect("legacy create_many");
        let repository = PostgresFoodLogRepository::new(pool.clone());
        repository
            .create_many(&sea_logs)
            .await
            .expect("repository create_many");

        for ((legacy_log, sea_log), label) in
            legacy_logs.iter().zip(&sea_logs).zip(["product", "ad-hoc"])
        {
            let legacy_found = legacy_find_by_id(&pool, legacy_log.id())
                .await
                .expect("legacy find created")
                .expect("legacy created log exists");
            let sea_found = repository
                .find_by_id(sea_log.id())
                .await
                .expect("repository find created")
                .expect("repository created log exists");

            assert_same_log_contents(legacy_log, &legacy_found, label);
            assert_same_log_contents(&legacy_found, &sea_found, label);

            let legacy_snapshots = legacy_load_snapshots(&pool, legacy_log.id().0)
                .await
                .expect("legacy load snapshots");
            let sea_snapshots = repository
                .load_snapshots(sea_log.id().0)
                .await
                .expect("repository load snapshots");
            assert_eq!(
                snapshot_shapes(&sea_snapshots),
                snapshot_shapes(&legacy_snapshots),
                "{label}: load_snapshots diverged"
            );
        }

        let meal_log = log_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Dinner),
            Some("UTC"),
            FoodLogItemSnapshot::Meal {
                id: MealId(meal_id),
                name: "Create Meal".into(),
            },
            Decimal::from(1),
            "serving",
            vec![snapshot("CARBS_G", 45, "g")],
            None,
            created_at,
        );
        legacy_create_many(&pool, std::slice::from_ref(&meal_log))
            .await
            .expect("legacy create meal log");
        let found = repository
            .find_by_id(meal_log.id())
            .await
            .expect("repository find meal log")
            .expect("meal log exists");
        assert_eq!(found.item(), meal_log.item());
        assert_eq!(found.meal_slot(), Some(MealSlot::Dinner));
    }

    #[sqlx::test]
    async fn find_by_id_matches_legacy_for_present_and_absent_logs(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "food-log-find").await;
        let product_id = seed_product(&pool, user_id, "Find Apple").await;
        let log = log_fixture(
            Uuid::new_v4(),
            user_id,
            date(2026, 6, 2),
            Some(MealSlot::Snack),
            Some("UTC"),
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Find Apple".into(),
                brand: None,
            },
            Decimal::from(120),
            "g",
            vec![
                snapshot("ENERGY_KCAL", 62, "kcal"),
                snapshot("FIBER_G", 3, "g"),
            ],
            Some("find me"),
            timestamp(date(2026, 6, 2), 15),
        );
        legacy_create_many(&pool, std::slice::from_ref(&log))
            .await
            .expect("seed food log");

        let repository = PostgresFoodLogRepository::new(pool.clone());
        let legacy_found = legacy_find_by_id(&pool, log.id())
            .await
            .expect("legacy find present")
            .expect("legacy log exists");
        let sea_found = repository
            .find_by_id(log.id())
            .await
            .expect("repository find present")
            .expect("repository log exists");
        assert_same_log_contents(&legacy_found, &sea_found, "find present");
        assert_same_log_contents(&log, &sea_found, "find expected");
        assert_eq!(legacy_found.id(), log.id());
        assert_eq!(sea_found.id(), log.id());
        assert_eq!(sea_found.user_id(), log.user_id());

        let missing = FoodLogId(Uuid::new_v4());
        let legacy_missing = legacy_find_by_id(&pool, missing)
            .await
            .expect("legacy find absent");
        let sea_missing = repository
            .find_by_id(missing)
            .await
            .expect("repository find absent");
        assert_eq!(sea_missing, legacy_missing);
        assert!(sea_missing.is_none());
    }

    #[sqlx::test]
    async fn list_by_user_and_date_matches_legacy_ordering_and_snapshots(pool: PgPool) {
        let user_a = seed_identity_and_profile(&pool, "food-log-list-a").await;
        let user_b = seed_identity_and_profile(&pool, "food-log-list-b").await;
        let product_id = seed_product(&pool, user_a, "List Apple").await;
        let listing_date = date(2026, 6, 2);

        let seed = |slot: Option<&'static str>, hour: u32, name: &'static str| LogSeed {
            user_id: user_a,
            log_date: listing_date,
            meal_slot: slot,
            product_id: Some(product_id),
            meal_id: None,
            item_name: name,
            created_at: timestamp(listing_date, hour),
        };

        let breakfast_early =
            seed_food_log(&pool, seed(Some("breakfast"), 8, "Breakfast early")).await;
        let breakfast_late =
            seed_food_log(&pool, seed(Some("breakfast"), 9, "Breakfast late")).await;
        let lunch = seed_food_log(&pool, seed(Some("lunch"), 12, "Lunch")).await;
        let dinner = seed_food_log(&pool, seed(Some("dinner"), 18, "Dinner")).await;
        let snack = seed_food_log(&pool, seed(Some("snack"), 15, "Snack")).await;
        let late_night =
            seed_food_log(&pool, seed(Some("late_night_snack"), 22, "Late night")).await;
        let null_slot = seed_food_log(&pool, seed(None, 23, "Null slot")).await;
        let unknown_slot = seed_food_log(&pool, seed(Some("brunch"), 20, "Unknown slot")).await;
        seed_food_log(
            &pool,
            LogSeed {
                user_id: user_b,
                log_date: listing_date,
                meal_slot: Some("breakfast"),
                product_id: Some(product_id),
                meal_id: None,
                item_name: "Other user breakfast",
                created_at: timestamp(listing_date, 7),
            },
        )
        .await;

        seed_snapshot(&pool, breakfast_early, "ENERGY_KCAL", 100, "kcal").await;
        seed_snapshot(&pool, breakfast_early, "PROTEIN_G", 5, "g").await;
        seed_snapshot(&pool, null_slot, "FAT_G", 9, "g").await;
        seed_snapshot(&pool, unknown_slot, "CARBS_G", 22, "g").await;

        let repository = PostgresFoodLogRepository::new(pool.clone());
        let legacy_logs = legacy_list_by_user_and_date(&pool, user_a, listing_date)
            .await
            .expect("legacy list_by_user_and_date");
        let sea_logs = repository
            .list_by_user_and_date(user_a, listing_date)
            .await
            .expect("repository list_by_user_and_date");

        assert_eq!(sea_logs.len(), legacy_logs.len());
        for (sea_log, legacy_log) in sea_logs.iter().zip(&legacy_logs) {
            assert_same_log_contents(sea_log, legacy_log, "list_by_user_and_date");
        }
        assert_eq!(
            sea_logs.iter().map(|log| log.id().0).collect::<Vec<_>>(),
            vec![
                breakfast_late,
                breakfast_early,
                lunch,
                dinner,
                snack,
                late_night,
                null_slot,
                unknown_slot,
            ],
            "slots must rank breakfast..late_night, then NULL/unknown, with created_at DESC inside a slot"
        );
        assert!(
            sea_logs.iter().all(|log| log.user_id() == user_a),
            "list_by_user_and_date must scope to the requested user"
        );

        let breakfast_early_log = sea_logs
            .iter()
            .find(|log| log.id().0 == breakfast_early)
            .expect("breakfast early log");
        assert_eq!(
            snapshot_shapes(breakfast_early_log.nutrient_snapshots()),
            vec![
                (
                    "ENERGY_KCAL".to_owned(),
                    Decimal::from(100),
                    "kcal".to_owned()
                ),
                ("PROTEIN_G".to_owned(), Decimal::from(5), "g".to_owned()),
            ],
            "the array-bind snapshot join must attach the right snapshots to a multi-log result"
        );
        let null_slot_log = sea_logs
            .iter()
            .find(|log| log.id().0 == null_slot)
            .expect("null slot log");
        assert_eq!(
            snapshot_shapes(null_slot_log.nutrient_snapshots()),
            vec![("FAT_G".to_owned(), Decimal::from(9), "g".to_owned())]
        );
        let unknown_slot_log = sea_logs
            .iter()
            .find(|log| log.id().0 == unknown_slot)
            .expect("unknown slot log");
        assert_eq!(
            snapshot_shapes(unknown_slot_log.nutrient_snapshots()),
            vec![("CARBS_G".to_owned(), Decimal::from(22), "g".to_owned())]
        );

        let user_b_logs = repository
            .list_by_user_and_date(user_b, listing_date)
            .await
            .expect("repository list for user b");
        assert_eq!(user_b_logs.len(), 1);
        assert_eq!(
            user_b_logs[0].item().clone(),
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Other user breakfast".into(),
                brand: None,
            }
        );
    }

    #[sqlx::test]
    async fn update_matches_legacy_and_replaces_snapshots(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "food-log-update-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "food-log-update-sea").await;
        let other_user_id = seed_identity_and_profile(&pool, "food-log-update-other").await;
        let product_id = seed_product(&pool, legacy_user_id, "Update Apple").await;
        let created_at = timestamp(date(2026, 5, 1), 8);

        let legacy_initial = log_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Breakfast),
            Some("UTC"),
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Update Apple".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![
                snapshot("ENERGY_KCAL", 100, "kcal"),
                snapshot("PROTEIN_G", 10, "g"),
            ],
            Some("before"),
            created_at,
        );
        let sea_initial = log_fixture(
            Uuid::new_v4(),
            sea_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Breakfast),
            Some("UTC"),
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Update Apple".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![
                snapshot("ENERGY_KCAL", 100, "kcal"),
                snapshot("PROTEIN_G", 10, "g"),
            ],
            Some("before"),
            created_at,
        );
        let sea_bystander = log_fixture(
            Uuid::new_v4(),
            sea_user_id,
            date(2026, 6, 3),
            Some(MealSlot::Dinner),
            Some("Europe/Paris"),
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Same-user bystander".into(),
                brand: Some("Keep".into()),
            },
            Decimal::from(250),
            "g",
            vec![snapshot("FIBER_G", 7, "g"), snapshot("IRON_MG", 3, "mg")],
            Some("same-user bystander"),
            timestamp(date(2026, 6, 3), 19),
        );
        let other_bystander = log_fixture(
            Uuid::new_v4(),
            other_user_id,
            date(2026, 6, 4),
            Some(MealSlot::Snack),
            None,
            FoodLogItemSnapshot::AdHoc {
                name: "Other user bystander".into(),
                brand: None,
            },
            Decimal::from(42),
            "g",
            vec![snapshot("SODIUM_MG", 11, "mg")],
            Some("other user bystander"),
            timestamp(date(2026, 6, 4), 16),
        );
        legacy_create_many(
            &pool,
            &[
                legacy_initial.clone(),
                sea_initial.clone(),
                sea_bystander.clone(),
                other_bystander.clone(),
            ],
        )
        .await
        .expect("seed food logs");

        let stale_updated_at = timestamp(date(2000, 1, 1), 0);
        sqlx::query("UPDATE food_logs SET updated_at = $1 WHERE id = ANY($2)")
            .bind(stale_updated_at)
            .bind(vec![legacy_initial.id().0, sea_initial.id().0])
            .execute(&pool)
            .await
            .expect("backdate food logs");

        let sea_bystander_row_before = fetch_food_log_row(&pool, sea_bystander.id().0)
            .await
            .expect("same-user bystander row before update");
        let sea_bystander_snapshots_before = legacy_load_snapshots(&pool, sea_bystander.id().0)
            .await
            .expect("same-user bystander snapshots before update");
        let other_bystander_row_before = fetch_food_log_row(&pool, other_bystander.id().0)
            .await
            .expect("other-user bystander row before update");
        let other_bystander_snapshots_before = legacy_load_snapshots(&pool, other_bystander.id().0)
            .await
            .expect("other-user bystander snapshots before update");

        let legacy_updated = log_fixture(
            legacy_initial.id().0,
            legacy_user_id,
            date(2026, 6, 5),
            Some(MealSlot::LateNightSnack),
            Some("America/New_York"),
            FoodLogItemSnapshot::AdHoc {
                name: "Updated ad hoc".into(),
                brand: Some("Brand".into()),
            },
            Decimal::new(25, 1),
            "serving",
            vec![
                snapshot("CARBS_G", 30, "g"),
                snapshot("ENERGY_KCAL", 200, "kcal"),
                snapshot("FAT_G", 12, "g"),
            ],
            None,
            timestamp(date(2026, 6, 7), 10),
        );
        let sea_updated = log_fixture(
            sea_initial.id().0,
            sea_user_id,
            date(2026, 6, 5),
            Some(MealSlot::LateNightSnack),
            Some("America/New_York"),
            FoodLogItemSnapshot::AdHoc {
                name: "Updated ad hoc".into(),
                brand: Some("Brand".into()),
            },
            Decimal::new(25, 1),
            "serving",
            vec![
                snapshot("CARBS_G", 30, "g"),
                snapshot("ENERGY_KCAL", 200, "kcal"),
                snapshot("FAT_G", 12, "g"),
            ],
            None,
            timestamp(date(2026, 6, 7), 10),
        );

        legacy_update(&pool, &legacy_updated)
            .await
            .expect("legacy update");
        let repository = PostgresFoodLogRepository::new(pool.clone());
        repository
            .update(&sea_updated)
            .await
            .expect("repository update");

        let legacy_row = fetch_food_log_row(&pool, legacy_initial.id().0)
            .await
            .expect("legacy updated row");
        let sea_row = fetch_food_log_row(&pool, sea_initial.id().0)
            .await
            .expect("repository updated row");

        assert_eq!(legacy_row.log_date, date(2026, 6, 5));
        assert_eq!(sea_row.log_date, legacy_row.log_date);
        assert_eq!(sea_row.meal_slot, legacy_row.meal_slot);
        assert_eq!(sea_row.device_timezone, legacy_row.device_timezone);
        assert_eq!(sea_row.item_product_id, None);
        assert_eq!(sea_row.item_product_id, legacy_row.item_product_id);
        assert_eq!(sea_row.item_meal_id, legacy_row.item_meal_id);
        assert_eq!(sea_row.item_name, legacy_row.item_name);
        assert_eq!(sea_row.item_brand, legacy_row.item_brand);
        assert_eq!(sea_row.quantity, legacy_row.quantity);
        assert_eq!(sea_row.unit, legacy_row.unit);
        assert_eq!(sea_row.notes, legacy_row.notes);
        assert_eq!(sea_row.notes, None);
        assert_eq!(sea_row.created_at, legacy_row.created_at);
        assert_eq!(sea_row.created_at, created_at);
        assert!(legacy_row.updated_at > stale_updated_at);
        assert!(sea_row.updated_at > stale_updated_at);
        assert_recent(legacy_row.updated_at, "legacy food log update");
        assert_recent(sea_row.updated_at, "repository food log update");

        let legacy_snapshots = legacy_load_snapshots(&pool, legacy_initial.id().0)
            .await
            .expect("legacy updated snapshots");
        let sea_snapshots = repository
            .load_snapshots(sea_initial.id().0)
            .await
            .expect("repository updated snapshots");
        let expected_snapshots = vec![
            ("CARBS_G".to_owned(), Decimal::from(30), "g".to_owned()),
            (
                "ENERGY_KCAL".to_owned(),
                Decimal::from(200),
                "kcal".to_owned(),
            ),
            ("FAT_G".to_owned(), Decimal::from(12), "g".to_owned()),
        ];
        assert_eq!(snapshot_shapes(&sea_snapshots), expected_snapshots);
        assert_eq!(snapshot_shapes(&legacy_snapshots), expected_snapshots);

        let legacy_found = legacy_find_by_id(&pool, legacy_initial.id())
            .await
            .expect("legacy find updated")
            .expect("legacy updated log exists");
        let sea_found = repository
            .find_by_id(sea_initial.id())
            .await
            .expect("repository find updated")
            .expect("repository updated log exists");
        assert_same_log_contents_except_updated_at(&legacy_found, &sea_found, "update");

        let sea_bystander_row_after = fetch_food_log_row(&pool, sea_bystander.id().0)
            .await
            .expect("same-user bystander row after update");
        assert_eq!(
            sea_bystander_row_after, sea_bystander_row_before,
            "repository update must not modify a same-user bystander food log"
        );
        let sea_bystander_snapshots_after = repository
            .load_snapshots(sea_bystander.id().0)
            .await
            .expect("same-user bystander snapshots after update");
        assert_eq!(
            snapshot_shapes(&sea_bystander_snapshots_after),
            snapshot_shapes(&sea_bystander_snapshots_before),
            "repository update must not modify a same-user bystander's snapshots"
        );

        let other_bystander_row_after = fetch_food_log_row(&pool, other_bystander.id().0)
            .await
            .expect("other-user bystander row after update");
        assert_eq!(
            other_bystander_row_after, other_bystander_row_before,
            "repository update must not modify another user's food log"
        );
        let other_bystander_snapshots_after = repository
            .load_snapshots(other_bystander.id().0)
            .await
            .expect("other-user bystander snapshots after update");
        assert_eq!(
            snapshot_shapes(&other_bystander_snapshots_after),
            snapshot_shapes(&other_bystander_snapshots_before),
            "repository update must not modify another user's snapshots"
        );
    }

    #[sqlx::test]
    async fn update_changes_between_non_null_product_and_meal_items(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "food-log-item-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "food-log-item-sea").await;
        let product_a = seed_product(&pool, legacy_user_id, "Item Product A").await;
        let product_b = seed_product(&pool, legacy_user_id, "Item Product B").await;
        let meal_id = seed_meal_row(&pool, legacy_user_id, "Item Meal").await;
        let created_at = timestamp(date(2026, 5, 1), 8);

        let product_a_log = |id: Uuid, user_id: Uuid| {
            log_fixture(
                id,
                user_id,
                date(2026, 6, 1),
                Some(MealSlot::Breakfast),
                Some("UTC"),
                FoodLogItemSnapshot::Product {
                    id: ProductId(product_a),
                    name: "Item Product A".into(),
                    brand: None,
                },
                Decimal::from(100),
                "g",
                vec![snapshot("ENERGY_KCAL", 100, "kcal")],
                Some("before item update"),
                created_at,
            )
        };

        let legacy_to_product = product_a_log(Uuid::new_v4(), legacy_user_id);
        let legacy_to_meal = product_a_log(Uuid::new_v4(), legacy_user_id);
        let sea_to_product = product_a_log(Uuid::new_v4(), sea_user_id);
        let sea_to_meal = product_a_log(Uuid::new_v4(), sea_user_id);
        legacy_create_many(
            &pool,
            &[
                legacy_to_product.clone(),
                legacy_to_meal.clone(),
                sea_to_product.clone(),
                sea_to_meal.clone(),
            ],
        )
        .await
        .expect("seed item update food logs");

        let updated_to_product = |id: Uuid, user_id: Uuid| {
            log_fixture(
                id,
                user_id,
                date(2026, 6, 2),
                Some(MealSlot::Lunch),
                Some("Europe/Berlin"),
                FoodLogItemSnapshot::Product {
                    id: ProductId(product_b),
                    name: "Item Product B".into(),
                    brand: Some("B Brand".into()),
                },
                Decimal::from(150),
                "g",
                vec![snapshot("PROTEIN_G", 20, "g")],
                Some("after product update"),
                timestamp(date(2026, 6, 7), 10),
            )
        };
        let updated_to_meal = |id: Uuid, user_id: Uuid| {
            log_fixture(
                id,
                user_id,
                date(2026, 6, 3),
                Some(MealSlot::Dinner),
                Some("America/Chicago"),
                FoodLogItemSnapshot::Meal {
                    id: MealId(meal_id),
                    name: "Item Meal".into(),
                },
                Decimal::from(1),
                "serving",
                vec![snapshot("CARBS_G", 45, "g")],
                Some("after meal update"),
                timestamp(date(2026, 6, 8), 10),
            )
        };

        let legacy_product_update = updated_to_product(legacy_to_product.id().0, legacy_user_id);
        let legacy_meal_update = updated_to_meal(legacy_to_meal.id().0, legacy_user_id);
        let sea_product_update = updated_to_product(sea_to_product.id().0, sea_user_id);
        let sea_meal_update = updated_to_meal(sea_to_meal.id().0, sea_user_id);

        legacy_update(&pool, &legacy_product_update)
            .await
            .expect("legacy product item update");
        legacy_update(&pool, &legacy_meal_update)
            .await
            .expect("legacy meal item update");
        let repository = PostgresFoodLogRepository::new(pool.clone());
        repository
            .update(&sea_product_update)
            .await
            .expect("repository product item update");
        repository
            .update(&sea_meal_update)
            .await
            .expect("repository meal item update");

        let legacy_product_row = fetch_food_log_row(&pool, legacy_to_product.id().0)
            .await
            .expect("legacy product item row");
        let sea_product_row = fetch_food_log_row(&pool, sea_to_product.id().0)
            .await
            .expect("repository product item row");
        let legacy_meal_row = fetch_food_log_row(&pool, legacy_to_meal.id().0)
            .await
            .expect("legacy meal item row");
        let sea_meal_row = fetch_food_log_row(&pool, sea_to_meal.id().0)
            .await
            .expect("repository meal item row");

        assert_eq!(legacy_product_row.item_product_id, Some(product_b));
        assert_eq!(sea_product_row.item_product_id, Some(product_b));
        assert_eq!(legacy_product_row.item_meal_id, None);
        assert_eq!(sea_product_row.item_meal_id, None);
        assert_eq!(sea_product_row.item_name, "Item Product B");
        assert_eq!(sea_product_row.item_brand.as_deref(), Some("B Brand"));

        assert_eq!(legacy_meal_row.item_product_id, None);
        assert_eq!(sea_meal_row.item_product_id, None);
        assert_eq!(legacy_meal_row.item_meal_id, Some(meal_id));
        assert_eq!(sea_meal_row.item_meal_id, Some(meal_id));
        assert_eq!(sea_meal_row.item_name, "Item Meal");
        assert_eq!(sea_meal_row.item_brand, None);

        assert_same_log_contents_except_updated_at(
            &legacy_find_by_id(&pool, legacy_to_product.id())
                .await
                .expect("legacy find product item")
                .expect("legacy product item exists"),
            &repository
                .find_by_id(sea_to_product.id())
                .await
                .expect("repository find product item")
                .expect("repository product item exists"),
            "product item update",
        );
        assert_same_log_contents_except_updated_at(
            &legacy_find_by_id(&pool, legacy_to_meal.id())
                .await
                .expect("legacy find meal item")
                .expect("legacy meal item exists"),
            &repository
                .find_by_id(sea_to_meal.id())
                .await
                .expect("repository find meal item")
                .expect("repository meal item exists"),
            "meal item update",
        );

        let sea_product_found = repository
            .find_by_id(sea_to_product.id())
            .await
            .expect("repository find product item again")
            .expect("repository product item exists");
        assert_eq!(
            sea_product_found.item(),
            &FoodLogItemSnapshot::Product {
                id: ProductId(product_b),
                name: "Item Product B".into(),
                brand: Some("B Brand".into()),
            }
        );
        let sea_meal_found = repository
            .find_by_id(sea_to_meal.id())
            .await
            .expect("repository find meal item again")
            .expect("repository meal item exists");
        assert_eq!(
            sea_meal_found.item(),
            &FoodLogItemSnapshot::Meal {
                id: MealId(meal_id),
                name: "Item Meal".into(),
            }
        );
    }

    #[sqlx::test]
    async fn create_many_empty_slice_is_a_noop(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "food-log-create-empty").await;
        let existing = log_fixture(
            Uuid::new_v4(),
            user_id,
            date(2026, 6, 1),
            Some(MealSlot::Breakfast),
            None,
            FoodLogItemSnapshot::AdHoc {
                name: "Existing".into(),
                brand: None,
            },
            Decimal::from(10),
            "g",
            vec![snapshot("ENERGY_KCAL", 10, "kcal")],
            None,
            timestamp(date(2026, 6, 1), 8),
        );
        legacy_create_many(&pool, std::slice::from_ref(&existing))
            .await
            .expect("seed existing food log");

        legacy_create_many(&pool, &[])
            .await
            .expect("legacy empty create_many must succeed");
        let repository = PostgresFoodLogRepository::new(pool.clone());
        repository
            .create_many(&[])
            .await
            .expect("empty create_many must succeed");

        let log_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM food_logs")
            .fetch_one(&pool)
            .await
            .expect("count food logs");
        assert_eq!(log_count, 1, "empty create_many must not write rows");
        let snapshot_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM food_log_nutrients")
            .fetch_one(&pool)
            .await
            .expect("count food log nutrients");
        assert_eq!(
            snapshot_count, 1,
            "empty create_many must not write nutrient snapshots"
        );
        let found = repository
            .find_by_id(existing.id())
            .await
            .expect("find existing log")
            .expect("existing log remains");
        assert_same_log_contents(&existing, &found, "empty create_many");
    }

    #[sqlx::test]
    async fn create_many_rolls_back_when_a_later_log_has_an_unknown_nutrient(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "food-log-rollback-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "food-log-rollback-sea").await;

        let fixture = |user_id: Uuid, name: &str, code: &str| {
            log_fixture(
                Uuid::new_v4(),
                user_id,
                date(2026, 6, 1),
                Some(MealSlot::Breakfast),
                None,
                FoodLogItemSnapshot::AdHoc {
                    name: name.into(),
                    brand: None,
                },
                Decimal::from(10),
                "g",
                vec![snapshot(code, 1, "g")],
                None,
                timestamp(date(2026, 6, 1), 8),
            )
        };

        let legacy_first = fixture(legacy_user_id, "Legacy first", "ENERGY_KCAL");
        let legacy_invalid = fixture(legacy_user_id, "Legacy invalid", "NOT_A_NUTRIENT");
        let legacy_error =
            legacy_create_many(&pool, &[legacy_first.clone(), legacy_invalid.clone()])
                .await
                .expect_err("legacy create_many must reject the unknown nutrient");
        assert!(
            matches!(&legacy_error, NutritionError::Validation(_)),
            "legacy create_many should surface a validation error, got {legacy_error:?}"
        );
        assert!(
            fetch_food_log_row(&pool, legacy_first.id().0)
                .await
                .is_none(),
            "legacy create_many must roll back the first log"
        );
        assert!(
            fetch_food_log_row(&pool, legacy_invalid.id().0)
                .await
                .is_none(),
            "legacy create_many must not persist the failing log"
        );

        let sea_first = fixture(sea_user_id, "Repository first", "ENERGY_KCAL");
        let sea_invalid = fixture(sea_user_id, "Repository invalid", "NOT_A_NUTRIENT");
        let repository = PostgresFoodLogRepository::new(pool.clone());
        let sea_error = repository
            .create_many(&[sea_first.clone(), sea_invalid.clone()])
            .await
            .expect_err("repository create_many must reject the unknown nutrient");
        assert!(
            matches!(&sea_error, NutritionError::Validation(_)),
            "repository create_many should surface a validation error, got {sea_error:?}"
        );
        assert!(
            fetch_food_log_row(&pool, sea_first.id().0).await.is_none(),
            "repository create_many must roll back the first log"
        );
        assert!(
            fetch_food_log_row(&pool, sea_invalid.id().0)
                .await
                .is_none(),
            "repository create_many must not persist the failing log"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM food_logs")
                .fetch_one(&pool)
                .await
                .expect("count rolled-back food logs"),
            0,
            "both create_many attempts must leave no food logs behind"
        );
    }

    #[sqlx::test]
    async fn delete_matches_legacy_and_keeps_unrelated_logs(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "food-log-delete-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "food-log-delete-sea").await;
        let product_id = seed_product(&pool, legacy_user_id, "Delete Apple").await;

        let deleted_legacy = log_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Breakfast),
            None,
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Delete legacy".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![snapshot("ENERGY_KCAL", 50, "kcal")],
            None,
            timestamp(date(2026, 6, 1), 8),
        );
        let kept_legacy = log_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Lunch),
            None,
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Keep legacy".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![snapshot("ENERGY_KCAL", 60, "kcal")],
            None,
            timestamp(date(2026, 6, 1), 9),
        );
        let deleted_sea = log_fixture(
            Uuid::new_v4(),
            sea_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Dinner),
            None,
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Delete repository".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![snapshot("ENERGY_KCAL", 70, "kcal")],
            None,
            timestamp(date(2026, 6, 1), 10),
        );
        let kept_sea = log_fixture(
            Uuid::new_v4(),
            sea_user_id,
            date(2026, 6, 1),
            Some(MealSlot::Snack),
            None,
            FoodLogItemSnapshot::Product {
                id: ProductId(product_id),
                name: "Keep repository".into(),
                brand: None,
            },
            Decimal::from(100),
            "g",
            vec![snapshot("ENERGY_KCAL", 80, "kcal")],
            None,
            timestamp(date(2026, 6, 1), 11),
        );
        legacy_create_many(
            &pool,
            &[
                deleted_legacy.clone(),
                kept_legacy.clone(),
                deleted_sea.clone(),
                kept_sea.clone(),
            ],
        )
        .await
        .expect("seed food logs");

        legacy_delete(&pool, deleted_legacy.id())
            .await
            .expect("legacy delete");
        let repository = PostgresFoodLogRepository::new(pool.clone());
        repository
            .delete(deleted_sea.id())
            .await
            .expect("repository delete");

        assert!(
            legacy_find_by_id(&pool, deleted_legacy.id())
                .await
                .expect("legacy deleted lookup")
                .is_none(),
            "legacy delete must remove the log"
        );
        assert!(
            repository
                .find_by_id(deleted_sea.id())
                .await
                .expect("repository deleted lookup")
                .is_none(),
            "repository delete must remove the log"
        );
        assert!(
            legacy_find_by_id(&pool, kept_legacy.id())
                .await
                .expect("legacy kept lookup")
                .is_some(),
            "legacy delete must not remove unrelated logs"
        );
        assert!(
            repository
                .find_by_id(kept_sea.id())
                .await
                .expect("repository kept lookup")
                .is_some(),
            "repository delete must not remove unrelated logs"
        );

        let remaining_snapshot_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM food_log_nutrients WHERE food_log_id = ANY($1)",
        )
        .bind(vec![deleted_legacy.id().0, deleted_sea.id().0])
        .fetch_one(&pool)
        .await
        .expect("count deleted snapshots");
        assert_eq!(
            remaining_snapshot_count, 0,
            "deleting a food log must cascade to its snapshots"
        );
    }
}

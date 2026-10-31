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

use crate::catalog::domain::*;
use crate::catalog::infra::pg as nutrient_batch;
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

fn food_log_load_snapshots_statement(food_log_id: Uuid) -> SelectStatement {
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

fn food_log_join_snapshots_statement(ids: Vec<Uuid>) -> SelectStatement {
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

fn food_log_find_by_id_statement(id: Uuid) -> SelectStatement {
    Query::select()
        .columns(food_log_columns())
        .from(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::Id).eq(id))
        .to_owned()
}

fn food_log_list_by_user_and_date_statement(user_id: Uuid, log_date: NaiveDate) -> SelectStatement {
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

fn food_log_insert_statement(log: &FoodLog) -> InsertStatement {
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

fn food_log_update_statement(log: &FoodLog) -> UpdateStatement {
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

fn food_log_delete_statement(id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::Id).eq(id))
        .to_owned()
}

fn food_log_nutrient_delete_by_food_log_id_statement(food_log_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(FoodLogNutrients::Table)
        .and_where(Expr::col(FoodLogNutrients::FoodLogId).eq(food_log_id))
        .to_owned()
}

#[derive(Clone)]
pub struct PgFoodLogRepo {
    pool: PgPool,
}

impl PgFoodLogRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_snapshots(
        &self,
        food_log_id: Uuid,
    ) -> Result<Vec<FoodLogNutrientSnapshot>, NutritionError> {
        let (sql, values) =
            food_log_load_snapshots_statement(food_log_id).build_sqlx(PostgresQueryBuilder);
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
        let (sql, values) = food_log_join_snapshots_statement(ids).build_sqlx(PostgresQueryBuilder);
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

fn food_log_list_by_filter_statement(filter: FoodLogListFilter) -> SelectStatement {
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
impl FoodLogRepo for PgFoodLogRepo {
    async fn create(&self, log: &FoodLog) -> Result<(), NutritionError> {
        self.create_many(std::slice::from_ref(log)).await
    }

    async fn create_many(&self, logs: &[FoodLog]) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        for log in logs {
            let (sql, values) = food_log_insert_statement(log).build_sqlx(PostgresQueryBuilder);
            sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .execute(&mut *tx)
                .await?;

            insert_food_log_nutrients(&mut tx, log.id().0, log.nutrient_snapshots()).await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, NutritionError> {
        let (sql, values) = food_log_find_by_id_statement(id.0).build_sqlx(PostgresQueryBuilder);
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
        let (sql, values) = food_log_list_by_user_and_date_statement(user_id, log_date)
            .build_sqlx(PostgresQueryBuilder);
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
        let statement = food_log_list_by_filter_statement(filter);
        let (sql, values) = statement.build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, FoodLogRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;
        self.rows_to_food_logs(rows).await
    }

    async fn update(&self, log: &FoodLog) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        let (sql, values) = food_log_update_statement(log).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) = food_log_nutrient_delete_by_food_log_id_statement(log.id().0)
            .build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        insert_food_log_nutrients(&mut tx, log.id().0, log.nutrient_snapshots()).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: FoodLogId) -> Result<(), NutritionError> {
        let (sql, values) = food_log_delete_statement(id.0).build_sqlx(PostgresQueryBuilder);
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

async fn insert_food_log_nutrients(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    food_log_id: Uuid,
    snapshots: &[FoodLogNutrientSnapshot],
) -> Result<(), NutritionError> {
    if snapshots.is_empty() {
        return Ok(());
    }

    // Resolve nutrient IDs in Rust instead of relying on a Postgres JOIN/UNNEST.
    let codes: Vec<String> = snapshots
        .iter()
        .map(|s| s.nutrient_code.0.clone())
        .collect();
    let nutrient_ids =
        nutrient_batch::resolve_nutrient_ids(tx, &codes, "food log snapshot").await?;

    let n = snapshots.len();
    let written = nutrient_batch::insert_chunked(tx, n, 100, |start, end| {
        let mut statement = Query::insert();
        statement.into_table(FoodLogNutrients::Table).columns([
            FoodLogNutrients::FoodLogId,
            FoodLogNutrients::NutrientId,
            FoodLogNutrients::Amount,
            FoodLogNutrients::Unit,
        ]);
        for snapshot in &snapshots[start..end] {
            let nutrient_id = nutrient_ids
                .get(&snapshot.nutrient_code.0)
                .expect("validated nutrient identity missing during insert");
            statement.values_panic([
                food_log_id.into(),
                (*nutrient_id).into(),
                snapshot.amount.into(),
                snapshot.unit.0.clone().into(),
            ]);
        }
        statement
    })
    .await?;

    if written != snapshots.len() {
        return Err(NutritionError::Validation(format!(
            "unknown nutrient code in food log snapshot (expected {} rows, inserted {})",
            snapshots.len(),
            written
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
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

    async fn seed_product_row(pool: &PgPool, user_id: Uuid, name: &str) -> Uuid {
        let product_id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO products (id, source, user_id, visibility, name)
            VALUES ($1, 'USER', $2, 'global', $3)
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

    async fn seed_meal_row(pool: &PgPool, user_id: Uuid, name: &str) -> Uuid {
        let meal_id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO meals (id, user_id, name)
            VALUES ($1, $2, $3)
            "#,
        )
        .bind(meal_id)
        .bind(user_id)
        .bind(name)
        .execute(pool)
        .await
        .expect("seed meal");
        meal_id
    }

    fn log_with_item(
        id: Uuid,
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        item: FoodLogItemSnapshot,
    ) -> FoodLog {
        let created_at = timestamp(log_date, 8);
        FoodLog::restore(
            FoodLogId(id),
            user_id,
            log_date,
            meal_slot,
            Some("UTC".to_owned()),
            item,
            Decimal::from(100),
            UnitCode("g".to_owned()),
            Vec::new(),
            None,
            created_at,
            created_at,
        )
    }

    fn ad_hoc_log(
        id: Uuid,
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
    ) -> FoodLog {
        log_with_item(
            id,
            user_id,
            log_date,
            meal_slot,
            FoodLogItemSnapshot::AdHoc {
                name: format!("ad-hoc-{id}"),
                brand: None,
            },
        )
    }

    fn filter(
        user_id: Uuid,
        date_range: DateRange,
        meal_slot: Option<MealSlot>,
        items: Vec<FoodLogItemRef>,
    ) -> FoodLogListFilter {
        FoodLogListFilter {
            user_id,
            date_range,
            meal_slot,
            items,
        }
    }

    fn ids(logs: &[FoodLog]) -> HashSet<FoodLogId> {
        logs.iter().map(FoodLog::id).collect()
    }

    fn expected_ids(ids: &[Uuid]) -> HashSet<FoodLogId> {
        ids.iter().copied().map(FoodLogId).collect()
    }

    #[sqlx::test]
    async fn list_by_filter_applies_date_bounds_and_meal_slot(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "food-log-filter-dates").await;
        let other_user_id = seed_identity_and_profile(&pool, "food-log-filter-dates-other").await;
        let repository = PgFoodLogRepo::new(pool.clone());

        let before_start = Uuid::new_v4();
        let on_start = Uuid::new_v4();
        let in_middle = Uuid::new_v4();
        let on_end = Uuid::new_v4();
        let after_end = Uuid::new_v4();
        let other_user_log = Uuid::new_v4();

        repository
            .create_many(&[
                ad_hoc_log(
                    before_start,
                    user_id,
                    date(2026, 5, 31),
                    Some(MealSlot::Breakfast),
                ),
                ad_hoc_log(
                    on_start,
                    user_id,
                    date(2026, 6, 1),
                    Some(MealSlot::Breakfast),
                ),
                ad_hoc_log(in_middle, user_id, date(2026, 6, 2), Some(MealSlot::Lunch)),
                ad_hoc_log(on_end, user_id, date(2026, 6, 3), Some(MealSlot::Breakfast)),
                ad_hoc_log(
                    after_end,
                    user_id,
                    date(2026, 6, 4),
                    Some(MealSlot::Breakfast),
                ),
                ad_hoc_log(
                    other_user_log,
                    other_user_id,
                    date(2026, 6, 2),
                    Some(MealSlot::Breakfast),
                ),
            ])
            .await
            .expect("create food logs");

        let inclusive = repository
            .list_by_filter(filter(
                user_id,
                DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap(),
                None,
                Vec::new(),
            ))
            .await
            .expect("list inclusive date range");
        assert_eq!(
            ids(&inclusive),
            expected_ids(&[on_start, in_middle, on_end]),
            "inclusive bounds must include both endpoints and exclude adjacent dates and other users"
        );

        let exclusive_end = repository
            .list_by_filter(filter(
                user_id,
                DateRange::inclusive_to_exclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap(),
                None,
                Vec::new(),
            ))
            .await
            .expect("list exclusive end date range");
        assert_eq!(
            ids(&exclusive_end),
            expected_ids(&[on_start, in_middle]),
            "exclusive end bound must exclude the end date"
        );

        let breakfast_only = repository
            .list_by_filter(filter(
                user_id,
                DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap(),
                Some(MealSlot::Breakfast),
                Vec::new(),
            ))
            .await
            .expect("list breakfast logs");
        assert_eq!(
            ids(&breakfast_only),
            expected_ids(&[on_start, on_end]),
            "meal slot filter must exclude logs in other slots"
        );
    }

    #[sqlx::test]
    async fn list_by_filter_matches_product_or_meal_items(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "food-log-filter-items").await;
        let product_a = seed_product_row(&pool, user_id, "Product A").await;
        let product_c = seed_product_row(&pool, user_id, "Product C").await;
        let meal_b = seed_meal_row(&pool, user_id, "Meal B").await;
        let repository = PgFoodLogRepo::new(pool.clone());

        let product_a_log = Uuid::new_v4();
        let meal_b_log = Uuid::new_v4();
        let product_c_log = Uuid::new_v4();
        let log_date = date(2026, 6, 2);

        repository
            .create_many(&[
                log_with_item(
                    product_a_log,
                    user_id,
                    log_date,
                    Some(MealSlot::Breakfast),
                    FoodLogItemSnapshot::Product {
                        id: ProductId(product_a),
                        name: "Product A".to_owned(),
                        brand: None,
                    },
                ),
                log_with_item(
                    meal_b_log,
                    user_id,
                    log_date,
                    Some(MealSlot::Lunch),
                    FoodLogItemSnapshot::Meal {
                        id: MealId(meal_b),
                        name: "Meal B".to_owned(),
                    },
                ),
                log_with_item(
                    product_c_log,
                    user_id,
                    log_date,
                    Some(MealSlot::Dinner),
                    FoodLogItemSnapshot::Product {
                        id: ProductId(product_c),
                        name: "Product C".to_owned(),
                        brand: None,
                    },
                ),
            ])
            .await
            .expect("create item food logs");

        let range = DateRange::inclusive(date(2026, 6, 1), date(2026, 6, 3)).unwrap();
        let mixed = repository
            .list_by_filter(filter(
                user_id,
                range.clone(),
                None,
                vec![
                    FoodLogItemRef::Product(ProductId(product_a)),
                    FoodLogItemRef::Meal(MealId(meal_b)),
                ],
            ))
            .await
            .expect("list mixed item filters");
        assert_eq!(
            ids(&mixed),
            expected_ids(&[product_a_log, meal_b_log]),
            "product and meal item filters must be OR-ed"
        );

        let meal_only = repository
            .list_by_filter(filter(
                user_id,
                range,
                None,
                vec![FoodLogItemRef::Meal(MealId(meal_b))],
            ))
            .await
            .expect("list meal item filter");
        assert_eq!(
            ids(&meal_only),
            expected_ids(&[meal_b_log]),
            "meal item filter must not require a matching product filter"
        );
    }
}

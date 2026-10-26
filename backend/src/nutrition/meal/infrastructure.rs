use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sea_query::{
    DeleteStatement, Expr, ExprTrait, Iden, InsertStatement, Order, PostgresQueryBuilder, Query,
    SelectStatement, UpdateStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::nutrition::catalog::domain::*;
use crate::nutrition::meal::domain::*;

#[derive(Iden)]
enum Meals {
    Table,
    Id,
    UserId,
    Name,
    Notes,
    TotalQuantityAmount,
    TotalQuantityUnit,
    CreatedAt,
    UpdatedAt,
}

#[derive(Iden)]
enum MealComponents {
    Table,
    Id,
    MealId,
    ComponentProductId,
    ComponentMealId,
    Quantity,
    Unit,
    CreatedAt,
}

fn meal_columns() -> [Meals; 8] {
    [
        Meals::Id,
        Meals::UserId,
        Meals::Name,
        Meals::Notes,
        Meals::TotalQuantityAmount,
        Meals::TotalQuantityUnit,
        Meals::CreatedAt,
        Meals::UpdatedAt,
    ]
}

fn load_components_statement(meal_id: Uuid) -> SelectStatement {
    Query::select()
        .columns([
            MealComponents::Id,
            MealComponents::ComponentProductId,
            MealComponents::ComponentMealId,
            MealComponents::Quantity,
            MealComponents::Unit,
        ])
        .from(MealComponents::Table)
        .and_where(Expr::col(MealComponents::MealId).eq(meal_id))
        .order_by(MealComponents::CreatedAt, Order::Asc)
        .to_owned()
}

fn find_meal_statement(id: Uuid) -> SelectStatement {
    Query::select()
        .columns(meal_columns())
        .from(Meals::Table)
        .and_where(Expr::col(Meals::Id).eq(id))
        .to_owned()
}

fn list_all_meals_statement() -> SelectStatement {
    Query::select()
        .columns(meal_columns())
        .from(Meals::Table)
        .order_by(Meals::CreatedAt, Order::Desc)
        .to_owned()
}

fn insert_meal_statement(meal: &Meal) -> InsertStatement {
    Query::insert()
        .into_table(Meals::Table)
        .columns(meal_columns())
        .values_panic([
            meal.id.0.into(),
            meal.user_id.into(),
            meal.name.as_str().into(),
            meal.notes.as_ref().map(|notes| notes.0.as_str()).into(),
            meal.total_quantity_amount.into(),
            meal.total_quantity_unit
                .as_ref()
                .map(|unit| unit.0.as_str())
                .into(),
            meal.created_at.into(),
            meal.updated_at.into(),
        ])
        .to_owned()
}

fn insert_component_statement(meal_id: Uuid, component: &MealComponent) -> InsertStatement {
    let (product_id, component_meal_id) = match &component.item {
        MealComponentItem::Product(pid) => (Some(pid.0), None::<Uuid>),
    };

    Query::insert()
        .into_table(MealComponents::Table)
        .columns([
            MealComponents::Id,
            MealComponents::MealId,
            MealComponents::ComponentProductId,
            MealComponents::ComponentMealId,
            MealComponents::Quantity,
            MealComponents::Unit,
        ])
        .values_panic([
            component.id.into(),
            meal_id.into(),
            product_id.into(),
            component_meal_id.into(),
            component.quantity_amount.into(),
            component.quantity_unit.0.as_str().into(),
        ])
        .to_owned()
}

fn update_meal_statement(meal: &Meal) -> UpdateStatement {
    Query::update()
        .table(Meals::Table)
        .value(Meals::Name, meal.name.as_str())
        .value(
            Meals::Notes,
            meal.notes.as_ref().map(|notes| notes.0.as_str()),
        )
        .value(Meals::TotalQuantityAmount, meal.total_quantity_amount)
        .value(
            Meals::TotalQuantityUnit,
            meal.total_quantity_unit
                .as_ref()
                .map(|unit| unit.0.as_str()),
        )
        .value(Meals::UpdatedAt, Expr::current_timestamp())
        .and_where(Expr::col(Meals::Id).eq(meal.id.0))
        .to_owned()
}

fn delete_meal_components_statement(meal_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(MealComponents::Table)
        .and_where(Expr::col(MealComponents::MealId).eq(meal_id))
        .to_owned()
}

fn delete_meal_statement(id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(Meals::Table)
        .and_where(Expr::col(Meals::Id).eq(id))
        .to_owned()
}

#[derive(Clone)]
pub struct PostgresMealRepository {
    pool: PgPool,
}

impl PostgresMealRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_components(&self, meal_id: Uuid) -> Result<Vec<MealComponent>, NutritionError> {
        let (sql, values) = load_components_statement(meal_id).build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, MealComponentRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter()
            .map(meal_component_row_to_component)
            .collect()
    }
}

fn meal_row_to_meal(row: MealRow, components: Vec<MealComponent>) -> Result<Meal, NutritionError> {
    Ok(Meal {
        id: MealId(row.id),
        user_id: row.user_id,
        name: MealName::new(&row.name)?,
        notes: row.notes.map(MealNotes),
        total_quantity_amount: row.total_quantity_amount,
        total_quantity_unit: row.total_quantity_unit.map(UnitCode),
        components,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn meal_component_row_to_component(row: MealComponentRow) -> Result<MealComponent, NutritionError> {
    let item = if let Some(pid) = row.component_product_id {
        MealComponentItem::Product(ProductId(pid))
    } else if let Some(_mid) = row.component_meal_id {
        return Err(NutritionError::Internal(
            "meal components of type meal not yet supported".into(),
        ));
    } else {
        return Err(NutritionError::Internal(
            "meal component has no item reference".into(),
        ));
    };

    Ok(MealComponent {
        id: row.id,
        item,
        quantity_amount: row.quantity,
        quantity_unit: UnitCode(row.unit),
    })
}

#[async_trait]
impl MealRepository for PostgresMealRepository {
    async fn create(&self, meal: &Meal) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        let (sql, values) = insert_meal_statement(meal).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        for component in &meal.components {
            let (sql, values) =
                insert_component_statement(meal.id.0, component).build_sqlx(PostgresQueryBuilder);
            sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .execute(&mut *tx)
                .await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, NutritionError> {
        let (sql, values) = find_meal_statement(id.0).build_sqlx(PostgresQueryBuilder);
        let row = sqlx::query_as_with::<_, MealRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_optional(&self.pool)
            .await?;

        match row {
            Some(r) => {
                let components = self.load_components(r.id).await?;
                Ok(Some(meal_row_to_meal(r, components)?))
            }
            None => Ok(None),
        }
    }

    async fn list_all(&self) -> Result<Vec<Meal>, NutritionError> {
        let (sql, values) = list_all_meals_statement().build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, MealRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_all(&self.pool)
            .await?;

        let mut results = Vec::new();
        for r in rows {
            let components = self.load_components(r.id).await?;
            results.push(meal_row_to_meal(r, components)?);
        }
        Ok(results)
    }

    async fn update(&self, meal: &Meal) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        let (sql, values) = update_meal_statement(meal).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) =
            delete_meal_components_statement(meal.id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        for component in &meal.components {
            let (sql, values) =
                insert_component_statement(meal.id.0, component).build_sqlx(PostgresQueryBuilder);
            sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .execute(&mut *tx)
                .await?;
        }

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: MealId) -> Result<(), NutritionError> {
        let (sql, values) = delete_meal_statement(id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
struct MealRow {
    id: Uuid,
    user_id: Uuid,
    name: String,
    notes: Option<String>,
    total_quantity_amount: Option<Decimal>,
    total_quantity_unit: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
struct MealComponentRow {
    id: Uuid,
    component_product_id: Option<Uuid>,
    component_meal_id: Option<Uuid>,
    quantity: Decimal,
    unit: String,
}

#[cfg(test)]
async fn legacy_load_components(
    pool: &PgPool,
    meal_id: Uuid,
) -> Result<Vec<MealComponent>, NutritionError> {
    let rows = sqlx::query_as::<_, MealComponentRow>(
        r#"
        SELECT id, component_product_id, component_meal_id, quantity, unit
        FROM meal_components WHERE meal_id = $1 ORDER BY created_at
        "#,
    )
    .bind(meal_id)
    .fetch_all(pool)
    .await?;

    rows.into_iter()
        .map(meal_component_row_to_component)
        .collect()
}

#[cfg(test)]
async fn legacy_find_by_id(pool: &PgPool, id: MealId) -> Result<Option<Meal>, NutritionError> {
    let row = sqlx::query_as::<_, MealRow>(
        r#"
        SELECT id, user_id, name, notes, total_quantity_amount, total_quantity_unit,
               created_at, updated_at
        FROM meals WHERE id = $1
        "#,
    )
    .bind(id.0)
    .fetch_optional(pool)
    .await?;

    match row {
        Some(r) => {
            let components = legacy_load_components(pool, r.id).await?;
            Ok(Some(meal_row_to_meal(r, components)?))
        }
        None => Ok(None),
    }
}

#[cfg(test)]
async fn legacy_list_all(pool: &PgPool) -> Result<Vec<Meal>, NutritionError> {
    let rows = sqlx::query_as::<_, MealRow>(
        r#"
        SELECT id, user_id, name, notes, total_quantity_amount, total_quantity_unit,
               created_at, updated_at
        FROM meals
        ORDER BY created_at DESC
        "#,
    )
    .fetch_all(pool)
    .await?;

    let mut results = Vec::new();
    for r in rows {
        let components = legacy_load_components(pool, r.id).await?;
        results.push(meal_row_to_meal(r, components)?);
    }
    Ok(results)
}

#[cfg(test)]
async fn legacy_create(pool: &PgPool, meal: &Meal) -> Result<(), NutritionError> {
    let mut tx = pool.begin().await?;

    sqlx::query(
        r#"
        INSERT INTO meals (id, user_id, name, notes, total_quantity_amount, total_quantity_unit, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        "#,
    )
    .bind(meal.id.0)
    .bind(meal.user_id)
    .bind(meal.name.as_str())
    .bind(meal.notes.as_ref().map(|n| n.0.as_str()))
    .bind(meal.total_quantity_amount)
    .bind(meal.total_quantity_unit.as_ref().map(|u| u.0.as_str()))
    .bind(meal.created_at)
    .bind(meal.updated_at)
    .execute(&mut *tx)
    .await?;

    for component in &meal.components {
        let (product_id, meal_id) = match &component.item {
            MealComponentItem::Product(pid) => (Some(pid.0), None::<Uuid>),
        };

        sqlx::query(
            r#"
            INSERT INTO meal_components (id, meal_id, component_product_id, component_meal_id, quantity, unit)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
        )
        .bind(component.id)
        .bind(meal.id.0)
        .bind(product_id)
        .bind(meal_id)
        .bind(component.quantity_amount)
        .bind(&component.quantity_unit.0)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

#[cfg(test)]
async fn legacy_update(pool: &PgPool, meal: &Meal) -> Result<(), NutritionError> {
    let mut tx = pool.begin().await?;

    sqlx::query(
        r#"
        UPDATE meals SET name=$2, notes=$3, total_quantity_amount=$4, total_quantity_unit=$5,
                         updated_at=now()
        WHERE id=$1
        "#,
    )
    .bind(meal.id.0)
    .bind(meal.name.as_str())
    .bind(meal.notes.as_ref().map(|n| n.0.as_str()))
    .bind(meal.total_quantity_amount)
    .bind(meal.total_quantity_unit.as_ref().map(|u| u.0.as_str()))
    .execute(&mut *tx)
    .await?;

    sqlx::query("DELETE FROM meal_components WHERE meal_id = $1")
        .bind(meal.id.0)
        .execute(&mut *tx)
        .await?;

    for component in &meal.components {
        let (product_id, meal_id) = match &component.item {
            MealComponentItem::Product(pid) => (Some(pid.0), None::<Uuid>),
        };

        sqlx::query(
            r#"
            INSERT INTO meal_components (id, meal_id, component_product_id, component_meal_id, quantity, unit)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
        )
        .bind(component.id)
        .bind(meal.id.0)
        .bind(product_id)
        .bind(meal_id)
        .bind(component.quantity_amount)
        .bind(&component.quantity_unit.0)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

#[cfg(test)]
async fn legacy_delete(pool: &PgPool, id: MealId) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM meals WHERE id = $1")
        .bind(id.0)
        .execute(pool)
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    fn timestamp(day: NaiveDate, hour: u32, minute: u32) -> DateTime<Utc> {
        day.and_hms_opt(hour, minute, 0).unwrap().and_utc()
    }

    fn assert_recent(timestamp: DateTime<Utc>, label: &str) {
        let age = Utc::now().signed_duration_since(timestamp);
        assert!(
            age.num_seconds().abs() < 300,
            "{label} updated_at should be current, got {timestamp}"
        );
    }

    fn normalize_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
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

    async fn seed_product(pool: &PgPool, user_id: Uuid, name: &str) -> ProductId {
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

        ProductId(product_id)
    }

    fn component(id: Uuid, product_id: ProductId, amount: i64, unit: &str) -> MealComponent {
        MealComponent {
            id,
            item: MealComponentItem::Product(product_id),
            quantity_amount: Decimal::from(amount),
            quantity_unit: UnitCode(unit.to_owned()),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn meal_fixture(
        id: Uuid,
        user_id: Uuid,
        name: &str,
        notes: Option<&str>,
        total_amount: Option<i64>,
        total_unit: Option<&str>,
        components: Vec<MealComponent>,
        created_at: DateTime<Utc>,
    ) -> Meal {
        Meal {
            id: MealId(id),
            user_id,
            name: MealName::new(name).expect("valid meal name"),
            notes: notes.map(|notes| MealNotes(notes.to_owned())),
            total_quantity_amount: total_amount.map(Decimal::from),
            total_quantity_unit: total_unit.map(|unit| UnitCode(unit.to_owned())),
            components,
            created_at,
            updated_at: created_at,
        }
    }

    fn component_shapes(meal: &Meal) -> Vec<(Uuid, Decimal, String)> {
        meal.components
            .iter()
            .map(|component| {
                let MealComponentItem::Product(product_id) = &component.item;
                (
                    product_id.0,
                    component.quantity_amount,
                    component.quantity_unit.0.clone(),
                )
            })
            .collect()
    }

    fn assert_same_meal_contents(left: &Meal, right: &Meal, label: &str) {
        assert_eq!(left.name, right.name, "{label}: name");
        assert_eq!(left.notes, right.notes, "{label}: notes");
        assert_eq!(
            left.total_quantity_amount, right.total_quantity_amount,
            "{label}: total amount"
        );
        assert_eq!(
            left.total_quantity_unit, right.total_quantity_unit,
            "{label}: total unit"
        );
        assert_eq!(left.created_at, right.created_at, "{label}: created_at");
        assert_eq!(
            component_shapes(left),
            component_shapes(right),
            "{label}: components"
        );
    }

    async fn fetch_meal_row(pool: &PgPool, id: Uuid) -> Option<MealRow> {
        sqlx::query_as::<_, MealRow>(
            r#"
            SELECT id, user_id, name, notes, total_quantity_amount, total_quantity_unit,
                   created_at, updated_at
            FROM meals WHERE id = $1
            "#,
        )
        .bind(id)
        .fetch_optional(pool)
        .await
        .expect("fetch meal row")
    }

    async fn fetch_component_rows(pool: &PgPool, meal_id: Uuid) -> Vec<MealComponentRow> {
        sqlx::query_as::<_, MealComponentRow>(
            r#"
            SELECT id, component_product_id, component_meal_id, quantity, unit
            FROM meal_components WHERE meal_id = $1 ORDER BY created_at
            "#,
        )
        .bind(meal_id)
        .fetch_all(pool)
        .await
        .expect("fetch meal component rows")
    }

    async fn set_component_created_at(
        pool: &PgPool,
        component_id: Uuid,
        created_at: DateTime<Utc>,
    ) {
        sqlx::query("UPDATE meal_components SET created_at = $1 WHERE id = $2")
            .bind(created_at)
            .bind(component_id)
            .execute(pool)
            .await
            .expect("set component created_at");
    }

    fn sorted_component_rows(mut rows: Vec<MealComponentRow>) -> Vec<MealComponentRow> {
        rows.sort_by_key(|row| row.id);
        rows
    }

    #[test]
    fn load_components_statement_orders_by_created_at() {
        let (sql, values) = load_components_statement(Uuid::nil()).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql.ends_with(r#"ORDER BY "created_at" ASC"#),
            "components must be ordered by created_at: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            1,
            "expected one meal_id bind: {sql}"
        );
    }

    #[test]
    fn list_all_statement_orders_by_created_at_desc() {
        let (sql, values) = list_all_meals_statement().build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql.ends_with(r#"ORDER BY "created_at" DESC"#),
            "list_all must order by created_at DESC: {sql}"
        );
        assert_eq!(values.0.iter().count(), 0, "list_all has no binds: {sql}");
    }

    #[test]
    fn update_statements_use_current_timestamp_without_extra_bind() {
        let meal = meal_fixture(
            Uuid::nil(),
            Uuid::nil(),
            "Timestamp meal",
            None,
            None,
            None,
            vec![],
            Utc::now(),
        );
        let (sql, values) = update_meal_statement(&meal).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql.contains(r#""updated_at" = CURRENT_TIMESTAMP"#),
            "update must use CURRENT_TIMESTAMP: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            5,
            "update must bind name, notes, both totals, and id only: {sql}"
        );
        assert!(
            sql.ends_with(r#"WHERE "id" = $5"#),
            "update must target exactly one meal by id: {sql}"
        );
    }

    #[sqlx::test]
    async fn create_matches_legacy_for_meal_and_components(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "meal-create-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "meal-create-sea").await;
        let first_product = seed_product(&pool, legacy_user_id, "Meal Create First").await;
        let second_product = seed_product(&pool, legacy_user_id, "Meal Create Second").await;
        let created_at = timestamp(date(2026, 6, 1), 8, 0);

        let legacy_components = vec![
            component(Uuid::new_v4(), first_product, 150, "g"),
            component(Uuid::new_v4(), second_product, 2, "piece"),
        ];
        let sea_components = vec![
            component(Uuid::new_v4(), first_product, 150, "g"),
            component(Uuid::new_v4(), second_product, 2, "piece"),
        ];
        let legacy_meal = meal_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            "Created meal",
            Some("created notes"),
            Some(152),
            Some("g"),
            legacy_components.clone(),
            created_at,
        );
        let sea_meal = meal_fixture(
            Uuid::new_v4(),
            sea_user_id,
            "Created meal",
            Some("created notes"),
            Some(152),
            Some("g"),
            sea_components.clone(),
            created_at,
        );

        legacy_create(&pool, &legacy_meal)
            .await
            .expect("legacy create");
        PostgresMealRepository::new(pool.clone())
            .create(&sea_meal)
            .await
            .expect("repository create");

        let legacy_row = fetch_meal_row(&pool, legacy_meal.id.0)
            .await
            .expect("legacy meal row");
        let sea_row = fetch_meal_row(&pool, sea_meal.id.0)
            .await
            .expect("repository meal row");

        assert_eq!(legacy_row.name, "Created meal");
        assert_eq!(sea_row.name, legacy_row.name);
        assert_eq!(sea_row.notes, legacy_row.notes);
        assert_eq!(
            sea_row.total_quantity_amount,
            legacy_row.total_quantity_amount
        );
        assert_eq!(sea_row.total_quantity_unit, legacy_row.total_quantity_unit);
        assert_eq!(sea_row.created_at, created_at);
        assert_eq!(sea_row.updated_at, created_at);

        // Assign distinct timestamps before the first comparison: rows created
        // in one transaction initially share created_at, so reading them in
        // tie order is not deterministic. The later assertions still verify
        // the ORDER BY created_at behavior.
        set_component_created_at(
            &pool,
            legacy_components[0].id,
            timestamp(date(2026, 6, 1), 9, 0),
        )
        .await;
        set_component_created_at(
            &pool,
            legacy_components[1].id,
            timestamp(date(2026, 6, 1), 8, 30),
        )
        .await;
        set_component_created_at(
            &pool,
            sea_components[0].id,
            timestamp(date(2026, 6, 1), 9, 0),
        )
        .await;
        set_component_created_at(
            &pool,
            sea_components[1].id,
            timestamp(date(2026, 6, 1), 8, 30),
        )
        .await;

        let legacy_component_rows = fetch_component_rows(&pool, legacy_meal.id.0).await;
        let sea_component_rows = fetch_component_rows(&pool, sea_meal.id.0).await;
        assert_eq!(legacy_component_rows.len(), 2);
        assert_eq!(sea_component_rows.len(), legacy_component_rows.len());
        for (legacy_row, sea_row) in legacy_component_rows.iter().zip(&sea_component_rows) {
            assert_eq!(
                sea_row.component_product_id,
                legacy_row.component_product_id
            );
            assert_eq!(sea_row.component_meal_id, legacy_row.component_meal_id);
            assert_eq!(sea_row.quantity, legacy_row.quantity);
            assert_eq!(sea_row.unit, legacy_row.unit);
        }

        let repository = PostgresMealRepository::new(pool.clone());
        let legacy_found = legacy_find_by_id(&pool, legacy_meal.id)
            .await
            .expect("legacy find_by_id")
            .expect("legacy meal exists");
        let sea_found = repository
            .find_by_id(sea_meal.id)
            .await
            .expect("repository find_by_id")
            .expect("repository meal exists");

        assert_same_meal_contents(&legacy_found, &sea_found, "create");
        assert_eq!(
            component_shapes(&legacy_found),
            vec![
                (second_product.0, Decimal::from(2), "piece".to_owned()),
                (first_product.0, Decimal::from(150), "g".to_owned()),
            ],
            "legacy components must be ordered by created_at"
        );
        assert_eq!(
            component_shapes(&sea_found),
            component_shapes(&legacy_found)
        );
    }

    #[sqlx::test]
    async fn create_rolls_back_meal_when_a_component_product_is_missing(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "meal-rollback-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "meal-rollback-sea").await;

        let bad_meal = |user_id: Uuid, name: &str| {
            meal_fixture(
                Uuid::new_v4(),
                user_id,
                name,
                Some("must roll back"),
                Some(100),
                Some("g"),
                vec![component(
                    Uuid::new_v4(),
                    ProductId(Uuid::new_v4()),
                    100,
                    "g",
                )],
                timestamp(date(2026, 6, 1), 8, 0),
            )
        };

        let legacy_meal = bad_meal(legacy_user_id, "Legacy missing product");
        legacy_create(&pool, &legacy_meal)
            .await
            .expect_err("legacy create must fail on the missing component product");
        assert!(
            fetch_meal_row(&pool, legacy_meal.id.0).await.is_none(),
            "legacy create must roll back the meal row"
        );
        assert!(
            fetch_component_rows(&pool, legacy_meal.id.0)
                .await
                .is_empty(),
            "legacy create must not leave components behind"
        );

        let sea_meal = bad_meal(sea_user_id, "Repository missing product");
        let repository = PostgresMealRepository::new(pool.clone());
        repository
            .create(&sea_meal)
            .await
            .expect_err("repository create must fail on the missing component product");
        assert!(
            fetch_meal_row(&pool, sea_meal.id.0).await.is_none(),
            "repository create must roll back the meal row"
        );
        assert!(
            fetch_component_rows(&pool, sea_meal.id.0).await.is_empty(),
            "repository create must not leave components behind"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM meals")
                .fetch_one(&pool)
                .await
                .expect("count rolled-back meals"),
            0,
            "both create attempts must leave no meals behind"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM meal_components")
                .fetch_one(&pool)
                .await
                .expect("count rolled-back components"),
            0,
            "both create attempts must leave no components behind"
        );
    }

    #[sqlx::test]
    async fn find_by_id_matches_legacy_for_present_and_absent_meals(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "meal-find").await;
        let product_id = seed_product(&pool, user_id, "Meal Find Product").await;
        let meal = meal_fixture(
            Uuid::new_v4(),
            user_id,
            "Found meal",
            None,
            None,
            None,
            vec![component(Uuid::new_v4(), product_id, 100, "g")],
            timestamp(date(2026, 6, 2), 12, 0),
        );
        legacy_create(&pool, &meal).await.expect("seed meal");

        let repository = PostgresMealRepository::new(pool.clone());
        let legacy_found = legacy_find_by_id(&pool, meal.id)
            .await
            .expect("legacy find present");
        let sea_found = repository
            .find_by_id(meal.id)
            .await
            .expect("repository find present");
        assert_eq!(sea_found, legacy_found);
        assert_eq!(sea_found, Some(meal));

        let missing = MealId(Uuid::new_v4());
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
    async fn list_all_matches_legacy_across_users_and_created_at_order(pool: PgPool) {
        let first_user = seed_identity_and_profile(&pool, "meal-list-first").await;
        let second_user = seed_identity_and_profile(&pool, "meal-list-second").await;
        let product_id = seed_product(&pool, first_user, "Meal List Product").await;

        let meals = [
            meal_fixture(
                Uuid::new_v4(),
                first_user,
                "Oldest meal",
                None,
                None,
                None,
                vec![component(Uuid::new_v4(), product_id, 100, "g")],
                timestamp(date(2026, 6, 1), 8, 0),
            ),
            meal_fixture(
                Uuid::new_v4(),
                second_user,
                "Newest meal",
                None,
                None,
                None,
                vec![component(Uuid::new_v4(), product_id, 200, "g")],
                timestamp(date(2026, 6, 3), 8, 0),
            ),
            meal_fixture(
                Uuid::new_v4(),
                first_user,
                "Middle meal",
                Some("middle"),
                Some(300),
                Some("g"),
                vec![component(Uuid::new_v4(), product_id, 300, "g")],
                timestamp(date(2026, 6, 2), 8, 0),
            ),
        ];
        for meal in &meals {
            legacy_create(&pool, meal).await.expect("seed meal");
        }

        let repository = PostgresMealRepository::new(pool.clone());
        let legacy_meals = legacy_list_all(&pool).await.expect("legacy list_all");
        let sea_meals = repository.list_all().await.expect("repository list_all");

        assert_eq!(sea_meals, legacy_meals);
        assert_eq!(sea_meals.len(), 3);
        assert_eq!(
            sea_meals
                .iter()
                .map(|meal| meal.name.as_str())
                .collect::<Vec<_>>(),
            vec!["Newest meal", "Middle meal", "Oldest meal"],
            "list_all must order by created_at DESC"
        );
        assert!(
            sea_meals.iter().any(|meal| meal.user_id == first_user)
                && sea_meals.iter().any(|meal| meal.user_id == second_user),
            "list_all must preserve its cross-user behavior"
        );
    }

    #[sqlx::test]
    async fn update_matches_legacy_and_replaces_components(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "meal-update-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "meal-update-sea").await;
        let other_user_id = seed_identity_and_profile(&pool, "meal-update-other").await;
        let first_product = seed_product(&pool, legacy_user_id, "Meal Update First").await;
        let second_product = seed_product(&pool, legacy_user_id, "Meal Update Second").await;
        let third_product = seed_product(&pool, legacy_user_id, "Meal Update Third").await;
        let created_at = timestamp(date(2026, 5, 1), 8, 0);

        let legacy_initial = meal_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            "Initial meal",
            Some("initial"),
            Some(100),
            Some("g"),
            vec![component(Uuid::new_v4(), first_product, 100, "g")],
            created_at,
        );
        let sea_initial = meal_fixture(
            Uuid::new_v4(),
            sea_user_id,
            "Initial meal",
            Some("initial"),
            Some(100),
            Some("g"),
            vec![component(Uuid::new_v4(), first_product, 100, "g")],
            created_at,
        );
        legacy_create(&pool, &legacy_initial)
            .await
            .expect("seed legacy meal");
        let repository = PostgresMealRepository::new(pool.clone());
        repository
            .create(&sea_initial)
            .await
            .expect("seed repository meal");

        let sea_bystander = meal_fixture(
            Uuid::new_v4(),
            sea_user_id,
            "Same-user bystander meal",
            Some("keep this meal"),
            Some(222),
            Some("g"),
            vec![
                component(Uuid::new_v4(), first_product, 111, "g"),
                component(Uuid::new_v4(), second_product, 2, "piece"),
            ],
            timestamp(date(2026, 6, 3), 18, 0),
        );
        let other_bystander = meal_fixture(
            Uuid::new_v4(),
            other_user_id,
            "Other user bystander meal",
            Some("other user"),
            Some(333),
            Some("g"),
            vec![component(Uuid::new_v4(), third_product, 333, "g")],
            timestamp(date(2026, 6, 4), 12, 0),
        );
        legacy_create(&pool, &sea_bystander)
            .await
            .expect("seed same-user bystander meal");
        legacy_create(&pool, &other_bystander)
            .await
            .expect("seed other-user bystander meal");

        let stale_updated_at = timestamp(date(2000, 1, 1), 0, 0);
        sqlx::query("UPDATE meals SET updated_at = $1 WHERE id = ANY($2)")
            .bind(stale_updated_at)
            .bind(vec![legacy_initial.id.0, sea_initial.id.0])
            .execute(&pool)
            .await
            .expect("backdate meals");

        let sea_bystander_row_before = fetch_meal_row(&pool, sea_bystander.id.0)
            .await
            .expect("same-user bystander meal row before update");
        let sea_bystander_components_before =
            sorted_component_rows(fetch_component_rows(&pool, sea_bystander.id.0).await);
        let other_bystander_row_before = fetch_meal_row(&pool, other_bystander.id.0)
            .await
            .expect("other-user bystander meal row before update");
        let other_bystander_components_before =
            sorted_component_rows(fetch_component_rows(&pool, other_bystander.id.0).await);

        let legacy_old_component_id = legacy_initial.components[0].id;
        let sea_old_component_id = sea_initial.components[0].id;
        let legacy_new_components = vec![
            component(Uuid::new_v4(), second_product, 250, "g"),
            component(Uuid::new_v4(), third_product, 1, "serving"),
        ];
        let sea_new_components = vec![
            component(Uuid::new_v4(), second_product, 250, "g"),
            component(Uuid::new_v4(), third_product, 1, "serving"),
        ];
        let legacy_update_meal = meal_fixture(
            legacy_initial.id.0,
            legacy_user_id,
            "Updated meal",
            None,
            Some(251),
            Some("g"),
            legacy_new_components.clone(),
            created_at,
        );
        let sea_update_meal = meal_fixture(
            sea_initial.id.0,
            sea_user_id,
            "Updated meal",
            None,
            Some(251),
            Some("g"),
            sea_new_components.clone(),
            created_at,
        );

        legacy_update(&pool, &legacy_update_meal)
            .await
            .expect("legacy update");
        repository
            .update(&sea_update_meal)
            .await
            .expect("repository update");

        set_component_created_at(
            &pool,
            legacy_new_components[0].id,
            timestamp(date(2026, 6, 2), 9, 0),
        )
        .await;
        set_component_created_at(
            &pool,
            legacy_new_components[1].id,
            timestamp(date(2026, 6, 2), 8, 30),
        )
        .await;
        set_component_created_at(
            &pool,
            sea_new_components[0].id,
            timestamp(date(2026, 6, 2), 9, 0),
        )
        .await;
        set_component_created_at(
            &pool,
            sea_new_components[1].id,
            timestamp(date(2026, 6, 2), 8, 30),
        )
        .await;

        let legacy_row = fetch_meal_row(&pool, legacy_initial.id.0)
            .await
            .expect("legacy updated row");
        let sea_row = fetch_meal_row(&pool, sea_initial.id.0)
            .await
            .expect("repository updated row");

        assert_eq!(legacy_row.name, "Updated meal");
        assert_eq!(sea_row.name, legacy_row.name);
        assert_eq!(sea_row.notes, legacy_row.notes);
        assert_eq!(
            sea_row.total_quantity_amount,
            legacy_row.total_quantity_amount
        );
        assert_eq!(sea_row.total_quantity_unit, legacy_row.total_quantity_unit);
        assert_eq!(sea_row.created_at, legacy_row.created_at);
        assert_eq!(sea_row.created_at, created_at);
        assert!(legacy_row.updated_at > stale_updated_at);
        assert!(sea_row.updated_at > stale_updated_at);
        assert_recent(legacy_row.updated_at, "legacy meal update");
        assert_recent(sea_row.updated_at, "repository meal update");
        assert_eq!(legacy_row.notes, None);
        assert_eq!(legacy_row.total_quantity_amount, Some(Decimal::from(251)));

        let legacy_components = fetch_component_rows(&pool, legacy_initial.id.0).await;
        let sea_components = fetch_component_rows(&pool, sea_initial.id.0).await;
        assert_eq!(sea_components.len(), 2);
        assert_eq!(legacy_components.len(), sea_components.len());
        assert!(
            legacy_components
                .iter()
                .all(|row| row.id != legacy_old_component_id),
            "legacy update must remove old components"
        );
        assert!(
            sea_components
                .iter()
                .all(|row| row.id != sea_old_component_id),
            "repository update must remove old components"
        );
        for (legacy_component, sea_component) in legacy_components.iter().zip(&sea_components) {
            assert_eq!(
                sea_component.component_product_id,
                legacy_component.component_product_id
            );
            assert_eq!(sea_component.quantity, legacy_component.quantity);
            assert_eq!(sea_component.unit, legacy_component.unit);
        }

        let legacy_found = legacy_find_by_id(&pool, legacy_initial.id)
            .await
            .expect("legacy find updated")
            .expect("legacy updated meal exists");
        let sea_found = repository
            .find_by_id(sea_initial.id)
            .await
            .expect("repository find updated")
            .expect("repository updated meal exists");
        assert_same_meal_contents(&legacy_found, &sea_found, "update");
        assert_eq!(
            component_shapes(&sea_found),
            vec![
                (third_product.0, Decimal::from(1), "serving".to_owned()),
                (second_product.0, Decimal::from(250), "g".to_owned()),
            ],
            "replacement components must be ordered by their distinct created_at values"
        );

        let sea_bystander_row_after = fetch_meal_row(&pool, sea_bystander.id.0)
            .await
            .expect("same-user bystander meal row after update");
        assert_eq!(
            sea_bystander_row_after, sea_bystander_row_before,
            "repository update must not modify a same-user bystander meal"
        );
        let sea_bystander_components_after =
            sorted_component_rows(fetch_component_rows(&pool, sea_bystander.id.0).await);
        assert_eq!(
            sea_bystander_components_after, sea_bystander_components_before,
            "repository update must not modify a same-user bystander's components"
        );

        let other_bystander_row_after = fetch_meal_row(&pool, other_bystander.id.0)
            .await
            .expect("other-user bystander meal row after update");
        assert_eq!(
            other_bystander_row_after, other_bystander_row_before,
            "repository update must not modify another user's meal"
        );
        let other_bystander_components_after =
            sorted_component_rows(fetch_component_rows(&pool, other_bystander.id.0).await);
        assert_eq!(
            other_bystander_components_after, other_bystander_components_before,
            "repository update must not modify another user's components"
        );
    }

    #[sqlx::test]
    async fn delete_matches_legacy_and_removes_components(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "meal-delete-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "meal-delete-sea").await;
        let product_id = seed_product(&pool, legacy_user_id, "Meal Delete Product").await;

        let legacy_deleted = meal_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            "Legacy deleted",
            None,
            None,
            None,
            vec![component(Uuid::new_v4(), product_id, 100, "g")],
            timestamp(date(2026, 6, 1), 8, 0),
        );
        let legacy_kept = meal_fixture(
            Uuid::new_v4(),
            legacy_user_id,
            "Legacy kept",
            None,
            None,
            None,
            vec![component(Uuid::new_v4(), product_id, 110, "g")],
            timestamp(date(2026, 6, 1), 9, 0),
        );
        let sea_deleted = meal_fixture(
            Uuid::new_v4(),
            sea_user_id,
            "Repository deleted",
            None,
            None,
            None,
            vec![component(Uuid::new_v4(), product_id, 120, "g")],
            timestamp(date(2026, 6, 1), 10, 0),
        );
        let sea_kept = meal_fixture(
            Uuid::new_v4(),
            sea_user_id,
            "Repository kept",
            None,
            None,
            None,
            vec![component(Uuid::new_v4(), product_id, 130, "g")],
            timestamp(date(2026, 6, 1), 11, 0),
        );
        for meal in [&legacy_deleted, &legacy_kept, &sea_deleted, &sea_kept] {
            legacy_create(&pool, meal).await.expect("seed meal");
        }

        let repository = PostgresMealRepository::new(pool.clone());
        legacy_delete(&pool, legacy_deleted.id)
            .await
            .expect("legacy delete");
        repository
            .delete(sea_deleted.id)
            .await
            .expect("repository delete");

        assert!(
            legacy_find_by_id(&pool, legacy_deleted.id)
                .await
                .expect("legacy deleted lookup")
                .is_none(),
            "legacy delete must remove the meal"
        );
        assert!(
            repository
                .find_by_id(sea_deleted.id)
                .await
                .expect("repository deleted lookup")
                .is_none(),
            "repository delete must remove the meal"
        );
        assert!(
            fetch_component_rows(&pool, legacy_deleted.id.0)
                .await
                .is_empty(),
            "legacy delete must cascade to components"
        );
        assert!(
            fetch_component_rows(&pool, sea_deleted.id.0)
                .await
                .is_empty(),
            "repository delete must cascade to components"
        );

        assert!(
            legacy_find_by_id(&pool, legacy_kept.id)
                .await
                .expect("legacy kept lookup")
                .is_some(),
            "legacy delete must not remove unrelated meals"
        );
        assert!(
            repository
                .find_by_id(sea_kept.id)
                .await
                .expect("repository kept lookup")
                .is_some(),
            "repository delete must not remove unrelated meals"
        );
    }
}

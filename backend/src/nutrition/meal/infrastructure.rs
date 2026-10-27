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

#[derive(sqlx::FromRow)]
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

#[derive(sqlx::FromRow)]
struct MealComponentRow {
    id: Uuid,
    component_product_id: Option<Uuid>,
    component_meal_id: Option<Uuid>,
    quantity: Decimal,
    unit: String,
}

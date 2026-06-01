use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::meal::*;

#[derive(Clone)]
pub struct PostgresMealRepository {
    pool: PgPool,
}

impl PostgresMealRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_components(&self, meal_id: Uuid) -> Result<Vec<MealComponent>, NutritionError> {
        let rows = sqlx::query_as::<_, MealComponentRow>(
            r#"
            SELECT id, component_product_id, component_meal_id, quantity, unit
            FROM meal_components WHERE meal_id = $1 ORDER BY created_at
            "#,
        )
        .bind(meal_id)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter()
            .map(meal_component_row_to_component)
            .collect()
    }
}

fn meal_row_to_meal(row: MealRow, components: Vec<MealComponent>) -> Meal {
    Meal {
        id: MealId(row.id),
        user_id: row.user_id,
        name: MealName(row.name),
        notes: row.notes.map(MealNotes),
        total_quantity_amount: row.total_quantity_amount,
        total_quantity_unit: row.total_quantity_unit.map(UnitCode),
        components,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
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

        sqlx::query(
            r#"
            INSERT INTO meals (id, user_id, name, notes, total_quantity_amount, total_quantity_unit, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            "#,
        )
        .bind(meal.id.0)
        .bind(meal.user_id)
        .bind(&meal.name.0)
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

    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, NutritionError> {
        let row = sqlx::query_as::<_, MealRow>(
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
                let components = self.load_components(r.id).await?;
                Ok(Some(meal_row_to_meal(r, components)))
            }
            None => Ok(None),
        }
    }

    async fn list_by_user_id(&self, user_id: Uuid) -> Result<Vec<Meal>, NutritionError> {
        let rows = sqlx::query_as::<_, MealRow>(
            r#"
            SELECT id, user_id, name, notes, total_quantity_amount, total_quantity_unit,
                   created_at, updated_at
            FROM meals WHERE user_id = $1
            ORDER BY created_at DESC
            "#,
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;

        let mut results = Vec::new();
        for r in rows {
            let components = self.load_components(r.id).await?;
            results.push(meal_row_to_meal(r, components));
        }
        Ok(results)
    }

    async fn update(&self, meal: &Meal) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        sqlx::query(
            r#"
            UPDATE meals SET name=$2, notes=$3, total_quantity_amount=$4, total_quantity_unit=$5,
                             updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(meal.id.0)
        .bind(&meal.name.0)
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

    async fn delete(&self, id: MealId) -> Result<(), NutritionError> {
        sqlx::query("DELETE FROM meals WHERE id = $1")
            .bind(id.0)
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

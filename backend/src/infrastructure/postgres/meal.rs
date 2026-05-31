use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::application::meal::*;
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

    async fn load_components(&self, meal_id: Uuid) -> Result<Vec<MealComponent>, MealError> {
        let rows = sqlx::query_as::<_, MealComponentRow>(
            r#"
            SELECT id, component_product_id, component_meal_id, quantity, unit
            FROM meal_components WHERE meal_id = $1 ORDER BY created_at
            "#,
        )
        .bind(meal_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

        rows.into_iter().map(row_to_component).collect()
    }

    fn row_to_meal(&self, r: MealRow, components: Vec<MealComponent>) -> Result<Meal, MealError> {
        Ok(Meal {
            id: MealId(r.id),
            user_id: r.user_id,
            name: MealName(r.name),
            notes: r.notes.map(MealNotes),
            total_quantity_amount: r.total_quantity_amount,
            total_quantity_unit: r.total_quantity_unit.map(UnitCode),
            components,
            created_at: r.created_at,
            updated_at: r.updated_at,
        })
    }
}

fn row_to_component(r: MealComponentRow) -> Result<MealComponent, MealError> {
    let item = if let Some(pid) = r.component_product_id {
        MealComponentItem::Product(ProductId(pid))
    } else if let Some(_mid) = r.component_meal_id {
        return Err(MealError::Internal("meal components of type meal not yet supported".into()));
    } else {
        return Err(MealError::Internal("meal component has no item reference".into()));
    };

    Ok(MealComponent {
        id: r.id,
        item,
        quantity_amount: r.quantity,
        quantity_unit: UnitCode(r.unit),
    })
}

#[async_trait]
impl MealRepository for PostgresMealRepository {
    async fn create(&self, meal: &Meal) -> Result<(), MealError> {
        let mut tx = self.pool.begin().await.map_err(|e| MealError::Database(e.to_string()))?;

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
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

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
            .await
            .map_err(|e| MealError::Database(e.to_string()))?;
        }

        tx.commit().await.map_err(|e| MealError::Database(e.to_string()))?;
        Ok(())
    }

    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, MealError> {
        let row = sqlx::query_as::<_, MealRow>(
            r#"
            SELECT id, user_id, name, notes, total_quantity_amount, total_quantity_unit,
                   created_at, updated_at
            FROM meals WHERE id = $1
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

        match row {
            Some(r) => {
                let components = self.load_components(r.id).await?;
                Ok(Some(self.row_to_meal(r, components)?))
            }
            None => Ok(None),
        }
    }

    async fn find_by_user(&self, user_id: Uuid) -> Result<Vec<Meal>, MealError> {
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
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

        let mut results = Vec::new();
        for r in rows {
            let components = self.load_components(r.id).await?;
            results.push(self.row_to_meal(r, components)?);
        }
        Ok(results)
    }

    async fn update(&self, meal: &Meal) -> Result<(), MealError> {
        let mut tx = self.pool.begin().await.map_err(|e| MealError::Database(e.to_string()))?;

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
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

        sqlx::query("DELETE FROM meal_components WHERE meal_id = $1")
            .bind(meal.id.0)
            .execute(&mut *tx)
            .await
            .map_err(|e| MealError::Database(e.to_string()))?;

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
            .await
            .map_err(|e| MealError::Database(e.to_string()))?;
        }

        tx.commit().await.map_err(|e| MealError::Database(e.to_string()))?;
        Ok(())
    }

    async fn delete(&self, id: MealId) -> Result<(), MealError> {
        sqlx::query("DELETE FROM meals WHERE id = $1")
            .bind(id.0)
            .execute(&self.pool)
            .await
            .map_err(|e| MealError::Database(e.to_string()))?;
        Ok(())
    }
}

#[async_trait]
impl MealProductLookup for PostgresMealRepository {
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, MealError> {
        let row = sqlx::query_as::<_, MealProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit, serving_size_g
            FROM products WHERE id = $1 AND deleted_at IS NULL
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

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

impl PostgresMealRepository {
    async fn load_product_nutrients(&self, product_id: Uuid) -> Result<Vec<ProductNutrient>, MealError> {
        let rows = sqlx::query_as::<_, MealProductNutrientRow>(
            r#"
            SELECT pn.amount_per_100g, pn.source, pn.confidence, n.code, n.unit
            FROM product_nutrients pn
            JOIN nutrients n ON n.id = pn.nutrient_id
            WHERE pn.product_id = $1
            "#,
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| ProductNutrient {
                nutrient_code: NutrientCode(r.code),
                amount_per_100g: AmountPer100g(r.amount_per_100g),
                unit: UnitCode(r.unit),
                source: r.source,
                confidence: r.confidence.and_then(|c| NutrientConfidence::from_str(&c).ok()),
            })
            .collect())
    }

    async fn load_product_servings(&self, product_id: Uuid) -> Result<Vec<ProductServing>, MealError> {
        let rows = sqlx::query_as::<_, MealProductServingRow>(
            "SELECT label, quantity, unit, grams FROM product_servings WHERE product_id = $1 ORDER BY created_at",
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| MealError::Database(e.to_string()))?;

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
        r: MealProductRow,
        nutrients: Vec<ProductNutrient>,
        servings: Vec<ProductServing>,
    ) -> Result<Product, MealError> {
        Ok(Product {
            id: ProductId(r.id),
            source: Source::from_str(&r.source).map_err(MealError::Internal)?,
            source_id: r.source_id,
            user_id: r.user_id,
            visibility: ProductVisibility::from_str(&r.visibility)
                .map_err(MealError::Internal)?,
            barcode: r.barcode.map(Barcode),
            name: ProductName(r.name),
            brand: r.brand.map(Brand),
            categories: r.categories.into_iter().map(Category).collect(),
            default_quantity: r.default_quantity,
            default_unit: r.default_unit.map(UnitCode),
            serving_size_g: r.serving_size_g,
            nutrients,
            servings,
        })
    }
}

#[derive(sqlx::FromRow)]
struct MealProductRow {
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
struct MealProductNutrientRow {
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct MealProductServingRow {
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
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

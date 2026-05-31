use async_trait::async_trait;
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

use crate::application::catalog::*;
use crate::domain::catalog::*;

// ─── Product Repository ────────────────────────────────────────

#[derive(Clone)]
pub struct PostgresProductRepository {
    pool: PgPool,
}

impl PostgresProductRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_nutrients(&self, product_id: Uuid) -> Result<Vec<ProductNutrient>, CatalogError> {
        let rows = sqlx::query_as::<_, ProductNutrientRow>(
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
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| ProductNutrient {
                nutrient_code: NutrientCode(r.code),
                amount_per_100g: AmountPer100g(r.amount_per_100g),
                unit: UnitCode(r.unit),
                source: r.source,
                confidence: r
                    .confidence
                    .and_then(|c| NutrientConfidence::from_str(&c).ok()),
            })
            .collect())
    }

    async fn load_servings(&self, product_id: Uuid) -> Result<Vec<ProductServing>, CatalogError> {
        let rows = sqlx::query_as::<_, ProductServingRow>(
            "SELECT label, quantity, unit, grams FROM product_servings WHERE product_id = $1 ORDER BY created_at",
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

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
        r: ProductRow,
        nutrients: Vec<ProductNutrient>,
        servings: Vec<ProductServing>,
    ) -> Result<Product, CatalogError> {
        Ok(Product {
            id: ProductId(r.id),
            source: Source::from_str(&r.source).map_err(CatalogError::Internal)?,
            source_id: r.source_id,
            user_id: r.user_id,
            visibility: ProductVisibility::from_str(&r.visibility)
                .map_err(CatalogError::Internal)?,
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

#[async_trait]
impl ProductRepository for PostgresProductRepository {
    async fn search(
        &self,
        query: ProductSearchQuery,
        user_id: Option<Uuid>,
    ) -> Result<Vec<Product>, CatalogError> {
        let rows = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit, serving_size_g
            FROM products
            WHERE deleted_at IS NULL
              AND (visibility = 'global' OR user_id = $2)
              AND ($1 = ''
                   OR name ILIKE '%' || $1 || '%'
                   OR brand ILIKE '%' || $1 || '%'
                   OR barcode ILIKE '%' || $1 || '%'
                   OR lower(name) % lower($1)
                   OR (brand IS NOT NULL AND lower(brand) % lower($1)))
              AND (cardinality($3::text[]) = 0 OR categories @> $3::text[])
              AND (cardinality($4::text[]) = 0 OR NOT categories && $4::text[])
            ORDER BY
                CASE
                    WHEN barcode = $1 THEN 0
                    WHEN barcode ILIKE $1 || '%' THEN 1
                    WHEN name ILIKE $1 || '%' THEN 2
                    WHEN name ILIKE '%' || $1 || '%' THEN 3
                    WHEN brand ILIKE $1 || '%' THEN 4
                    WHEN brand ILIKE '%' || $1 || '%' THEN 5
                    ELSE 6
                END,
                GREATEST(
                    similarity(lower(name), lower($1)),
                    similarity(lower(COALESCE(brand, '')), lower($1))
                ) DESC,
                lower(name)
            LIMIT 50
            "#,
        )
        .bind(&query.text)
        .bind(user_id)
        .bind(&query.include_categories)
        .bind(&query.exclude_categories)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        let product_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
        let energy_by_product = if product_ids.is_empty() {
            HashMap::new()
        } else {
            let energy_rows = sqlx::query_as::<_, SearchEnergyRow>(
                r#"
                SELECT pn.product_id, pn.amount_per_100g, pn.source, pn.confidence, n.code, n.unit
                FROM product_nutrients pn
                JOIN nutrients n ON n.id = pn.nutrient_id
                WHERE pn.product_id = ANY($1)
                  AND n.code = 'ENERGY_KCAL'
                "#,
            )
            .bind(&product_ids)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;

            energy_rows
                .into_iter()
                .map(|r| {
                    (
                        r.product_id,
                        ProductNutrient {
                            nutrient_code: NutrientCode(r.code),
                            amount_per_100g: AmountPer100g(r.amount_per_100g),
                            unit: UnitCode(r.unit),
                            source: r.source,
                            confidence: r
                                .confidence
                                .and_then(|c| NutrientConfidence::from_str(&c).ok()),
                        },
                    )
                })
                .collect()
        };

        rows.into_iter()
            .map(|r| {
                let nutrients = energy_by_product
                    .get(&r.id)
                    .cloned()
                    .map(|n| vec![n])
                    .unwrap_or_default();
                self.row_to_product(r, nutrients, vec![])
            })
            .collect()
    }

    async fn list_categories(
        &self,
        query: &str,
        user_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<CategorySuggestion>, CatalogError> {
        let rows = sqlx::query_as::<_, CategorySuggestionRow>(
            r#"
            SELECT category AS value, COUNT(*)::BIGINT AS count
            FROM products p
            CROSS JOIN LATERAL UNNEST(p.categories) AS category
            WHERE p.deleted_at IS NULL
              AND (p.visibility = 'global' OR p.user_id = $2)
              AND ($1 = ''
                   OR category ILIKE $1 || '%'
                   OR category ILIKE '%' || $1 || '%'
                   OR similarity(lower(category), lower($1)) > 0.30)
            GROUP BY category
            ORDER BY
                CASE
                    WHEN category ILIKE $1 || '%' THEN 0
                    WHEN category ILIKE '%' || $1 || '%' THEN 1
                    ELSE 2
                END,
                COUNT(*) DESC,
                similarity(lower(category), lower($1)) DESC,
                category
            LIMIT $3
            "#,
        )
        .bind(query)
        .bind(user_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| CategorySuggestion {
                value: r.value,
                count: r.count,
            })
            .collect())
    }

    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, CatalogError> {
        let row = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit, serving_size_g
            FROM products WHERE id = $1 AND deleted_at IS NULL
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        match row {
            Some(r) => {
                let nutrients = self.load_nutrients(r.id).await?;
                let servings = self.load_servings(r.id).await?;
                Ok(Some(self.row_to_product(r, nutrients, servings)?))
            }
            None => Ok(None),
        }
    }

    async fn find_by_barcode(&self, barcode: &str) -> Result<Option<Product>, CatalogError> {
        let row = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit, serving_size_g
            FROM products WHERE barcode = $1 AND deleted_at IS NULL
            "#,
        )
        .bind(barcode)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        match row {
            Some(r) => {
                let nutrients = self.load_nutrients(r.id).await?;
                let servings = self.load_servings(r.id).await?;
                Ok(Some(self.row_to_product(r, nutrients, servings)?))
            }
            None => Ok(None),
        }
    }

    async fn create(&self, product: &Product) -> Result<(), CatalogError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;

        sqlx::query(
            r#"
            INSERT INTO products (id, source, source_id, user_id, visibility, barcode, name,
                                  brand, categories, default_quantity, default_unit, serving_size_g)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            "#,
        )
        .bind(product.id.0)
        .bind(product.source.as_str())
        .bind(&product.source_id)
        .bind(product.user_id)
        .bind(product.visibility.as_str())
        .bind(product.barcode.as_ref().map(|b| &b.0))
        .bind(&product.name.0)
        .bind(product.brand.as_ref().map(|b| &b.0))
        .bind(
            product
                .categories
                .iter()
                .map(|c| c.0.clone())
                .collect::<Vec<_>>(),
        )
        .bind(product.default_quantity)
        .bind(product.default_unit.as_ref().map(|u| &u.0))
        .bind(product.serving_size_g)
        .execute(&mut *tx)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        insert_product_nutrients(&mut tx, product.id.0, &product.nutrients).await?;
        insert_product_servings(&mut tx, product.id.0, &product.servings).await?;

        tx.commit()
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;
        Ok(())
    }

    async fn update(&self, product: &Product) -> Result<(), CatalogError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;

        sqlx::query(
            r#"
            UPDATE products SET name=$2, brand=$3, categories=$4, default_quantity=$5,
                                default_unit=$6, serving_size_g=$7, updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(product.id.0)
        .bind(&product.name.0)
        .bind(product.brand.as_ref().map(|b| &b.0))
        .bind(
            product
                .categories
                .iter()
                .map(|c| c.0.clone())
                .collect::<Vec<_>>(),
        )
        .bind(product.default_quantity)
        .bind(product.default_unit.as_ref().map(|u| &u.0))
        .bind(product.serving_size_g)
        .execute(&mut *tx)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        sqlx::query("DELETE FROM product_nutrients WHERE product_id = $1")
            .bind(product.id.0)
            .execute(&mut *tx)
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;

        sqlx::query("DELETE FROM product_servings WHERE product_id = $1")
            .bind(product.id.0)
            .execute(&mut *tx)
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;

        insert_product_nutrients(&mut tx, product.id.0, &product.nutrients).await?;
        insert_product_servings(&mut tx, product.id.0, &product.servings).await?;

        tx.commit()
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;
        Ok(())
    }

    async fn soft_delete(&self, id: ProductId) -> Result<(), CatalogError> {
        sqlx::query("UPDATE products SET deleted_at = now() WHERE id = $1")
            .bind(id.0)
            .execute(&self.pool)
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;
        Ok(())
    }
}

// ─── Row Types ─────────────────────────────────────────────────

#[derive(sqlx::FromRow)]
struct ProductRow {
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
struct ProductNutrientRow {
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct SearchEnergyRow {
    product_id: Uuid,
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct ProductServingRow {
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

#[derive(sqlx::FromRow)]
struct CategorySuggestionRow {
    value: String,
    count: i64,
}

// ─── Nutrient Repository ───────────────────────────────────────

#[derive(Clone)]
pub struct PostgresNutrientRepository {
    pool: PgPool,
}

impl PostgresNutrientRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl NutrientRepository for PostgresNutrientRepository {
    async fn list_all(&self) -> Result<Vec<Nutrient>, CatalogError> {
        let rows = sqlx::query_as::<_, NutrientRow>(
            "SELECT code, name, unit, category FROM nutrients ORDER BY code",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, CatalogError> {
        let row = sqlx::query_as::<_, NutrientRow>(
            "SELECT code, name, unit, category FROM nutrients WHERE code = $1",
        )
        .bind(code)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        Ok(row.map(Into::into))
    }
}

#[derive(sqlx::FromRow)]
struct NutrientRow {
    code: String,
    name: String,
    unit: String,
    category: String,
}

impl From<NutrientRow> for Nutrient {
    fn from(r: NutrientRow) -> Self {
        Nutrient(NutrientCode(r.code), r.name, UnitCode(r.unit), r.category)
    }
}

// ─── Unit Repository ───────────────────────────────────────────

#[derive(Clone)]
pub struct PostgresUnitRepository {
    pool: PgPool,
}

impl PostgresUnitRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl UnitRepository for PostgresUnitRepository {
    async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
        let rows = sqlx::query_as::<_, UnitRow>("SELECT code, name, kind FROM units ORDER BY code")
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CatalogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| (UnitCode(r.code), r.name, r.kind))
            .collect())
    }

    async fn mass_factors(&self) -> Result<Vec<(String, Decimal)>, CatalogError> {
        let rows = sqlx::query_as::<_, MassFactorRow>(
            "SELECT code, canonical_grams FROM units WHERE canonical_grams IS NOT NULL",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| CatalogError::Database(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| (r.code, r.canonical_grams))
            .collect())
    }
}

#[derive(sqlx::FromRow)]
struct UnitRow {
    code: String,
    name: String,
    kind: String,
}

#[derive(sqlx::FromRow)]
struct MassFactorRow {
    code: String,
    canonical_grams: Decimal,
}

async fn insert_product_nutrients(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    product_id: Uuid,
    nutrients: &[ProductNutrient],
) -> Result<(), CatalogError> {
    if nutrients.is_empty() {
        return Ok(());
    }

    let codes: Vec<String> = nutrients
        .iter()
        .map(|n| n.nutrient_code.0.clone())
        .collect();
    let amounts: Vec<Decimal> = nutrients.iter().map(|n| n.amount_per_100g.0).collect();
    let sources: Vec<Option<String>> = nutrients.iter().map(|n| n.source.clone()).collect();
    let confidences: Vec<Option<String>> = nutrients
        .iter()
        .map(|n| n.confidence.as_ref().map(|c| c.as_str().to_string()))
        .collect();

    let inserted: i64 = sqlx::query_scalar(
        r#"
        WITH ins AS (
            INSERT INTO product_nutrients (product_id, nutrient_id, amount_per_100g, source, confidence)
            SELECT $1, n.id, v.amount, v.source, v.confidence
            FROM UNNEST($2::text[], $3::numeric[], $4::text[], $5::text[])
                AS v(code, amount, source, confidence)
            JOIN nutrients n ON n.code = v.code
            RETURNING 1
        )
        SELECT COUNT(*) FROM ins
        "#,
    )
    .bind(product_id)
    .bind(&codes)
    .bind(&amounts)
    .bind(&sources)
    .bind(&confidences)
    .fetch_one(&mut **tx)
    .await
    .map_err(|e| CatalogError::Database(e.to_string()))?;

    if (inserted as usize) != nutrients.len() {
        return Err(CatalogError::Validation(format!(
            "unknown nutrient code in product (expected {} rows, inserted {})",
            nutrients.len(),
            inserted
        )));
    }
    Ok(())
}

async fn insert_product_servings(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    product_id: Uuid,
    servings: &[ProductServing],
) -> Result<(), CatalogError> {
    if servings.is_empty() {
        return Ok(());
    }

    let labels: Vec<String> = servings.iter().map(|s| s.label.0.clone()).collect();
    let quantities: Vec<Decimal> = servings.iter().map(|s| s.quantity).collect();
    let units: Vec<String> = servings.iter().map(|s| s.unit.0.clone()).collect();
    let grams: Vec<Decimal> = servings.iter().map(|s| s.grams).collect();

    sqlx::query(
        r#"
        INSERT INTO product_servings (product_id, label, quantity, unit, grams)
        SELECT $1, v.label, v.quantity, v.unit, v.grams
        FROM UNNEST($2::text[], $3::numeric[], $4::text[], $5::numeric[])
            AS v(label, quantity, unit, grams)
        "#,
    )
    .bind(product_id)
    .bind(&labels)
    .bind(&quantities)
    .bind(&units)
    .bind(&grams)
    .execute(&mut **tx)
    .await
    .map_err(|e| CatalogError::Database(e.to_string()))?;
    Ok(())
}

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use sqlx::{Postgres, QueryBuilder};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use crate::nutrition::catalog::domain::*;

mod open_food_facts;
pub use open_food_facts::OpenFoodFactsClient;

// ─── Product Repository ────────────────────────────────────────

const SEARCH_NUTRIENT_CODES: [&str; 5] =
    ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G"];
const PRODUCT_UPSERT_CHUNK_SIZE: usize = 1_000;

#[derive(Clone)]
pub struct PostgresProductRepository {
    pool: PgPool,
}

impl PostgresProductRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_nutrients(
        &self,
        product_id: Uuid,
    ) -> Result<Vec<ProductNutrient>, NutritionError> {
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
        .await?;

        rows.into_iter()
            .map(|r| {
                Ok(ProductNutrient {
                    nutrient_code: NutrientCode(r.code),
                    amount_per_100g: AmountPer100g::new(r.amount_per_100g)?,
                    unit: UnitCode(r.unit),
                    source: r.source,
                    confidence: r.confidence.and_then(|c| c.parse().ok()),
                })
            })
            .collect()
    }

    async fn load_servings(&self, product_id: Uuid) -> Result<Vec<ProductServing>, NutritionError> {
        let rows = sqlx::query_as::<_, ProductServingRow>(
            "SELECT unit, grams_per_unit FROM product_servings WHERE product_id = $1 ORDER BY position",
        )
        .bind(product_id)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| ProductServing {
                unit: UnitCode(r.unit),
                grams_per_unit: r.grams_per_unit,
            })
            .collect())
    }

    async fn load_nutrients_for_products(
        &self,
        product_ids: &[Uuid],
    ) -> Result<HashMap<Uuid, Vec<ProductNutrient>>, NutritionError> {
        if product_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let rows = sqlx::query_as::<_, ProductNutrientWithProductRow>(
            r#"
            SELECT pn.product_id, pn.amount_per_100g, pn.source, pn.confidence, n.code, n.unit
            FROM product_nutrients pn
            JOIN nutrients n ON n.id = pn.nutrient_id
            WHERE pn.product_id = ANY($1)
            "#,
        )
        .bind(product_ids)
        .fetch_all(&self.pool)
        .await?;

        let mut by_product: HashMap<Uuid, Vec<ProductNutrient>> = HashMap::new();
        for r in rows {
            by_product
                .entry(r.product_id)
                .or_default()
                .push(ProductNutrient {
                    nutrient_code: NutrientCode(r.code),
                    amount_per_100g: AmountPer100g::new(r.amount_per_100g)?,
                    unit: UnitCode(r.unit),
                    source: r.source,
                    confidence: r.confidence.and_then(|c| c.parse().ok()),
                });
        }
        Ok(by_product)
    }

    async fn load_servings_for_products(
        &self,
        product_ids: &[Uuid],
    ) -> Result<HashMap<Uuid, Vec<ProductServing>>, NutritionError> {
        if product_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let rows = sqlx::query_as::<_, ProductServingWithProductRow>(
            r#"
            SELECT product_id, unit, grams_per_unit
            FROM product_servings
            WHERE product_id = ANY($1)
            ORDER BY product_id, position
            "#,
        )
        .bind(product_ids)
        .fetch_all(&self.pool)
        .await?;

        let mut by_product: HashMap<Uuid, Vec<ProductServing>> = HashMap::new();
        for r in rows {
            by_product
                .entry(r.product_id)
                .or_default()
                .push(ProductServing {
                    unit: UnitCode(r.unit),
                    grams_per_unit: r.grams_per_unit,
                });
        }
        Ok(by_product)
    }
}

#[async_trait]
impl ProductRepository for PostgresProductRepository {
    async fn search(
        &self,
        query: ProductSearchSpec,
        scope: ProductSearchScope,
        user_id: Option<Uuid>,
    ) -> Result<Vec<Product>, NutritionError> {
        let include: Vec<String> = query
            .include_categories
            .iter()
            .map(|c| c.0.clone())
            .collect();
        let exclude: Vec<String> = query
            .exclude_categories
            .iter()
            .map(|c| c.0.clone())
            .collect();

        let rows = match scope {
            ProductSearchScope::All => {
                sqlx::query_as::<_, ProductRow>(
                    r#"
                    SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                           categories, default_quantity, default_unit,
                           created_at, updated_at
                    FROM products
                    WHERE deleted_at IS NULL
                      AND ($1 = ''
                           OR name ILIKE '%' || $1 || '%'
                           OR brand ILIKE '%' || $1 || '%'
                           OR barcode ILIKE '%' || $1 || '%'
                           OR lower(name) % lower($1)
                           OR (brand IS NOT NULL AND lower(brand) % lower($1)))
                      AND (cardinality($2::text[]) = 0 OR categories @> $2::text[])
                      AND (cardinality($3::text[]) = 0 OR NOT categories && $3::text[])
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
                .bind(&include)
                .bind(&exclude)
                .fetch_all(&self.pool)
                .await?
            }
            ProductSearchScope::Custom => {
                sqlx::query_as::<_, ProductRow>(
                    r#"
                    SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                           categories, default_quantity, default_unit,
                           created_at, updated_at
                    FROM products
                    WHERE deleted_at IS NULL
                      AND source = 'USER'
                      AND ($1 = ''
                           OR name ILIKE '%' || $1 || '%'
                           OR brand ILIKE '%' || $1 || '%'
                           OR barcode ILIKE '%' || $1 || '%'
                           OR lower(name) % lower($1)
                           OR (brand IS NOT NULL AND lower(brand) % lower($1)))
                      AND (cardinality($2::text[]) = 0 OR categories @> $2::text[])
                      AND (cardinality($3::text[]) = 0 OR NOT categories && $3::text[])
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
                .bind(&include)
                .bind(&exclude)
                .fetch_all(&self.pool)
                .await?
            }
            ProductSearchScope::History => {
                sqlx::query_as::<_, ProductRow>(
                    r#"
                    WITH latest_logs AS (
                        SELECT item_product_id AS product_id,
                               MAX(log_date) AS last_log_date,
                               MAX(created_at) AS last_logged_at
                        FROM food_logs
                        WHERE user_id = $2
                          AND item_product_id IS NOT NULL
                        GROUP BY item_product_id
                    )
                    SELECT p.id, p.source, p.source_id, p.user_id, p.visibility, p.barcode,
                           p.name, p.brand, p.categories, p.default_quantity, p.default_unit,
                           p.created_at, p.updated_at
                    FROM products p
                    JOIN latest_logs l ON l.product_id = p.id
                    WHERE p.deleted_at IS NULL
                      AND ($1 = ''
                           OR p.name ILIKE '%' || $1 || '%'
                           OR p.brand ILIKE '%' || $1 || '%'
                           OR p.barcode ILIKE '%' || $1 || '%'
                           OR EXISTS (
                               SELECT 1 FROM unnest(p.categories) AS category
                               WHERE category ILIKE '%' || $1 || '%'
                                  OR lower(category) % lower($1)
                           )
                           OR lower(p.name) % lower($1)
                           OR (p.brand IS NOT NULL AND lower(p.brand) % lower($1)))
                      AND (cardinality($3::text[]) = 0 OR p.categories @> $3::text[])
                      AND (cardinality($4::text[]) = 0 OR NOT p.categories && $4::text[])
                    ORDER BY
                        l.last_log_date DESC,
                        l.last_logged_at DESC,
                        CASE
                            WHEN p.barcode = $1 THEN 0
                            WHEN p.barcode ILIKE $1 || '%' THEN 1
                            WHEN p.name ILIKE $1 || '%' THEN 2
                            WHEN p.name ILIKE '%' || $1 || '%' THEN 3
                            WHEN p.brand ILIKE $1 || '%' THEN 4
                            WHEN p.brand ILIKE '%' || $1 || '%' THEN 5
                            ELSE 6
                        END,
                        GREATEST(
                            similarity(lower(p.name), lower($1)),
                            similarity(lower(COALESCE(p.brand, '')), lower($1))
                        ) DESC,
                        lower(p.name)
                    LIMIT 50
                    "#,
                )
                .bind(&query.text)
                .bind(user_id)
                .bind(&include)
                .bind(&exclude)
                .fetch_all(&self.pool)
                .await?
            }
        };

        let product_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
        let summary_nutrients_by_product = if product_ids.is_empty() {
            HashMap::new()
        } else {
            let summary_rows = sqlx::query_as::<_, SearchNutrientRow>(
                r#"
                SELECT pn.product_id, pn.amount_per_100g, pn.source, pn.confidence, n.code, n.unit
                FROM product_nutrients pn
                JOIN nutrients n ON n.id = pn.nutrient_id
                WHERE pn.product_id = ANY($1)
                  AND n.code = ANY($2)
                "#,
            )
            .bind(&product_ids)
            .bind(SEARCH_NUTRIENT_CODES.as_slice())
            .fetch_all(&self.pool)
            .await?;

            let mut by_product: HashMap<Uuid, Vec<ProductNutrient>> = HashMap::new();
            for r in summary_rows {
                by_product
                    .entry(r.product_id)
                    .or_default()
                    .push(ProductNutrient {
                        nutrient_code: NutrientCode(r.code),
                        amount_per_100g: AmountPer100g::new(r.amount_per_100g)?,
                        unit: UnitCode(r.unit),
                        source: r.source,
                        confidence: r.confidence.and_then(|c| c.parse().ok()),
                    });
            }
            by_product
        };

        rows.into_iter()
            .map(|r| {
                let nutrients = summary_nutrients_by_product
                    .get(&r.id)
                    .cloned()
                    .unwrap_or_default();
                product_row_to_product(r, nutrients, vec![])
            })
            .collect()
    }

    async fn list_categories(
        &self,
        query: &str,
        _user_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<CategorySuggestion>, NutritionError> {
        let rows = sqlx::query_as::<_, CategorySuggestionRow>(
            r#"
            SELECT category AS value, COUNT(*)::BIGINT AS count
            FROM products p
            CROSS JOIN LATERAL UNNEST(p.categories) AS category
            WHERE p.deleted_at IS NULL
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
            LIMIT $2
            "#,
        )
        .bind(query)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| CategorySuggestion {
                value: r.value,
                count: r.count,
            })
            .collect())
    }

    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, NutritionError> {
        let row = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit,
                   created_at, updated_at
            FROM products WHERE id = $1 AND deleted_at IS NULL
            "#,
        )
        .bind(id.0)
        .fetch_optional(&self.pool)
        .await?;

        match row {
            Some(r) => {
                let nutrients = self.load_nutrients(r.id).await?;
                let servings = self.load_servings(r.id).await?;
                Ok(Some(product_row_to_product(r, nutrients, servings)?))
            }
            None => Ok(None),
        }
    }

    async fn existing_ids(&self, ids: &[ProductId]) -> Result<HashSet<ProductId>, NutritionError> {
        if ids.is_empty() {
            return Ok(HashSet::new());
        }
        let raw: Vec<Uuid> = ids.iter().map(|p| p.0).collect();
        let rows: Vec<(Uuid,)> =
            sqlx::query_as("SELECT id FROM products WHERE id = ANY($1) AND deleted_at IS NULL")
                .bind(&raw)
                .fetch_all(&self.pool)
                .await?;
        Ok(rows.into_iter().map(|(id,)| ProductId(id)).collect())
    }

    async fn find_by_barcode(
        &self,
        barcode: &str,
        _user_id: Option<Uuid>,
    ) -> Result<Option<Product>, NutritionError> {
        let row = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit,
                   created_at, updated_at
            FROM products
            WHERE barcode = $1
              AND deleted_at IS NULL
            "#,
        )
        .bind(barcode)
        .fetch_optional(&self.pool)
        .await?;

        match row {
            Some(r) => {
                let nutrients = self.load_nutrients(r.id).await?;
                let servings = self.load_servings(r.id).await?;
                Ok(Some(product_row_to_product(r, nutrients, servings)?))
            }
            None => Ok(None),
        }
    }

    async fn list_custom_foods(&self) -> Result<Vec<Product>, NutritionError> {
        let rows = sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit,
                   created_at, updated_at
            FROM products
            WHERE source = 'USER'
              AND deleted_at IS NULL
            ORDER BY created_at DESC
            "#,
        )
        .fetch_all(&self.pool)
        .await?;

        if rows.is_empty() {
            return Ok(Vec::new());
        }

        let product_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
        let nutrients_by_product = self.load_nutrients_for_products(&product_ids).await?;
        let servings_by_product = self.load_servings_for_products(&product_ids).await?;

        rows.into_iter()
            .map(|r| {
                let nutrients = nutrients_by_product.get(&r.id).cloned().unwrap_or_default();
                let servings = servings_by_product.get(&r.id).cloned().unwrap_or_default();
                product_row_to_product(r, nutrients, servings)
            })
            .collect()
    }

    async fn create(&self, product: &Product) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        sqlx::query(
            r#"
            INSERT INTO products (id, source, source_id, user_id, visibility, barcode, name,
                                  brand, categories, default_quantity, default_unit)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            "#,
        )
        .bind(product.id.0)
        .bind(product.source.as_str())
        .bind(&product.source_id)
        .bind(product.user_id)
        .bind(product.visibility.as_str())
        .bind(product.barcode.as_ref().map(|b| &b.0))
        .bind(product.name.as_str())
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
        .execute(&mut *tx)
        .await?;

        insert_product_nutrients(&mut tx, product.id.0, &product.nutrients).await?;
        insert_product_servings(&mut tx, product.id.0, &product.servings).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn upsert_external_many(
        &self,
        batch: &ExternalProductBatch,
    ) -> Result<ProductUpsertResult, NutritionError> {
        let products = batch.products();
        if products.is_empty() {
            return Ok(ProductUpsertResult::default());
        }

        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "LOCK TABLE products, product_nutrients, product_servings IN SHARE ROW EXCLUSIVE MODE",
        )
        .execute(&mut *tx)
        .await?;

        let mut products: Vec<&Product> = products.iter().collect();
        products.sort_by_key(|product| {
            (
                product.source.as_str(),
                product.source_id.as_deref().unwrap_or_default(),
            )
        });

        let requested_nutrient_codes: HashSet<String> = products
            .iter()
            .flat_map(|product| &product.nutrients)
            .map(|nutrient| nutrient.nutrient_code.0.clone())
            .collect();
        let requested_nutrient_codes: Vec<String> = requested_nutrient_codes.into_iter().collect();
        let nutrient_rows = if requested_nutrient_codes.is_empty() {
            Vec::new()
        } else {
            sqlx::query_as::<_, (String, Uuid)>(
                "SELECT code, id FROM nutrients WHERE code = ANY($1)",
            )
            .bind(&requested_nutrient_codes)
            .fetch_all(&mut *tx)
            .await?
        };
        let nutrient_ids: HashMap<String, Uuid> = nutrient_rows.into_iter().collect();
        let mut unknown_codes: Vec<&str> = requested_nutrient_codes
            .iter()
            .filter(|code| !nutrient_ids.contains_key(code.as_str()))
            .map(String::as_str)
            .collect();
        if !unknown_codes.is_empty() {
            unknown_codes.sort_unstable();
            return Err(NutritionError::Validation(format!(
                "unknown nutrient code(s): {}",
                unknown_codes.join(", ")
            )));
        }

        let mut result = ProductUpsertResult::default();
        for chunk in products.chunks(PRODUCT_UPSERT_CHUNK_SIZE) {
            let mut query = QueryBuilder::<Postgres>::new(
                r#"INSERT INTO products (
                       id, source, source_id, user_id, visibility, barcode, name, brand,
                       categories, default_quantity, default_unit
                   ) "#,
            );
            query.push_values(chunk.iter().copied(), |mut row, product| {
                row.push_bind(product.id.0)
                    .push_bind(product.source.as_str())
                    .push_bind(product.source_id.as_deref().unwrap_or_default())
                    .push_bind(product.user_id)
                    .push_bind(product.visibility.as_str())
                    .push_bind(product.barcode.as_ref().map(|barcode| barcode.0.as_str()))
                    .push_bind(product.name.as_str())
                    .push_bind(product.brand.as_ref().map(|brand| brand.0.as_str()))
                    .push_bind(
                        product
                            .categories
                            .iter()
                            .map(|category| category.0.clone())
                            .collect::<Vec<_>>(),
                    )
                    .push_bind(product.default_quantity)
                    .push_bind(product.default_unit.as_ref().map(|unit| unit.0.as_str()));
            });
            query.push(" ON CONFLICT (source, source_id) DO NOTHING");
            result.created += query.build().execute(&mut *tx).await?.rows_affected() as i64;

            let mut query = QueryBuilder::<Postgres>::new(
                r#"UPDATE products AS product SET
                       user_id = incoming.user_id,
                       visibility = incoming.visibility,
                       barcode = incoming.barcode,
                       name = incoming.name,
                       brand = incoming.brand,
                       categories = incoming.categories,
                       default_quantity = incoming.default_quantity,
                       default_unit = incoming.default_unit,
                       deleted_at = NULL,
                       updated_at = NOW()
                   FROM ("#,
            );
            query.push_values(chunk.iter().copied(), |mut row, product| {
                row.push_bind(product.source.as_str())
                    .push_bind(product.source_id.as_deref().unwrap_or_default())
                    .push_bind(product.user_id)
                    .push_bind(product.visibility.as_str())
                    .push_bind(product.barcode.as_ref().map(|barcode| barcode.0.as_str()))
                    .push_bind(product.name.as_str())
                    .push_bind(product.brand.as_ref().map(|brand| brand.0.as_str()))
                    .push_bind(
                        product
                            .categories
                            .iter()
                            .map(|category| category.0.clone())
                            .collect::<Vec<_>>(),
                    )
                    .push_bind(product.default_quantity)
                    .push_bind(product.default_unit.as_ref().map(|unit| unit.0.as_str()));
            });
            query.push(
                r#") AS incoming(
                       source, source_id, user_id, visibility, barcode, name, brand,
                       categories, default_quantity, default_unit
                   )
                   WHERE product.source = incoming.source
                     AND product.source_id = incoming.source_id
                     AND ROW(
                         product.user_id, product.visibility, product.barcode, product.name,
                         product.brand, product.categories, product.default_quantity,
                         product.default_unit, product.deleted_at
                     ) IS DISTINCT FROM ROW(
                         incoming.user_id, incoming.visibility, incoming.barcode, incoming.name,
                         incoming.brand, incoming.categories, incoming.default_quantity,
                         incoming.default_unit, NULL::timestamptz
                     )"#,
            );
            result.updated += query.build().execute(&mut *tx).await?.rows_affected() as i64;
        }

        let mut product_ids_by_source: HashMap<(String, String), Uuid> = HashMap::new();
        for chunk in products.chunks(PRODUCT_UPSERT_CHUNK_SIZE) {
            let mut query = QueryBuilder::<Postgres>::new(
                "SELECT id, source, source_id FROM products WHERE (source, source_id) IN (",
            );
            for (index, product) in chunk.iter().enumerate() {
                if index > 0 {
                    query.push(", ");
                }
                query
                    .push("(")
                    .push_bind(product.source.as_str())
                    .push(", ")
                    .push_bind(product.source_id.as_deref().unwrap_or_default())
                    .push(")");
            }
            query.push(") ORDER BY source, source_id");
            let rows = query
                .build_query_as::<(Uuid, String, String)>()
                .fetch_all(&mut *tx)
                .await?;
            for (id, source, source_id) in rows {
                product_ids_by_source.insert((source, source_id), id);
            }
        }

        if product_ids_by_source.len() != products.len() {
            return Err(NutritionError::Internal(
                "not every external product could be resolved after upsert".into(),
            ));
        }

        let product_ids: Vec<Uuid> = products
            .iter()
            .map(|product| {
                product_ids_by_source
                    .get(&(
                        product.source.as_str().to_owned(),
                        product.source_id.as_deref().unwrap_or_default().to_owned(),
                    ))
                    .copied()
                    .ok_or_else(|| {
                        NutritionError::Internal(
                            "external product identity missing after upsert".into(),
                        )
                    })
            })
            .collect::<Result<_, _>>()?;

        result.nutrients_written =
            replace_product_nutrients(&mut tx, &products, &product_ids, &nutrient_ids).await?;
        result.servings_written =
            replace_product_servings(&mut tx, &products, &product_ids).await?;

        tx.commit().await?;
        Ok(result)
    }

    async fn update(&self, product: &Product) -> Result<(), NutritionError> {
        let mut tx = self.pool.begin().await?;

        sqlx::query(
            r#"
            UPDATE products SET name=$2, brand=$3, categories=$4, default_quantity=$5,
                                default_unit=$6, updated_at=now()
            WHERE id=$1
            "#,
        )
        .bind(product.id.0)
        .bind(product.name.as_str())
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
        .execute(&mut *tx)
        .await?;

        sqlx::query("DELETE FROM product_nutrients WHERE product_id = $1")
            .bind(product.id.0)
            .execute(&mut *tx)
            .await?;

        sqlx::query("DELETE FROM product_servings WHERE product_id = $1")
            .bind(product.id.0)
            .execute(&mut *tx)
            .await?;

        insert_product_nutrients(&mut tx, product.id.0, &product.nutrients).await?;
        insert_product_servings(&mut tx, product.id.0, &product.servings).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: ProductId) -> Result<(), NutritionError> {
        sqlx::query("UPDATE products SET deleted_at = now() WHERE id = $1")
            .bind(id.0)
            .execute(&self.pool)
            .await?;
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
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
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
struct ProductNutrientWithProductRow {
    product_id: Uuid,
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct SearchNutrientRow {
    product_id: Uuid,
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
struct ProductServingRow {
    unit: String,
    grams_per_unit: Decimal,
}

#[derive(sqlx::FromRow)]
struct ProductServingWithProductRow {
    product_id: Uuid,
    unit: String,
    grams_per_unit: Decimal,
}

#[derive(sqlx::FromRow)]
struct CategorySuggestionRow {
    value: String,
    count: i64,
}

fn product_row_to_product(
    row: ProductRow,
    nutrients: Vec<ProductNutrient>,
    servings: Vec<ProductServing>,
) -> Result<Product, NutritionError> {
    Ok(Product {
        id: ProductId(row.id),
        source: row
            .source
            .parse::<Source>()
            .map_err(NutritionError::Internal)?,
        source_id: row.source_id,
        user_id: row.user_id,
        visibility: row
            .visibility
            .parse::<ProductVisibility>()
            .map_err(NutritionError::Internal)?,
        barcode: row.barcode.map(Barcode),
        name: ProductName::new(&row.name)?,
        brand: row.brand.map(Brand),
        categories: row.categories.into_iter().map(Category).collect(),
        default_quantity: row.default_quantity,
        default_unit: row.default_unit.map(UnitCode),
        nutrients,
        servings,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
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
    async fn list_all(&self) -> Result<Vec<Nutrient>, NutritionError> {
        let rows = sqlx::query_as::<_, NutrientRow>(
            "SELECT code, name, unit, category FROM nutrients ORDER BY code",
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().map(nutrient_row_to_nutrient).collect())
    }

    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, NutritionError> {
        let row = sqlx::query_as::<_, NutrientRow>(
            "SELECT code, name, unit, category FROM nutrients WHERE code = $1",
        )
        .bind(code)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(nutrient_row_to_nutrient))
    }
}

#[derive(sqlx::FromRow)]
struct NutrientRow {
    code: String,
    name: String,
    unit: String,
    category: String,
}

fn nutrient_row_to_nutrient(row: NutrientRow) -> Nutrient {
    Nutrient {
        code: NutrientCode(row.code),
        name: row.name,
        unit: UnitCode(row.unit),
        category: row.category,
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
    async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
        let rows = sqlx::query_as::<_, UnitRow>("SELECT code, name, kind FROM units ORDER BY code")
            .fetch_all(&self.pool)
            .await?;

        Ok(rows
            .into_iter()
            .map(|r| (UnitCode(r.code), r.name, r.kind))
            .collect())
    }

    async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, NutritionError> {
        let rows = sqlx::query_as::<_, MassFactorRow>(
            "SELECT code, canonical_grams FROM units WHERE canonical_grams IS NOT NULL",
        )
        .fetch_all(&self.pool)
        .await?;

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
) -> Result<(), NutritionError> {
    if nutrients.is_empty() {
        return Ok(());
    }

    let codes: Vec<String> = nutrients
        .iter()
        .map(|n| n.nutrient_code.0.clone())
        .collect();
    let amounts: Vec<Decimal> = nutrients
        .iter()
        .map(|n| n.amount_per_100g.value())
        .collect();
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
    .await?;

    if (inserted as usize) != nutrients.len() {
        return Err(NutritionError::Validation(format!(
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
) -> Result<(), NutritionError> {
    if servings.is_empty() {
        return Ok(());
    }

    let units: Vec<String> = servings.iter().map(|s| s.unit.0.clone()).collect();
    let grams_per_unit: Vec<Decimal> = servings.iter().map(|s| s.grams_per_unit).collect();
    let positions: Vec<i32> = (0..servings.len() as i32).collect();

    sqlx::query(
        r#"
        INSERT INTO product_servings (product_id, unit, grams_per_unit, position)
        SELECT $1, v.unit, v.grams_per_unit, v.position
        FROM UNNEST($2::text[], $3::numeric[], $4::integer[])
            AS v(unit, grams_per_unit, position)
        "#,
    )
    .bind(product_id)
    .bind(&units)
    .bind(&grams_per_unit)
    .bind(&positions)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn replace_product_nutrients(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    products: &[&Product],
    product_ids: &[Uuid],
    nutrient_ids: &HashMap<String, Uuid>,
) -> Result<i64, NutritionError> {
    let mut incoming_product_ids = Vec::new();
    let mut incoming_nutrient_ids = Vec::new();
    let mut amounts = Vec::new();
    let mut sources = Vec::new();
    let mut confidences = Vec::new();

    for (product, product_id) in products.iter().zip(product_ids) {
        for nutrient in &product.nutrients {
            incoming_product_ids.push(*product_id);
            incoming_nutrient_ids.push(*nutrient_ids.get(&nutrient.nutrient_code.0).ok_or_else(
                || {
                    NutritionError::Internal(
                        "validated nutrient identity missing during upsert".into(),
                    )
                },
            )?);
            amounts.push(nutrient.amount_per_100g.value());
            sources.push(nutrient.source.clone());
            confidences.push(
                nutrient
                    .confidence
                    .as_ref()
                    .map(|confidence| confidence.as_str().to_owned()),
            );
        }
    }

    sqlx::query("DELETE FROM product_nutrients WHERE product_id = ANY($1)")
        .bind(product_ids)
        .execute(&mut **tx)
        .await?;

    if incoming_product_ids.is_empty() {
        return Ok(0);
    }

    let written = sqlx::query(
        r#"
        INSERT INTO product_nutrients (
            product_id, nutrient_id, amount_per_100g, source, confidence
        )
        SELECT value.product_id, value.nutrient_id, value.amount, value.source, value.confidence
        FROM UNNEST($1::uuid[], $2::uuid[], $3::numeric[], $4::text[], $5::text[])
            AS value(product_id, nutrient_id, amount, source, confidence)
        "#,
    )
    .bind(&incoming_product_ids)
    .bind(&incoming_nutrient_ids)
    .bind(&amounts)
    .bind(&sources)
    .bind(&confidences)
    .execute(&mut **tx)
    .await?
    .rows_affected() as i64;

    Ok(written)
}

async fn replace_product_servings(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    products: &[&Product],
    product_ids: &[Uuid],
) -> Result<i64, NutritionError> {
    let mut incoming_product_ids = Vec::new();
    let mut units = Vec::new();
    let mut grams_per_unit = Vec::new();
    let mut positions = Vec::new();

    for (product, product_id) in products.iter().zip(product_ids) {
        for (position, serving) in product.servings.iter().enumerate() {
            let position = i32::try_from(position).map_err(|_| {
                NutritionError::Validation("too many servings for external product".into())
            })?;
            incoming_product_ids.push(*product_id);
            units.push(serving.unit.0.clone());
            grams_per_unit.push(serving.grams_per_unit);
            positions.push(position);
        }
    }

    sqlx::query("DELETE FROM product_servings WHERE product_id = ANY($1)")
        .bind(product_ids)
        .execute(&mut **tx)
        .await?;

    if incoming_product_ids.is_empty() {
        return Ok(0);
    }

    let written = sqlx::query(
        r#"
        INSERT INTO product_servings (product_id, unit, grams_per_unit, position)
        SELECT value.product_id, value.unit, value.grams_per_unit, value.position
        FROM UNNEST($1::uuid[], $2::text[], $3::numeric[], $4::integer[])
            AS value(product_id, unit, grams_per_unit, position)
        "#,
    )
    .bind(&incoming_product_ids)
    .bind(&units)
    .bind(&grams_per_unit)
    .bind(&positions)
    .execute(&mut **tx)
    .await?
    .rows_affected() as i64;

    Ok(written)
}

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sea_query::extension::postgres::PgExpr;
use sea_query::{
    DeleteStatement, Expr, ExprTrait, Iden, InsertStatement, JoinType, OnConflict, Order,
    PostgresQueryBuilder, Query, SelectStatement, UpdateStatement,
};
use sea_query_sqlx::SqlxBinder;
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

#[derive(Iden)]
enum Products {
    Table,
    Id,
    Source,
    SourceId,
    UserId,
    Visibility,
    Barcode,
    Name,
    Brand,
    Categories,
    DefaultQuantity,
    DefaultUnit,
    DeletedAt,
    CreatedAt,
    UpdatedAt,
}

#[derive(Iden)]
enum ProductNutrients {
    Table,
    ProductId,
    NutrientId,
    #[iden = "amount_per_100g"]
    AmountPer100g,
    Source,
    Confidence,
}

#[derive(Iden)]
enum ProductServings {
    Table,
    ProductId,
    Unit,
    GramsPerUnit,
    Position,
}

#[derive(Iden)]
enum Nutrients {
    Table,
    Id,
    Code,
    Name,
    Unit,
    Category,
}

#[derive(Iden)]
enum Units {
    Table,
    Code,
    Name,
    Kind,
    CanonicalGrams,
}

fn product_columns() -> [Products; 13] {
    [
        Products::Id,
        Products::Source,
        Products::SourceId,
        Products::UserId,
        Products::Visibility,
        Products::Barcode,
        Products::Name,
        Products::Brand,
        Products::Categories,
        Products::DefaultQuantity,
        Products::DefaultUnit,
        Products::CreatedAt,
        Products::UpdatedAt,
    ]
}

fn insert_product_columns() -> [Products; 11] {
    [
        Products::Id,
        Products::Source,
        Products::SourceId,
        Products::UserId,
        Products::Visibility,
        Products::Barcode,
        Products::Name,
        Products::Brand,
        Products::Categories,
        Products::DefaultQuantity,
        Products::DefaultUnit,
    ]
}

fn load_nutrients_statement(product_id: Uuid) -> SelectStatement {
    Query::select()
        .column((ProductNutrients::Table, ProductNutrients::AmountPer100g))
        .column((ProductNutrients::Table, ProductNutrients::Source))
        .column((ProductNutrients::Table, ProductNutrients::Confidence))
        .column((Nutrients::Table, Nutrients::Code))
        .column((Nutrients::Table, Nutrients::Unit))
        .from(ProductNutrients::Table)
        .join(
            JoinType::InnerJoin,
            Nutrients::Table,
            Expr::col((Nutrients::Table, Nutrients::Id))
                .equals((ProductNutrients::Table, ProductNutrients::NutrientId)),
        )
        .and_where(Expr::col((ProductNutrients::Table, ProductNutrients::ProductId)).eq(product_id))
        .to_owned()
}

fn load_servings_statement(product_id: Uuid) -> SelectStatement {
    Query::select()
        .columns([ProductServings::Unit, ProductServings::GramsPerUnit])
        .from(ProductServings::Table)
        .and_where(Expr::col(ProductServings::ProductId).eq(product_id))
        .order_by(ProductServings::Position, Order::Asc)
        .to_owned()
}

fn load_nutrients_for_products_statement(product_ids: &[Uuid]) -> SelectStatement {
    Query::select()
        .column((ProductNutrients::Table, ProductNutrients::ProductId))
        .column((ProductNutrients::Table, ProductNutrients::AmountPer100g))
        .column((ProductNutrients::Table, ProductNutrients::Source))
        .column((ProductNutrients::Table, ProductNutrients::Confidence))
        .column((Nutrients::Table, Nutrients::Code))
        .column((Nutrients::Table, Nutrients::Unit))
        .from(ProductNutrients::Table)
        .join(
            JoinType::InnerJoin,
            Nutrients::Table,
            Expr::col((Nutrients::Table, Nutrients::Id))
                .equals((ProductNutrients::Table, ProductNutrients::NutrientId)),
        )
        .and_where(
            Expr::col((ProductNutrients::Table, ProductNutrients::ProductId))
                .eq_any(product_ids.to_vec()),
        )
        .to_owned()
}

fn load_servings_for_products_statement(product_ids: &[Uuid]) -> SelectStatement {
    Query::select()
        .columns([
            ProductServings::ProductId,
            ProductServings::Unit,
            ProductServings::GramsPerUnit,
        ])
        .from(ProductServings::Table)
        .and_where(Expr::col(ProductServings::ProductId).eq_any(product_ids.to_vec()))
        .order_by(ProductServings::ProductId, Order::Asc)
        .order_by(ProductServings::Position, Order::Asc)
        .to_owned()
}

fn search_summary_nutrients_statement(product_ids: &[Uuid]) -> SelectStatement {
    let nutrient_codes = SEARCH_NUTRIENT_CODES
        .iter()
        .map(|code| (*code).to_owned())
        .collect::<Vec<_>>();

    Query::select()
        .column((ProductNutrients::Table, ProductNutrients::ProductId))
        .column((ProductNutrients::Table, ProductNutrients::AmountPer100g))
        .column((ProductNutrients::Table, ProductNutrients::Source))
        .column((ProductNutrients::Table, ProductNutrients::Confidence))
        .column((Nutrients::Table, Nutrients::Code))
        .column((Nutrients::Table, Nutrients::Unit))
        .from(ProductNutrients::Table)
        .join(
            JoinType::InnerJoin,
            Nutrients::Table,
            Expr::col((Nutrients::Table, Nutrients::Id))
                .equals((ProductNutrients::Table, ProductNutrients::NutrientId)),
        )
        .and_where(
            Expr::col((ProductNutrients::Table, ProductNutrients::ProductId))
                .eq_any(product_ids.to_vec()),
        )
        .and_where(Expr::col((Nutrients::Table, Nutrients::Code)).eq_any(nutrient_codes))
        .to_owned()
}

fn find_product_statement(id: Uuid) -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Id).eq(id))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

fn find_product_by_barcode_statement(barcode: &str) -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Barcode).eq(barcode))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

fn list_custom_foods_statement() -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Source).eq("USER"))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .order_by(Products::CreatedAt, Order::Desc)
        .to_owned()
}

fn existing_ids_statement(ids: Vec<Uuid>) -> SelectStatement {
    Query::select()
        .column(Products::Id)
        .from(Products::Table)
        .and_where(Expr::col(Products::Id).eq_any(ids))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

fn insert_product_statement(product: &Product) -> InsertStatement {
    Query::insert()
        .into_table(Products::Table)
        .columns(insert_product_columns())
        .values_panic([
            product.id.0.into(),
            product.origin.source_code().into(),
            product.origin.source_id().into(),
            product.origin.owner_id().into(),
            product.visibility.as_str().into(),
            product
                .origin
                .barcode()
                .map(|barcode| barcode.0.as_str())
                .into(),
            product.name.as_str().into(),
            product.brand.as_ref().map(|brand| brand.0.as_str()).into(),
            product
                .categories
                .iter()
                .map(|category| category.0.clone())
                .collect::<Vec<_>>()
                .into(),
            product.default_quantity.into(),
            product
                .default_unit
                .as_ref()
                .map(|unit| unit.0.as_str())
                .into(),
        ])
        .to_owned()
}

fn insert_external_products_statement(chunk: &[&Product]) -> InsertStatement {
    let mut statement = Query::insert();
    statement
        .into_table(Products::Table)
        .columns(insert_product_columns());

    for product in chunk {
        statement.values_panic([
            product.id.0.into(),
            product.origin.source_code().into(),
            product.origin.source_id().unwrap_or_default().into(),
            product.origin.owner_id().into(),
            product.visibility.as_str().into(),
            product
                .origin
                .barcode()
                .map(|barcode| barcode.0.as_str())
                .into(),
            product.name.as_str().into(),
            product.brand.as_ref().map(|brand| brand.0.as_str()).into(),
            product
                .categories
                .iter()
                .map(|category| category.0.clone())
                .collect::<Vec<_>>()
                .into(),
            product.default_quantity.into(),
            product
                .default_unit
                .as_ref()
                .map(|unit| unit.0.as_str())
                .into(),
        ]);
    }

    statement.on_conflict(
        OnConflict::columns([Products::Source, Products::SourceId])
            .do_nothing()
            .to_owned(),
    );

    statement.to_owned()
}

fn resolve_external_product_ids_statement(chunk: &[&Product]) -> SelectStatement {
    let identities = chunk.iter().map(|product| {
        (
            product.origin.source_code().to_owned(),
            product.origin.source_id().unwrap_or_default().to_owned(),
        )
    });

    Query::select()
        .columns([Products::Id, Products::Source, Products::SourceId])
        .from(Products::Table)
        .and_where(
            Expr::tuple([Expr::col(Products::Source), Expr::col(Products::SourceId)])
                .in_tuples(identities),
        )
        .order_by(Products::Source, Order::Asc)
        .order_by(Products::SourceId, Order::Asc)
        .to_owned()
}

fn update_product_statement(product: &Product) -> UpdateStatement {
    Query::update()
        .table(Products::Table)
        .value(Products::Name, product.name.as_str())
        .value(
            Products::Brand,
            product.brand.as_ref().map(|brand| brand.0.as_str()),
        )
        .value(
            Products::Categories,
            product
                .categories
                .iter()
                .map(|category| category.0.clone())
                .collect::<Vec<_>>(),
        )
        .value(Products::DefaultQuantity, product.default_quantity)
        .value(
            Products::DefaultUnit,
            product.default_unit.as_ref().map(|unit| unit.0.as_str()),
        )
        .value(Products::UpdatedAt, Expr::current_timestamp())
        .and_where(Expr::col(Products::Id).eq(product.id.0))
        .to_owned()
}

fn delete_product_nutrients_statement(product_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(ProductNutrients::Table)
        .and_where(Expr::col(ProductNutrients::ProductId).eq(product_id))
        .to_owned()
}

fn delete_product_servings_statement(product_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(ProductServings::Table)
        .and_where(Expr::col(ProductServings::ProductId).eq(product_id))
        .to_owned()
}

fn soft_delete_product_statement(id: Uuid) -> UpdateStatement {
    Query::update()
        .table(Products::Table)
        .value(Products::DeletedAt, Expr::current_timestamp())
        .and_where(Expr::col(Products::Id).eq(id))
        .to_owned()
}

fn list_nutrients_statement() -> SelectStatement {
    Query::select()
        .columns([
            Nutrients::Code,
            Nutrients::Name,
            Nutrients::Unit,
            Nutrients::Category,
        ])
        .from(Nutrients::Table)
        .order_by(Nutrients::Code, Order::Asc)
        .to_owned()
}

fn find_nutrient_statement(code: &str) -> SelectStatement {
    Query::select()
        .columns([
            Nutrients::Code,
            Nutrients::Name,
            Nutrients::Unit,
            Nutrients::Category,
        ])
        .from(Nutrients::Table)
        .and_where(Expr::col(Nutrients::Code).eq(code))
        .to_owned()
}

fn list_units_statement() -> SelectStatement {
    Query::select()
        .columns([Units::Code, Units::Name, Units::Kind])
        .from(Units::Table)
        .order_by(Units::Code, Order::Asc)
        .to_owned()
}

fn list_mass_factors_statement() -> SelectStatement {
    Query::select()
        .columns([Units::Code, Units::CanonicalGrams])
        .from(Units::Table)
        .and_where(Expr::col(Units::CanonicalGrams).is_not_null())
        .to_owned()
}

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
        let (sql, values) = load_nutrients_statement(product_id).build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, ProductNutrientRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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
        let (sql, values) = load_servings_statement(product_id).build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, ProductServingRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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
        let (sql, values) =
            load_nutrients_for_products_statement(product_ids).build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, ProductNutrientWithProductRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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
        let (sql, values) =
            load_servings_for_products_statement(product_ids).build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, ProductServingWithProductRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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

    async fn load_summary_nutrients(
        &self,
        product_ids: &[Uuid],
    ) -> Result<HashMap<Uuid, Vec<ProductNutrient>>, NutritionError> {
        if product_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let (sql, values) =
            search_summary_nutrients_statement(product_ids).build_sqlx(PostgresQueryBuilder);
        let summary_rows = sqlx::query_as_with::<_, SearchNutrientRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
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

        // The three search queries stay raw: they rely on pg_trgm similarity,
        // text[] containment/overlap, and a history CTE with per-scope
        // parameter numbering. Rebuilding them in sea-query would obscure the
        // ranking logic without changing the Postgres-only SQL.
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
        let summary_nutrients_by_product = self.load_summary_nutrients(&product_ids).await?;

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
        // Raw by design: category search uses UNNEST plus pg_trgm similarity,
        // which sea-query does not model with enough clarity to justify a
        // rewrite.
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
        let (sql, values) = find_product_statement(id.0).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, ProductRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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
        let (sql, values) = existing_ids_statement(raw).build_sqlx(PostgresQueryBuilder);
        let rows: Vec<(Uuid,)> =
            sqlx::query_as_with::<_, (Uuid,), _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;
        Ok(rows.into_iter().map(|(id,)| ProductId(id)).collect())
    }

    async fn find_by_barcode(
        &self,
        barcode: &str,
        _user_id: Option<Uuid>,
    ) -> Result<Option<Product>, NutritionError> {
        let (sql, values) =
            find_product_by_barcode_statement(barcode).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, ProductRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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
        let (sql, values) = list_custom_foods_statement().build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, ProductRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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

        let (sql, values) = insert_product_statement(product).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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
                product.origin.source_code(),
                product.origin.source_id().unwrap_or_default(),
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
            let (sql, values) =
                insert_external_products_statement(chunk).build_sqlx(PostgresQueryBuilder);
            result.created += sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .execute(&mut *tx)
                .await?
                .rows_affected() as i64;

            // Intentionally raw: the bulk UPDATE ... FROM (VALUES ...) with a
            // ROW(...) IS DISTINCT FROM comparison is clearer and safer to keep
            // in its proven Postgres form than to reassemble through sea-query.
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
                row.push_bind(product.origin.source_code())
                    .push_bind(product.origin.source_id().unwrap_or_default())
                    .push_bind(product.origin.owner_id())
                    .push_bind(product.visibility.as_str())
                    .push_bind(product.origin.barcode().map(|barcode| barcode.0.as_str()))
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
            let (sql, values) =
                resolve_external_product_ids_statement(chunk).build_sqlx(PostgresQueryBuilder);
            let rows = sqlx::query_as_with::<_, (Uuid, String, String), _>(
                sqlx::AssertSqlSafe(sql.as_str()),
                values,
            )
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
                        product.origin.source_code().to_owned(),
                        product.origin.source_id().unwrap_or_default().to_owned(),
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

        let (sql, values) = update_product_statement(product).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) =
            delete_product_nutrients_statement(product.id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) =
            delete_product_servings_statement(product.id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        insert_product_nutrients(&mut tx, product.id.0, &product.nutrients).await?;
        insert_product_servings(&mut tx, product.id.0, &product.servings).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: ProductId) -> Result<(), NutritionError> {
        let (sql, values) = soft_delete_product_statement(id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

// ─── Row Types ─────────────────────────────────────────────────

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
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
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct ProductNutrientRow {
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct ProductNutrientWithProductRow {
    product_id: Uuid,
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct SearchNutrientRow {
    product_id: Uuid,
    amount_per_100g: Decimal,
    source: Option<String>,
    confidence: Option<String>,
    code: String,
    unit: String,
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct ProductServingRow {
    unit: String,
    grams_per_unit: Decimal,
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct ProductServingWithProductRow {
    product_id: Uuid,
    unit: String,
    grams_per_unit: Decimal,
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct CategorySuggestionRow {
    value: String,
    count: i64,
}

fn product_row_to_product(
    row: ProductRow,
    nutrients: Vec<ProductNutrient>,
    servings: Vec<ProductServing>,
) -> Result<Product, NutritionError> {
    let origin = match row.source.as_str() {
        "USER" => {
            let user_id = row.user_id.ok_or_else(|| {
                NutritionError::Internal("custom product row is missing user_id".into())
            })?;
            if row.source_id.is_some() || row.barcode.is_some() {
                return Err(NutritionError::Internal(
                    "custom product row contains external identity fields".into(),
                ));
            }
            ProductOrigin::Custom { user_id }
        }
        _ => {
            let source = row
                .source
                .parse::<ExternalSource>()
                .map_err(NutritionError::Internal)?;
            if row.user_id.is_some() {
                return Err(NutritionError::Internal(
                    "external product row contains user_id".into(),
                ));
            }
            let source_id = ExternalProductId::new(row.source_id.ok_or_else(|| {
                NutritionError::Internal("external product row is missing source_id".into())
            })?)
            .map_err(|_| {
                NutritionError::Internal("external product row has a blank source_id".into())
            })?;
            ProductOrigin::External {
                source,
                source_id,
                barcode: row.barcode.map(Barcode),
            }
        }
    };

    Ok(Product {
        id: ProductId(row.id),
        origin,
        visibility: row
            .visibility
            .parse::<ProductVisibility>()
            .map_err(NutritionError::Internal)?,
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

#[cfg(test)]
async fn legacy_load_nutrients(
    pool: &PgPool,
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
    .fetch_all(pool)
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

#[cfg(test)]
async fn legacy_load_servings(
    pool: &PgPool,
    product_id: Uuid,
) -> Result<Vec<ProductServing>, NutritionError> {
    let rows = sqlx::query_as::<_, ProductServingRow>(
        "SELECT unit, grams_per_unit FROM product_servings WHERE product_id = $1 ORDER BY position",
    )
    .bind(product_id)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| ProductServing {
            unit: UnitCode(r.unit),
            grams_per_unit: r.grams_per_unit,
        })
        .collect())
}

#[cfg(test)]
async fn legacy_load_nutrients_for_products(
    pool: &PgPool,
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
    .fetch_all(pool)
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

#[cfg(test)]
async fn legacy_load_servings_for_products(
    pool: &PgPool,
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
    .fetch_all(pool)
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

#[cfg(test)]
async fn legacy_load_summary_nutrients(
    pool: &PgPool,
    product_ids: &[Uuid],
) -> Result<HashMap<Uuid, Vec<ProductNutrient>>, NutritionError> {
    let summary_rows = sqlx::query_as::<_, SearchNutrientRow>(
        r#"
        SELECT pn.product_id, pn.amount_per_100g, pn.source, pn.confidence, n.code, n.unit
        FROM product_nutrients pn
        JOIN nutrients n ON n.id = pn.nutrient_id
        WHERE pn.product_id = ANY($1)
          AND n.code = ANY($2)
        "#,
    )
    .bind(product_ids)
    .bind(SEARCH_NUTRIENT_CODES.as_slice())
    .fetch_all(pool)
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
    Ok(by_product)
}

#[cfg(test)]
async fn legacy_find_by_id(
    pool: &PgPool,
    id: ProductId,
) -> Result<Option<Product>, NutritionError> {
    let row = sqlx::query_as::<_, ProductRow>(
        r#"
        SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
               categories, default_quantity, default_unit,
               created_at, updated_at
        FROM products WHERE id = $1 AND deleted_at IS NULL
        "#,
    )
    .bind(id.0)
    .fetch_optional(pool)
    .await?;

    match row {
        Some(r) => {
            let nutrients = legacy_load_nutrients(pool, r.id).await?;
            let servings = legacy_load_servings(pool, r.id).await?;
            Ok(Some(product_row_to_product(r, nutrients, servings)?))
        }
        None => Ok(None),
    }
}

#[cfg(test)]
async fn legacy_existing_ids(
    pool: &PgPool,
    ids: &[ProductId],
) -> Result<HashSet<ProductId>, sqlx::Error> {
    if ids.is_empty() {
        return Ok(HashSet::new());
    }
    let raw: Vec<Uuid> = ids.iter().map(|id| id.0).collect();
    let rows: Vec<(Uuid,)> =
        sqlx::query_as("SELECT id FROM products WHERE id = ANY($1) AND deleted_at IS NULL")
            .bind(&raw)
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|(id,)| ProductId(id)).collect())
}

#[cfg(test)]
async fn legacy_find_by_barcode(
    pool: &PgPool,
    barcode: &str,
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
    .fetch_optional(pool)
    .await?;

    match row {
        Some(r) => {
            let nutrients = legacy_load_nutrients(pool, r.id).await?;
            let servings = legacy_load_servings(pool, r.id).await?;
            Ok(Some(product_row_to_product(r, nutrients, servings)?))
        }
        None => Ok(None),
    }
}

#[cfg(test)]
async fn legacy_list_custom_foods(pool: &PgPool) -> Result<Vec<Product>, NutritionError> {
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
    .fetch_all(pool)
    .await?;

    if rows.is_empty() {
        return Ok(Vec::new());
    }

    let product_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
    let nutrients_by_product = legacy_load_nutrients_for_products(pool, &product_ids).await?;
    let servings_by_product = legacy_load_servings_for_products(pool, &product_ids).await?;

    rows.into_iter()
        .map(|r| {
            let nutrients = nutrients_by_product.get(&r.id).cloned().unwrap_or_default();
            let servings = servings_by_product.get(&r.id).cloned().unwrap_or_default();
            product_row_to_product(r, nutrients, servings)
        })
        .collect()
}

#[cfg(test)]
async fn legacy_create(pool: &PgPool, product: &Product) -> Result<(), NutritionError> {
    let mut tx = pool.begin().await?;

    sqlx::query(
        r#"
        INSERT INTO products (id, source, source_id, user_id, visibility, barcode, name,
                              brand, categories, default_quantity, default_unit)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        "#,
    )
    .bind(product.id.0)
    .bind(product.origin.source_code())
    .bind(product.origin.source_id())
    .bind(product.origin.owner_id())
    .bind(product.visibility.as_str())
    .bind(product.origin.barcode().map(|barcode| barcode.0.as_str()))
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

#[cfg(test)]
async fn legacy_upsert_external_many(
    pool: &PgPool,
    batch: &ExternalProductBatch,
) -> Result<ProductUpsertResult, NutritionError> {
    let products = batch.products();
    if products.is_empty() {
        return Ok(ProductUpsertResult::default());
    }

    let mut tx = pool.begin().await?;
    sqlx::query(
        "LOCK TABLE products, product_nutrients, product_servings IN SHARE ROW EXCLUSIVE MODE",
    )
    .execute(&mut *tx)
    .await?;

    let mut products: Vec<&Product> = products.iter().collect();
    products.sort_by_key(|product| {
        (
            product.origin.source_code(),
            product.origin.source_id().unwrap_or_default(),
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
        sqlx::query_as::<_, (String, Uuid)>("SELECT code, id FROM nutrients WHERE code = ANY($1)")
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
                .push_bind(product.origin.source_code())
                .push_bind(product.origin.source_id().unwrap_or_default())
                .push_bind(product.origin.owner_id())
                .push_bind(product.visibility.as_str())
                .push_bind(product.origin.barcode().map(|barcode| barcode.0.as_str()))
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
            row.push_bind(product.origin.source_code())
                .push_bind(product.origin.source_id().unwrap_or_default())
                .push_bind(product.origin.owner_id())
                .push_bind(product.visibility.as_str())
                .push_bind(product.origin.barcode().map(|barcode| barcode.0.as_str()))
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
                .push_bind(product.origin.source_code())
                .push(", ")
                .push_bind(product.origin.source_id().unwrap_or_default())
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
                    product.origin.source_code().to_owned(),
                    product.origin.source_id().unwrap_or_default().to_owned(),
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
    result.servings_written = replace_product_servings(&mut tx, &products, &product_ids).await?;

    tx.commit().await?;
    Ok(result)
}

#[cfg(test)]
async fn legacy_update(pool: &PgPool, product: &Product) -> Result<(), NutritionError> {
    let mut tx = pool.begin().await?;

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

#[cfg(test)]
async fn legacy_delete(pool: &PgPool, id: ProductId) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE products SET deleted_at = now() WHERE id = $1")
        .bind(id.0)
        .execute(pool)
        .await?;
    Ok(())
}

#[cfg(test)]
async fn legacy_list_nutrients(pool: &PgPool) -> Result<Vec<Nutrient>, sqlx::Error> {
    let rows = sqlx::query_as::<_, NutrientRow>(
        "SELECT code, name, unit, category FROM nutrients ORDER BY code",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(nutrient_row_to_nutrient).collect())
}

#[cfg(test)]
async fn legacy_find_nutrient(pool: &PgPool, code: &str) -> Result<Option<Nutrient>, sqlx::Error> {
    let row = sqlx::query_as::<_, NutrientRow>(
        "SELECT code, name, unit, category FROM nutrients WHERE code = $1",
    )
    .bind(code)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(nutrient_row_to_nutrient))
}

#[cfg(test)]
async fn legacy_list_units(pool: &PgPool) -> Result<Vec<(UnitCode, String, String)>, sqlx::Error> {
    let rows = sqlx::query_as::<_, UnitRow>("SELECT code, name, kind FROM units ORDER BY code")
        .fetch_all(pool)
        .await?;

    Ok(rows
        .into_iter()
        .map(|r| (UnitCode(r.code), r.name, r.kind))
        .collect())
}

#[cfg(test)]
async fn legacy_list_mass_factors(pool: &PgPool) -> Result<Vec<(String, Decimal)>, sqlx::Error> {
    let rows = sqlx::query_as::<_, MassFactorRow>(
        "SELECT code, canonical_grams FROM units WHERE canonical_grams IS NOT NULL",
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| (r.code, r.canonical_grams))
        .collect())
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
        let (sql, values) = list_nutrients_statement().build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, NutrientRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        Ok(rows.into_iter().map(nutrient_row_to_nutrient).collect())
    }

    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, NutritionError> {
        let (sql, values) = find_nutrient_statement(code).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, NutrientRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        Ok(row.map(nutrient_row_to_nutrient))
    }
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
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
        let (sql, values) = list_units_statement().build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, UnitRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_all(&self.pool)
            .await?;

        Ok(rows
            .into_iter()
            .map(|r| (UnitCode(r.code), r.name, r.kind))
            .collect())
    }

    async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, NutritionError> {
        let (sql, values) = list_mass_factors_statement().build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, MassFactorRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        Ok(rows
            .into_iter()
            .map(|r| (r.code, r.canonical_grams))
            .collect())
    }
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct UnitRow {
    code: String,
    name: String,
    kind: String,
}

#[derive(sqlx::FromRow)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct MassFactorRow {
    code: String,
    canonical_grams: Decimal,
}

// The four child bulk helpers below stay raw by design: they rely on Postgres
// UNNEST of parallel typed arrays plus the insert/count validation contract.
// They are shared by the sea-query parent writes and the test-only legacy
// oracles.
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn timestamp(day: u32, hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 6, day, hour, 0, 0).unwrap()
    }

    fn assert_recent(timestamp: DateTime<Utc>, label: &str) {
        let age = Utc::now().signed_duration_since(timestamp);
        assert!(
            age.num_seconds().abs() < 300,
            "{label} should be current, got {timestamp}"
        );
    }

    fn normalize_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    fn sql_contains(sql: &str, needle: &str) -> bool {
        str::contains(sql, needle)
    }

    fn sql_match_count(sql: &str, needle: &str) -> usize {
        str::matches(sql, needle).count()
    }

    fn normalized(mut product: Product) -> Product {
        product
            .nutrients
            .sort_by(|left, right| left.nutrient_code.0.cmp(&right.nutrient_code.0));
        product
            .servings
            .sort_by(|left, right| left.unit.0.cmp(&right.unit.0));
        product
    }

    fn normalized_option(product: Option<Product>) -> Option<Product> {
        product.map(normalized)
    }

    fn sorted_nutrients(mut nutrients: Vec<ProductNutrient>) -> Vec<ProductNutrient> {
        nutrients.sort_by(|left, right| left.nutrient_code.0.cmp(&right.nutrient_code.0));
        nutrients
    }

    fn custom_origin(user_id: Uuid) -> ProductOrigin {
        ProductOrigin::Custom { user_id }
    }

    fn external_origin(source_id: &str, barcode: Option<&str>) -> ProductOrigin {
        ProductOrigin::External {
            source: ExternalSource::Off,
            source_id: ExternalProductId::new(source_id).expect("valid external product id"),
            barcode: barcode.map(|barcode| Barcode(barcode.to_owned())),
        }
    }

    fn nutrient(
        code: &str,
        amount: i64,
        unit: &str,
        source: Option<&str>,
        confidence: Option<NutrientConfidence>,
    ) -> ProductNutrient {
        ProductNutrient {
            nutrient_code: NutrientCode(code.to_owned()),
            amount_per_100g: AmountPer100g::new(Decimal::from(amount)).expect("valid amount"),
            unit: UnitCode(unit.to_owned()),
            source: source.map(str::to_owned),
            confidence,
        }
    }

    fn serving(unit: &str, grams_per_unit: i64) -> ProductServing {
        ProductServing {
            unit: UnitCode(unit.to_owned()),
            grams_per_unit: Decimal::from(grams_per_unit),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn product_fixture(
        id: Uuid,
        origin: ProductOrigin,
        name: &str,
        brand: Option<&str>,
        categories: &[&str],
        default_quantity: Option<i64>,
        default_unit: Option<&str>,
        nutrients: Vec<ProductNutrient>,
        servings: Vec<ProductServing>,
        created_at: DateTime<Utc>,
        updated_at: DateTime<Utc>,
    ) -> Product {
        Product {
            id: ProductId(id),
            origin,
            visibility: ProductVisibility::Global,
            name: ProductName::new(name).expect("valid product name"),
            brand: brand.map(|brand| Brand(brand.to_owned())),
            categories: categories
                .iter()
                .map(|category| Category((*category).to_owned()))
                .collect(),
            default_quantity: default_quantity.map(Decimal::from),
            default_unit: default_unit.map(|unit| UnitCode(unit.to_owned())),
            nutrients,
            servings,
            created_at,
            updated_at,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn external_product(
        id: Uuid,
        source_id: &str,
        barcode: Option<&str>,
        name: &str,
        categories: &[&str],
        nutrients: Vec<ProductNutrient>,
        servings: Vec<ProductServing>,
        created_at: DateTime<Utc>,
    ) -> Product {
        product_fixture(
            id,
            external_origin(source_id, barcode),
            name,
            Some("Bulk brand"),
            categories,
            Some(100),
            Some("g"),
            nutrients,
            servings,
            created_at,
            created_at,
        )
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

    async fn seed_product(pool: &PgPool, product: &Product) -> ProductRow {
        sqlx::query(
            r#"
            INSERT INTO products (
                id, source, source_id, user_id, visibility, barcode, name, brand, categories,
                default_quantity, default_unit, created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            "#,
        )
        .bind(product.id.0)
        .bind(product.origin.source_code())
        .bind(product.origin.source_id())
        .bind(product.origin.owner_id())
        .bind(product.visibility.as_str())
        .bind(product.origin.barcode().map(|barcode| barcode.0.as_str()))
        .bind(product.name.as_str())
        .bind(product.brand.as_ref().map(|brand| brand.0.as_str()))
        .bind(
            product
                .categories
                .iter()
                .map(|category| category.0.clone())
                .collect::<Vec<_>>(),
        )
        .bind(product.default_quantity)
        .bind(product.default_unit.as_ref().map(|unit| unit.0.as_str()))
        .bind(product.created_at)
        .bind(product.updated_at)
        .execute(pool)
        .await
        .expect("seed product");

        for nutrient in &product.nutrients {
            let inserted = sqlx::query(
                r#"
                INSERT INTO product_nutrients (
                    product_id, nutrient_id, amount_per_100g, source, confidence
                )
                SELECT $1, id, $3, $4, $5
                FROM nutrients
                WHERE code = $2
                "#,
            )
            .bind(product.id.0)
            .bind(&nutrient.nutrient_code.0)
            .bind(nutrient.amount_per_100g.value())
            .bind(nutrient.source.as_deref())
            .bind(
                nutrient
                    .confidence
                    .as_ref()
                    .map(|confidence| confidence.as_str()),
            )
            .execute(pool)
            .await
            .expect("seed product nutrient");
            assert_eq!(
                inserted.rows_affected(),
                1,
                "seed nutrient code must exist: {}",
                nutrient.nutrient_code.0
            );
        }

        for (position, serving) in product.servings.iter().enumerate() {
            sqlx::query(
                r#"
                INSERT INTO product_servings (product_id, unit, grams_per_unit, position)
                VALUES ($1, $2, $3, $4)
                "#,
            )
            .bind(product.id.0)
            .bind(serving.unit.0.as_str())
            .bind(serving.grams_per_unit)
            .bind(position as i32)
            .execute(pool)
            .await
            .expect("seed product serving");
        }

        fetch_product_row(pool, product.id.0)
            .await
            .expect("seeded product row")
    }

    async fn insert_serving_row(
        pool: &PgPool,
        product_id: Uuid,
        serving: &ProductServing,
        position: i32,
    ) {
        sqlx::query(
            r#"
            INSERT INTO product_servings (product_id, unit, grams_per_unit, position)
            VALUES ($1, $2, $3, $4)
            "#,
        )
        .bind(product_id)
        .bind(serving.unit.0.as_str())
        .bind(serving.grams_per_unit)
        .bind(position)
        .execute(pool)
        .await
        .expect("insert product serving row");
    }

    async fn soft_delete_row(pool: &PgPool, id: Uuid, deleted_at: DateTime<Utc>) {
        sqlx::query("UPDATE products SET deleted_at = $2 WHERE id = $1")
            .bind(id)
            .bind(deleted_at)
            .execute(pool)
            .await
            .expect("soft delete seeded product");
    }

    async fn fetch_product_row(pool: &PgPool, id: Uuid) -> Option<ProductRow> {
        sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit,
                   created_at, updated_at
            FROM products WHERE id = $1
            "#,
        )
        .bind(id)
        .fetch_optional(pool)
        .await
        .expect("fetch product row")
    }

    async fn product_deleted_at(pool: &PgPool, id: Uuid) -> Option<DateTime<Utc>> {
        sqlx::query_scalar("SELECT deleted_at FROM products WHERE id = $1")
            .bind(id)
            .fetch_one(pool)
            .await
            .expect("fetch product deleted_at")
    }

    async fn fetch_product_row_by_identity(
        pool: &PgPool,
        source: &str,
        source_id: &str,
    ) -> Option<ProductRow> {
        sqlx::query_as::<_, ProductRow>(
            r#"
            SELECT id, source, source_id, user_id, visibility, barcode, name, brand,
                   categories, default_quantity, default_unit,
                   created_at, updated_at
            FROM products WHERE source = $1 AND source_id = $2
            "#,
        )
        .bind(source)
        .bind(source_id)
        .fetch_optional(pool)
        .await
        .expect("fetch product row by identity")
    }

    async fn nutrient_shapes(
        pool: &PgPool,
        product_id: Uuid,
    ) -> Vec<(String, Decimal, Option<String>, Option<String>)> {
        sqlx::query_as(
            r#"
            SELECT nutrient.code, product_nutrient.amount_per_100g,
                   product_nutrient.source, product_nutrient.confidence
            FROM product_nutrients AS product_nutrient
            JOIN nutrients AS nutrient ON nutrient.id = product_nutrient.nutrient_id
            WHERE product_nutrient.product_id = $1
            ORDER BY nutrient.code
            "#,
        )
        .bind(product_id)
        .fetch_all(pool)
        .await
        .expect("fetch product nutrient shapes")
    }

    async fn serving_shapes(pool: &PgPool, product_id: Uuid) -> Vec<(String, Decimal, i32)> {
        sqlx::query_as(
            r#"
            SELECT unit, grams_per_unit, position
            FROM product_servings
            WHERE product_id = $1
            ORDER BY position
            "#,
        )
        .bind(product_id)
        .fetch_all(pool)
        .await
        .expect("fetch product serving shapes")
    }

    fn sorted_mass_factors(mut factors: Vec<(String, Decimal)>) -> Vec<(String, Decimal)> {
        factors.sort_by(|left, right| left.0.cmp(&right.0));
        factors
    }

    #[test]
    fn bulk_load_statements_use_single_array_binds() {
        let ids = vec![Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];

        let (sql, values) =
            load_nutrients_for_products_statement(&ids).build_sqlx(PostgresQueryBuilder);
        assert_eq!(
            values.0.iter().count(),
            1,
            "nutrient bulk load must bind one uuid[] array: {sql}"
        );
        assert!(
            matches!(
                values.0.iter().next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::Uuid,
                    Some(values)
                )) if values.len() == 3
            ),
            "nutrient bulk load must bind all ids without truncation: {sql}"
        );

        let (sql, values) =
            load_servings_for_products_statement(&ids).build_sqlx(PostgresQueryBuilder);
        assert_eq!(
            values.0.iter().count(),
            1,
            "serving bulk load must bind one uuid[] array: {sql}"
        );
        assert!(
            matches!(
                values.0.iter().next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::Uuid,
                    Some(values)
                )) if values.len() == 3
            ),
            "serving bulk load must bind all ids without truncation: {sql}"
        );

        let (sql, values) = existing_ids_statement(ids).build_sqlx(PostgresQueryBuilder);
        assert_eq!(
            values.0.iter().count(),
            1,
            "existing_ids must bind one uuid[] array: {sql}"
        );
        assert!(
            matches!(
                values.0.iter().next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::Uuid,
                    Some(values)
                )) if values.len() == 3
            ),
            "existing_ids must bind all ids without truncation: {sql}"
        );
    }

    #[test]
    fn serving_statements_order_by_position() {
        let product_id = Uuid::new_v4();

        let (sql, values) = load_servings_statement(product_id).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);
        assert!(
            sql.ends_with(r#"ORDER BY "position" ASC"#),
            "single-product servings must order by position: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            1,
            "single-product servings must bind one product id: {sql}"
        );

        let (sql, values) =
            load_servings_for_products_statement(&[product_id]).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);
        assert!(
            sql.ends_with(r#"ORDER BY "product_id" ASC, "position" ASC"#),
            "bulk servings must order by product_id then position: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            1,
            "bulk servings must bind one uuid[] product id array: {sql}"
        );
    }

    #[test]
    fn search_summary_statement_uses_uuid_and_text_array_binds() {
        let ids = vec![Uuid::new_v4(), Uuid::new_v4()];
        let (sql, values) =
            search_summary_nutrients_statement(&ids).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert_eq!(
            values.0.iter().count(),
            2,
            "search summary must bind two arrays: {sql}"
        );
        let mut values = values.0.iter();
        assert!(
            matches!(
                values.next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::Uuid,
                    Some(ids)
                )) if ids.len() == 2
            ),
            "search summary must bind a uuid[] product ids array: {sql}"
        );
        assert!(
            matches!(
                values.next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::String,
                    Some(codes)
                )) if codes.len() == SEARCH_NUTRIENT_CODES.len()
            ),
            "search summary must bind one text[] nutrient codes array: {sql}"
        );
    }

    #[test]
    fn external_upsert_statements_use_conflict_target_and_tuple_in() {
        let created_at = timestamp(1, 8);
        let first = external_product(
            Uuid::new_v4(),
            "statement-first",
            None,
            "Statement first",
            &[],
            vec![],
            vec![],
            created_at,
        );
        let second = external_product(
            Uuid::new_v4(),
            "statement-second",
            None,
            "Statement second",
            &[],
            vec![],
            vec![],
            created_at,
        );
        let products = vec![&first, &second];

        let (sql, values) =
            insert_external_products_statement(&products).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);
        assert!(
            sql_contains(&sql, r#"ON CONFLICT ("source", "source_id") DO NOTHING"#),
            "external insert must use the source/source_id conflict target: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            22,
            "two products must bind eleven columns each: {sql}"
        );

        let (sql, values) =
            resolve_external_product_ids_statement(&products).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);
        assert!(
            sql_contains(&sql, r#"("source", "source_id") IN (($1, $2), ($3, $4))"#),
            "identity resolve must use a tuple IN list: {sql}"
        );
        assert!(
            sql.ends_with(r#"ORDER BY "source" ASC, "source_id" ASC"#),
            "identity resolve must remain deterministic: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            4,
            "identity resolve must bind two values per product: {sql}"
        );
    }

    #[test]
    fn upsert_chunk_boundary_statements_bind_every_product() {
        assert_eq!(
            PRODUCT_UPSERT_CHUNK_SIZE, 1_000,
            "the upsert chunk size is a pinned persistence contract"
        );
        let created_at = timestamp(1, 8);
        let products = (0..=PRODUCT_UPSERT_CHUNK_SIZE)
            .map(|index| {
                external_product(
                    Uuid::new_v4(),
                    &format!("chunk-boundary-{index}"),
                    None,
                    "Chunk boundary product",
                    &[],
                    vec![],
                    vec![],
                    created_at,
                )
            })
            .collect::<Vec<_>>();
        let references = products.iter().collect::<Vec<_>>();
        let chunks = references
            .chunks(PRODUCT_UPSERT_CHUNK_SIZE)
            .collect::<Vec<_>>();

        assert_eq!(
            chunks.iter().map(|chunk| chunk.len()).collect::<Vec<_>>(),
            vec![PRODUCT_UPSERT_CHUNK_SIZE, 1],
            "one product over the constant must produce a full chunk and a remainder"
        );

        let mut insert_binds = 0;
        let mut resolve_binds = 0;
        for chunk in &chunks {
            let (_, values) =
                insert_external_products_statement(chunk).build_sqlx(PostgresQueryBuilder);
            let chunk_insert_binds = values.0.iter().count();
            assert_eq!(
                chunk_insert_binds,
                11 * chunk.len(),
                "insert must bind eleven columns per product in a {}-product chunk",
                chunk.len()
            );
            insert_binds += chunk_insert_binds;

            let (sql, values) =
                resolve_external_product_ids_statement(chunk).build_sqlx(PostgresQueryBuilder);
            let chunk_resolve_binds = values.0.iter().count();
            assert_eq!(
                chunk_resolve_binds,
                2 * chunk.len(),
                "identity resolve must bind two values per product in a {}-product chunk",
                chunk.len()
            );
            let sql = normalize_sql(&sql);
            assert_eq!(
                sql_match_count(&sql, "), (") + 1,
                chunk.len(),
                "identity resolve must contain one tuple per product: {sql}"
            );
            resolve_binds += chunk_resolve_binds;
        }

        assert_eq!(
            insert_binds,
            11 * (PRODUCT_UPSERT_CHUNK_SIZE + 1),
            "chunked inserts must bind every product across the boundary"
        );
        assert_eq!(
            resolve_binds,
            2 * (PRODUCT_UPSERT_CHUNK_SIZE + 1),
            "chunked identity resolves must bind every identity across the boundary"
        );
    }

    #[test]
    fn update_and_delete_statements_use_current_timestamp_and_target_one_id() {
        let created_at = timestamp(1, 8);
        let product = product_fixture(
            Uuid::new_v4(),
            custom_origin(Uuid::new_v4()),
            "Timestamp product",
            Some("Brand"),
            &["category"],
            Some(100),
            Some("g"),
            vec![],
            vec![],
            created_at,
            created_at,
        );

        let (sql, values) = update_product_statement(&product).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);
        assert!(
            sql_contains(&sql, r#""updated_at" = CURRENT_TIMESTAMP"#),
            "update must use CURRENT_TIMESTAMP: {sql}"
        );
        assert_eq!(
            sql_match_count(&sql, " WHERE "),
            1,
            "update must have exactly one WHERE clause: {sql}"
        );
        let where_tail = sql
            .rsplit_once(" WHERE ")
            .map(|(_, tail)| tail)
            .expect("update statement must have a WHERE clause");
        assert_eq!(
            where_tail, r#""id" = $6"#,
            "id must be the only update predicate: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            6,
            "update must bind five editable columns and id only: {sql}"
        );

        let (sql, values) =
            soft_delete_product_statement(product.id.0).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);
        assert_eq!(
            sql,
            r#"UPDATE "products" SET "deleted_at" = CURRENT_TIMESTAMP WHERE "id" = $1"#
        );
        assert_eq!(values.0.iter().count(), 1, "delete must bind one id: {sql}");
    }

    #[sqlx::test]
    async fn find_by_id_matches_legacy_for_live_soft_deleted_and_absent(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-find-by-id").await;
        let created_at = timestamp(1, 8);
        let updated_at = timestamp(1, 9);
        let live = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Live product",
            Some("Live brand"),
            &["breakfast", "snacks"],
            Some(100),
            Some("g"),
            vec![
                nutrient(
                    "ENERGY_KCAL",
                    120,
                    "kcal",
                    Some("USER"),
                    Some(NutrientConfidence::Approved),
                ),
                nutrient("PROTEIN_G", 8, "g", None, None),
            ],
            vec![serving("cup", 240), serving("slice", 30)],
            created_at,
            updated_at,
        );
        seed_product(&pool, &live).await;

        let deleted = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Deleted product",
            None,
            &["deleted"],
            None,
            None,
            vec![nutrient("FAT_G", 3, "g", None, None)],
            vec![serving("piece", 50)],
            created_at,
            updated_at,
        );
        seed_product(&pool, &deleted).await;
        soft_delete_row(&pool, deleted.id.0, timestamp(1, 10)).await;

        let repository = PostgresProductRepository::new(pool.clone());
        let missing = ProductId::new();

        for (id, label) in [
            (live.id, "live"),
            (deleted.id, "soft-deleted"),
            (missing, "absent"),
        ] {
            let expected = normalized_option(legacy_find_by_id(&pool, id).await.expect("legacy"));
            let actual = normalized_option(
                repository
                    .find_by_id(id)
                    .await
                    .expect("repository find_by_id"),
            );
            assert_eq!(actual, expected, "{label}: repository must match legacy");
        }

        let found = repository
            .find_by_id(live.id)
            .await
            .expect("find live")
            .expect("live product exists");
        assert_eq!(normalized(found), normalized(live.clone()));
    }

    #[sqlx::test]
    async fn serving_loads_return_position_order_without_normalizing(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-serving-order").await;
        let created_at = timestamp(2, 8);
        let product = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Reversed serving product",
            None,
            &["serving-order"],
            None,
            None,
            vec![],
            vec![],
            created_at,
            created_at,
        );
        seed_product(&pool, &product).await;

        // Insert position 1 first so a query without ORDER BY returns the
        // physical insertion order and fails the position-order assertion.
        insert_serving_row(&pool, product.id.0, &serving("cup", 240), 1).await;
        insert_serving_row(&pool, product.id.0, &serving("slice", 30), 0).await;

        let expected_servings = vec![serving("slice", 30), serving("cup", 240)];
        let repository = PostgresProductRepository::new(pool.clone());

        let found = repository
            .find_by_id(product.id)
            .await
            .expect("find product by id")
            .expect("product exists");
        assert_eq!(
            found.servings, expected_servings,
            "find_by_id must return servings in position order without normalization"
        );

        let custom_foods = repository
            .list_custom_foods()
            .await
            .expect("list custom foods");
        assert_eq!(custom_foods.len(), 1, "one custom product is seeded");
        assert_eq!(
            custom_foods[0].servings, expected_servings,
            "list_custom_foods must return servings in position order without normalization"
        );
    }

    #[sqlx::test]
    async fn find_by_barcode_matches_legacy_for_live_soft_deleted_and_absent(pool: PgPool) {
        let created_at = timestamp(2, 8);
        let live = external_product(
            Uuid::new_v4(),
            "barcode-live",
            Some("987654321"),
            "Barcode live",
            &["scan"],
            vec![nutrient("ENERGY_KCAL", 100, "kcal", Some("OFF"), None)],
            vec![serving("packet", 25)],
            created_at,
        );
        seed_product(&pool, &live).await;

        let deleted = external_product(
            Uuid::new_v4(),
            "barcode-deleted",
            Some("987654322"),
            "Barcode deleted",
            &["scan"],
            vec![],
            vec![],
            created_at,
        );
        seed_product(&pool, &deleted).await;
        soft_delete_row(&pool, deleted.id.0, timestamp(2, 9)).await;

        let repository = PostgresProductRepository::new(pool.clone());
        for (barcode, label) in [
            ("987654321", "live"),
            ("987654322", "soft-deleted"),
            ("000000000", "absent"),
        ] {
            let expected = normalized_option(
                legacy_find_by_barcode(&pool, barcode)
                    .await
                    .expect("legacy find_by_barcode"),
            );
            let actual = normalized_option(
                repository
                    .find_by_barcode(barcode, None)
                    .await
                    .expect("repository find_by_barcode"),
            );
            assert_eq!(actual, expected, "{label}: repository must match legacy");
        }

        let found = repository
            .find_by_barcode("987654321", None)
            .await
            .expect("find barcode")
            .expect("live barcode exists");
        assert_eq!(normalized(found), normalized(live.clone()));
    }

    #[sqlx::test]
    async fn list_custom_foods_orders_and_attaches_children(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-list-custom").await;
        let first = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "First custom",
            None,
            &["first"],
            None,
            None,
            vec![nutrient("ENERGY_KCAL", 10, "kcal", Some("USER"), None)],
            vec![serving("cup", 100)],
            timestamp(3, 8),
            timestamp(3, 8),
        );
        let second = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Second custom",
            Some("Second brand"),
            &["second"],
            Some(50),
            Some("g"),
            vec![
                nutrient("PROTEIN_G", 2, "g", None, None),
                nutrient("CARBS_G", 3, "g", None, None),
            ],
            vec![serving("slice", 30), serving("cup", 120)],
            timestamp(3, 9),
            timestamp(3, 9),
        );
        let third = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Third custom",
            None,
            &["third"],
            None,
            None,
            vec![nutrient(
                "FAT_G",
                4,
                "g",
                None,
                Some(NutrientConfidence::Derived),
            )],
            vec![serving("piece", 40)],
            timestamp(3, 10),
            timestamp(3, 10),
        );
        let deleted = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Deleted custom",
            None,
            &["deleted"],
            None,
            None,
            vec![],
            vec![],
            timestamp(3, 11),
            timestamp(3, 11),
        );
        let external = external_product(
            Uuid::new_v4(),
            "list-custom-external",
            None,
            "External product",
            &["external"],
            vec![],
            vec![],
            timestamp(3, 12),
        );

        for product in [&first, &second, &third, &deleted, &external] {
            seed_product(&pool, product).await;
        }
        soft_delete_row(&pool, deleted.id.0, timestamp(3, 13)).await;

        let repository = PostgresProductRepository::new(pool.clone());
        let expected = vec![
            normalized(third.clone()),
            normalized(second.clone()),
            normalized(first.clone()),
        ];
        let actual = repository
            .list_custom_foods()
            .await
            .expect("repository list_custom_foods")
            .into_iter()
            .map(normalized)
            .collect::<Vec<_>>();
        let legacy = legacy_list_custom_foods(&pool)
            .await
            .expect("legacy list_custom_foods")
            .into_iter()
            .map(normalized)
            .collect::<Vec<_>>();

        assert_eq!(
            actual.iter().map(|product| product.id).collect::<Vec<_>>(),
            vec![third.id, second.id, first.id],
            "custom foods must be ordered by created_at DESC"
        );
        assert_eq!(actual, expected, "repository list must contain seeded rows");
        assert_eq!(actual, legacy, "repository list must match legacy");
        assert!(
            actual
                .iter()
                .all(|product| matches!(product.origin, ProductOrigin::Custom { .. })),
            "list_custom_foods must exclude external rows"
        );
        assert!(
            actual.iter().all(|product| product.id != deleted.id),
            "list_custom_foods must exclude soft-deleted rows"
        );

        let second_row = actual
            .iter()
            .find(|product| product.id == second.id)
            .expect("second custom present");
        assert_eq!(
            sorted_nutrients(second_row.nutrients.clone()),
            sorted_nutrients(second.nutrients.clone())
        );
        assert_eq!(
            serving_shapes(&pool, second.id.0).await,
            vec![
                ("slice".to_owned(), Decimal::from(30), 0),
                ("cup".to_owned(), Decimal::from(120), 1),
            ],
            "custom list must attach servings in position order"
        );
    }

    #[sqlx::test]
    async fn existing_ids_matches_legacy_without_truncating_multi_id_batches(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-existing-ids").await;
        let mut live_ids = Vec::new();
        for index in 0..6 {
            let product = product_fixture(
                Uuid::new_v4(),
                custom_origin(user_id),
                &format!("Existing {index}"),
                None,
                &[],
                None,
                None,
                vec![],
                vec![],
                timestamp(4, index),
                timestamp(4, index),
            );
            seed_product(&pool, &product).await;
            live_ids.push(product.id);
        }

        let deleted = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Existing deleted",
            None,
            &[],
            None,
            None,
            vec![],
            vec![],
            timestamp(4, 20),
            timestamp(4, 20),
        );
        seed_product(&pool, &deleted).await;
        soft_delete_row(&pool, deleted.id.0, timestamp(4, 21)).await;

        let missing = ProductId::new();
        let mut queried = live_ids.clone();
        queried.push(live_ids[0]);
        queried.push(deleted.id);
        queried.push(missing);

        let repository = PostgresProductRepository::new(pool.clone());
        let expected: HashSet<ProductId> = live_ids.iter().copied().collect();
        let actual = repository
            .existing_ids(&queried)
            .await
            .expect("repository existing_ids");
        let legacy = legacy_existing_ids(&pool, &queried)
            .await
            .expect("legacy existing_ids");

        assert_eq!(actual.len(), 6, "all live ids must be returned");
        assert_eq!(actual, expected);
        assert_eq!(actual, legacy);
        assert!(
            !actual.contains(&deleted.id),
            "soft-deleted ids must be excluded"
        );
        assert!(!actual.contains(&missing), "missing ids must be excluded");

        let single = repository
            .existing_ids(&[live_ids[0]])
            .await
            .expect("single existing_ids");
        assert_eq!(
            single,
            HashSet::from([live_ids[0]]),
            "single-id lookup must return exactly one row"
        );
        assert!(
            repository
                .existing_ids(&[])
                .await
                .expect("empty existing_ids")
                .is_empty(),
            "empty existing_ids must short-circuit"
        );
    }

    #[sqlx::test]
    async fn create_matches_legacy_and_child_validation_still_rolls_back(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "catalog-create-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "catalog-create-sea").await;
        let legacy_product = product_fixture(
            Uuid::new_v4(),
            custom_origin(legacy_user_id),
            "Created custom",
            Some("Created brand"),
            &["created", "snacks"],
            Some(100),
            Some("cup"),
            vec![
                nutrient(
                    "ENERGY_KCAL",
                    200,
                    "kcal",
                    Some("USER"),
                    Some(NutrientConfidence::Approved),
                ),
                nutrient("PROTEIN_G", 12, "g", None, None),
            ],
            vec![serving("cup", 240), serving("slice", 30)],
            timestamp(5, 8),
            timestamp(5, 8),
        );
        let sea_product = product_fixture(
            Uuid::new_v4(),
            custom_origin(sea_user_id),
            "Created custom",
            Some("Created brand"),
            &["created", "snacks"],
            Some(100),
            Some("cup"),
            legacy_product.nutrients.clone(),
            legacy_product.servings.clone(),
            timestamp(5, 8),
            timestamp(5, 8),
        );

        legacy_create(&pool, &legacy_product)
            .await
            .expect("legacy create");
        let repository = PostgresProductRepository::new(pool.clone());
        repository
            .create(&sea_product)
            .await
            .expect("repository create");

        let legacy_row = fetch_product_row(&pool, legacy_product.id.0)
            .await
            .expect("legacy product row");
        let sea_row = fetch_product_row(&pool, sea_product.id.0)
            .await
            .expect("repository product row");

        assert_eq!(sea_row.source, legacy_row.source);
        assert_eq!(sea_row.source_id, legacy_row.source_id);
        assert_eq!(sea_row.visibility, legacy_row.visibility);
        assert_eq!(sea_row.barcode, legacy_row.barcode);
        assert_eq!(sea_row.name, legacy_row.name);
        assert_eq!(sea_row.brand, legacy_row.brand);
        assert_eq!(sea_row.categories, legacy_row.categories);
        assert_eq!(sea_row.default_quantity, legacy_row.default_quantity);
        assert_eq!(sea_row.default_unit, legacy_row.default_unit);
        assert_recent(sea_row.created_at, "created_at");
        assert_recent(sea_row.updated_at, "created_at");
        assert_eq!(
            nutrient_shapes(&pool, sea_product.id.0).await,
            nutrient_shapes(&pool, legacy_product.id.0).await,
            "created nutrients must match legacy"
        );
        assert_eq!(
            serving_shapes(&pool, sea_product.id.0).await,
            serving_shapes(&pool, legacy_product.id.0).await,
            "created servings must match legacy"
        );

        let found = repository
            .find_by_id(sea_product.id)
            .await
            .expect("find created product")
            .expect("created product exists");
        assert_eq!(found.name.as_str(), "Created custom");
        assert_eq!(
            found.brand.as_ref().map(|brand| brand.0.as_str()),
            Some("Created brand")
        );
        assert_eq!(sorted_nutrients(found.nutrients).len(), 2);
        assert_eq!(found.servings, sea_product.servings);

        let legacy_invalid = product_fixture(
            Uuid::new_v4(),
            custom_origin(legacy_user_id),
            "Invalid legacy",
            None,
            &[],
            None,
            None,
            vec![nutrient("DOES_NOT_EXIST", 1, "g", None, None)],
            vec![],
            timestamp(5, 9),
            timestamp(5, 9),
        );
        let sea_invalid = product_fixture(
            Uuid::new_v4(),
            custom_origin(sea_user_id),
            "Invalid sea",
            None,
            &[],
            None,
            None,
            legacy_invalid.nutrients.clone(),
            vec![],
            timestamp(5, 9),
            timestamp(5, 9),
        );

        let legacy_error = legacy_create(&pool, &legacy_invalid)
            .await
            .expect_err("legacy create must reject unknown nutrient codes");
        assert!(matches!(legacy_error, NutritionError::Validation(_)));
        let sea_error = repository
            .create(&sea_invalid)
            .await
            .expect_err("repository create must reject unknown nutrient codes");
        assert!(matches!(sea_error, NutritionError::Validation(_)));
        assert!(
            fetch_product_row(&pool, legacy_invalid.id.0)
                .await
                .is_none(),
            "legacy create must roll back the parent"
        );
        assert!(
            fetch_product_row(&pool, sea_invalid.id.0).await.is_none(),
            "repository create must roll back the parent"
        );
    }

    #[sqlx::test]
    async fn delete_matches_legacy_without_touching_bystanders(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-delete").await;
        let created_at = timestamp(6, 8);
        let legacy_product = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Delete product",
            None,
            &["delete"],
            None,
            None,
            vec![nutrient("ENERGY_KCAL", 1, "kcal", None, None)],
            vec![serving("cup", 100)],
            created_at,
            created_at,
        );
        let sea_product = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Delete product",
            None,
            &["delete"],
            None,
            None,
            legacy_product.nutrients.clone(),
            legacy_product.servings.clone(),
            created_at,
            created_at,
        );
        let bystander = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Delete bystander",
            None,
            &["bystander"],
            None,
            None,
            vec![nutrient("FAT_G", 2, "g", None, None)],
            vec![serving("slice", 20)],
            created_at,
            created_at,
        );
        for product in [&legacy_product, &sea_product, &bystander] {
            seed_product(&pool, product).await;
        }
        let bystander_before = fetch_product_row(&pool, bystander.id.0)
            .await
            .expect("bystander before");

        legacy_delete(&pool, legacy_product.id)
            .await
            .expect("legacy delete");
        let repository = PostgresProductRepository::new(pool.clone());
        repository
            .delete(sea_product.id)
            .await
            .expect("repository delete");

        let legacy_row = fetch_product_row(&pool, legacy_product.id.0)
            .await
            .expect("legacy deleted row");
        let sea_row = fetch_product_row(&pool, sea_product.id.0)
            .await
            .expect("repository deleted row");
        let legacy_deleted_at = sqlx::query_scalar::<_, Option<DateTime<Utc>>>(
            "SELECT deleted_at FROM products WHERE id = $1",
        )
        .bind(legacy_product.id.0)
        .fetch_one(&pool)
        .await
        .expect("legacy deleted_at");
        let sea_deleted_at = sqlx::query_scalar::<_, Option<DateTime<Utc>>>(
            "SELECT deleted_at FROM products WHERE id = $1",
        )
        .bind(sea_product.id.0)
        .fetch_one(&pool)
        .await
        .expect("repository deleted_at");
        assert_recent(
            legacy_deleted_at.expect("legacy row is soft-deleted"),
            "deleted_at",
        );
        assert_recent(
            sea_deleted_at.expect("repository row is soft-deleted"),
            "deleted_at",
        );

        assert_eq!(legacy_row.created_at, created_at);
        assert_eq!(sea_row.created_at, created_at);
        assert_eq!(sea_row.name, legacy_row.name);
        assert_eq!(sea_row.categories, legacy_row.categories);
        assert_eq!(
            repository
                .find_by_id(sea_product.id)
                .await
                .expect("find deleted"),
            None
        );
        assert_eq!(
            legacy_find_by_id(&pool, legacy_product.id)
                .await
                .expect("legacy find deleted"),
            None
        );
        assert_eq!(
            fetch_product_row(&pool, bystander.id.0).await,
            Some(bystander_before),
            "delete must not touch other products"
        );
    }

    #[sqlx::test]
    async fn update_matches_legacy_and_replaces_children_in_isolation(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-update").await;
        let other_user_id = seed_identity_and_profile(&pool, "catalog-update-other").await;
        let created_at = timestamp(7, 8);
        let old_updated_at = timestamp(7, 9);
        let legacy_product = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Legacy old name",
            Some("Old brand"),
            &["old"],
            Some(50),
            Some("g"),
            vec![nutrient("ENERGY_KCAL", 10, "kcal", None, None)],
            vec![serving("cup", 100)],
            created_at,
            old_updated_at,
        );
        let sea_product = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Sea old name",
            Some("Old brand"),
            &["old"],
            Some(50),
            Some("g"),
            legacy_product.nutrients.clone(),
            legacy_product.servings.clone(),
            created_at,
            old_updated_at,
        );
        let same_user_bystander = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Same user bystander",
            None,
            &["bystander"],
            None,
            None,
            vec![nutrient("FAT_G", 6, "g", None, None)],
            vec![serving("slice", 25)],
            created_at,
            old_updated_at,
        );
        let other_user_bystander = product_fixture(
            Uuid::new_v4(),
            custom_origin(other_user_id),
            "Other user bystander",
            None,
            &["bystander"],
            None,
            None,
            vec![nutrient("CARBS_G", 7, "g", None, None)],
            vec![serving("piece", 35)],
            created_at,
            old_updated_at,
        );
        for product in [
            &legacy_product,
            &sea_product,
            &same_user_bystander,
            &other_user_bystander,
        ] {
            seed_product(&pool, product).await;
        }
        let same_before = fetch_product_row(&pool, same_user_bystander.id.0)
            .await
            .expect("same-user bystander before");
        let other_before = fetch_product_row(&pool, other_user_bystander.id.0)
            .await
            .expect("other-user bystander before");
        let same_nutrients_before = nutrient_shapes(&pool, same_user_bystander.id.0).await;
        let same_servings_before = serving_shapes(&pool, same_user_bystander.id.0).await;
        let other_nutrients_before = nutrient_shapes(&pool, other_user_bystander.id.0).await;
        let other_servings_before = serving_shapes(&pool, other_user_bystander.id.0).await;

        let replacement_nutrients = vec![
            nutrient(
                "PROTEIN_G",
                20,
                "g",
                Some("USER"),
                Some(NutrientConfidence::Derived),
            ),
            nutrient("FAT_G", 9, "g", None, None),
        ];
        let replacement_servings = vec![serving("slice", 30), serving("cup", 250)];
        let legacy_update_product = product_fixture(
            legacy_product.id.0,
            custom_origin(user_id),
            "Updated name",
            Some("New brand"),
            &["new", "updated"],
            Some(75),
            Some("slice"),
            replacement_nutrients.clone(),
            replacement_servings.clone(),
            created_at,
            created_at,
        );
        let sea_update_product = product_fixture(
            sea_product.id.0,
            custom_origin(user_id),
            "Updated name",
            Some("New brand"),
            &["new", "updated"],
            Some(75),
            Some("slice"),
            replacement_nutrients.clone(),
            replacement_servings.clone(),
            created_at,
            created_at,
        );

        legacy_update(&pool, &legacy_update_product)
            .await
            .expect("legacy update");
        let repository = PostgresProductRepository::new(pool.clone());
        repository
            .update(&sea_update_product)
            .await
            .expect("repository update");

        let legacy_row = fetch_product_row(&pool, legacy_product.id.0)
            .await
            .expect("legacy updated row");
        let sea_row = fetch_product_row(&pool, sea_product.id.0)
            .await
            .expect("repository updated row");
        assert_eq!(legacy_row.created_at, created_at);
        assert_eq!(sea_row.created_at, created_at);
        assert_recent(sea_row.updated_at, "updated_at");
        assert_eq!(sea_row.name, legacy_row.name);
        assert_eq!(sea_row.brand, legacy_row.brand);
        assert_eq!(sea_row.categories, legacy_row.categories);
        assert_eq!(sea_row.default_quantity, legacy_row.default_quantity);
        assert_eq!(sea_row.default_unit, legacy_row.default_unit);
        assert_eq!(sea_row.name, "Updated name");
        assert_eq!(sea_row.brand.as_deref(), Some("New brand"));
        assert_eq!(
            sea_row.categories,
            vec!["new".to_owned(), "updated".to_owned()]
        );
        assert_eq!(sea_row.default_quantity, Some(Decimal::from(75)));
        assert_eq!(sea_row.default_unit.as_deref(), Some("slice"));

        let expected_nutrients = vec![
            ("FAT_G".to_owned(), Decimal::from(9), None, None),
            (
                "PROTEIN_G".to_owned(),
                Decimal::from(20),
                Some("USER".to_owned()),
                Some("derived".to_owned()),
            ),
        ];
        assert_eq!(
            nutrient_shapes(&pool, sea_product.id.0).await,
            expected_nutrients,
            "update must replace nutrients"
        );
        assert_eq!(
            nutrient_shapes(&pool, sea_product.id.0).await,
            nutrient_shapes(&pool, legacy_product.id.0).await,
            "updated nutrients must match legacy"
        );
        let expected_servings = vec![
            ("slice".to_owned(), Decimal::from(30), 0),
            ("cup".to_owned(), Decimal::from(250), 1),
        ];
        assert_eq!(
            serving_shapes(&pool, sea_product.id.0).await,
            expected_servings,
            "update must replace servings in incoming order"
        );
        assert_eq!(
            serving_shapes(&pool, sea_product.id.0).await,
            serving_shapes(&pool, legacy_product.id.0).await,
            "updated servings must match legacy"
        );

        let legacy_clear = product_fixture(
            legacy_product.id.0,
            custom_origin(user_id),
            "Cleared name",
            None,
            &["cleared"],
            None,
            None,
            vec![],
            vec![],
            created_at,
            created_at,
        );
        let sea_clear = product_fixture(
            sea_product.id.0,
            custom_origin(user_id),
            "Cleared name",
            None,
            &["cleared"],
            None,
            None,
            vec![],
            vec![],
            created_at,
            created_at,
        );
        legacy_update(&pool, &legacy_clear)
            .await
            .expect("legacy clearing update");
        repository
            .update(&sea_clear)
            .await
            .expect("repository clearing update");

        let legacy_cleared = fetch_product_row(&pool, legacy_product.id.0)
            .await
            .expect("legacy cleared row");
        let sea_cleared = fetch_product_row(&pool, sea_product.id.0)
            .await
            .expect("repository cleared row");
        assert_eq!(legacy_cleared.created_at, created_at);
        assert_eq!(sea_cleared.created_at, created_at);
        assert_recent(sea_cleared.updated_at, "cleared updated_at");
        assert_eq!(sea_cleared.name, legacy_cleared.name);
        assert_eq!(sea_cleared.brand, legacy_cleared.brand);
        assert_eq!(sea_cleared.categories, legacy_cleared.categories);
        assert_eq!(
            sea_cleared.default_quantity,
            legacy_cleared.default_quantity
        );
        assert_eq!(sea_cleared.default_unit, legacy_cleared.default_unit);
        assert_eq!(sea_cleared.name, "Cleared name");
        assert!(
            sea_cleared.brand.is_none(),
            "update must clear brand to SQL NULL"
        );
        assert_eq!(
            sea_cleared.default_quantity, None,
            "update must clear default_quantity to SQL NULL"
        );
        assert_eq!(
            sea_cleared.default_unit, None,
            "update must clear default_unit to SQL NULL"
        );
        assert_eq!(
            nutrient_shapes(&pool, sea_product.id.0).await,
            Vec::new(),
            "clearing update must remove nutrients"
        );
        assert_eq!(
            serving_shapes(&pool, sea_product.id.0).await,
            Vec::new(),
            "clearing update must remove servings"
        );
        assert_eq!(
            nutrient_shapes(&pool, sea_product.id.0).await,
            nutrient_shapes(&pool, legacy_product.id.0).await,
            "cleared nutrients must match legacy"
        );
        assert_eq!(
            serving_shapes(&pool, sea_product.id.0).await,
            serving_shapes(&pool, legacy_product.id.0).await,
            "cleared servings must match legacy"
        );

        assert_eq!(
            fetch_product_row(&pool, same_user_bystander.id.0).await,
            Some(same_before),
            "update must not touch same-user bystanders"
        );
        assert_eq!(
            nutrient_shapes(&pool, same_user_bystander.id.0).await,
            same_nutrients_before,
            "update must not touch same-user bystander nutrients"
        );
        assert_eq!(
            serving_shapes(&pool, same_user_bystander.id.0).await,
            same_servings_before,
            "update must not touch same-user bystander servings"
        );
        assert_eq!(
            fetch_product_row(&pool, other_user_bystander.id.0).await,
            Some(other_before),
            "update must not touch other-user bystanders"
        );
        assert_eq!(
            nutrient_shapes(&pool, other_user_bystander.id.0).await,
            other_nutrients_before,
            "update must not touch other-user bystander nutrients"
        );
        assert_eq!(
            serving_shapes(&pool, other_user_bystander.id.0).await,
            other_servings_before,
            "update must not touch other-user bystander servings"
        );
    }

    #[sqlx::test]
    async fn upsert_external_many_matches_legacy_for_insert_and_update_paths(pool: PgPool) {
        let created_at = timestamp(8, 8);
        let legacy_existing = external_product(
            Uuid::new_v4(),
            "legacy-existing",
            Some("legacy-old-barcode"),
            "Legacy existing old",
            &["old"],
            vec![nutrient("ENERGY_KCAL", 10, "kcal", Some("OFF"), None)],
            vec![serving("cup", 100)],
            created_at,
        );
        let sea_existing = external_product(
            Uuid::new_v4(),
            "sea-existing",
            Some("sea-old-barcode"),
            "Sea existing old",
            &["old"],
            legacy_existing.nutrients.clone(),
            legacy_existing.servings.clone(),
            created_at,
        );
        seed_product(&pool, &legacy_existing).await;
        seed_product(&pool, &sea_existing).await;
        soft_delete_row(&pool, legacy_existing.id.0, timestamp(8, 9)).await;
        soft_delete_row(&pool, sea_existing.id.0, timestamp(8, 9)).await;
        assert!(
            product_deleted_at(&pool, legacy_existing.id.0)
                .await
                .is_some(),
            "legacy existing product must start soft-deleted"
        );
        assert!(
            product_deleted_at(&pool, sea_existing.id.0).await.is_some(),
            "repository existing product must start soft-deleted"
        );

        let legacy_batch = ExternalProductBatch::new(vec![
            external_product(
                legacy_existing.id.0,
                "legacy-existing",
                Some("legacy-new-barcode"),
                "Existing updated",
                &["new", "bulk"],
                vec![
                    nutrient("ENERGY_KCAL", 120, "kcal", Some("OFF"), None),
                    nutrient("PROTEIN_G", 5, "g", Some("OFF"), None),
                ],
                vec![serving("cup", 240), serving("slice", 30)],
                created_at,
            ),
            external_product(
                Uuid::new_v4(),
                "legacy-new-a",
                Some("legacy-new-a-barcode"),
                "New A",
                &["bulk"],
                vec![nutrient("FAT_G", 2, "g", Some("OFF"), None)],
                vec![serving("piece", 50)],
                created_at,
            ),
            external_product(
                Uuid::new_v4(),
                "legacy-new-b",
                None,
                "New B",
                &["bulk"],
                vec![],
                vec![],
                created_at,
            ),
        ])
        .expect("legacy external batch");
        let sea_batch = ExternalProductBatch::new(vec![
            external_product(
                sea_existing.id.0,
                "sea-existing",
                Some("sea-new-barcode"),
                "Existing updated",
                &["new", "bulk"],
                vec![
                    nutrient("ENERGY_KCAL", 120, "kcal", Some("OFF"), None),
                    nutrient("PROTEIN_G", 5, "g", Some("OFF"), None),
                ],
                vec![serving("cup", 240), serving("slice", 30)],
                created_at,
            ),
            external_product(
                Uuid::new_v4(),
                "sea-new-a",
                Some("sea-new-a-barcode"),
                "New A",
                &["bulk"],
                vec![nutrient("FAT_G", 2, "g", Some("OFF"), None)],
                vec![serving("piece", 50)],
                created_at,
            ),
            external_product(
                Uuid::new_v4(),
                "sea-new-b",
                None,
                "New B",
                &["bulk"],
                vec![],
                vec![],
                created_at,
            ),
        ])
        .expect("sea external batch");

        let legacy_result = legacy_upsert_external_many(&pool, &legacy_batch)
            .await
            .expect("legacy upsert");
        let repository = PostgresProductRepository::new(pool.clone());
        let sea_result = repository
            .upsert_external_many(&sea_batch)
            .await
            .expect("repository upsert");

        assert_eq!(
            legacy_result,
            ProductUpsertResult {
                created: 2,
                updated: 1,
                nutrients_written: 3,
                servings_written: 3,
            },
            "legacy upsert counters"
        );
        assert_eq!(
            sea_result, legacy_result,
            "upsert counters must match legacy"
        );
        assert_eq!(
            sea_result.updated, 1,
            "the soft-deleted existing product must count as updated"
        );
        assert_eq!(
            product_deleted_at(&pool, legacy_existing.id.0).await,
            None,
            "legacy upsert must revive the soft-deleted existing product"
        );
        assert_eq!(
            product_deleted_at(&pool, sea_existing.id.0).await,
            None,
            "repository upsert must clear deleted_at on the existing product"
        );

        let legacy_revived = legacy_find_by_id(&pool, legacy_existing.id)
            .await
            .expect("legacy find revived product")
            .expect("legacy existing product must be visible after upsert");
        let sea_revived = repository
            .find_by_id(sea_existing.id)
            .await
            .expect("repository find revived product")
            .expect("existing product must be visible after upsert");
        assert_eq!(sea_revived.name.as_str(), "Existing updated");
        assert_eq!(sea_revived.name, legacy_revived.name);
        assert_eq!(sea_revived.brand, legacy_revived.brand);
        assert_eq!(sea_revived.categories, legacy_revived.categories);
        assert_eq!(
            sorted_nutrients(sea_revived.nutrients),
            sorted_nutrients(legacy_revived.nutrients)
        );
        assert_eq!(sea_revived.servings, legacy_revived.servings);

        let legacy_existing_row = fetch_product_row_by_identity(&pool, "OFF", "legacy-existing")
            .await
            .expect("legacy existing row");
        let sea_existing_row = fetch_product_row_by_identity(&pool, "OFF", "sea-existing")
            .await
            .expect("sea existing row");
        assert_eq!(legacy_existing_row.id, legacy_existing.id.0);
        assert_eq!(sea_existing_row.id, sea_existing.id.0);
        assert_eq!(sea_existing_row.name, legacy_existing_row.name);
        assert_eq!(sea_existing_row.brand, legacy_existing_row.brand);
        assert_eq!(sea_existing_row.categories, legacy_existing_row.categories);
        assert_eq!(
            sea_existing_row.default_quantity,
            legacy_existing_row.default_quantity
        );
        assert_eq!(
            sea_existing_row.default_unit,
            legacy_existing_row.default_unit
        );
        assert_eq!(sea_existing_row.barcode, Some("sea-new-barcode".into()));
        assert_eq!(sea_existing_row.created_at, created_at);
        assert_recent(sea_existing_row.updated_at, "existing updated_at");
        assert_eq!(
            nutrient_shapes(&pool, sea_existing_row.id).await,
            nutrient_shapes(&pool, legacy_existing_row.id).await,
            "existing nutrients must match legacy"
        );
        assert_eq!(
            nutrient_shapes(&pool, sea_existing_row.id).await,
            vec![
                (
                    "ENERGY_KCAL".to_owned(),
                    Decimal::from(120),
                    Some("OFF".to_owned()),
                    None
                ),
                (
                    "PROTEIN_G".to_owned(),
                    Decimal::from(5),
                    Some("OFF".to_owned()),
                    None
                ),
            ],
            "existing nutrients must be replaced"
        );
        assert_eq!(
            serving_shapes(&pool, sea_existing_row.id).await,
            serving_shapes(&pool, legacy_existing_row.id).await,
            "existing servings must match legacy"
        );
        assert_eq!(
            serving_shapes(&pool, sea_existing_row.id).await,
            vec![
                ("cup".to_owned(), Decimal::from(240), 0),
                ("slice".to_owned(), Decimal::from(30), 1),
            ],
            "existing servings must be replaced"
        );

        let legacy_new_a = fetch_product_row_by_identity(&pool, "OFF", "legacy-new-a")
            .await
            .expect("legacy new A");
        let sea_new_a = fetch_product_row_by_identity(&pool, "OFF", "sea-new-a")
            .await
            .expect("sea new A");
        assert_eq!(sea_new_a.name, legacy_new_a.name);
        assert_eq!(sea_new_a.categories, legacy_new_a.categories);
        assert_eq!(sea_new_a.barcode, Some("sea-new-a-barcode".into()));
        assert_recent(sea_new_a.created_at, "new A created_at");
        assert_recent(sea_new_a.updated_at, "new A updated_at");
        assert_eq!(
            nutrient_shapes(&pool, sea_new_a.id).await,
            nutrient_shapes(&pool, legacy_new_a.id).await,
            "new A nutrients must match legacy"
        );
        assert_eq!(
            serving_shapes(&pool, sea_new_a.id).await,
            serving_shapes(&pool, legacy_new_a.id).await,
            "new A servings must match legacy"
        );

        let legacy_new_b = fetch_product_row_by_identity(&pool, "OFF", "legacy-new-b")
            .await
            .expect("legacy new B");
        let sea_new_b = fetch_product_row_by_identity(&pool, "OFF", "sea-new-b")
            .await
            .expect("sea new B");
        assert_eq!(sea_new_b.name, legacy_new_b.name);
        assert!(sea_new_b.barcode.is_none());
        assert_recent(sea_new_b.created_at, "new B created_at");
        assert_eq!(
            nutrient_shapes(&pool, sea_new_b.id).await,
            Vec::new(),
            "new B must have no nutrients"
        );
        assert_eq!(
            nutrient_shapes(&pool, sea_new_b.id).await,
            nutrient_shapes(&pool, legacy_new_b.id).await,
            "new B nutrients must match legacy"
        );
        assert_eq!(
            serving_shapes(&pool, sea_new_b.id).await,
            Vec::new(),
            "new B must have no servings"
        );
        assert_eq!(
            serving_shapes(&pool, sea_new_b.id).await,
            serving_shapes(&pool, legacy_new_b.id).await,
            "new B servings must match legacy"
        );

        let product_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM products WHERE source = 'OFF' AND source_id = ANY($1)",
        )
        .bind(vec![
            "legacy-existing",
            "legacy-new-a",
            "legacy-new-b",
            "sea-existing",
            "sea-new-a",
            "sea-new-b",
        ])
        .fetch_one(&pool)
        .await
        .expect("count external products");
        assert_eq!(product_count, 6, "upsert must not duplicate identities");
    }

    #[sqlx::test]
    async fn nutrient_repository_matches_legacy(pool: PgPool) {
        let repository = PostgresNutrientRepository::new(pool.clone());
        let actual = repository.list_all().await.expect("repository list_all");
        let legacy = legacy_list_nutrients(&pool).await.expect("legacy list_all");

        assert_eq!(actual, legacy);
        assert!(
            actual
                .windows(2)
                .all(|pair| pair[0].code.0 <= pair[1].code.0),
            "nutrients must be ordered by code"
        );
        assert!(actual.iter().any(|nutrient| nutrient.code.0 == "PROTEIN_G"));

        let found = repository
            .find_by_code("PROTEIN_G")
            .await
            .expect("repository find_by_code")
            .expect("protein exists");
        assert_eq!(found.code, NutrientCode("PROTEIN_G".into()));
        assert_eq!(found.name, "Protein");
        assert_eq!(found.unit, UnitCode("g".into()));
        assert_eq!(found.category, "macro");
        assert_eq!(
            Some(found),
            legacy_find_nutrient(&pool, "PROTEIN_G")
                .await
                .expect("legacy find_by_code")
        );
        assert_eq!(
            repository
                .find_by_code("DOES_NOT_EXIST")
                .await
                .expect("repository missing nutrient"),
            None
        );
        assert_eq!(
            legacy_find_nutrient(&pool, "DOES_NOT_EXIST")
                .await
                .expect("legacy missing nutrient"),
            None
        );
    }

    #[sqlx::test]
    async fn unit_repository_matches_legacy_and_filters_null_mass_factors(pool: PgPool) {
        let repository = PostgresUnitRepository::new(pool.clone());
        let actual = repository.list_all().await.expect("repository list_all");
        let legacy = legacy_list_units(&pool).await.expect("legacy list_all");

        assert_eq!(actual, legacy);
        assert!(
            actual.windows(2).all(|pair| pair[0].0.0 <= pair[1].0.0),
            "units must be ordered by code"
        );
        assert!(actual.iter().any(|(code, _, _)| code.0 == "g"));

        let actual_factors = sorted_mass_factors(
            repository
                .list_mass_factors()
                .await
                .expect("repository mass factors"),
        );
        let legacy_factors = sorted_mass_factors(
            legacy_list_mass_factors(&pool)
                .await
                .expect("legacy mass factors"),
        );
        assert_eq!(actual_factors, legacy_factors);
        assert_eq!(
            actual_factors
                .iter()
                .map(|(code, _)| code.as_str())
                .collect::<Vec<_>>(),
            vec!["g", "kg", "mg", "ug"],
            "mass factors must exclude units without canonical grams"
        );
        assert!(
            actual_factors
                .iter()
                .all(|(_, grams)| *grams > Decimal::ZERO),
            "mass factors must be positive"
        );
        assert!(
            actual_factors.iter().all(|(code, _)| code != "ml"),
            "volume units must be filtered out"
        );
    }

    #[sqlx::test]
    async fn search_summary_nutrients_match_legacy_and_filter_codes(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "catalog-search-summary").await;
        let first = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Summary first",
            None,
            &[],
            None,
            None,
            vec![
                nutrient("ENERGY_KCAL", 100, "kcal", Some("USER"), None),
                nutrient("PROTEIN_G", 5, "g", None, None),
                nutrient("SUGAR_G", 9, "g", None, None),
            ],
            vec![],
            timestamp(9, 8),
            timestamp(9, 8),
        );
        let second = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Summary second",
            None,
            &[],
            None,
            None,
            vec![
                nutrient("CARBS_G", 12, "g", None, None),
                nutrient("FAT_G", 4, "g", None, None),
                nutrient("FIBER_G", 3, "g", None, None),
            ],
            vec![],
            timestamp(9, 9),
            timestamp(9, 9),
        );
        let third = product_fixture(
            Uuid::new_v4(),
            custom_origin(user_id),
            "Summary third",
            None,
            &[],
            None,
            None,
            vec![nutrient("SUGAR_G", 2, "g", None, None)],
            vec![],
            timestamp(9, 10),
            timestamp(9, 10),
        );
        for product in [&first, &second, &third] {
            seed_product(&pool, product).await;
        }

        let ids = vec![first.id.0, second.id.0, third.id.0, Uuid::new_v4()];
        let repository = PostgresProductRepository::new(pool.clone());
        let actual = repository
            .load_summary_nutrients(&ids)
            .await
            .expect("repository summary nutrients");
        let legacy = legacy_load_summary_nutrients(&pool, &ids)
            .await
            .expect("legacy summary nutrients");

        let actual_first = sorted_nutrients(actual.get(&first.id.0).cloned().unwrap_or_default());
        let legacy_first = sorted_nutrients(legacy.get(&first.id.0).cloned().unwrap_or_default());
        assert_eq!(actual_first, legacy_first);
        assert_eq!(
            actual_first
                .iter()
                .map(|nutrient| nutrient.nutrient_code.0.as_str())
                .collect::<Vec<_>>(),
            vec!["ENERGY_KCAL", "PROTEIN_G"],
            "summary nutrients must only include the search nutrient codes"
        );
        assert_eq!(
            sorted_nutrients(actual.get(&second.id.0).cloned().unwrap_or_default()),
            sorted_nutrients(legacy.get(&second.id.0).cloned().unwrap_or_default())
        );
        assert!(
            !actual.contains_key(&third.id.0),
            "products without summary nutrients must be absent"
        );
        assert_eq!(actual.len(), legacy.len());
    }
}

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

fn nutrient_ids_by_code_statement(nutrient_codes: &[String]) -> SelectStatement {
    Query::select()
        .columns([Nutrients::Code, Nutrients::Id])
        .from(Nutrients::Table)
        .and_where(Expr::col(Nutrients::Code).eq_any(nutrient_codes.to_vec()))
        .to_owned()
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
        // Intentionally raw boundary: LOCK TABLE and the bulk UPDATE below are
        // Postgres-specific. Sea-query has no table-lock builder, and the
        // UPDATE's ROW(...) IS DISTINCT FROM comparison is clearer and safer to
        // keep in its proven Postgres form than to reassemble through sea-query.
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
            let (sql, values) = nutrient_ids_by_code_statement(&requested_nutrient_codes)
                .build_sqlx(PostgresQueryBuilder);
            sqlx::query_as_with::<_, (String, Uuid), _>(sqlx::AssertSqlSafe(sql.as_str()), values)
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

            // Intentionally raw; part of the same Postgres-specific boundary as
            // the LOCK TABLE above. The bulk UPDATE ... FROM (VALUES ...) with a
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

// The four child bulk helpers below stay raw by design: they rely on Postgres
// UNNEST of parallel typed arrays plus the insert/count validation contract.
// They are used by the sea-query parent writes.
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

    fn normalize_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    fn sql_contains(sql: &str, needle: &str) -> bool {
        str::contains(sql, needle)
    }

    fn sql_match_count(sql: &str, needle: &str) -> usize {
        str::matches(sql, needle).count()
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

    async fn seed_product(pool: &PgPool, product: &Product) {
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

    #[sqlx::test]
    async fn nutrient_id_lookup_binds_one_text_array_and_resolves_multiple_codes(pool: PgPool) {
        let codes = vec![
            "ENERGY_KCAL".to_owned(),
            "PROTEIN_G".to_owned(),
            "FAT_G".to_owned(),
        ];
        let (sql, values) = nutrient_ids_by_code_statement(&codes).build_sqlx(PostgresQueryBuilder);
        let normalized = normalize_sql(&sql);

        assert_eq!(
            values.0.iter().count(),
            1,
            "nutrient lookup must bind one text[] array: {normalized}"
        );
        assert!(
            matches!(
                values.0.iter().next(),
                Some(sea_query::Value::Array(
                    sea_query::ArrayType::String,
                    Some(values)
                )) if values.len() == codes.len()
            ),
            "nutrient lookup must bind every requested code without truncation: {normalized}"
        );
        assert!(
            sql_contains(&normalized, r#""code" = ANY("#),
            "nutrient lookup must use a single code = ANY(array) predicate: {normalized}"
        );

        let rows: Vec<(String, Uuid)> =
            sqlx::query_as_with::<_, (String, Uuid), _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&pool)
                .await
                .expect("resolve nutrient ids");
        let resolved: HashSet<String> = rows.into_iter().map(|(code, _)| code).collect();
        assert_eq!(
            resolved.len(),
            codes.len(),
            "nutrient lookup must resolve every requested code: {normalized}"
        );
        for code in &codes {
            assert!(
                resolved.contains(code),
                "nutrient lookup must resolve {code}: {normalized}"
            );
        }
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
}

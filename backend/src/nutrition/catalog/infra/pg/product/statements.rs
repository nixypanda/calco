use sea_query::extension::postgres::{PgBinOper, PgExpr};
use sea_query::{
    Alias, Asterisk, CommonTableExpression, Condition, DeleteStatement, Expr, ExprTrait, Func,
    Iden, InsertStatement, JoinType, OnConflict, Order, Query, SelectStatement, UpdateStatement,
};
use uuid::Uuid;

use crate::nutrition::catalog::domain::{CatalogSearchScope, Product};

use super::super::iden::Nutrients;

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
enum FoodLogs {
    Table,
    UserId,
    LogDate,
    ItemProductId,
    CreatedAt,
}

#[derive(Iden)]
enum LatestLogs {
    Table,
    ProductId,
    LastLogDate,
    LastLoggedAt,
}

#[derive(Iden)]
enum CategoryUnnest {
    Table,
    Category,
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

const SEARCH_NUTRIENT_CODES: [&str; 5] =
    ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G"];

// Ranking lives in `domain/search_ranking.rs`. These candidate queries only
// apply storage filters; they intentionally contain no text matching, ranking,
// ordering, or pre-ranking limit.
pub(super) fn search_catalog_candidates_statement(
    scope: CatalogSearchScope,
    include: &[String],
    exclude: &[String],
) -> SelectStatement {
    let mut statement = Query::select();
    statement
        .columns([
            Products::Id,
            Products::Name,
            Products::Brand,
            Products::Barcode,
        ])
        .from(Products::Table)
        .and_where(Expr::col(Products::DeletedAt).is_null());

    if scope == CatalogSearchScope::Custom {
        statement.and_where(Expr::col(Products::Source).eq("USER"));
    }

    apply_category_filters(&mut statement, include, exclude);
    statement.to_owned()
}

pub(super) fn search_history_candidates_statement(
    user_id: Uuid,
    include: &[String],
    exclude: &[String],
) -> SelectStatement {
    let latest_logs = Query::select()
        .expr_as(Expr::col(FoodLogs::ItemProductId), Alias::new("product_id"))
        .expr_as(
            Func::max(Expr::col(FoodLogs::LogDate)),
            Alias::new("last_log_date"),
        )
        .expr_as(
            Func::max(Expr::col(FoodLogs::CreatedAt)),
            Alias::new("last_logged_at"),
        )
        .from(FoodLogs::Table)
        .and_where(Expr::col(FoodLogs::UserId).eq(user_id))
        .and_where(Expr::col(FoodLogs::ItemProductId).is_not_null())
        .group_by_col(FoodLogs::ItemProductId)
        .to_owned();
    let latest_logs = CommonTableExpression::new()
        .table_name(LatestLogs::Table)
        .query(latest_logs)
        .to_owned();

    let mut statement = Query::select();
    statement
        .column((Products::Table, Products::Id))
        .column((Products::Table, Products::Name))
        .column((Products::Table, Products::Brand))
        .column((Products::Table, Products::Barcode))
        .column((Products::Table, Products::Categories))
        .column((LatestLogs::Table, LatestLogs::LastLogDate))
        .column((LatestLogs::Table, LatestLogs::LastLoggedAt))
        .from(Products::Table)
        .join(
            JoinType::InnerJoin,
            LatestLogs::Table,
            Expr::col((LatestLogs::Table, LatestLogs::ProductId))
                .equals((Products::Table, Products::Id)),
        )
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .with_cte(latest_logs);

    apply_category_filters(&mut statement, include, exclude);
    statement.to_owned()
}

pub(super) fn category_counts_statement() -> SelectStatement {
    // sea-query has no first-class UNNEST/BTRIM expressions; these custom
    // function names are the only raw identifiers in this generated query.
    let categories = Query::select()
        .expr_as(
            Func::cust(Alias::new("unnest"))
                .arg(Expr::col((Products::Table, Products::Categories))),
            Alias::new("category"),
        )
        .take();

    Query::select()
        .expr_as(
            Expr::col((CategoryUnnest::Table, CategoryUnnest::Category)),
            Alias::new("value"),
        )
        .expr_as(Func::count(Expr::col(Asterisk)), Alias::new("count"))
        .from(Products::Table)
        // `join_lateral` always emits an `ON` clause, so `CrossJoin` would
        // render invalid SQL. `INNER JOIN LATERAL ... ON TRUE` is equivalent
        // to `CROSS JOIN LATERAL` for this set-returning subquery.
        .join_lateral(
            JoinType::InnerJoin,
            categories,
            CategoryUnnest::Table,
            Condition::all(),
        )
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .and_where(
            Func::cust(Alias::new("btrim"))
                .arg(Expr::col(Products::Name))
                .ne(""),
        )
        .group_by_col((CategoryUnnest::Table, CategoryUnnest::Category))
        .to_owned()
}

fn apply_category_filters(statement: &mut SelectStatement, include: &[String], exclude: &[String]) {
    // Empty filters add no predicates, so they also add no array binds.
    if !include.is_empty() {
        statement.and_where(Expr::col(Products::Categories).contains(Expr::val(include.to_vec())));
    }
    if !exclude.is_empty() {
        statement.and_where(
            Expr::col(Products::Categories)
                .binary(PgBinOper::Overlap, Expr::val(exclude.to_vec()))
                .not(),
        );
    }
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

pub(super) fn load_nutrients_statement(product_id: Uuid) -> SelectStatement {
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

pub(super) fn load_servings_statement(product_id: Uuid) -> SelectStatement {
    Query::select()
        .columns([ProductServings::Unit, ProductServings::GramsPerUnit])
        .from(ProductServings::Table)
        .and_where(Expr::col(ProductServings::ProductId).eq(product_id))
        .order_by(ProductServings::Position, Order::Asc)
        .to_owned()
}

pub(super) fn load_nutrients_for_products_statement(product_ids: &[Uuid]) -> SelectStatement {
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

pub(super) fn load_servings_for_products_statement(product_ids: &[Uuid]) -> SelectStatement {
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

pub(super) fn search_summary_nutrients_statement(product_ids: &[Uuid]) -> SelectStatement {
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

pub(super) fn find_product_statement(id: Uuid) -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Id).eq(id))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

pub(super) fn find_search_summaries_statement(product_ids: Vec<Uuid>) -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Id).eq_any(product_ids))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

pub(super) fn find_product_by_barcode_statement(barcode: &str) -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Barcode).eq(barcode))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

pub(super) fn list_custom_foods_statement() -> SelectStatement {
    Query::select()
        .columns(product_columns())
        .from(Products::Table)
        .and_where(Expr::col(Products::Source).eq("USER"))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .order_by(Products::CreatedAt, Order::Desc)
        .to_owned()
}

pub(super) fn existing_ids_statement(ids: Vec<Uuid>) -> SelectStatement {
    Query::select()
        .column(Products::Id)
        .from(Products::Table)
        .and_where(Expr::col(Products::Id).eq_any(ids))
        .and_where(Expr::col(Products::DeletedAt).is_null())
        .to_owned()
}

pub(super) fn insert_product_statement(product: &Product) -> InsertStatement {
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

pub(super) fn insert_external_products_statement(chunk: &[&Product]) -> InsertStatement {
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

pub(super) fn nutrient_ids_by_code_statement(nutrient_codes: &[String]) -> SelectStatement {
    let mut statement = Query::select();
    statement
        .columns([Nutrients::Code, Nutrients::Id])
        .from(Nutrients::Table);
    if nutrient_codes.is_empty() {
        statement.and_where(Expr::value(1).eq(2));
    } else {
        statement.and_where(Expr::col(Nutrients::Code).is_in(nutrient_codes.to_vec()));
    }
    statement.to_owned()
}

pub(super) fn resolve_external_product_ids_statement(chunk: &[&Product]) -> SelectStatement {
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

pub(super) fn update_product_statement(product: &Product) -> UpdateStatement {
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

pub(super) fn delete_product_nutrients_statement(product_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(ProductNutrients::Table)
        .and_where(Expr::col(ProductNutrients::ProductId).eq(product_id))
        .to_owned()
}

pub(super) fn delete_product_servings_statement(product_id: Uuid) -> DeleteStatement {
    Query::delete()
        .from_table(ProductServings::Table)
        .and_where(Expr::col(ProductServings::ProductId).eq(product_id))
        .to_owned()
}

pub(super) fn soft_delete_product_statement(id: Uuid) -> UpdateStatement {
    Query::update()
        .table(Products::Table)
        .value(Products::DeletedAt, Expr::current_timestamp())
        .and_where(Expr::col(Products::Id).eq(id))
        .to_owned()
}

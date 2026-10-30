use std::collections::HashMap;

use sea_query::{Expr, ExprTrait, Iden, PostgresQueryBuilder, Query};
use sea_query_sqlx::SqlxBinder;
use sqlx::Postgres;
use uuid::Uuid;

use crate::nutrition::catalog::domain::{NutritionError, Product, ProductNutrient, ProductServing};
use crate::nutrition::infra::pg as nutrient_batch;

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

pub(super) async fn insert_product_nutrients(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    product_id: Uuid,
    nutrients: &[ProductNutrient],
) -> Result<(), NutritionError> {
    if nutrients.is_empty() {
        return Ok(());
    }

    // Resolve nutrient IDs in Rust instead of relying on a Postgres JOIN/UNNEST.
    let codes: Vec<String> = nutrients
        .iter()
        .map(|n| n.nutrient_code.0.clone())
        .collect();
    let nutrient_ids = nutrient_batch::resolve_nutrient_ids(tx, &codes, "product").await?;

    let n = nutrients.len();
    let written = nutrient_batch::insert_chunked(tx, n, 100, |start, end| {
        let mut statement = Query::insert();
        statement.into_table(ProductNutrients::Table).columns([
            ProductNutrients::ProductId,
            ProductNutrients::NutrientId,
            ProductNutrients::AmountPer100g,
            ProductNutrients::Source,
            ProductNutrients::Confidence,
        ]);
        for nutrient in &nutrients[start..end] {
            let nutrient_id = nutrient_ids
                .get(&nutrient.nutrient_code.0)
                .expect("validated nutrient identity missing during insert");
            statement.values_panic([
                product_id.into(),
                (*nutrient_id).into(),
                nutrient.amount_per_100g.value().into(),
                nutrient.source.clone().into(),
                nutrient
                    .confidence
                    .as_ref()
                    .map(|c| c.as_str().to_string())
                    .into(),
            ]);
        }
        statement
    })
    .await?;

    if written != nutrients.len() {
        return Err(NutritionError::Validation(format!(
            "unknown nutrient code in product (expected {} rows, inserted {})",
            nutrients.len(),
            written
        )));
    }
    Ok(())
}

pub(super) async fn insert_product_servings(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    product_id: Uuid,
    servings: &[ProductServing],
) -> Result<(), NutritionError> {
    if servings.is_empty() {
        return Ok(());
    }

    let mut statement = Query::insert();
    statement.into_table(ProductServings::Table).columns([
        ProductServings::ProductId,
        ProductServings::Unit,
        ProductServings::GramsPerUnit,
        ProductServings::Position,
    ]);
    for (position, serving) in servings.iter().enumerate() {
        let position = i32::try_from(position)
            .map_err(|_| NutritionError::Validation("too many servings for product".into()))?;
        statement.values_panic([
            product_id.into(),
            serving.unit.0.clone().into(),
            serving.grams_per_unit.into(),
            position.into(),
        ]);
    }
    let (sql, values) = statement.build_sqlx(PostgresQueryBuilder);
    sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

pub(super) async fn replace_product_nutrients(
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

    if !product_ids.is_empty() {
        let mut delete = Query::delete();
        delete
            .from_table(ProductNutrients::Table)
            .and_where(Expr::col(ProductNutrients::ProductId).is_in(product_ids.to_vec()));
        let (sql, values) = delete.build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut **tx)
            .await?;
    }

    if incoming_product_ids.is_empty() {
        return Ok(0);
    }

    let n = incoming_product_ids.len();
    let written_usize = nutrient_batch::insert_chunked(tx, n, 100, |start, end| {
        let mut statement = Query::insert();
        statement.into_table(ProductNutrients::Table).columns([
            ProductNutrients::ProductId,
            ProductNutrients::NutrientId,
            ProductNutrients::AmountPer100g,
            ProductNutrients::Source,
            ProductNutrients::Confidence,
        ]);
        for i in start..end {
            statement.values_panic([
                incoming_product_ids[i].into(),
                incoming_nutrient_ids[i].into(),
                amounts[i].into(),
                sources[i].clone().into(),
                confidences[i].clone().into(),
            ]);
        }
        statement
    })
    .await?;
    let written = written_usize as i64;

    Ok(written)
}

pub(super) async fn replace_product_servings(
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

    if !product_ids.is_empty() {
        let mut delete = Query::delete();
        delete
            .from_table(ProductServings::Table)
            .and_where(Expr::col(ProductServings::ProductId).is_in(product_ids.to_vec()));
        let (sql, values) = delete.build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut **tx)
            .await?;
    }

    if incoming_product_ids.is_empty() {
        return Ok(0);
    }

    let n = incoming_product_ids.len();
    let written_usize = nutrient_batch::insert_chunked(tx, n, 100, |start, end| {
        let mut statement = Query::insert();
        statement.into_table(ProductServings::Table).columns([
            ProductServings::ProductId,
            ProductServings::Unit,
            ProductServings::GramsPerUnit,
            ProductServings::Position,
        ]);
        for i in start..end {
            statement.values_panic([
                incoming_product_ids[i].into(),
                units[i].clone().into(),
                grams_per_unit[i].into(),
                positions[i].into(),
            ]);
        }
        statement
    })
    .await?;
    let written = written_usize as i64;

    Ok(written)
}

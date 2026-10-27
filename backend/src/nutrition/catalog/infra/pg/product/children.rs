use std::collections::HashMap;

use rust_decimal::Decimal;
use sqlx::Postgres;
use uuid::Uuid;

use crate::nutrition::catalog::domain::{NutritionError, Product, ProductNutrient, ProductServing};

// The four child bulk helpers below stay raw by design: they rely on Postgres
// UNNEST of parallel typed arrays plus the insert/count validation contract.
// They are used by the sea-query parent writes.
pub(super) async fn insert_product_nutrients(
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

pub(super) async fn insert_product_servings(
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

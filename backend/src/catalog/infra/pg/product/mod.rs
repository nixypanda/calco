mod children;
mod rows;
mod statements;
#[cfg(test)]
mod tests;

use async_trait::async_trait;
use sea_query::PostgresQueryBuilder;
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;
use sqlx::{Postgres, QueryBuilder};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use crate::catalog::domain::search_ranking::{
    CategoryCount, HistorySearchCandidate, ProductSearchFields,
};
use crate::catalog::domain::*;

use children::{
    insert_product_nutrients, insert_product_servings, replace_product_nutrients,
    replace_product_servings,
};
use rows::{
    CategoryCountRow, HistorySearchCandidateRow, ProductNutrientRow, ProductNutrientWithProductRow,
    ProductRow, ProductSearchCandidateRow, ProductServingRow, ProductServingWithProductRow,
    SearchNutrientRow, history_search_candidate_from_row, product_row_to_product,
    product_search_fields_from_row,
};
use statements::{
    nutrient_ids_by_code_statement, product_category_counts_statement,
    product_existing_ids_statement, product_find_by_barcode_statement,
    product_find_by_id_statement, product_find_search_summaries_by_product_ids_statement,
    product_insert_external_statement, product_insert_statement, product_list_custom_statement,
    product_nutrient_delete_by_product_id_statement, product_nutrient_load_by_product_id_statement,
    product_nutrient_load_by_product_ids_statement, product_resolve_external_ids_statement,
    product_search_catalog_candidates_statement, product_search_history_candidates_statement,
    product_search_summary_nutrients_statement, product_serving_delete_by_product_id_statement,
    product_serving_load_by_product_id_statement, product_serving_load_by_product_ids_statement,
    product_soft_delete_statement, product_update_statement,
};

// ─── Product Repo ────────────────────────────────────────

const PRODUCT_UPSERT_CHUNK_SIZE: usize = 1_000;

#[derive(Clone)]
pub struct PgProductRepo {
    pool: PgPool,
}

impl PgProductRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn load_nutrients(
        &self,
        product_id: Uuid,
    ) -> Result<Vec<ProductNutrient>, CatalogError> {
        let (sql, values) = product_nutrient_load_by_product_id_statement(product_id)
            .build_sqlx(PostgresQueryBuilder);
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

    async fn load_servings(&self, product_id: Uuid) -> Result<Vec<ProductServing>, CatalogError> {
        let (sql, values) = product_serving_load_by_product_id_statement(product_id)
            .build_sqlx(PostgresQueryBuilder);
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
    ) -> Result<HashMap<Uuid, Vec<ProductNutrient>>, CatalogError> {
        if product_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let (sql, values) = product_nutrient_load_by_product_ids_statement(product_ids)
            .build_sqlx(PostgresQueryBuilder);
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
    ) -> Result<HashMap<Uuid, Vec<ProductServing>>, CatalogError> {
        if product_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let (sql, values) = product_serving_load_by_product_ids_statement(product_ids)
            .build_sqlx(PostgresQueryBuilder);
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
    ) -> Result<HashMap<Uuid, Vec<ProductNutrient>>, CatalogError> {
        if product_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let (sql, values) = product_search_summary_nutrients_statement(product_ids)
            .build_sqlx(PostgresQueryBuilder);
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
impl ProductRepo for PgProductRepo {
    async fn search_catalog_candidates(
        &self,
        spec: &ProductSearchSpec,
        scope: CatalogSearchScope,
    ) -> Result<Vec<ProductSearchFields>, CatalogError> {
        let include: Vec<String> = spec
            .include_categories
            .iter()
            .map(|category| category.0.clone())
            .collect();
        let exclude: Vec<String> = spec
            .exclude_categories
            .iter()
            .map(|category| category.0.clone())
            .collect();
        let (sql, values) = product_search_catalog_candidates_statement(scope, &include, &exclude)
            .build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, ProductSearchCandidateRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(product_search_fields_from_row)
            .collect())
    }

    async fn search_history_candidates(
        &self,
        spec: &ProductSearchSpec,
        user_id: Uuid,
    ) -> Result<Vec<HistorySearchCandidate>, CatalogError> {
        let include: Vec<String> = spec
            .include_categories
            .iter()
            .map(|category| category.0.clone())
            .collect();
        let exclude: Vec<String> = spec
            .exclude_categories
            .iter()
            .map(|category| category.0.clone())
            .collect();
        let (sql, values) =
            product_search_history_candidates_statement(user_id, &include, &exclude)
                .build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, HistorySearchCandidateRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(history_search_candidate_from_row)
            .collect())
    }

    async fn category_counts(&self) -> Result<Vec<CategoryCount>, CatalogError> {
        // Ranking lives in `domain/search_ranking.rs`; only storage aggregation
        // remains here.
        let (sql, values) = product_category_counts_statement().build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, CategoryCountRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let Some(value) = Category::new(&row.value) else {
                    tracing::warn!(
                        category = %row.value,
                        "skipping blank stored category count"
                    );
                    return None;
                };
                let Some(count) = CategoryCount::new(value, row.count) else {
                    tracing::warn!(
                        category = %row.value,
                        count = row.count,
                        "skipping category count with a negative count"
                    );
                    return None;
                };
                Some(count)
            })
            .collect())
    }

    async fn find_search_summaries(
        &self,
        ids: &[ProductId],
    ) -> Result<Vec<Product>, CatalogError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let product_ids: Vec<Uuid> = ids.iter().map(|id| id.0).collect();
        let (sql, values) =
            product_find_search_summaries_by_product_ids_statement(product_ids.clone())
                .build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, ProductRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        let summary_nutrients_by_product = self.load_summary_nutrients(&product_ids).await?;

        rows.into_iter()
            .map(|row| {
                let nutrients = summary_nutrients_by_product
                    .get(&row.id)
                    .cloned()
                    .unwrap_or_default();
                product_row_to_product(row, nutrients, vec![])
            })
            .collect()
    }

    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, CatalogError> {
        let (sql, values) = product_find_by_id_statement(id.0).build_sqlx(PostgresQueryBuilder);
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

    async fn existing_ids(&self, ids: &[ProductId]) -> Result<HashSet<ProductId>, CatalogError> {
        if ids.is_empty() {
            return Ok(HashSet::new());
        }
        let raw: Vec<Uuid> = ids.iter().map(|p| p.0).collect();
        let (sql, values) = product_existing_ids_statement(raw).build_sqlx(PostgresQueryBuilder);
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
    ) -> Result<Option<Product>, CatalogError> {
        let (sql, values) =
            product_find_by_barcode_statement(barcode).build_sqlx(PostgresQueryBuilder);
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

    async fn list_custom_foods(&self) -> Result<Vec<Product>, CatalogError> {
        let (sql, values) = product_list_custom_statement().build_sqlx(PostgresQueryBuilder);
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

    async fn create(&self, product: &Product) -> Result<(), CatalogError> {
        let mut tx = self.pool.begin().await?;

        let (sql, values) = product_insert_statement(product).build_sqlx(PostgresQueryBuilder);
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
    ) -> Result<ProductUpsertResult, CatalogError> {
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
            return Err(CatalogError::Validation(format!(
                "unknown nutrient code(s): {}",
                unknown_codes.join(", ")
            )));
        }

        let mut result = ProductUpsertResult::default();
        for chunk in products.chunks(PRODUCT_UPSERT_CHUNK_SIZE) {
            let (sql, values) =
                product_insert_external_statement(chunk).build_sqlx(PostgresQueryBuilder);
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
                product_resolve_external_ids_statement(chunk).build_sqlx(PostgresQueryBuilder);
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
            return Err(CatalogError::Internal(
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
                        CatalogError::Internal(
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

    async fn update(&self, product: &Product) -> Result<(), CatalogError> {
        let mut tx = self.pool.begin().await?;

        let (sql, values) = product_update_statement(product).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) = product_nutrient_delete_by_product_id_statement(product.id.0)
            .build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        let (sql, values) = product_serving_delete_by_product_id_statement(product.id.0)
            .build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut *tx)
            .await?;

        insert_product_nutrients(&mut tx, product.id.0, &product.nutrients).await?;
        insert_product_servings(&mut tx, product.id.0, &product.servings).await?;

        tx.commit().await?;
        Ok(())
    }

    async fn delete(&self, id: ProductId) -> Result<(), CatalogError> {
        let (sql, values) = product_soft_delete_statement(id.0).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

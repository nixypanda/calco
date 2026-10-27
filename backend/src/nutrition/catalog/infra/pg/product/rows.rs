use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::nutrition::catalog::domain::search_ranking::{
    HistorySearchCandidate, ProductSearchFields, SearchRecency,
};
use crate::nutrition::catalog::domain::*;

// ─── Row Types ─────────────────────────────────────────────────

#[derive(sqlx::FromRow)]
pub(super) struct ProductRow {
    pub(super) id: Uuid,
    pub(super) source: String,
    pub(super) source_id: Option<String>,
    pub(super) user_id: Option<Uuid>,
    pub(super) visibility: String,
    pub(super) barcode: Option<String>,
    pub(super) name: String,
    pub(super) brand: Option<String>,
    pub(super) categories: Vec<String>,
    pub(super) default_quantity: Option<Decimal>,
    pub(super) default_unit: Option<String>,
    pub(super) created_at: DateTime<Utc>,
    pub(super) updated_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
pub(super) struct ProductNutrientRow {
    pub(super) amount_per_100g: Decimal,
    pub(super) source: Option<String>,
    pub(super) confidence: Option<String>,
    pub(super) code: String,
    pub(super) unit: String,
}

#[derive(sqlx::FromRow)]
pub(super) struct ProductNutrientWithProductRow {
    pub(super) product_id: Uuid,
    pub(super) amount_per_100g: Decimal,
    pub(super) source: Option<String>,
    pub(super) confidence: Option<String>,
    pub(super) code: String,
    pub(super) unit: String,
}

#[derive(sqlx::FromRow)]
pub(super) struct SearchNutrientRow {
    pub(super) product_id: Uuid,
    pub(super) amount_per_100g: Decimal,
    pub(super) source: Option<String>,
    pub(super) confidence: Option<String>,
    pub(super) code: String,
    pub(super) unit: String,
}

#[derive(sqlx::FromRow)]
pub(super) struct ProductServingRow {
    pub(super) unit: String,
    pub(super) grams_per_unit: Decimal,
}

#[derive(sqlx::FromRow)]
pub(super) struct ProductServingWithProductRow {
    pub(super) product_id: Uuid,
    pub(super) unit: String,
    pub(super) grams_per_unit: Decimal,
}

#[derive(sqlx::FromRow)]
pub(super) struct ProductSearchCandidateRow {
    id: Uuid,
    name: String,
    brand: Option<String>,
    barcode: Option<String>,
}

#[derive(sqlx::FromRow)]
pub(super) struct HistorySearchCandidateRow {
    id: Uuid,
    name: String,
    brand: Option<String>,
    barcode: Option<String>,
    categories: Vec<String>,
    last_log_date: NaiveDate,
    last_logged_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
pub(super) struct CategoryCountRow {
    pub(super) value: String,
    pub(super) count: i64,
}

pub(super) fn product_search_fields_from_row(
    row: ProductSearchCandidateRow,
) -> Option<ProductSearchFields> {
    let id = ProductId(row.id);
    let name = match ProductName::new(&row.name) {
        Ok(name) => name,
        Err(error) => {
            tracing::warn!(
                product_id = %id.0,
                error = %error,
                "skipping search candidate with an invalid stored name"
            );
            return None;
        }
    };

    Some(ProductSearchFields::new(id, name, row.brand, row.barcode))
}

pub(super) fn history_search_candidate_from_row(
    row: HistorySearchCandidateRow,
) -> Option<HistorySearchCandidate> {
    let HistorySearchCandidateRow {
        id,
        name,
        brand,
        barcode,
        categories,
        last_log_date,
        last_logged_at,
    } = row;
    let fields = product_search_fields_from_row(ProductSearchCandidateRow {
        id,
        name,
        brand,
        barcode,
    })?;
    let product_id = fields.id().0;
    let categories: Vec<Category> = categories
        .into_iter()
        .filter_map(|value| match Category::new(&value) {
            Some(category) => Some(category),
            None => {
                tracing::warn!(
                    product_id = %product_id,
                    category = %value,
                    "skipping blank stored category on history candidate"
                );
                None
            }
        })
        .collect();

    Some(HistorySearchCandidate::new(
        fields,
        categories,
        SearchRecency::new(last_log_date, last_logged_at),
    ))
}

pub(super) fn product_row_to_product(
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

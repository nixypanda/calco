use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use schemars::JsonSchema;
use serde::Serialize;
use uuid::Uuid;

use crate::catalog::api::shared::{NutrientSummaryDto, nutrient_summary_from_entries};
use crate::catalog::domain::*;

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SourceDto {
    User,
    Off,
    Usda,
    Ifct,
    Indb,
}

impl From<&ProductOrigin> for SourceDto {
    fn from(origin: &ProductOrigin) -> Self {
        match origin {
            ProductOrigin::Custom { .. } => SourceDto::User,
            ProductOrigin::External { source, .. } => match source {
                ExternalSource::Off => SourceDto::Off,
                ExternalSource::Usda => SourceDto::Usda,
                ExternalSource::Ifct => SourceDto::Ifct,
                ExternalSource::Indb => SourceDto::Indb,
            },
        }
    }
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ProductVisibilityDto {
    Global,
}

impl From<ProductVisibility> for ProductVisibilityDto {
    fn from(visibility: ProductVisibility) -> Self {
        match visibility {
            ProductVisibility::Global => ProductVisibilityDto::Global,
        }
    }
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum NutrientConfidenceDto {
    Approved,
    Derived,
    Unknown,
}

impl From<NutrientConfidence> for NutrientConfidenceDto {
    fn from(confidence: NutrientConfidence) -> Self {
        match confidence {
            NutrientConfidence::Approved => NutrientConfidenceDto::Approved,
            NutrientConfidence::Derived => NutrientConfidenceDto::Derived,
            NutrientConfidence::Unknown => NutrientConfidenceDto::Unknown,
        }
    }
}

#[derive(Serialize, JsonSchema)]
pub struct ProductSearchItemDto {
    pub id: Uuid,
    pub source: SourceDto,
    pub source_id: Option<String>,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub nutrition_summary: ProductNutritionSummaryDto,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Serialize, JsonSchema)]
pub struct SearchListResponse {
    pub items: Vec<ProductSearchItemDto>,
}

#[derive(Serialize, JsonSchema)]
pub struct ProductDetailResponse {
    pub id: Uuid,
    pub source: SourceDto,
    pub source_id: Option<String>,
    pub visibility: ProductVisibilityDto,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrition_summary: ProductNutritionSummaryDto,
    pub nutrients: Vec<ProductNutrientDto>,
    pub servings: Vec<ProductServingDto>,
    pub allowed_units: Vec<UnitItemDto>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Serialize, JsonSchema)]
pub struct ProductNutritionSummaryDto {
    pub per_100g: NutrientSummaryDto,
}

#[derive(Serialize, JsonSchema)]
pub struct ProductNutrientDto {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub unit: String,
    pub source: Option<String>,
    pub confidence: Option<NutrientConfidenceDto>,
}

#[derive(Serialize, JsonSchema)]
pub struct ProductServingDto {
    pub unit: String,
    pub grams_per_unit: Decimal,
}

#[derive(Serialize, JsonSchema)]
pub struct UnitItemDto {
    pub code: String,
    pub name: String,
    pub kind: String,
}

pub(crate) fn products_to_search_response(products: Vec<Product>) -> SearchListResponse {
    SearchListResponse {
        items: products
            .into_iter()
            .map(product_to_search_item_dto)
            .collect(),
    }
}

pub(crate) fn product_to_search_item_dto(product: Product) -> ProductSearchItemDto {
    let nutrition_summary = product_nutrition_summary(&product);

    ProductSearchItemDto {
        id: product.id.0,
        source: (&product.origin).into(),
        source_id: product.origin.source_id().map(str::to_owned),
        barcode: product.origin.barcode().map(|b| b.0.clone()),
        name: product.name.into_inner(),
        brand: product.brand.map(|b| b.0),
        categories: product.categories.into_iter().map(|c| c.0).collect(),
        nutrition_summary,
        created_at: product.created_at,
        updated_at: product.updated_at,
    }
}

pub(crate) fn product_to_detail_response(
    product: &Product,
    allowed_units: Vec<(UnitCode, String, String)>,
) -> ProductDetailResponse {
    ProductDetailResponse {
        id: product.id.0,
        source: (&product.origin).into(),
        source_id: product.origin.source_id().map(str::to_owned),
        visibility: product.visibility.into(),
        barcode: product.origin.barcode().map(|b| b.0.clone()),
        name: product.name.as_str().to_string(),
        brand: product.brand.as_ref().map(|b| b.0.clone()),
        categories: product.categories.iter().map(|c| c.0.clone()).collect(),
        default_quantity: product.default_quantity,
        default_unit: product.default_unit.as_ref().map(|u| u.0.clone()),
        nutrition_summary: product_nutrition_summary(product),
        nutrients: product
            .nutrients
            .iter()
            .map(product_nutrient_to_dto)
            .collect(),
        servings: product
            .servings
            .iter()
            .map(product_serving_to_dto)
            .collect(),
        allowed_units: allowed_units
            .into_iter()
            .map(unit_tuple_to_item_dto)
            .collect(),
        created_at: product.created_at,
        updated_at: product.updated_at,
    }
}

pub(crate) fn product_nutrition_summary(product: &Product) -> ProductNutritionSummaryDto {
    let per_100g = nutrient_summary_from_entries(
        product
            .nutrients
            .iter()
            .map(|n| (n.nutrient_code.0.clone(), n.amount_per_100g.value())),
    );
    ProductNutritionSummaryDto { per_100g }
}

pub(crate) fn unit_tuple_to_item_dto(
    (code, name, kind): (UnitCode, String, String),
) -> UnitItemDto {
    UnitItemDto {
        code: code.0,
        name,
        kind,
    }
}

fn product_nutrient_to_dto(nutrient: &ProductNutrient) -> ProductNutrientDto {
    ProductNutrientDto {
        code: nutrient.nutrient_code.0.clone(),
        amount_per_100g: nutrient.amount_per_100g.value(),
        unit: nutrient.unit.0.clone(),
        source: nutrient.source.clone(),
        confidence: nutrient.confidence.map(Into::into),
    }
}

fn product_serving_to_dto(serving: &ProductServing) -> ProductServingDto {
    ProductServingDto {
        unit: serving.unit.0.clone(),
        grams_per_unit: serving.grams_per_unit,
    }
}

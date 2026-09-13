use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post, put},
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::AppState;
use crate::auth::interfaces::http::AuthUser;
use crate::nutrition::catalog::application::BarcodeLookupOrigin;
use crate::nutrition::catalog::domain::*;
use crate::nutrition::module::CatalogModule;

// ─── Routes ────────────────────────────────────────────────────

pub fn catalog_routes(state: AppState) -> Router {
    Router::new()
        .route("/foods/search", get(search_products_handler))
        .route("/foods/categories", get(list_categories_handler))
        .route("/foods/barcode/{barcode}", get(barcode_lookup_handler))
        .route("/foods/{id}", get(product_detail_handler))
        .route(
            "/foods/custom",
            post(create_custom_food_handler).get(list_custom_foods_handler),
        )
        .route(
            "/foods/custom/{id}",
            put(update_custom_food_handler).delete(delete_custom_food_handler),
        )
        .route("/nutrients", get(list_nutrients_handler))
        .route("/nutrients/{code}", get(get_nutrient_handler))
        .route("/units", get(list_units_handler))
        .with_state(state)
}

// ─── DTOs ──────────────────────────────────────────────────────

use crate::nutrition::interfaces::{
    NutrientSummaryDto, error_response, internal_error, nutrient_summary_from_entries,
};

#[derive(Serialize)]
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

#[derive(Serialize)]
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

#[derive(Serialize)]
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

#[derive(Serialize)]
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

#[derive(Serialize)]
pub struct SearchListResponse {
    pub items: Vec<ProductSearchItemDto>,
}

#[derive(Serialize)]
pub struct CustomFoodListResponse {
    pub items: Vec<ProductDetailResponse>,
}

#[derive(Serialize)]
pub struct ProductIdResponse {
    pub id: Uuid,
}

#[derive(Serialize)]
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

#[derive(Serialize)]
pub struct BarcodeLookupResponse {
    #[serde(flatten)]
    pub product: ProductDetailResponse,
    pub lookup: BarcodeLookupMetadataDto,
}

#[derive(Serialize)]
pub struct BarcodeLookupMetadataDto {
    pub origin: BarcodeLookupOriginDto,
    pub note: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BarcodeLookupOriginDto {
    Local,
    OpenFoodFacts,
}

#[derive(Serialize)]
pub struct ProductNutritionSummaryDto {
    pub per_100g: NutrientSummaryDto,
}

#[derive(Serialize)]
pub struct ProductNutrientDto {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub unit: String,
    pub source: Option<String>,
    pub confidence: Option<NutrientConfidenceDto>,
}

#[derive(Serialize)]
pub struct ProductServingDto {
    pub unit: String,
    pub grams_per_unit: Decimal,
}

#[derive(Deserialize)]
pub struct CreateCustomFoodRequest {
    pub name: String,
    pub brand: Option<String>,
    #[serde(default)]
    pub categories: Vec<String>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrients: Vec<CreateProductNutrientDto>,
    pub servings: Vec<CreateProductServingDto>,
}

#[derive(Deserialize)]
pub struct CreateProductNutrientDto {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateProductServingDto {
    pub unit: String,
    pub grams_per_unit: Decimal,
}

#[derive(Serialize)]
pub struct NutrientListResponse {
    pub items: Vec<NutrientItemDto>,
}

#[derive(Serialize)]
pub struct NutrientItemDto {
    pub code: String,
    pub name: String,
    pub unit: String,
    pub category: String,
}

#[derive(Serialize)]
pub struct UnitListResponse {
    pub items: Vec<UnitItemDto>,
}

#[derive(Serialize)]
pub struct UnitItemDto {
    pub code: String,
    pub name: String,
    pub kind: String,
}

#[derive(Serialize)]
pub struct CategoryListResponse {
    pub items: Vec<CategoryItemDto>,
}

#[derive(Serialize)]
pub struct CategoryItemDto {
    pub value: String,
    pub count: i64,
}

#[derive(Deserialize)]
pub struct SearchQuery {
    pub q: String,
    pub scope: Option<String>,
}

#[derive(Deserialize)]
pub struct CategoryQuery {
    #[serde(default)]
    pub q: String,
    pub limit: Option<i64>,
}

// ─── Handlers ─────────────────────────────────────────────────

async fn search_products_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Query(query): Query<SearchQuery>,
) -> impl IntoResponse {
    let scope = match ProductSearchScope::parse(query.scope.as_deref()) {
        Ok(scope) => scope,
        Err(e) => return e.into_response(),
    };

    match state
        .services
        .search(auth.0.id, ProductSearchSpec::parse(&query.q), scope)
        .await
    {
        Ok(items) => Json(products_to_search_response(items)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_categories_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Query(query): Query<CategoryQuery>,
) -> impl IntoResponse {
    let limit = query.limit.unwrap_or(10).clamp(1, 50);
    match state
        .services
        .list_categories(auth.0.id, query.q.trim(), limit)
        .await
    {
        Ok(categories) => {
            let items = categories
                .into_iter()
                .map(category_suggestion_to_item_dto)
                .collect();
            Json(CategoryListResponse { items }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_custom_foods_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
) -> impl IntoResponse {
    let products = match state.services.list_custom_foods(auth.0.id).await {
        Ok(p) => p,
        Err(e) => return internal_error(e).into_response(),
    };

    match custom_foods_to_list_response(&state, &products).await {
        Ok(resp) => Json(resp).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn barcode_lookup_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Path(barcode): Path<String>,
) -> impl IntoResponse {
    let result = match state.services.find_by_barcode(auth.0.id, &barcode).await {
        Ok(Some(result)) => result,
        Ok(None) => {
            return error_response(
                "not_found",
                format!("product with barcode {barcode} not found"),
            )
            .into_response();
        }
        Err(e) => return e.into_response(),
    };

    match state.services.allowed_units(&result.product).await {
        Ok(units) => Json(barcode_lookup_response(result, units)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn product_detail_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let product = match state.services.get_product(auth.0.id, ProductId(id)).await {
        Ok(product) => product,
        Err(e) => return e.into_response(),
    };

    match state.services.allowed_units(&product).await {
        Ok(units) => Json(product_to_detail_response(&product, units)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn create_custom_food_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Json(req): Json<CreateCustomFoodRequest>,
) -> impl IntoResponse {
    let input = match custom_food_request_to_input(req) {
        Ok(input) => input,
        Err(error) => return error.into_response(),
    };
    let product = match state.services.create_custom_food(auth.0.id, input).await {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };
    (StatusCode::CREATED, Json(product_to_id_response(product))).into_response()
}

async fn update_custom_food_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Path(id): Path<Uuid>,
    Json(req): Json<CreateCustomFoodRequest>,
) -> impl IntoResponse {
    let input = match custom_food_request_to_input(req) {
        Ok(input) => input,
        Err(error) => return error.into_response(),
    };
    let updated = match state
        .services
        .update_custom_food(auth.0.id, ProductId(id), input)
        .await
    {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };
    Json(product_to_id_response(updated)).into_response()
}

async fn delete_custom_food_handler(
    auth: AuthUser,
    State(state): State<CatalogModule>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    match state
        .services
        .delete_custom_food(auth.0.id, ProductId(id))
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

async fn list_nutrients_handler(
    _auth: AuthUser,
    State(state): State<CatalogModule>,
) -> impl IntoResponse {
    match state.services.list_nutrients().await {
        Ok(nutrients) => {
            let items: Vec<NutrientItemDto> =
                nutrients.into_iter().map(nutrient_to_item_dto).collect();
            Json(NutrientListResponse { items }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn get_nutrient_handler(
    _auth: AuthUser,
    State(state): State<CatalogModule>,
    Path(code): Path<String>,
) -> impl IntoResponse {
    match state.services.get_nutrient(&code).await {
        Ok(Some(n)) => Json(nutrient_to_item_dto(n)).into_response(),
        Ok(None) => {
            error_response("not_found", format!("nutrient {code} not found")).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_units_handler(
    _auth: AuthUser,
    State(state): State<CatalogModule>,
) -> impl IntoResponse {
    match state.services.list_units().await {
        Ok(units) => {
            let items: Vec<UnitItemDto> = units.into_iter().map(unit_tuple_to_item_dto).collect();
            Json(UnitListResponse { items }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

// ─── Helpers ───────────────────────────────────────────────────

// ─── Conversions ───────────────────────────────────────────────

fn custom_food_request_to_input(
    req: CreateCustomFoodRequest,
) -> Result<CustomProductBuilder, NutritionError> {
    Ok(CustomProductBuilder::new(req.name)
        .brand(req.brand)
        .categories(req.categories)
        .optional_default_portion(req.default_quantity, req.default_unit)?
        .nutrients(product_nutrient_dtos_to_inputs(req.nutrients))
        .servings(product_serving_dtos_to_inputs(req.servings)))
}

fn product_nutrient_dtos_to_inputs(
    entries: Vec<CreateProductNutrientDto>,
) -> Vec<ProductNutrientInput> {
    entries
        .into_iter()
        .map(product_nutrient_dto_to_input)
        .collect()
}

fn product_nutrient_dto_to_input(entry: CreateProductNutrientDto) -> ProductNutrientInput {
    ProductNutrientInput {
        code: entry.code,
        amount_per_100g: entry.amount_per_100g,
        source: entry.source,
        confidence: entry.confidence,
    }
}

fn product_serving_dtos_to_inputs(
    entries: Vec<CreateProductServingDto>,
) -> Vec<ProductServingInput> {
    entries
        .into_iter()
        .map(product_serving_dto_to_input)
        .collect()
}

fn product_serving_dto_to_input(entry: CreateProductServingDto) -> ProductServingInput {
    ProductServingInput {
        unit: entry.unit,
        grams_per_unit: entry.grams_per_unit,
    }
}

fn products_to_search_response(products: Vec<Product>) -> SearchListResponse {
    SearchListResponse {
        items: products
            .into_iter()
            .map(product_to_search_item_dto)
            .collect(),
    }
}

async fn custom_foods_to_list_response(
    state: &CatalogModule,
    products: &[Product],
) -> Result<CustomFoodListResponse, NutritionError> {
    let all_units = state.services.list_units().await?;
    let mut items = Vec::with_capacity(products.len());
    for product in products {
        let allowed_units = state.services.filter_allowed_units(product, &all_units);
        items.push(product_to_detail_response(product, allowed_units));
    }
    Ok(CustomFoodListResponse { items })
}

fn product_to_search_item_dto(product: Product) -> ProductSearchItemDto {
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

fn product_nutrition_summary(product: &Product) -> ProductNutritionSummaryDto {
    let per_100g = nutrient_summary_from_entries(
        product
            .nutrients
            .iter()
            .map(|n| (n.nutrient_code.0.clone(), n.amount_per_100g.value())),
    );
    ProductNutritionSummaryDto { per_100g }
}

fn category_suggestion_to_item_dto(category: CategorySuggestion) -> CategoryItemDto {
    CategoryItemDto {
        value: category.value,
        count: category.count,
    }
}

fn product_to_id_response(product: Product) -> ProductIdResponse {
    ProductIdResponse { id: product.id.0 }
}

fn nutrient_to_item_dto(nutrient: Nutrient) -> NutrientItemDto {
    NutrientItemDto {
        code: nutrient.code.0,
        name: nutrient.name,
        unit: nutrient.unit.0,
        category: nutrient.category,
    }
}

fn unit_tuple_to_item_dto((code, name, kind): (UnitCode, String, String)) -> UnitItemDto {
    UnitItemDto {
        code: code.0,
        name,
        kind,
    }
}

fn product_to_detail_response(
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

fn barcode_lookup_response(
    result: crate::nutrition::catalog::application::BarcodeLookupResult,
    allowed_units: Vec<(UnitCode, String, String)>,
) -> BarcodeLookupResponse {
    let (origin, note) = match result.origin {
        BarcodeLookupOrigin::Local => (BarcodeLookupOriginDto::Local, None),
        BarcodeLookupOrigin::OpenFoodFacts => (
            BarcodeLookupOriginDto::OpenFoodFacts,
            Some("Food was not found locally and was imported from Open Food Facts.".into()),
        ),
    };
    BarcodeLookupResponse {
        product: product_to_detail_response(&result.product, allowed_units),
        lookup: BarcodeLookupMetadataDto { origin, note },
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

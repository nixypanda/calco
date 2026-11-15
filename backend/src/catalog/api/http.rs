use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post, put},
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::AppState;
use crate::auth::api::http::{ReadUser, WriteUser};
use crate::catalog::api::dto::{
    ProductDetailResponse, UnitItemDto, product_to_detail_response, products_to_search_response,
    unit_tuple_to_item_dto,
};
use crate::catalog::app::BarcodeLookupOrigin;
use crate::catalog::domain::*;
use crate::catalog::module::CatalogModule;
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

use crate::catalog::api::shared::{error_response, internal_error};

#[derive(Serialize)]
pub struct CustomFoodListResponse {
    pub items: Vec<ProductDetailResponse>,
}

#[derive(Serialize)]
pub struct ProductIdResponse {
    pub id: Uuid,
}

#[derive(Serialize)]
pub struct BarcodeLookupResponse {
    #[serde(flatten)]
    pub product: ProductDetailResponse,
    pub lookup: BarcodeLookupMetaDto,
}

#[derive(Serialize)]
pub struct BarcodeLookupMetaDto {
    pub origin: BarcodeLookupOriginDto,
    pub note: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BarcodeLookupOriginDto {
    Local,
    OpenFoodFacts,
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
    auth: ReadUser,
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
    auth: ReadUser,
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
    auth: ReadUser,
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
    auth: ReadUser,
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
    auth: ReadUser,
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
    auth: WriteUser,
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
    auth: WriteUser,
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
    auth: WriteUser,
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
    _auth: ReadUser,
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
    _auth: ReadUser,
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
    _auth: ReadUser,
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
) -> Result<CustomProductBuilder, CatalogError> {
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

async fn custom_foods_to_list_response(
    state: &CatalogModule,
    products: &[Product],
) -> Result<CustomFoodListResponse, CatalogError> {
    let all_units = state.services.list_units().await?;
    let mut items = Vec::with_capacity(products.len());
    for product in products {
        let allowed_units = state.services.filter_allowed_units(product, &all_units);
        items.push(product_to_detail_response(product, allowed_units));
    }
    Ok(CustomFoodListResponse { items })
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

fn barcode_lookup_response(
    result: crate::catalog::app::BarcodeLookupResult,
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
        lookup: BarcodeLookupMetaDto { origin, note },
    }
}

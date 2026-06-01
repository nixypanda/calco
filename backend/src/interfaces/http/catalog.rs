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

use crate::domain::catalog::*;
use crate::interfaces::http::auth::{AppState, AuthUser};

// ─── Routes ────────────────────────────────────────────────────

pub fn catalog_routes(state: AppState) -> Router {
    Router::new()
        .route("/foods/search", get(search_products_handler))
        .route("/foods/categories", get(list_categories_handler))
        .route("/foods/barcode/{barcode}", get(barcode_lookup_handler))
        .route("/foods/{id}", get(product_detail_handler))
        .route("/foods/custom", post(create_custom_food_handler))
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

use crate::interfaces::http::{error_response, internal_error};

#[derive(Serialize)]
pub struct ProductSearchItemDto {
    pub id: Uuid,
    pub source: String,
    pub source_id: Option<String>,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub serving_size_g: Option<Decimal>,
    pub energy_kcal_per_100g: Option<Decimal>,
    pub energy_kcal_per_serving: Option<Decimal>,
}

#[derive(Serialize)]
pub struct SearchListResponse {
    pub items: Vec<ProductSearchItemDto>,
}

#[derive(Serialize)]
pub struct ProductIdResponse {
    pub id: Uuid,
}

#[derive(Serialize)]
pub struct ProductDetailResponse {
    pub id: Uuid,
    pub source: String,
    pub source_id: Option<String>,
    pub visibility: String,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub serving_size_g: Option<Decimal>,
    pub nutrients: Vec<ProductNutrientDto>,
    pub servings: Vec<ProductServingDto>,
    pub allowed_units: Vec<UnitItemDto>,
}

#[derive(Serialize)]
pub struct ProductNutrientDto {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub unit: String,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

#[derive(Serialize)]
pub struct ProductServingDto {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

#[derive(Deserialize)]
pub struct CreateCustomFoodRequest {
    pub name: String,
    pub brand: Option<String>,
    #[serde(default)]
    pub categories: Vec<String>,
    pub serving_size_g: Option<Decimal>,
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
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
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
}

#[derive(Deserialize)]
pub struct CategoryQuery {
    #[serde(default)]
    pub q: String,
    pub limit: Option<i64>,
}

struct CustomFoodParams {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    serving_size_g: Option<Decimal>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<ProductNutrientInput>,
    servings: Vec<ProductServingInput>,
}

// ─── Handlers ─────────────────────────────────────────────────

async fn search_products_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> impl IntoResponse {
    match state
        .product_repo
        .search(ProductSearchQuery::parse(&query.q), Some(auth.0.id))
        .await
    {
        Ok(items) => Json(products_to_search_response(items)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_categories_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<CategoryQuery>,
) -> impl IntoResponse {
    let limit = query.limit.unwrap_or(10).clamp(1, 50);
    match state
        .product_repo
        .list_categories(query.q.trim(), Some(auth.0.id), limit)
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

async fn barcode_lookup_handler(
    _auth: AuthUser,
    State(state): State<AppState>,
    Path(barcode): Path<String>,
) -> impl IntoResponse {
    let product = match state.product_repo.find_by_barcode(&barcode).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return error_response(
                "not_found",
                format!("product with barcode {barcode} not found"),
            )
            .into_response();
        }
        Err(e) => return internal_error(e).into_response(),
    };

    match load_allowed_units(&state, &product).await {
        Ok(units) => Json(product_to_detail_response(&product, units)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn product_detail_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let product = match state.product_repo.find_by_id(ProductId(id)).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return error_response("not_found", format!("product {id} not found")).into_response();
        }
        Err(e) => return internal_error(e).into_response(),
    };

    if product.visibility != ProductVisibility::Global && !product.is_owned_by(auth.0.id) {
        return error_response("not_found", format!("product {id} not found")).into_response();
    }

    match load_allowed_units(&state, &product).await {
        Ok(units) => Json(product_to_detail_response(&product, units)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn create_custom_food_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateCustomFoodRequest>,
) -> impl IntoResponse {
    let args = custom_food_request_to_params(req);

    let catalog = match load_nutrient_catalog(&state).await {
        Ok(c) => c,
        Err(e) => return internal_error(e).into_response(),
    };

    let product = match Product::new_custom(
        auth.0.id,
        args.name,
        args.brand,
        args.categories,
        args.serving_size_g,
        args.default_quantity,
        args.default_unit,
        args.nutrients,
        args.servings,
        &catalog,
    ) {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };

    match state.product_repo.create(&product).await {
        Ok(()) => (StatusCode::CREATED, Json(product_to_id_response(product))).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn update_custom_food_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<CreateCustomFoodRequest>,
) -> impl IntoResponse {
    let args = custom_food_request_to_params(req);

    let existing = match state.product_repo.find_by_id(ProductId(id)).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return error_response("not_found", format!("product {id} not found")).into_response();
        }
        Err(e) => return internal_error(e).into_response(),
    };

    if let Err(e) = existing.assert_owned_by(auth.0.id) {
        return e.into_response();
    }

    let catalog = match load_nutrient_catalog(&state).await {
        Ok(c) => c,
        Err(e) => return internal_error(e).into_response(),
    };

    let updated = match existing.update_custom(
        args.name,
        args.brand,
        args.categories,
        args.serving_size_g,
        args.default_quantity,
        args.default_unit,
        args.nutrients,
        args.servings,
        &catalog,
    ) {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };

    match state.product_repo.update(&updated).await {
        Ok(()) => Json(product_to_id_response(updated)).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn delete_custom_food_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let existing = match state.product_repo.find_by_id(ProductId(id)).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return error_response("not_found", format!("product {id} not found")).into_response();
        }
        Err(e) => return internal_error(e).into_response(),
    };

    if let Err(e) = existing.assert_owned_by(auth.0.id) {
        return e.into_response();
    }

    match state.product_repo.delete(ProductId(id)).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_nutrients_handler(
    _auth: AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    match state.nutrient_repo.list_all().await {
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
    State(state): State<AppState>,
    Path(code): Path<String>,
) -> impl IntoResponse {
    match state.nutrient_repo.find_by_code(&code).await {
        Ok(Some(n)) => Json(nutrient_to_item_dto(n)).into_response(),
        Ok(None) => {
            error_response("not_found", format!("nutrient {code} not found")).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_units_handler(_auth: AuthUser, State(state): State<AppState>) -> impl IntoResponse {
    match state.unit_repo.list_all().await {
        Ok(units) => {
            let items: Vec<UnitItemDto> = units.into_iter().map(unit_tuple_to_item_dto).collect();
            Json(UnitListResponse { items }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

// ─── Helpers ───────────────────────────────────────────────────

async fn load_nutrient_catalog(state: &AppState) -> Result<NutrientCatalog, NutritionError> {
    let nutrients = state.nutrient_repo.list_all().await?;
    Ok(nutrients.into_iter().collect())
}

async fn load_allowed_units(
    state: &AppState,
    product: &Product,
) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
    let all_units = state.unit_repo.list_all().await?;
    let allowed = product.allowed_unit_codes(&state.unit_converter);
    Ok(all_units
        .into_iter()
        .filter(|(code, _, _)| allowed.contains(&code.0))
        .collect())
}

// ─── Conversions ───────────────────────────────────────────────

fn custom_food_request_to_params(req: CreateCustomFoodRequest) -> CustomFoodParams {
    CustomFoodParams {
        name: req.name,
        brand: req.brand,
        categories: req.categories,
        serving_size_g: req.serving_size_g,
        default_quantity: req.default_quantity,
        default_unit: req.default_unit,
        nutrients: product_nutrient_dtos_to_inputs(req.nutrients),
        servings: product_serving_dtos_to_inputs(req.servings),
    }
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
        label: entry.label,
        quantity: entry.quantity,
        unit: entry.unit,
        grams: entry.grams,
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

fn product_to_search_item_dto(product: Product) -> ProductSearchItemDto {
    let energy_kcal_per_100g = product_energy_kcal_per_100g(&product);
    let energy_kcal_per_serving =
        energy_kcal_per_serving(energy_kcal_per_100g, product.serving_size_g);

    ProductSearchItemDto {
        id: product.id.0,
        source: product.source.as_str().to_string(),
        source_id: product.source_id,
        barcode: product.barcode.map(|b| b.0),
        name: product.name.0,
        brand: product.brand.map(|b| b.0),
        categories: product.categories.into_iter().map(|c| c.0).collect(),
        serving_size_g: product.serving_size_g,
        energy_kcal_per_100g,
        energy_kcal_per_serving,
    }
}

fn product_energy_kcal_per_100g(product: &Product) -> Option<Decimal> {
    product
        .nutrients
        .iter()
        .find(|n| n.nutrient_code.0 == "ENERGY_KCAL")
        .map(|n| n.amount_per_100g.0)
}

fn energy_kcal_per_serving(
    energy_kcal_per_100g: Option<Decimal>,
    serving_size_g: Option<Decimal>,
) -> Option<Decimal> {
    match (energy_kcal_per_100g, serving_size_g) {
        (Some(kcal), Some(serving_size_g)) => Some(kcal * serving_size_g / Decimal::new(100, 0)),
        _ => None,
    }
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
        code: nutrient.code().0.clone(),
        name: nutrient.name().to_string(),
        unit: nutrient.unit().0.clone(),
        category: nutrient.category().to_string(),
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
        source: product.source.as_str().to_string(),
        source_id: product.source_id.clone(),
        visibility: product.visibility.as_str().to_string(),
        barcode: product.barcode.as_ref().map(|b| b.0.clone()),
        name: product.name.0.clone(),
        brand: product.brand.as_ref().map(|b| b.0.clone()),
        categories: product.categories.iter().map(|c| c.0.clone()).collect(),
        default_quantity: product.default_quantity,
        default_unit: product.default_unit.as_ref().map(|u| u.0.clone()),
        serving_size_g: product.serving_size_g,
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
    }
}

fn product_nutrient_to_dto(nutrient: &ProductNutrient) -> ProductNutrientDto {
    ProductNutrientDto {
        code: nutrient.nutrient_code.0.clone(),
        amount_per_100g: nutrient.amount_per_100g.0,
        unit: nutrient.unit.0.clone(),
        source: nutrient.source.clone(),
        confidence: nutrient.confidence.as_ref().map(|c| c.as_str().to_string()),
    }
}

fn product_serving_to_dto(serving: &ProductServing) -> ProductServingDto {
    ProductServingDto {
        label: serving.label.0.clone(),
        quantity: serving.quantity,
        unit: serving.unit.0.clone(),
        grams: serving.grams,
    }
}

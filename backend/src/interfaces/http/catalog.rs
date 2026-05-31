use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post, put},
    Router,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::catalog::*;
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
        .route("/foods/custom/{id}", put(update_custom_food_handler).delete(delete_custom_food_handler))
        .route("/nutrients", get(list_nutrients_handler))
        .route("/nutrients/{code}", get(get_nutrient_handler))
        .route("/units", get(list_units_handler))
        .with_state(state)
}

// ─── DTOs ──────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: ErrorBody,
}

#[derive(Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

fn error_response(code: &str, message: String) -> (StatusCode, Json<ErrorResponse>) {
    (
        match code {
            "not_found" => StatusCode::NOT_FOUND,
            "forbidden" => StatusCode::FORBIDDEN,
            "validation" => StatusCode::BAD_REQUEST,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        },
        Json(ErrorResponse {
            error: ErrorBody {
                code: code.to_string(),
                message,
            },
        }),
    )
}

fn internal_error<E: std::fmt::Display>(e: E) -> (StatusCode, Json<ErrorResponse>) {
    tracing::error!(error = %e, "catalog request failed");
    error_response("internal", "internal server error".into())
}

#[derive(Serialize)]
pub struct SearchResult {
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
    pub nutrients: Vec<NutrientEntry>,
    pub servings: Vec<ServingEntry>,
    pub allowed_units: Vec<UnitItem>,
}

#[derive(Serialize)]
pub struct NutrientEntry {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub unit: String,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

#[derive(Serialize)]
pub struct ServingEntry {
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
    pub nutrients: Vec<CreateNutrientEntry>,
    pub servings: Vec<CreateServingEntry>,
}

#[derive(Deserialize)]
pub struct CreateNutrientEntry {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateServingEntry {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

#[derive(Serialize)]
pub struct NutrientListResponse {
    pub items: Vec<NutrientItem>,
}

#[derive(Serialize)]
pub struct NutrientItem {
    pub code: String,
    pub name: String,
    pub unit: String,
    pub category: String,
}

#[derive(Serialize)]
pub struct UnitListResponse {
    pub items: Vec<UnitItem>,
}

#[derive(Serialize)]
pub struct UnitItem {
    pub code: String,
    pub name: String,
    pub kind: String,
}

#[derive(Serialize)]
pub struct CategoryListResponse {
    pub items: Vec<CategoryItem>,
}

#[derive(Serialize)]
pub struct CategoryItem {
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

// ─── Handlers ─────────────────────────────────────────────────

async fn search_products_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> impl IntoResponse {
    let services = &state.catalog_services;
    let products = services.search_products(SearchCriteria {
        query: query.q,
        user_id: Some(auth.0.id),
    }).await;

    match products {
        Ok(items) => {
            let results: Vec<SearchResult> = items
                .into_iter()
                .map(|p| {
                    let energy_kcal_per_100g = p
                        .nutrients
                        .iter()
                        .find(|n| n.nutrient_code.0 == "ENERGY_KCAL")
                        .map(|n| n.amount_per_100g.0);
                    let energy_kcal_per_serving = match (energy_kcal_per_100g, p.serving_size_g) {
                        (Some(kcal), Some(serving_size_g)) => {
                            Some(kcal * serving_size_g / Decimal::new(100, 0))
                        }
                        _ => None,
                    };

                    SearchResult {
                        id: p.id.0,
                        source: p.source.as_str().to_string(),
                        source_id: p.source_id,
                        barcode: p.barcode.map(|b| b.0),
                        name: p.name.0,
                        brand: p.brand.map(|b| b.0),
                        categories: p.categories.into_iter().map(|c| c.0).collect(),
                        serving_size_g: p.serving_size_g,
                        energy_kcal_per_100g,
                        energy_kcal_per_serving,
                    }
                })
                .collect();
            Json(serde_json::json!({ "items": results })).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_categories_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<CategoryQuery>,
) -> impl IntoResponse {
    let services = &state.catalog_services;
    match services
        .list_categories(&query.q, Some(auth.0.id), query.limit)
        .await
    {
        Ok(categories) => {
            let items = categories
                .into_iter()
                .map(|c| CategoryItem {
                    value: c.value,
                    count: c.count,
                })
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
    let services = &state.catalog_services;
    match services.get_product_by_barcode(&barcode).await {
        Ok(product) => match services.allowed_units_for_product(&product).await {
            Ok(units) => Json(serde_json::to_value(product_to_detail(&product, units)).unwrap()).into_response(),
            Err(e) => internal_error(e).into_response(),
        },
        Err(CatalogError::NotFound(_)) => {
            error_response("not_found", format!("product with barcode {barcode} not found")).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn product_detail_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.catalog_services;
    match services.get_product(ProductId(id)).await {
        Ok(product) if product.visibility == ProductVisibility::Global || product.is_owned_by(auth.0.id) => {
            match services.allowed_units_for_product(&product).await {
                Ok(units) => Json(serde_json::to_value(product_to_detail(&product, units)).unwrap()).into_response(),
                Err(e) => internal_error(e).into_response(),
            }
        }
        Ok(_) => error_response("not_found", format!("product {id} not found")).into_response(),
        Err(CatalogError::NotFound(_)) => {
            error_response("not_found", format!("product {id} not found")).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn create_custom_food_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateCustomFoodRequest>,
) -> impl IntoResponse {
    let services = &state.catalog_services;

    match services.create_custom_food(
        auth.0.id,
        req.name,
        req.brand,
        req.categories,
        req.serving_size_g,
        req.default_quantity,
        req.default_unit,
        req.nutrients
            .into_iter()
            .map(|n| ProductNutrientInput {
                code: n.code,
                amount_per_100g: n.amount_per_100g,
                source: n.source,
                confidence: n.confidence,
            })
            .collect(),
        req.servings
            .into_iter()
            .map(|s| ProductServingInput {
                label: s.label,
                quantity: s.quantity,
                unit: s.unit,
                grams: s.grams,
            })
            .collect(),
    )
    .await
    {
        Ok(product) => (
            StatusCode::CREATED,
            Json(serde_json::json!({ "id": product.id.0 })),
        )
            .into_response(),
        Err(CatalogError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn update_custom_food_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<CreateCustomFoodRequest>,
) -> impl IntoResponse {
    let services = &state.catalog_services;

    match services.update_custom_food(
        ProductId(id),
        auth.0.id,
        req.name,
        req.brand,
        req.categories,
        req.serving_size_g,
        req.default_quantity,
        req.default_unit,
        req.nutrients
            .into_iter()
            .map(|n| ProductNutrientInput {
                code: n.code,
                amount_per_100g: n.amount_per_100g,
                source: n.source,
                confidence: n.confidence,
            })
            .collect(),
        req.servings
            .into_iter()
            .map(|s| ProductServingInput {
                label: s.label,
                quantity: s.quantity,
                unit: s.unit,
                grams: s.grams,
            })
            .collect(),
    )
    .await
    {
        Ok(product) => Json(serde_json::json!({ "id": product.id.0 })).into_response(),
        Err(CatalogError::NotFound(_)) => {
            error_response("not_found", format!("product {id} not found")).into_response()
        }
        Err(CatalogError::Forbidden(msg)) => error_response("forbidden", msg).into_response(),
        Err(CatalogError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn delete_custom_food_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.catalog_services;

    match services.delete_custom_food(ProductId(id), auth.0.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(CatalogError::NotFound(_)) => {
            error_response("not_found", format!("product {id} not found")).into_response()
        }
        Err(CatalogError::Forbidden(msg)) => error_response("forbidden", msg).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_nutrients_handler(
    _auth: AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let services = &state.catalog_services;
    match services.list_nutrients().await {
        Ok(nutrients) => {
            let items: Vec<NutrientItem> = nutrients
                .into_iter()
                .map(|n| NutrientItem {
                    code: n.code().0.clone(),
                    name: n.name().to_string(),
                    unit: n.unit().0.clone(),
                    category: n.category().to_string(),
                })
                .collect();
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
    let services = &state.catalog_services;
    match services.get_nutrient(&code).await {
        Ok(n) => {
            Json(serde_json::json!({
                "code": n.code().0,
                "name": n.name(),
                "unit": n.unit().0,
                "category": n.category(),
            }))
            .into_response()
        }
        Err(CatalogError::NotFound(_)) => {
            error_response("not_found", format!("nutrient {code} not found")).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_units_handler(
    _auth: AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let services = &state.catalog_services;
    match services.list_units().await {
        Ok(units) => {
            let items: Vec<UnitItem> = units
                .into_iter()
                .map(|(code, name, kind)| UnitItem {
                    code: code.0,
                    name,
                    kind,
                })
                .collect();
            Json(UnitListResponse { items }).into_response()
        }
        Err(e) => internal_error(e).into_response(),
    }
}

fn product_to_detail(
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
            .map(|pn| NutrientEntry {
                code: pn.nutrient_code.0.clone(),
                amount_per_100g: pn.amount_per_100g.0,
                unit: pn.unit.0.clone(),
                source: pn.source.clone(),
                confidence: pn.confidence.as_ref().map(|c| c.as_str().to_string()),
            })
            .collect(),
        servings: product
            .servings
            .iter()
            .map(|ps| ServingEntry {
                label: ps.label.0.clone(),
                quantity: ps.quantity,
                unit: ps.unit.0.clone(),
                grams: ps.grams,
            })
            .collect(),
        allowed_units: allowed_units
            .into_iter()
            .map(|(code, name, kind)| UnitItem {
                code: code.0,
                name,
                kind,
            })
            .collect(),
    }
}

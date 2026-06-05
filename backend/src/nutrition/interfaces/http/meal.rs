use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::AppState;
use crate::auth::interfaces::http::AuthUser;
use crate::nutrition::application::food_log::load_meal_products;
use crate::nutrition::application::meal::*;
use crate::nutrition::domain::calculation::Quantity;
use crate::nutrition::domain::catalog::{Product, ProductId, UnitCode};
use crate::nutrition::domain::error::NutritionError;
use crate::nutrition::domain::meal::*;

pub fn meal_routes(state: AppState) -> Router {
    Router::new()
        .route("/meals", post(create_meal_handler).get(list_meals_handler))
        .route(
            "/meals/{id}",
            get(get_meal_handler)
                .put(update_meal_handler)
                .delete(delete_meal_handler),
        )
        .route("/meals/{id}/nutrients", get(meal_nutrients_handler))
        .with_state(state)
}

use crate::nutrition::interfaces::http::{
    NutrientSummaryDto, error_response, internal_error, is_summary_nutrient_code,
    nutrient_summary_from_entries,
};

#[derive(Deserialize)]
pub struct CreateMealRequest {
    pub name: String,
    pub notes: Option<String>,
    pub total_quantity: Option<QuantityDto>,
    pub components: Vec<CreateMealComponentRequest>,
}

#[derive(Deserialize)]
pub struct CreateMealComponentRequest {
    pub item: ItemRefDto,
    pub quantity: QuantityDto,
}

#[derive(Deserialize)]
pub struct ItemRefDto {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: Uuid,
}

#[derive(Deserialize, Serialize)]
pub struct QuantityDto {
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Serialize)]
pub struct MealResponse {
    pub id: Uuid,
    pub name: String,
    pub notes: Option<String>,
    pub total_quantity: Option<QuantityDto>,
    pub nutrition_summary: Option<NutrientSummaryDto>,
    pub components: Vec<MealComponentDto>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Serialize)]
pub struct MealComponentDto {
    pub id: Uuid,
    pub item: ItemDto,
    pub quantity: QuantityDto,
    pub nutrition_summary: Option<NutrientSummaryDto>,
}

#[derive(Serialize)]
pub struct ItemDto {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: Uuid,
}

#[derive(Serialize)]
pub struct MealListResponse {
    pub items: Vec<MealResponse>,
}

#[derive(Serialize)]
pub struct MealNutritionResponse {
    pub meal_id: Uuid,
    pub quantity: QuantityDto,
    pub nutrition_summary: NutrientSummaryDto,
    pub nutrients: Vec<MealNutrientDto>,
}

#[derive(Serialize)]
pub struct MealNutrientDto {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Deserialize)]
pub struct MealNutrientQuery {
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Deserialize)]
pub struct UpdateMealRequest {
    pub name: Option<String>,
    pub notes: Option<Option<String>>,
    pub total_quantity: Option<Option<QuantityDto>>,
    pub components: Option<Vec<CreateMealComponentRequest>>,
}

async fn create_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateMealRequest>,
) -> impl IntoResponse {
    let services = &state.meal_services;

    let input = match meal_create_request_to_input(req, auth.0.id) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services.create_meal(input).await {
        Ok(meal) => match meal_to_response(&state, &meal).await {
            Ok(resp) => (StatusCode::CREATED, Json(resp)).into_response(),
            Err(e) => internal_error(e).into_response(),
        },
        Err(e) => e.into_response(),
    }
}

async fn get_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    match state.meal_repo.find_by_id(MealId(id)).await {
        Ok(Some(meal)) => {
            if !meal.is_owned_by(auth.0.id) {
                return error_response("forbidden", "not your meal".into()).into_response();
            }
            match meal_to_response(&state, &meal).await {
                Ok(resp) => Json(resp).into_response(),
                Err(e) => internal_error(e).into_response(),
            }
        }
        Ok(None) => error_response("not_found", "meal not found".into()).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_meals_handler(auth: AuthUser, State(state): State<AppState>) -> impl IntoResponse {
    match state.meal_repo.list_by_user_id(auth.0.id).await {
        Ok(meals) => match meals_to_list_response(&state, meals).await {
            Ok(resp) => Json(resp).into_response(),
            Err(e) => internal_error(e).into_response(),
        },
        Err(e) => internal_error(e).into_response(),
    }
}

async fn update_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMealRequest>,
) -> impl IntoResponse {
    let services = &state.meal_services;

    let input = match meal_update_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services.update_meal(MealId(id), auth.0.id, input).await {
        Ok(meal) => match meal_to_response(&state, &meal).await {
            Ok(resp) => Json(resp).into_response(),
            Err(e) => internal_error(e).into_response(),
        },
        Err(e) => e.into_response(),
    }
}

async fn delete_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.meal_services;

    match services.delete_meal(MealId(id), auth.0.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

async fn meal_nutrients_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Query(query): Query<MealNutrientQuery>,
) -> impl IntoResponse {
    match state.meal_repo.find_by_id(MealId(id)).await {
        Ok(Some(meal)) => {
            if !meal.is_owned_by(auth.0.id) {
                return error_response("forbidden", "not your meal".into()).into_response();
            }
        }
        Ok(None) => return error_response("not_found", "meal not found".into()).into_response(),
        Err(e) => return internal_error(e).into_response(),
    }

    let quantity = match Quantity::new(query.amount, UnitCode(query.unit)) {
        Ok(q) => q,
        Err(err) => return err.into_response(),
    };
    let services = &state.meal_services;
    match services.get_meal_nutrients(MealId(id), quantity).await {
        Ok(nutrition) => Json(meal_nutrition_to_response(nutrition)).into_response(),
        Err(e) => e.into_response(),
    }
}

// ─── Conversions ───────────────────────────────────────────────

fn parse_component_item(item: &ItemRefDto) -> Result<MealComponentItem, NutritionError> {
    match item.item_type.as_str() {
        "product" => Ok(MealComponentItem::Product(ProductId(item.id))),
        other => Err(NutritionError::Validation(format!(
            "unsupported component item type: {other}"
        ))),
    }
}

fn parse_quantity_dto(q: &QuantityDto) -> Result<Quantity, NutritionError> {
    Quantity::new(q.amount, UnitCode(q.unit.clone()))
}

fn meal_create_request_to_input(
    req: CreateMealRequest,
    user_id: Uuid,
) -> Result<CreateMealInput, NutritionError> {
    Ok(CreateMealInput {
        user_id,
        name: req.name,
        notes: req.notes,
        total_quantity_amount: req.total_quantity.as_ref().map(|q| q.amount),
        total_quantity_unit: req
            .total_quantity
            .as_ref()
            .map(|q| UnitCode(q.unit.clone())),
        components: meal_component_requests_to_inputs(req.components)?,
    })
}

fn meal_update_request_to_input(req: UpdateMealRequest) -> Result<UpdateMealInput, NutritionError> {
    let total_quantity = req.total_quantity;
    let total_quantity_amount = total_quantity
        .as_ref()
        .map(|quantity| quantity.as_ref().map(|q| q.amount));
    let total_quantity_unit = total_quantity.map(|quantity| quantity.map(|q| UnitCode(q.unit)));
    let components = req
        .components
        .map(meal_component_requests_to_inputs)
        .transpose()?;
    Ok(UpdateMealInput {
        name: req.name,
        notes: req.notes,
        total_quantity_amount,
        total_quantity_unit,
        components,
    })
}

fn meal_component_requests_to_inputs(
    components: Vec<CreateMealComponentRequest>,
) -> Result<Vec<CreateMealComponentInput>, NutritionError> {
    components
        .into_iter()
        .map(meal_component_request_to_input)
        .collect()
}

fn meal_component_request_to_input(
    component: CreateMealComponentRequest,
) -> Result<CreateMealComponentInput, NutritionError> {
    Ok(CreateMealComponentInput {
        item: parse_component_item(&component.item)?,
        quantity: parse_quantity_dto(&component.quantity)?,
    })
}

async fn meals_to_list_response(
    state: &AppState,
    meals: Vec<Meal>,
) -> Result<MealListResponse, NutritionError> {
    let mut items = Vec::with_capacity(meals.len());
    for meal in &meals {
        items.push(meal_to_response(state, meal).await?);
    }
    Ok(MealListResponse { items })
}

async fn meal_to_response(state: &AppState, meal: &Meal) -> Result<MealResponse, NutritionError> {
    let products = load_meal_products(meal, state.product_repo.as_ref()).await?;
    Ok(meal_to_response_with_products(
        meal,
        &products,
        &state.unit_converter,
    ))
}

fn meal_to_response_with_products(
    meal: &Meal,
    products: &[(ProductId, Product)],
    unit_converter: &crate::nutrition::domain::units::UnitConverter,
) -> MealResponse {
    MealResponse {
        id: meal.id.0,
        name: meal.name.0.clone(),
        notes: meal.notes.as_ref().map(|n| n.0.clone()),
        total_quantity: meal_total_quantity_to_dto(meal),
        nutrition_summary: meal_declared_nutrition_summary(meal, products, unit_converter),
        components: meal
            .components
            .iter()
            .map(|component| meal_component_to_dto(component, products, unit_converter))
            .collect(),
        created_at: meal.created_at,
        updated_at: meal.updated_at,
    }
}

fn meal_total_quantity_to_dto(meal: &Meal) -> Option<QuantityDto> {
    meal.total_quantity_amount.map(|amount| QuantityDto {
        amount,
        unit: meal
            .total_quantity_unit
            .as_ref()
            .map(|unit| unit.0.clone())
            .unwrap_or_default(),
    })
}

fn meal_component_to_dto(
    component: &MealComponent,
    products: &[(ProductId, Product)],
    unit_converter: &crate::nutrition::domain::units::UnitConverter,
) -> MealComponentDto {
    let (item_type, item_id) = meal_component_item_to_parts(&component.item);
    MealComponentDto {
        id: component.id,
        item: item_parts_to_dto(item_type, item_id),
        quantity: quantity_to_dto(component.quantity_amount, component.quantity_unit.0.clone()),
        nutrition_summary: meal_component_nutrition_summary(component, products, unit_converter),
    }
}

fn meal_component_item_to_parts(item: &MealComponentItem) -> (&'static str, Uuid) {
    match item {
        MealComponentItem::Product(product_id) => ("product", product_id.0),
    }
}

fn item_parts_to_dto(item_type: &str, id: Uuid) -> ItemDto {
    ItemDto {
        item_type: item_type.to_string(),
        id,
    }
}

fn quantity_to_dto(amount: Decimal, unit: String) -> QuantityDto {
    QuantityDto { amount, unit }
}

fn meal_nutrition_to_response(nutrition: MealNutritionOutput) -> MealNutritionResponse {
    let nutrition_summary = meal_nutrient_entries_summary(&nutrition.nutrients);
    MealNutritionResponse {
        meal_id: nutrition.meal_id,
        quantity: quantity_to_dto(nutrition.quantity_amount, nutrition.quantity_unit),
        nutrition_summary,
        nutrients: nutrition
            .nutrients
            .into_iter()
            .filter(|nutrient| is_summary_nutrient_code(&nutrient.code))
            .map(meal_nutrient_to_dto)
            .collect(),
    }
}

fn meal_declared_nutrition_summary(
    meal: &Meal,
    products: &[(ProductId, Product)],
    unit_converter: &crate::nutrition::domain::units::UnitConverter,
) -> Option<NutrientSummaryDto> {
    match (
        meal.total_quantity_amount,
        meal.total_quantity_unit.as_ref(),
    ) {
        (Some(amount), Some(unit)) => {
            Quantity::new(amount, unit.clone())
                .ok()
                .and_then(|quantity| {
                    meal.nutrition_for(&quantity, products, unit_converter)
                        .ok()
                        .map(|nutrition| {
                            nutrient_summary_from_entries(
                                nutrition
                                    .amounts
                                    .into_iter()
                                    .map(|amount| (amount.nutrient_code.0, amount.amount)),
                            )
                        })
                })
        }
        _ => None,
    }
}

fn meal_component_nutrition_summary(
    component: &MealComponent,
    products: &[(ProductId, Product)],
    unit_converter: &crate::nutrition::domain::units::UnitConverter,
) -> Option<NutrientSummaryDto> {
    let product_id = match component.item {
        MealComponentItem::Product(product_id) => product_id,
    };
    let product = products
        .iter()
        .find(|(id, _)| id == &product_id)
        .map(|(_, product)| product)?;
    let quantity =
        Quantity::new(component.quantity_amount, component.quantity_unit.clone()).ok()?;
    product
        .nutrition_for(&quantity, unit_converter)
        .ok()
        .map(|nutrition| {
            nutrient_summary_from_entries(
                nutrition
                    .amounts
                    .into_iter()
                    .map(|amount| (amount.nutrient_code.0, amount.amount)),
            )
        })
}

fn meal_nutrient_entries_summary(nutrients: &[MealNutrientEntry]) -> NutrientSummaryDto {
    nutrient_summary_from_entries(
        nutrients
            .iter()
            .map(|nutrient| (nutrient.code.clone(), nutrient.amount)),
    )
}

fn meal_nutrient_to_dto(nutrient: MealNutrientEntry) -> MealNutrientDto {
    MealNutrientDto {
        code: nutrient.code,
        amount: nutrient.amount,
        unit: nutrient.unit,
    }
}

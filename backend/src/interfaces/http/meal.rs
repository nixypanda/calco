use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::meal::*;
use crate::domain::meal::*;
use crate::interfaces::http::auth::{AppState, AuthUser};

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

use crate::interfaces::http::{error_response, internal_error};

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
    pub components: Vec<MealComponentDto>,
}

#[derive(Serialize)]
pub struct MealComponentDto {
    pub id: Uuid,
    pub item: ItemDto,
    pub quantity: QuantityDto,
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

    let input = meal_create_request_to_input(req, auth.0.id);

    match services.create_meal(input).await {
        Ok(meal) => {
            let resp = meal_to_response(&meal);
            (StatusCode::CREATED, Json(resp)).into_response()
        }
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
            let resp = meal_to_response(&meal);
            Json(resp).into_response()
        }
        Ok(None) => error_response("not_found", "meal not found".into()).into_response(),
        Err(e) => internal_error(e).into_response(),
    }
}

async fn list_meals_handler(auth: AuthUser, State(state): State<AppState>) -> impl IntoResponse {
    match state.meal_repo.list_by_user_id(auth.0.id).await {
        Ok(meals) => Json(meals_to_list_response(meals)).into_response(),
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

    let input = meal_update_request_to_input(req);

    match services.update_meal(MealId(id), auth.0.id, input).await {
        Ok(meal) => {
            let resp = meal_to_response(&meal);
            Json(resp).into_response()
        }
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

    let services = &state.meal_services;
    match services
        .get_meal_nutrients(MealId(id), query.amount, query.unit)
        .await
    {
        Ok(nutrition) => Json(meal_nutrition_to_response(nutrition)).into_response(),
        Err(e) => e.into_response(),
    }
}

// ─── Conversions ───────────────────────────────────────────────

fn meal_create_request_to_input(req: CreateMealRequest, user_id: Uuid) -> CreateMealInput {
    CreateMealInput {
        user_id,
        name: req.name,
        notes: req.notes,
        total_quantity_amount: req.total_quantity.as_ref().map(|q| q.amount),
        total_quantity_unit: req.total_quantity.as_ref().map(|q| q.unit.clone()),
        components: meal_component_requests_to_inputs(req.components),
    }
}

fn meal_update_request_to_input(req: UpdateMealRequest) -> UpdateMealInput {
    let total_quantity = req.total_quantity;
    UpdateMealInput {
        name: req.name,
        notes: req.notes,
        total_quantity_amount: total_quantity
            .as_ref()
            .map(|quantity| quantity.as_ref().map(|q| q.amount)),
        total_quantity_unit: total_quantity.map(|quantity| quantity.map(|q| q.unit)),
        components: req.components.map(meal_component_requests_to_inputs),
    }
}

fn meal_component_requests_to_inputs(
    components: Vec<CreateMealComponentRequest>,
) -> Vec<CreateMealComponentInput> {
    components
        .into_iter()
        .map(meal_component_request_to_input)
        .collect()
}

fn meal_component_request_to_input(
    component: CreateMealComponentRequest,
) -> CreateMealComponentInput {
    CreateMealComponentInput {
        item_type: component.item.item_type,
        item_id: component.item.id,
        quantity_amount: component.quantity.amount,
        quantity_unit: component.quantity.unit,
    }
}

fn meals_to_list_response(meals: Vec<Meal>) -> MealListResponse {
    MealListResponse {
        items: meals.iter().map(meal_to_response).collect(),
    }
}

fn meal_to_response(meal: &Meal) -> MealResponse {
    MealResponse {
        id: meal.id.0,
        name: meal.name.0.clone(),
        notes: meal.notes.as_ref().map(|n| n.0.clone()),
        total_quantity: meal_total_quantity_to_dto(meal),
        components: meal.components.iter().map(meal_component_to_dto).collect(),
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

fn meal_component_to_dto(component: &MealComponent) -> MealComponentDto {
    let (item_type, item_id) = meal_component_item_to_parts(&component.item);
    MealComponentDto {
        id: component.id,
        item: item_parts_to_dto(item_type, item_id),
        quantity: quantity_to_dto(component.quantity_amount, component.quantity_unit.0.clone()),
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
    MealNutritionResponse {
        meal_id: nutrition.meal_id,
        quantity: quantity_to_dto(nutrition.quantity_amount, nutrition.quantity_unit),
        nutrients: nutrition
            .nutrients
            .into_iter()
            .map(meal_nutrient_to_dto)
            .collect(),
    }
}

fn meal_nutrient_to_dto(nutrient: MealNutrientEntry) -> MealNutrientDto {
    MealNutrientDto {
        code: nutrient.code,
        amount: nutrient.amount,
        unit: nutrient.unit,
    }
}

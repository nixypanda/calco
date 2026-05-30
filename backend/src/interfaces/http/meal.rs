use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
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
        .route("/meals/{id}", get(get_meal_handler).put(update_meal_handler).delete(delete_meal_handler))
        .route("/meals/{id}/nutrients", get(meal_nutrients_handler))
        .with_state(state)
}

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

#[derive(Deserialize)]
pub struct CreateMealRequest {
    pub name: String,
    pub notes: Option<String>,
    pub total_quantity: Option<QuantityDto>,
    pub components: Vec<CreateMealComponentRequest>,
}

#[derive(Deserialize)]
pub struct CreateMealComponentRequest {
    pub item: ItemRef,
    pub quantity: QuantityDto,
}

#[derive(Deserialize)]
pub struct ItemRef {
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
    pub components: Vec<MealComponentResponse>,
}

#[derive(Serialize)]
pub struct MealComponentResponse {
    pub id: Uuid,
    pub item: ItemResponse,
    pub quantity: QuantityDto,
}

#[derive(Serialize)]
pub struct ItemResponse {
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
    pub nutrients: Vec<NutrientEntry>,
}

#[derive(Serialize)]
pub struct NutrientEntry {
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

fn meal_to_response(meal: &Meal) -> MealResponse {
    MealResponse {
        id: meal.id.0,
        name: meal.name.0.clone(),
        notes: meal.notes.as_ref().map(|n| n.0.clone()),
        total_quantity: meal.total_quantity_amount.map(|a| QuantityDto {
            amount: a,
            unit: meal.total_quantity_unit.as_ref().map(|u| u.0.clone()).unwrap_or_default(),
        }),
        components: meal.components.iter().map(|c| {
            let (item_type, item_id) = match &c.item {
                MealComponentItem::Product(pid) => ("product", pid.0),
            };
            MealComponentResponse {
                id: c.id,
                item: ItemResponse {
                    item_type: item_type.to_string(),
                    id: item_id,
                },
                quantity: QuantityDto {
                    amount: c.quantity_amount,
                    unit: c.quantity_unit.0.clone(),
                },
            }
        }).collect(),
    }
}

async fn create_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(req): Json<CreateMealRequest>,
) -> impl IntoResponse {
    let services = match &state.meal_services {
        Some(s) => s,
        None => return error_response("internal", "meal services not configured".into()).into_response(),
    };

    let input = CreateMealInput {
        user_id: auth.1.id,
        name: req.name,
        notes: req.notes,
        total_quantity_amount: req.total_quantity.as_ref().map(|q| q.amount),
        total_quantity_unit: req.total_quantity.as_ref().map(|q| q.unit.clone()),
        components: req.components.into_iter().map(|c| CreateMealComponentInput {
            item_type: c.item.item_type,
            item_id: c.item.id,
            quantity_amount: c.quantity.amount,
            quantity_unit: c.quantity.unit,
        }).collect(),
    };

    match services.create_meal(input).await {
        Ok(meal) => {
            let resp = meal_to_response(&meal);
            (StatusCode::CREATED, Json(serde_json::to_value(&resp).unwrap())).into_response()
        }
        Err(MealError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(MealError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => error_response("internal", e.to_string()).into_response(),
    }
}

async fn get_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = match &state.meal_services {
        Some(s) => s,
        None => return error_response("internal", "meal services not configured".into()).into_response(),
    };

    match services.get_meal(MealId(id)).await {
        Ok(meal) => {
            if !meal.is_owned_by(auth.1.id) {
                return error_response("forbidden", "not your meal".into()).into_response();
            }
            let resp = meal_to_response(&meal);
            Json(serde_json::to_value(&resp).unwrap()).into_response()
        }
        Err(MealError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(e) => error_response("internal", e.to_string()).into_response(),
    }
}

async fn list_meals_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let services = match &state.meal_services {
        Some(s) => s,
        None => return error_response("internal", "meal services not configured".into()).into_response(),
    };

    match services.list_meals(auth.1.id).await {
        Ok(meals) => {
            let items: Vec<MealResponse> = meals.iter().map(meal_to_response).collect();
            Json(MealListResponse { items }).into_response()
        }
        Err(e) => error_response("internal", e.to_string()).into_response(),
    }
}

async fn update_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMealRequest>,
) -> impl IntoResponse {
    let services = match &state.meal_services {
        Some(s) => s,
        None => return error_response("internal", "meal services not configured".into()).into_response(),
    };

    let total_qty = req.total_quantity;
    let input = UpdateMealInput {
        name: req.name,
        notes: req.notes,
        total_quantity_amount: total_qty.as_ref().map(|tq| tq.as_ref().map(|q| q.amount)),
        total_quantity_unit: total_qty.map(|tq| tq.map(|q| q.unit)),
        components: req.components.map(|components| {
            components.into_iter().map(|c| CreateMealComponentInput {
                item_type: c.item.item_type,
                item_id: c.item.id,
                quantity_amount: c.quantity.amount,
                quantity_unit: c.quantity.unit,
            }).collect()
        }),
    };

    match services.update_meal(MealId(id), auth.1.id, input).await {
        Ok(meal) => {
            let resp = meal_to_response(&meal);
            Json(serde_json::to_value(&resp).unwrap()).into_response()
        }
        Err(MealError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(MealError::Forbidden(msg)) => error_response("forbidden", msg).into_response(),
        Err(MealError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => error_response("internal", e.to_string()).into_response(),
    }
}

async fn delete_meal_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = match &state.meal_services {
        Some(s) => s,
        None => return error_response("internal", "meal services not configured".into()).into_response(),
    };

    match services.delete_meal(MealId(id), auth.1.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(MealError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(MealError::Forbidden(msg)) => error_response("forbidden", msg).into_response(),
        Err(e) => error_response("internal", e.to_string()).into_response(),
    }
}

async fn meal_nutrients_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Query(query): Query<MealNutrientQuery>,
) -> impl IntoResponse {
    let services = match &state.meal_services {
        Some(s) => s,
        None => return error_response("internal", "meal services not configured".into()).into_response(),
    };

    match services.get_meal(MealId(id)).await {
        Ok(meal) => {
            if !meal.is_owned_by(auth.1.id) {
                return error_response("forbidden", "not your meal".into()).into_response();
            }
        }
        Err(MealError::NotFound(msg)) => return error_response("not_found", msg).into_response(),
        Err(e) => return error_response("internal", e.to_string()).into_response(),
    }

    match services.get_meal_nutrients(MealId(id), query.amount, query.unit).await {
        Ok(nutrition) => {
            Json(MealNutritionResponse {
                meal_id: nutrition.meal_id,
                quantity: QuantityDto {
                    amount: nutrition.quantity_amount,
                    unit: nutrition.quantity_unit,
                },
                nutrients: nutrition.nutrients.into_iter().map(|n| NutrientEntry {
                    code: n.code,
                    amount: n.amount,
                    unit: n.unit,
                }).collect(),
            }).into_response()
        }
        Err(MealError::NotFound(msg)) => error_response("not_found", msg).into_response(),
        Err(MealError::Validation(msg)) => error_response("validation", msg).into_response(),
        Err(e) => error_response("internal", e.to_string()).into_response(),
    }
}

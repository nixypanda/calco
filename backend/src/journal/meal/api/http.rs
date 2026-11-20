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
use crate::auth::api::http::{AccountBoundReadUser, AccountBoundWriteUser};
use crate::catalog::domain::calculation::{CalculatedNutrition, Quantity};
use crate::catalog::domain::{ProductId, UnitCode};
use crate::journal::error::{
    JournalError, MealComponentUnavailableReason, MealQuantityUnavailableReason,
    UnavailableMealComponent, UnavailableMealComponents,
};
use crate::journal::meal::app::*;
use crate::journal::meal::domain::*;
use crate::journal::module::MealModule;

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

use crate::journal::api::http::{
    NutrientSummaryDto, is_summary_nutrient_code, nutrient_summary_from_entries,
};

#[derive(Deserialize)]
struct CreateMealRequest {
    name: String,
    notes: Option<String>,
    total_quantity: Option<QuantityDto>,
    components: Vec<CreateMealComponentRequest>,
}

#[derive(Deserialize)]
struct CreateMealComponentRequest {
    item: ItemRefDto,
    quantity: QuantityDto,
}

#[derive(Deserialize)]
struct ItemRefDto {
    #[serde(rename = "type")]
    item_type: String,
    id: Uuid,
}

#[derive(Deserialize, Serialize)]
struct QuantityDto {
    amount: Decimal,
    unit: String,
}

#[derive(Serialize)]
struct MealResponse {
    id: Uuid,
    name: String,
    notes: Option<String>,
    total_quantity: Option<QuantityDto>,
    nutrition: MealNutritionDto,
    components: Vec<MealComponentDto>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum MealNutritionDto {
    Available {
        summary: NutrientSummaryDto,
    },
    NotDeclared,
    Unavailable {
        unavailable_components: UnavailableMealComponentsDto,
    },
    TotalQuantityUnavailable {
        reason: MealQuantityUnavailableReason,
        total_quantity: QuantityDto,
    },
}

#[derive(Serialize)]
#[serde(tag = "availability", rename_all = "snake_case")]
enum MealComponentDto {
    Available {
        id: Uuid,
        item: ItemDto,
        quantity: QuantityDto,
        nutrition_summary: NutrientSummaryDto,
    },
    Unavailable {
        id: Uuid,
        item: ItemDto,
        quantity: QuantityDto,
        reason: MealComponentUnavailableReason,
    },
}

#[derive(Serialize)]
struct UnavailableMealComponentDto {
    component_id: Uuid,
    item: ItemDto,
    quantity: QuantityDto,
    reason: MealComponentUnavailableReason,
}

impl From<&UnavailableMealComponent> for UnavailableMealComponentDto {
    fn from(component: &UnavailableMealComponent) -> Self {
        Self {
            component_id: component.component_id,
            item: ItemDto {
                item_type: "product".to_string(),
                id: component.product_id,
            },
            quantity: quantity_to_dto(component.quantity_amount, component.quantity_unit.clone()),
            reason: component.reason,
        }
    }
}

/// Wire representation of a guaranteed non-empty unavailable-component set.
///
/// The inner vector is private and can only be built from the domain's
/// `UnavailableMealComponents`, so an empty set cannot be constructed as a
/// valid DTO.
#[derive(Serialize)]
#[serde(transparent)]
struct UnavailableMealComponentsDto(Vec<UnavailableMealComponentDto>);

impl From<&UnavailableMealComponents> for UnavailableMealComponentsDto {
    fn from(components: &UnavailableMealComponents) -> Self {
        Self(
            components
                .as_slice()
                .iter()
                .map(UnavailableMealComponentDto::from)
                .collect(),
        )
    }
}

#[derive(Serialize)]
struct ItemDto {
    #[serde(rename = "type")]
    item_type: String,
    id: Uuid,
}

#[derive(Serialize)]
struct MealListResponse {
    items: Vec<MealResponse>,
}

#[derive(Serialize)]
struct MealNutritionResponse {
    meal_id: Uuid,
    quantity: QuantityDto,
    nutrition_summary: NutrientSummaryDto,
    nutrients: Vec<MealNutrientDto>,
}

#[derive(Serialize)]
struct MealNutrientDto {
    code: String,
    amount: Decimal,
    unit: String,
}

#[derive(Deserialize)]
struct MealNutrientQuery {
    amount: Decimal,
    unit: String,
}

#[derive(Deserialize)]
struct UpdateMealRequest {
    name: Option<String>,
    notes: Option<Option<String>>,
    total_quantity: Option<Option<QuantityDto>>,
    components: Option<Vec<CreateMealComponentRequest>>,
}

async fn create_meal_handler(
    auth: AccountBoundWriteUser,
    State(state): State<MealModule>,
    Json(req): Json<CreateMealRequest>,
) -> impl IntoResponse {
    let services = &state.meal_services;

    let input = match meal_create_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services.create_meal(auth.0.id, input).await {
        Ok(meal) => match meal_to_response(&state.meal_services, auth.0.id, &meal).await {
            Ok(resp) => (StatusCode::CREATED, Json(resp)).into_response(),
            Err(e) => e.into_response(),
        },
        Err(e) => e.into_response(),
    }
}

async fn get_meal_handler(
    auth: AccountBoundReadUser,
    State(state): State<MealModule>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    match state.meal_services.get_meal(auth.0.id, MealId(id)).await {
        Ok(meal) => match meal_to_response(&state.meal_services, auth.0.id, &meal).await {
            Ok(resp) => Json(resp).into_response(),
            Err(e) => e.into_response(),
        },
        Err(e) => e.into_response(),
    }
}

async fn list_meals_handler(
    auth: AccountBoundReadUser,
    State(state): State<MealModule>,
) -> impl IntoResponse {
    match state.meal_services.list_meals(auth.0.id).await {
        Ok(meals) => match meals_to_list_response(&state.meal_services, auth.0.id, meals).await {
            Ok(resp) => Json(resp).into_response(),
            Err(e) => e.into_response(),
        },
        Err(e) => e.into_response(),
    }
}

async fn update_meal_handler(
    auth: AccountBoundWriteUser,
    State(state): State<MealModule>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMealRequest>,
) -> impl IntoResponse {
    let services = &state.meal_services;

    let input = match meal_update_request_to_input(req) {
        Ok(input) => input,
        Err(err) => return err.into_response(),
    };

    match services.update_meal(MealId(id), auth.0.id, input).await {
        Ok(meal) => match meal_to_response(&state.meal_services, auth.0.id, &meal).await {
            Ok(resp) => Json(resp).into_response(),
            Err(e) => e.into_response(),
        },
        Err(e) => e.into_response(),
    }
}

async fn delete_meal_handler(
    auth: AccountBoundWriteUser,
    State(state): State<MealModule>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.meal_services;

    match services.delete_meal(MealId(id), auth.0.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

async fn meal_nutrients_handler(
    auth: AccountBoundReadUser,
    State(state): State<MealModule>,
    Path(id): Path<Uuid>,
    Query(query): Query<MealNutrientQuery>,
) -> impl IntoResponse {
    let quantity = match Quantity::new(query.amount, UnitCode(query.unit)) {
        Ok(q) => q,
        Err(err) => return err.into_response(),
    };
    let services = &state.meal_services;
    match services
        .get_meal_nutrients(auth.0.id, MealId(id), quantity)
        .await
    {
        Ok(nutrition) => Json(meal_nutrition_to_response(nutrition)).into_response(),
        Err(e) => e.into_response(),
    }
}

// ─── Conversions ───────────────────────────────────────────────

fn parse_component_item(item: &ItemRefDto) -> Result<MealComponentItem, JournalError> {
    match item.item_type.as_str() {
        "product" => Ok(MealComponentItem::Product(ProductId(item.id))),
        other => Err(JournalError::Validation(format!(
            "unsupported component item type: {other}"
        ))),
    }
}

fn parse_quantity_dto(q: &QuantityDto) -> Result<Quantity, JournalError> {
    Quantity::new(q.amount, UnitCode(q.unit.clone())).map_err(JournalError::from)
}

fn parse_meal_quantity_dto(q: &QuantityDto) -> Result<MealQuantity, JournalError> {
    let quantity = parse_quantity_dto(q)?;
    let (amount, unit) = quantity.into_parts();
    MealQuantity::new(amount, unit)
}

fn meal_create_request_to_input(req: CreateMealRequest) -> Result<CreateMealInput, JournalError> {
    let total_quantity = req
        .total_quantity
        .as_ref()
        .map(parse_meal_quantity_dto)
        .transpose()?;
    Ok(CreateMealInput::new(
        req.name,
        req.notes,
        total_quantity,
        meal_component_requests_to_inputs(req.components)?,
    ))
}

fn meal_update_request_to_input(req: UpdateMealRequest) -> Result<UpdateMealInput, JournalError> {
    let total_quantity = match req.total_quantity {
        None => MealTotalQuantityPatch::Unchanged,
        Some(None) => MealTotalQuantityPatch::Clear,
        Some(Some(quantity)) => MealTotalQuantityPatch::Set(parse_meal_quantity_dto(&quantity)?),
    };
    let components = req
        .components
        .map(meal_component_requests_to_inputs)
        .transpose()?;
    Ok(UpdateMealInput::new(
        req.name,
        req.notes,
        total_quantity,
        components,
    ))
}

fn meal_component_requests_to_inputs(
    components: Vec<CreateMealComponentRequest>,
) -> Result<Vec<CreateMealComponentInput>, JournalError> {
    components
        .into_iter()
        .map(meal_component_request_to_input)
        .collect()
}

fn meal_component_request_to_input(
    component: CreateMealComponentRequest,
) -> Result<CreateMealComponentInput, JournalError> {
    Ok(CreateMealComponentInput::new(
        parse_component_item(&component.item)?,
        parse_meal_quantity_dto(&component.quantity)?,
    ))
}

async fn meals_to_list_response(
    services: &MealService,
    actor_id: Uuid,
    meals: Vec<Meal>,
) -> Result<MealListResponse, JournalError> {
    let mut items = Vec::with_capacity(meals.len());
    for meal in &meals {
        items.push(meal_to_response(services, actor_id, meal).await?);
    }
    Ok(MealListResponse { items })
}

async fn meal_to_response(
    services: &MealService,
    actor_id: Uuid,
    meal: &Meal,
) -> Result<MealResponse, JournalError> {
    let resolution = services.resolve_meal_products(actor_id, meal).await?;
    meal_to_response_with_resolution(meal, &resolution, services.unit_converter())
}

fn meal_to_response_with_resolution(
    meal: &Meal,
    resolution: &MealProductResolution,
    unit_converter: &crate::catalog::domain::units::UnitConverter,
) -> Result<MealResponse, JournalError> {
    let nutrition = meal_nutrition_dto(meal, resolution, unit_converter)?;
    let components = resolution
        .components()
        .iter()
        .map(meal_component_to_dto)
        .collect();

    Ok(MealResponse {
        id: meal.id().0,
        name: meal.name().as_str().to_string(),
        notes: meal.notes().map(|notes| notes.0.clone()),
        total_quantity: meal
            .total_quantity()
            .map(|quantity| quantity_to_dto(quantity.amount(), quantity.unit().0.clone())),
        nutrition,
        components,
        created_at: meal.created_at(),
        updated_at: meal.updated_at(),
    })
}

fn meal_nutrition_dto(
    meal: &Meal,
    resolution: &MealProductResolution,
    unit_converter: &crate::catalog::domain::units::UnitConverter,
) -> Result<MealNutritionDto, JournalError> {
    if let Some(unavailable) = resolution.unavailable_components() {
        return Ok(MealNutritionDto::Unavailable {
            unavailable_components: (&unavailable).into(),
        });
    }
    let Some(total) = meal.total_quantity() else {
        return Ok(MealNutritionDto::NotDeclared);
    };
    let total_quantity = quantity_to_dto(total.amount(), total.unit().0.clone());

    match resolution.declared_nutrition(meal, unit_converter) {
        Ok(nutrition) => Ok(MealNutritionDto::Available {
            summary: calculated_nutrition_summary(nutrition),
        }),
        Err(MealNutritionResolutionError::QuantityNotConvertible { .. }) => {
            Ok(MealNutritionDto::TotalQuantityUnavailable {
                reason: MealQuantityUnavailableReason::QuantityNotConvertible,
                total_quantity,
            })
        }
        Err(MealNutritionResolutionError::UnavailableComponents(unavailable)) => {
            Ok(MealNutritionDto::Unavailable {
                unavailable_components: (&unavailable).into(),
            })
        }
        Err(MealNutritionResolutionError::Internal(message)) => {
            Err(JournalError::Internal(message))
        }
    }
}

fn meal_component_to_dto(component: &ResolvedMealComponent) -> MealComponentDto {
    let (item_type, item_id) = meal_component_item_to_parts(component.component().item());
    let item = item_parts_to_dto(item_type, item_id);
    let quantity = quantity_to_dto(
        component.component().quantity().amount(),
        component.component().quantity().unit().0.clone(),
    );
    let id = component.component().id();

    match component.availability() {
        ResolvedMealComponentAvailability::Available { nutrition, .. } => {
            MealComponentDto::Available {
                id,
                item,
                quantity,
                nutrition_summary: calculated_nutrition_summary(nutrition.clone()),
            }
        }
        ResolvedMealComponentAvailability::Unavailable { reason } => {
            MealComponentDto::Unavailable {
                id,
                item,
                quantity,
                reason: *reason,
            }
        }
    }
}

fn calculated_nutrition_summary(nutrition: CalculatedNutrition) -> NutrientSummaryDto {
    nutrient_summary_from_entries(
        nutrition
            .amounts
            .into_iter()
            .map(|amount| (amount.nutrient_code.0, amount.amount)),
    )
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::domain::units::UnitConverter;
    use crate::catalog::domain::{
        AmountPer100g, NutrientCode, Product, ProductName, ProductNutrient, ProductOrigin,
        ProductVisibility,
    };

    fn product() -> Product {
        Product {
            id: ProductId(Uuid::nil()),
            origin: ProductOrigin::Custom {
                user_id: Uuid::nil(),
            },
            visibility: ProductVisibility::Global,
            name: ProductName::new("Test Food").unwrap(),
            brand: None,
            categories: vec![],
            default_quantity: Some(Decimal::new(100, 0)),
            default_unit: Some(UnitCode("g".into())),
            nutrients: vec![ProductNutrient {
                nutrient_code: NutrientCode("ENERGY_KCAL".into()),
                amount_per_100g: AmountPer100g::new(Decimal::new(100, 0)).unwrap(),
                unit: UnitCode("kcal".into()),
                source: None,
                confidence: None,
            }],
            servings: vec![],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn unavailable_component_quantity_is_degraded_instead_of_failing_response() {
        let product = product();
        let component = MealComponent::from_stored(
            Uuid::new_v4(),
            MealComponentItem::Product(product.id),
            MealQuantity::new(Decimal::ONE, UnitCode("cup".into()))
                .expect("stored quantity should be valid"),
        );
        let meal = Meal::from_stored(StoredMeal {
            id: MealId::new(),
            user_id: Uuid::nil(),
            name: "Test Meal".into(),
            notes: None,
            total_quantity: None,
            components: vec![component],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        })
        .unwrap();
        let converter = UnitConverter::from_entries([("g".to_string(), Decimal::new(1, 0))]);
        let resolution =
            MealProductResolution::from_products(&meal, &[(product.id, product)], &converter)
                .unwrap();

        let response = meal_to_response_with_resolution(&meal, &resolution, &converter).unwrap();

        assert!(matches!(
            response.nutrition,
            MealNutritionDto::Unavailable { .. }
        ));
        assert!(matches!(
            &response.components[0],
            MealComponentDto::Unavailable {
                reason: MealComponentUnavailableReason::QuantityNotConvertible,
                ..
            }
        ));

        let json = serde_json::to_value(&response).unwrap();
        let unavailable = json["nutrition"]["unavailable_components"]
            .as_array()
            .expect("unavailable components must serialize as an array");
        assert_eq!(unavailable.len(), 1);
    }
}

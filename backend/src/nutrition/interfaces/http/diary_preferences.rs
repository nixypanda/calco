use std::str::FromStr;

use axum::{Json, Router, extract::State, response::IntoResponse, routing::get};
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::auth::interfaces::http::AuthUser;
use crate::nutrition::domain::diary_preferences::{DiaryPreferences, EnabledMealSlots};
use crate::nutrition::domain::error::NutritionError;
use crate::nutrition::domain::food_log::MealSlot;

pub fn diary_preferences_routes(state: AppState) -> Router {
    Router::new()
        .route(
            "/diary-preferences",
            get(get_preferences_handler).put(put_preferences_handler),
        )
        .with_state(state)
}

#[derive(Debug, Deserialize)]
pub struct PutDiaryPreferencesRequest {
    pub enabled_meal_slots: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DiaryPreferencesResponse {
    pub enabled_meal_slots: Vec<String>,
}

async fn get_preferences_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    match state.diary_preferences_services.get(auth.0.id).await {
        Ok(preferences) => Json(to_response(preferences)).into_response(),
        Err(err) => err.into_response(),
    }
}

async fn put_preferences_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(request): Json<PutDiaryPreferencesRequest>,
) -> impl IntoResponse {
    let slots = match parse_enabled_slots(request.enabled_meal_slots) {
        Ok(slots) => slots,
        Err(err) => return err.into_response(),
    };
    match state
        .diary_preferences_services
        .replace(auth.0.id, slots)
        .await
    {
        Ok(preferences) => Json(to_response(preferences)).into_response(),
        Err(err) => err.into_response(),
    }
}

fn parse_enabled_slots(slots: Vec<String>) -> Result<EnabledMealSlots, NutritionError> {
    EnabledMealSlots::new(
        slots
            .into_iter()
            .map(|slot| MealSlot::from_str(&slot).map_err(NutritionError::Validation))
            .collect::<Result<Vec<_>, _>>()?,
    )
}

fn to_response(preferences: DiaryPreferences) -> DiaryPreferencesResponse {
    DiaryPreferencesResponse {
        enabled_meal_slots: preferences
            .enabled_meal_slots
            .canonical()
            .into_iter()
            .map(|slot| slot.as_str().to_owned())
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_is_canonicalized() {
        let parsed = parse_enabled_slots(vec![
            "late_night_snack".into(),
            "breakfast".into(),
            "late_night_snack".into(),
        ])
        .unwrap();
        assert_eq!(
            parsed.canonical(),
            vec![MealSlot::Breakfast, MealSlot::LateNightSnack]
        );
    }

    #[test]
    fn request_rejects_unknown_and_empty_slots() {
        assert!(parse_enabled_slots(vec!["supper".into()]).is_err());
        assert!(parse_enabled_slots(vec![]).is_err());
    }
}

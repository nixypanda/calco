use std::str::FromStr;

use axum::{Json, Router, extract::State, response::IntoResponse, routing::get};
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::auth::api::http::{ReadUser, WriteUser};
use crate::journal::diary_prefs::domain::{DiaryPrefs, EnabledMealSlots};
use crate::journal::error::JournalError;
use crate::journal::food_log::domain::MealSlot;
use crate::journal::module::DiaryPrefsModule;

pub fn diary_prefs_routes(state: AppState) -> Router {
    Router::new()
        .route(
            "/diary-preferences",
            get(get_prefs_handler).put(put_prefs_handler),
        )
        .with_state(state)
}

#[derive(Debug, Deserialize)]
pub struct PutDiaryPrefsRequest {
    pub enabled_meal_slots: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DiaryPrefsResponse {
    pub enabled_meal_slots: Vec<String>,
}

async fn get_prefs_handler(
    auth: ReadUser,
    State(state): State<DiaryPrefsModule>,
) -> impl IntoResponse {
    match state.diary_prefs_services.get(auth.0.id).await {
        Ok(prefs) => Json(to_response(prefs)).into_response(),
        Err(err) => err.into_response(),
    }
}

async fn put_prefs_handler(
    auth: WriteUser,
    State(state): State<DiaryPrefsModule>,
    Json(request): Json<PutDiaryPrefsRequest>,
) -> impl IntoResponse {
    let slots = match parse_enabled_slots(request.enabled_meal_slots) {
        Ok(slots) => slots,
        Err(err) => return err.into_response(),
    };
    match state.diary_prefs_services.replace(auth.0.id, slots).await {
        Ok(prefs) => Json(to_response(prefs)).into_response(),
        Err(err) => err.into_response(),
    }
}

fn parse_enabled_slots(slots: Vec<String>) -> Result<EnabledMealSlots, JournalError> {
    EnabledMealSlots::new(
        slots
            .into_iter()
            .map(|slot| MealSlot::from_str(&slot).map_err(JournalError::Validation))
            .collect::<Result<Vec<_>, _>>()?,
    )
}

fn to_response(prefs: DiaryPrefs) -> DiaryPrefsResponse {
    DiaryPrefsResponse {
        enabled_meal_slots: prefs
            .enabled_meal_slots
            .canonical()
            .into_iter()
            .map(|slot| slot.as_str().to_owned())
            .collect(),
    }
}

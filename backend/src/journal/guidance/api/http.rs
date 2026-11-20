use axum::{
    Router,
    extract::{Query, State},
    response::{IntoResponse, Json},
    routing::get,
};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

use crate::AppState;
use crate::auth::api::http::ReadUser;
use crate::journal::error::JournalError;
use crate::journal::guidance::app::{
    NutrientCoverage, NutritionDetails, NutritionDetailsEntry, NutritionDetailsStatus,
};
use crate::journal::guidance::domain::{
    NutrientDetailsSection, NutrientGuidanceKind, NutrientGuidanceSet,
};
use crate::journal::module::GuidanceModule;

pub fn nutrition_details_routes(state: AppState) -> Router {
    Router::new()
        .route("/nutrition/details", get(get_nutrition_details_handler))
        .with_state(state)
}
#[derive(Deserialize)]
pub struct NutritionDetailsQuery {
    pub date: String,
}
#[derive(Serialize)]
pub struct NutritionDetailsResponse {
    pub date: NaiveDate,
    pub reference: NutrientGuidanceSetResponse,
    pub logged_items: usize,
    pub nutrients: Vec<NutritionDetailsEntryResponse>,
}
#[derive(Serialize)]
pub struct NutrientGuidanceSetResponse {
    pub code: String,
    pub name: String,
    pub authority: String,
    pub jurisdiction: String,
    pub population_label: String,
    pub source_url: String,
}
#[derive(Serialize)]
pub struct NutritionDetailsEntryResponse {
    pub code: String,
    pub name: String,
    pub section: NutrientDetailsSectionDto,
    pub known_amount: Option<Decimal>,
    pub unit: String,
    pub reference_amount: Option<Decimal>,
    pub guidance_kind: NutrientGuidanceKindDto,
    pub items_with_data: usize,
    pub coverage: NutrientCoverageDto,
    pub status: NutritionDetailsStatusDto,
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NutrientDetailsSectionDto {
    Overview,
    Carbohydrates,
    Fats,
    Limits,
    VitaminsMinerals,
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NutrientGuidanceKindDto {
    Informational,
    Adequacy,
    Maximum,
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NutrientCoverageDto {
    None,
    Partial,
    Complete,
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NutritionDetailsStatusDto {
    NoData,
    PartialData,
    Available,
    BelowReference,
    MetReference,
    WithinLimit,
    OverLimit,
}

async fn get_nutrition_details_handler(
    auth: ReadUser,
    State(state): State<GuidanceModule>,
    Query(query): Query<NutritionDetailsQuery>,
) -> impl IntoResponse {
    let date = match NaiveDate::parse_from_str(&query.date, "%Y-%m-%d") {
        Ok(date) => date,
        Err(_) => return JournalError::Validation("invalid date".into()).into_response(),
    };
    match state
        .nutrition_details_services
        .get_for_date(auth.0.id, date)
        .await
    {
        Ok(report) => Json(nutrition_details_to_response(report)).into_response(),
        Err(error) => error.into_response(),
    }
}

fn nutrition_details_to_response(report: NutritionDetails) -> NutritionDetailsResponse {
    NutritionDetailsResponse {
        date: report.date,
        reference: guidance_set_to_response(&report.guidance_set),
        logged_items: report.logged_items,
        nutrients: report.nutrients.iter().map(entry_to_response).collect(),
    }
}
fn guidance_set_to_response(set: &NutrientGuidanceSet) -> NutrientGuidanceSetResponse {
    NutrientGuidanceSetResponse {
        code: set.code().into(),
        name: set.name().into(),
        authority: set.authority().into(),
        jurisdiction: set.jurisdiction().into(),
        population_label: set.population_label().into(),
        source_url: set.source_url().into(),
    }
}
fn entry_to_response(entry: &NutritionDetailsEntry) -> NutritionDetailsEntryResponse {
    NutritionDetailsEntryResponse {
        code: entry.guidance.nutrient_code().0.clone(),
        name: entry.guidance.display_name().into(),
        section: match entry.guidance.section() {
            NutrientDetailsSection::Overview => NutrientDetailsSectionDto::Overview,
            NutrientDetailsSection::Carbohydrates => NutrientDetailsSectionDto::Carbohydrates,
            NutrientDetailsSection::Fats => NutrientDetailsSectionDto::Fats,
            NutrientDetailsSection::Limits => NutrientDetailsSectionDto::Limits,
            NutrientDetailsSection::VitaminsMinerals => NutrientDetailsSectionDto::VitaminsMinerals,
        },
        known_amount: entry.known_amount,
        unit: entry.guidance.unit().0.clone(),
        reference_amount: entry.guidance.reference_amount(),
        guidance_kind: match entry.guidance.kind() {
            NutrientGuidanceKind::Informational => NutrientGuidanceKindDto::Informational,
            NutrientGuidanceKind::Adequacy => NutrientGuidanceKindDto::Adequacy,
            NutrientGuidanceKind::Maximum => NutrientGuidanceKindDto::Maximum,
        },
        items_with_data: entry.items_with_data,
        coverage: match entry.coverage {
            NutrientCoverage::None => NutrientCoverageDto::None,
            NutrientCoverage::Partial => NutrientCoverageDto::Partial,
            NutrientCoverage::Complete => NutrientCoverageDto::Complete,
        },
        status: match entry.status {
            NutritionDetailsStatus::NoData => NutritionDetailsStatusDto::NoData,
            NutritionDetailsStatus::PartialData => NutritionDetailsStatusDto::PartialData,
            NutritionDetailsStatus::Available => NutritionDetailsStatusDto::Available,
            NutritionDetailsStatus::BelowReference => NutritionDetailsStatusDto::BelowReference,
            NutritionDetailsStatus::MetReference => NutritionDetailsStatusDto::MetReference,
            NutritionDetailsStatus::WithinLimit => NutritionDetailsStatusDto::WithinLimit,
            NutritionDetailsStatus::OverLimit => NutritionDetailsStatusDto::OverLimit,
        },
    }
}

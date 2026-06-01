use axum::{
    Router,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::catalog::normalize_categories;
use crate::application::import::StageResult;
use crate::domain::import::*;
use crate::interfaces::http::auth::{AppState, AuthAdmin};

pub fn import_routes(state: AppState) -> Router {
    Router::new()
        .route("/imports", post(create_import_handler))
        .route("/imports/{id}/foods", post(stage_foods_handler))
        .route("/imports/{id}/nutrients", post(stage_nutrients_handler))
        .route("/imports/{id}/servings", post(stage_servings_handler))
        .route("/imports/{id}/commit", post(commit_import_handler))
        .route("/imports/{id}", get(get_import_handler))
        .route("/imports/{id}/errors", get(get_import_errors_handler))
        .with_state(state)
}

#[derive(Serialize)]
struct ErrorBody {
    code: String,
    message: String,
}

#[derive(Serialize)]
struct ErrorResponse {
    error: ErrorBody,
}

#[derive(Deserialize)]
struct CreateImportRequest {
    source: String,
}

#[derive(Serialize)]
struct CreateImportResponse {
    id: Uuid,
    source: String,
    status: String,
}

async fn create_import_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Json(req): Json<CreateImportRequest>,
) -> impl IntoResponse {
    let services = &state.import_services;

    match services.create_job(req.source, None).await {
        Ok(job) => (
            StatusCode::CREATED,
            Json(import_job_to_create_response(job)),
        )
            .into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Deserialize)]
struct StageFoodsRequest {
    rows: Vec<ImportFoodRowDto>,
}

#[derive(Deserialize)]
struct ImportFoodRowDto {
    row_number: Option<i32>,
    source: String,
    source_id: String,
    barcode: Option<String>,
    name: String,
    brand: Option<String>,
    #[serde(default)]
    categories: Vec<String>,
    serving_size_g: Option<Decimal>,
}

#[derive(Serialize)]
struct ImportStageResponse {
    accepted: i64,
    rejected: i64,
}

async fn stage_foods_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<StageFoodsRequest>,
) -> impl IntoResponse {
    let services = &state.import_services;

    let foods = import_stage_foods_request_to_products(req);

    match services.stage_foods(ImportId(id), foods).await {
        Ok(result) => Json(import_stage_result_to_response(result)).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Deserialize)]
struct StageNutrientsRequest {
    rows: Vec<ImportNutrientRowDto>,
}

#[derive(Deserialize)]
struct ImportNutrientRowDto {
    row_number: Option<i32>,
    source: String,
    source_id: String,
    nutrient_code: String,
    amount_per_100g: Decimal,
}

async fn stage_nutrients_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<StageNutrientsRequest>,
) -> impl IntoResponse {
    let services = &state.import_services;

    let nutrients = import_stage_nutrients_request_to_nutrients(req);

    match services.stage_nutrients(ImportId(id), nutrients).await {
        Ok(result) => Json(import_stage_result_to_response(result)).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Deserialize)]
struct StageServingsRequest {
    rows: Vec<ImportServingRowDto>,
}

#[derive(Deserialize)]
struct ImportServingRowDto {
    row_number: Option<i32>,
    source: String,
    source_id: String,
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

async fn stage_servings_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<StageServingsRequest>,
) -> impl IntoResponse {
    let services = &state.import_services;

    let servings = import_stage_servings_request_to_servings(req);

    match services.stage_servings(ImportId(id), servings).await {
        Ok(result) => Json(import_stage_result_to_response(result)).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Serialize)]
struct ImportCommitResponse {
    status: String,
    products_created: i64,
    products_updated: i64,
    nutrients_inserted: i64,
    servings_inserted: i64,
    errors_logged: i64,
}

async fn commit_import_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.import_services;

    match services.commit_job(ImportId(id)).await {
        Ok(result) => Json(import_commit_result_to_response(result)).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Serialize)]
struct ImportStatusResponse {
    id: Uuid,
    source: String,
    status: String,
    created_at: String,
    committed_at: Option<String>,
    failed_at: Option<String>,
}

async fn get_import_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.import_services;

    match services.get_job(ImportId(id)).await {
        Ok(job) => Json(import_job_to_status_response(job)).into_response(),
        Err(ImportError::NotFound(_)) => import_not_found_response(id).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Serialize)]
struct ImportErrorListResponse {
    items: Vec<ImportErrorItemDto>,
}

#[derive(Serialize)]
struct ImportErrorItemDto {
    row_number: Option<i32>,
    error: String,
}

async fn get_import_errors_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.import_services;

    match services.get_errors(ImportId(id)).await {
        Ok(errors) => Json(import_errors_to_error_list_response(errors)).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

// ─── Conversions ───────────────────────────────────────────────

fn import_error_response(err: &ImportError) -> (StatusCode, Json<ErrorResponse>) {
    let (status, code, message) = import_error_to_status_code_message(err);
    (
        status,
        Json(ErrorResponse {
            error: ErrorBody {
                code: code.to_string(),
                message,
            },
        }),
    )
}

fn import_error_to_status_code_message(err: &ImportError) -> (StatusCode, &'static str, String) {
    match err {
        ImportError::NotFound(msg) => (StatusCode::NOT_FOUND, "not_found", msg.clone()),
        ImportError::InvalidStatus(msg) => (StatusCode::CONFLICT, "invalid_status", msg.clone()),
        ImportError::Validation(msg) => (StatusCode::BAD_REQUEST, "validation_error", msg.clone()),
        ImportError::Database(_) => {
            tracing::error!(error = %err, "import request failed");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                "internal server error".to_string(),
            )
        }
    }
}

fn import_not_found_response(id: Uuid) -> (StatusCode, Json<ErrorResponse>) {
    (
        StatusCode::NOT_FOUND,
        Json(ErrorResponse {
            error: ErrorBody {
                code: "not_found".into(),
                message: format!("import {id} not found"),
            },
        }),
    )
}

fn import_job_to_create_response(job: ImportJob) -> CreateImportResponse {
    CreateImportResponse {
        id: job.id.0,
        source: job.source,
        status: job.status.as_str().to_string(),
    }
}

fn import_stage_foods_request_to_products(req: StageFoodsRequest) -> Vec<StagedImportProduct> {
    req.rows
        .into_iter()
        .map(import_food_row_dto_to_product)
        .collect()
}

fn import_food_row_dto_to_product(row: ImportFoodRowDto) -> StagedImportProduct {
    StagedImportProduct {
        source: row.source,
        source_id: row.source_id,
        barcode: row.barcode,
        name: row.name,
        brand: row.brand,
        categories: normalize_categories(row.categories),
        serving_size_g: row.serving_size_g,
        raw_payload: None,
        row_number: row.row_number,
    }
}

fn import_stage_nutrients_request_to_nutrients(
    req: StageNutrientsRequest,
) -> Vec<StagedImportNutrient> {
    req.rows
        .into_iter()
        .map(import_nutrient_row_dto_to_nutrient)
        .collect()
}

fn import_nutrient_row_dto_to_nutrient(row: ImportNutrientRowDto) -> StagedImportNutrient {
    StagedImportNutrient {
        source: row.source,
        source_id: row.source_id,
        nutrient_code: row.nutrient_code,
        amount_per_100g: row.amount_per_100g,
        raw_payload: None,
        row_number: row.row_number,
    }
}

fn import_stage_servings_request_to_servings(
    req: StageServingsRequest,
) -> Vec<StagedImportServing> {
    req.rows
        .into_iter()
        .map(import_serving_row_dto_to_serving)
        .collect()
}

fn import_serving_row_dto_to_serving(row: ImportServingRowDto) -> StagedImportServing {
    StagedImportServing {
        source: row.source,
        source_id: row.source_id,
        label: row.label,
        quantity: row.quantity,
        unit: row.unit,
        grams: row.grams,
        raw_payload: None,
        row_number: row.row_number,
    }
}

fn import_stage_result_to_response(result: StageResult) -> ImportStageResponse {
    ImportStageResponse {
        accepted: result.accepted,
        rejected: result.rejected,
    }
}

fn import_commit_result_to_response(result: ImportCommitResult) -> ImportCommitResponse {
    ImportCommitResponse {
        status: "committed".into(),
        products_created: result.products_created,
        products_updated: result.products_updated,
        nutrients_inserted: result.nutrients_inserted,
        servings_inserted: result.servings_inserted,
        errors_logged: result.errors_logged,
    }
}

fn import_job_to_status_response(job: ImportJob) -> ImportStatusResponse {
    ImportStatusResponse {
        id: job.id.0,
        source: job.source,
        status: job.status.as_str().to_string(),
        created_at: job.created_at.to_rfc3339(),
        committed_at: job.committed_at.map(|time| time.to_rfc3339()),
        failed_at: job.failed_at.map(|time| time.to_rfc3339()),
    }
}

fn import_errors_to_error_list_response(errors: Vec<ImportErrorRecord>) -> ImportErrorListResponse {
    ImportErrorListResponse {
        items: errors.into_iter().map(import_error_to_item_dto).collect(),
    }
}

fn import_error_to_item_dto(error: ImportErrorRecord) -> ImportErrorItemDto {
    ImportErrorItemDto {
        row_number: error.row_number,
        error: error.error,
    }
}

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::import::ImportError;
use crate::domain::import::*;
use crate::interfaces::http::auth::{AppState, AuthAdmin};

pub fn import_routes(state: AppState) -> Router {
    Router::new()
        .route("/imports", post(create_import_handler))
        .route("/imports/{id}/foods", post(stage_foods_handler))
        .route("/imports/{id}/nutrients", post(stage_nutrients_handler))
        .route("/imports/{id}/commit", post(commit_import_handler))
        .route("/imports/{id}", get(get_import_handler))
        .route("/imports/{id}/errors", get(get_import_errors_handler))
        .with_state(state)
}

fn import_error_response(err: &ImportError) -> (StatusCode, Json<ErrorBody>) {
    let (status, code, message) = match err {
        ImportError::NotFound(msg) => (StatusCode::NOT_FOUND, "not_found", msg.clone()),
        ImportError::InvalidStatus(msg) => (StatusCode::CONFLICT, "invalid_status", msg.clone()),
        ImportError::Validation(msg) => (StatusCode::BAD_REQUEST, "validation_error", msg.clone()),
        ImportError::Database(_) | ImportError::Internal(_) => {
            tracing::error!(error = %err, "import request failed");
            (StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "internal server error".to_string())
        }
    };
    (
        status,
        Json(ErrorBody {
            error: ApiError {
                code: code.to_string(),
                message,
            },
        }),
    )
}

#[derive(Serialize)]
struct ApiError {
    code: String,
    message: String,
}

#[derive(Serialize)]
struct ErrorBody {
    error: ApiError,
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

    match services.create_job(req.source.clone(), None).await {
        Ok(job) => (
            StatusCode::CREATED,
            Json(CreateImportResponse {
                id: job.id.0,
                source: job.source,
                status: job.status.as_str().to_string(),
            }),
        ).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Deserialize)]
struct StageFoodsRequest {
    rows: Vec<FoodRow>,
}

#[derive(Deserialize)]
struct FoodRow {
    row_number: Option<i32>,
    source: String,
    source_id: String,
    barcode: Option<String>,
    name: String,
    brand: Option<String>,
    category: Option<String>,
    serving_size_g: Option<Decimal>,
}

#[derive(Serialize)]
struct StageResponse {
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

    let foods: Vec<StagedImportProduct> = req.rows.into_iter().map(|r| StagedImportProduct {
        source: r.source,
        source_id: r.source_id,
        barcode: r.barcode,
        name: r.name,
        brand: r.brand,
        category: r.category,
        serving_size_g: r.serving_size_g,
        raw_payload: None,
        row_number: r.row_number,
    }).collect();

    match services.stage_foods(ImportId(id), foods).await {
        Ok(result) => Json(StageResponse {
            accepted: result.accepted,
            rejected: result.rejected,
        }).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Deserialize)]
struct StageNutrientsRequest {
    rows: Vec<NutrientRow>,
}

#[derive(Deserialize)]
struct NutrientRow {
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

    let nutrients: Vec<StagedImportNutrient> = req.rows.into_iter().map(|r| StagedImportNutrient {
        source: r.source,
        source_id: r.source_id,
        nutrient_code: r.nutrient_code,
        amount_per_100g: r.amount_per_100g,
        raw_payload: None,
        row_number: r.row_number,
    }).collect();

    match services.stage_nutrients(ImportId(id), nutrients).await {
        Ok(result) => Json(StageResponse {
            accepted: result.accepted,
            rejected: result.rejected,
        }).into_response(),
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Serialize)]
struct CommitResponse {
    status: String,
    products_created: i64,
    products_updated: i64,
    nutrients_inserted: i64,
    errors_logged: i64,
}

async fn commit_import_handler(
    _admin: AuthAdmin,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> impl IntoResponse {
    let services = &state.import_services;

    match services.commit_job(ImportId(id)).await {
        Ok(result) => Json(CommitResponse {
            status: "committed".into(),
            products_created: result.products_created,
            products_updated: result.products_updated,
            nutrients_inserted: result.nutrients_inserted,
            errors_logged: result.errors_logged,
        }).into_response(),
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
        Ok(job) => Json(ImportStatusResponse {
            id: job.id.0,
            source: job.source,
            status: job.status.as_str().to_string(),
            created_at: job.created_at.to_rfc3339(),
            committed_at: job.committed_at.map(|t| t.to_rfc3339()),
            failed_at: job.failed_at.map(|t| t.to_rfc3339()),
        }).into_response(),
        Err(ImportError::NotFound(_)) => {
            (StatusCode::NOT_FOUND, Json(ErrorBody {
                error: ApiError {
                    code: "not_found".into(),
                    message: format!("import {id} not found"),
                },
            })).into_response()
        }
        Err(e) => import_error_response(&e).into_response(),
    }
}

#[derive(Serialize)]
struct ErrorListResponse {
    items: Vec<ErrorItem>,
}

#[derive(Serialize)]
struct ErrorItem {
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
        Ok(errors) => {
            let items: Vec<ErrorItem> = errors.into_iter().map(|e| ErrorItem {
                row_number: e.row_number,
                error: e.error,
            }).collect();
            Json(ErrorListResponse { items }).into_response()
        }
        Err(e) => import_error_response(&e).into_response(),
    }
}

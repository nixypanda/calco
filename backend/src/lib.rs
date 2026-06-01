pub mod application;
pub mod config;
pub mod domain;
pub mod infrastructure;
pub mod interfaces;

use std::sync::Arc;

use axum::http::{HeaderValue, Method, header};
use axum::{Router, routing::get};
use sqlx::PgPool;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::application::auth::{AdminUserServices, AuthBootstrapServices, AuthSessionServices};
use crate::application::food_log::FoodLogServices;
use crate::application::import::ImportServices;
use crate::application::meal::MealServices;
use crate::config::AppConfig;
use crate::domain::auth::{IdentityRepository, SessionRepository, UserProfileRepository};
use crate::domain::catalog::{NutrientRepository, ProductRepository, UnitRepository};
use crate::domain::food_log::FoodLogRepository;
use crate::domain::import::ImportRepository;
use crate::domain::meal::MealRepository;
use crate::domain::units::UnitConverter;
use crate::infrastructure::postgres::auth::{
    PostgresIdentityRepository, PostgresSessionRepository, PostgresUserProfileRepository,
};
use crate::infrastructure::postgres::catalog::{
    PostgresNutrientRepository, PostgresProductRepository, PostgresUnitRepository,
};
use crate::infrastructure::postgres::food_log::PostgresFoodLogRepository;
use crate::infrastructure::postgres::import::PostgresImportRepository;
use crate::infrastructure::postgres::meal::PostgresMealRepository;
use crate::interfaces::http::auth::{AppState, auth_routes};
use crate::interfaces::http::catalog::catalog_routes;
use crate::interfaces::http::food_log::food_log_routes;
use crate::interfaces::http::import::import_routes;
use crate::interfaces::http::meal::meal_routes;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

pub async fn build_app_state(pool: PgPool, config: AppConfig) -> Result<AppState, BoxError> {
    let identity_repo =
        Arc::new(PostgresIdentityRepository::new(pool.clone())) as Arc<dyn IdentityRepository>;
    let session_repo =
        Arc::new(PostgresSessionRepository::new(pool.clone())) as Arc<dyn SessionRepository>;
    let profile_repo = Arc::new(PostgresUserProfileRepository::new(pool.clone()))
        as Arc<dyn UserProfileRepository>;

    let auth_bootstrap =
        AuthBootstrapServices::new(identity_repo.clone(), session_repo.clone(), config.clone());
    let auth_sessions = AuthSessionServices::new(
        identity_repo.clone(),
        session_repo.clone(),
        profile_repo.clone(),
        config.clone(),
    );
    let admin_users = AdminUserServices::new(
        identity_repo.clone(),
        session_repo.clone(),
        profile_repo.clone(),
    );

    let product_repo =
        Arc::new(PostgresProductRepository::new(pool.clone())) as Arc<dyn ProductRepository>;
    let nutrient_repo =
        Arc::new(PostgresNutrientRepository::new(pool.clone())) as Arc<dyn NutrientRepository>;
    let unit_repo = Arc::new(PostgresUnitRepository::new(pool.clone())) as Arc<dyn UnitRepository>;

    let mass_factors = unit_repo.list_mass_factors().await?;
    let unit_converter = Arc::new(UnitConverter::from_entries(mass_factors));

    let food_log_repo =
        Arc::new(PostgresFoodLogRepository::new(pool.clone())) as Arc<dyn FoodLogRepository>;
    let meal_repo = Arc::new(PostgresMealRepository::new(pool.clone())) as Arc<dyn MealRepository>;

    let food_log_services = FoodLogServices::new(
        food_log_repo.clone(),
        product_repo.clone(),
        unit_converter.clone(),
        meal_repo.clone(),
    );

    let meal_services = MealServices::new(
        meal_repo.clone(),
        product_repo.clone(),
        unit_converter.clone(),
    );

    let import_repo =
        Arc::new(PostgresImportRepository::new(pool.clone())) as Arc<dyn ImportRepository>;
    let import_services = ImportServices::new(import_repo.clone());

    Ok(AppState {
        config,
        auth_bootstrap,
        auth_sessions,
        admin_users,
        product_repo,
        nutrient_repo,
        unit_repo,
        unit_converter,
        food_log_repo,
        meal_repo,
        import_repo,
        food_log_services,
        meal_services,
        import_services,
    })
}

pub async fn build_router(pool: PgPool, config: AppConfig) -> Result<Router, BoxError> {
    let cors = build_cors_layer(&config);
    let auth_state = build_app_state(pool, config).await?;

    let api = Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .merge(auth_routes(auth_state.clone()))
        .merge(catalog_routes(auth_state.clone()))
        .merge(food_log_routes(auth_state.clone()))
        .merge(meal_routes(auth_state.clone()))
        .merge(import_routes(auth_state));

    Ok(Router::new().nest("/api", api).layer(cors))
}

fn build_cors_layer(config: &AppConfig) -> CorsLayer {
    let methods = [
        Method::GET,
        Method::POST,
        Method::PUT,
        Method::DELETE,
        Method::PATCH,
        Method::OPTIONS,
    ];
    let headers = [header::CONTENT_TYPE, header::ACCEPT];

    if config.cors_allowed_origins.is_empty() {
        return CorsLayer::new()
            .allow_methods(methods)
            .allow_headers(headers);
    }

    let origins: Vec<HeaderValue> = config
        .cors_allowed_origins
        .iter()
        .map(|o| {
            HeaderValue::from_str(o)
                .unwrap_or_else(|_| panic!("invalid CORS_ALLOWED_ORIGINS entry: {o}"))
        })
        .collect();

    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_credentials(true)
        .allow_methods(methods)
        .allow_headers(headers)
}

async fn health() -> &'static str {
    "ok"
}

async fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

pub mod auth;
pub mod config;
pub mod import;
pub mod nutrition;

use std::sync::Arc;

use axum::http::{HeaderValue, Method, header};
use axum::{Router, routing::get};
use sqlx::PgPool;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::auth::application::{AdminUserServices, AuthBootstrapServices, AuthSessionServices};
use crate::auth::domain::{IdentityRepository, SessionRepository, UserProfileRepository};
use crate::auth::infrastructure::postgres::{
    PostgresIdentityRepository, PostgresSessionRepository, PostgresUserProfileRepository,
};
use crate::auth::interfaces::http::auth_routes;
use crate::config::AppConfig;
use crate::import::application::ImportServices;
use crate::import::domain::ImportRepository;
use crate::import::infrastructure::postgres::PostgresImportRepository;
use crate::import::interfaces::http::import_routes;
use crate::nutrition::application::food_log::{FoodLogHistoryServices, FoodLogServices};
use crate::nutrition::application::goal_target::GoalTargetServices;
use crate::nutrition::application::meal::MealServices;
use crate::nutrition::domain::catalog::{NutrientRepository, ProductRepository, UnitRepository};
use crate::nutrition::domain::food_log::FoodLogRepository;
use crate::nutrition::domain::goal_target::GoalTargetRepository;
use crate::nutrition::domain::meal::MealRepository;
use crate::nutrition::domain::units::UnitConverter;
use crate::nutrition::infrastructure::postgres::catalog::{
    PostgresNutrientRepository, PostgresProductRepository, PostgresUnitRepository,
};
use crate::nutrition::infrastructure::postgres::food_log::PostgresFoodLogRepository;
use crate::nutrition::infrastructure::postgres::goal_target::PostgresGoalTargetRepository;
use crate::nutrition::infrastructure::postgres::meal::PostgresMealRepository;
use crate::nutrition::interfaces::http::catalog::catalog_routes;
use crate::nutrition::interfaces::http::food_log::food_log_routes;
use crate::nutrition::interfaces::http::goal_target::goal_target_routes;
use crate::nutrition::interfaces::http::meal::meal_routes;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub auth_bootstrap: AuthBootstrapServices,
    pub auth_sessions: AuthSessionServices,
    pub admin_users: AdminUserServices,
    pub product_repo: Arc<dyn ProductRepository>,
    pub nutrient_repo: Arc<dyn NutrientRepository>,
    pub unit_repo: Arc<dyn UnitRepository>,
    pub unit_converter: Arc<UnitConverter>,
    pub food_log_repo: Arc<dyn FoodLogRepository>,
    pub meal_repo: Arc<dyn MealRepository>,
    pub goal_target_repo: Arc<dyn GoalTargetRepository>,
    pub import_repo: Arc<dyn ImportRepository>,
    pub food_log_services: FoodLogServices,
    pub food_log_history_services: FoodLogHistoryServices,
    pub meal_services: MealServices,
    pub goal_target_services: GoalTargetServices,
    pub import_services: ImportServices,
}

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
    let goal_target_repo =
        Arc::new(PostgresGoalTargetRepository::new(pool.clone())) as Arc<dyn GoalTargetRepository>;

    let food_log_services = FoodLogServices::new(
        food_log_repo.clone(),
        product_repo.clone(),
        unit_converter.clone(),
        meal_repo.clone(),
    );
    let food_log_history_services = FoodLogHistoryServices::new(food_log_repo.clone());

    let meal_services = MealServices::new(
        meal_repo.clone(),
        product_repo.clone(),
        unit_converter.clone(),
    );
    let goal_target_services = GoalTargetServices::new(goal_target_repo.clone());

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
        goal_target_repo,
        import_repo,
        food_log_services,
        food_log_history_services,
        meal_services,
        goal_target_services,
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
        .merge(goal_target_routes(auth_state.clone()))
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

mod config;
mod domain;
mod application;
mod infrastructure;
mod interfaces;

use std::sync::Arc;

use axum::{Router, routing::get};
use sqlx::postgres::PgPoolOptions;
use tower_http::cors::CorsLayer;
use tracing_subscriber::EnvFilter;

use crate::config::AppConfig;
use crate::infrastructure::postgres::auth::{
    PostgresIdentityRepository,
    PostgresSessionRepository,
    PostgresUserProfileRepository,
};
use crate::infrastructure::postgres::catalog::{
    PostgresProductRepository,
    PostgresNutrientRepository,
    PostgresUnitRepository,
};
use crate::infrastructure::postgres::food_log::{
    PostgresFoodLogRepository,
    PostgresSummaryRepository,
};
use crate::interfaces::http::auth::{auth_routes, AppState};
use crate::interfaces::http::catalog::{catalog_routes, CatalogState};
use crate::interfaces::http::food_log::food_log_routes;
use crate::application::catalog::{CatalogServices, ProductRepository, NutrientRepository, UnitRepository};
use crate::application::food_log::{FoodLogServices, FoodLogRepository, SummaryRepository, ProductLookup};

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let _ = dotenvy::dotenv();

    let config = AppConfig::from_env();

    tracing::info!("connecting to database...");
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&config.database_url)
        .await
        .expect("failed to connect to database");

    tracing::info!("running migrations...");
    sqlx::migrate!("src/infrastructure/postgres/migrations")
        .run(&pool)
        .await
        .expect("failed to run migrations");

    let identity_repo = Arc::new(PostgresIdentityRepository::new(pool.clone()));
    let session_repo = Arc::new(PostgresSessionRepository::new(pool.clone()));
    let profile_repo = Arc::new(PostgresUserProfileRepository::new(pool.clone()));

    let product_repo = Arc::new(PostgresProductRepository::new(pool.clone())) as Arc<dyn ProductRepository>;
    let nutrient_repo = Arc::new(PostgresNutrientRepository::new(pool.clone())) as Arc<dyn NutrientRepository>;
    let unit_repo = Arc::new(PostgresUnitRepository::new(pool.clone())) as Arc<dyn UnitRepository>;

    let food_log_repo_impl = Arc::new(PostgresFoodLogRepository::new(pool.clone()));
    let food_log_repo = food_log_repo_impl.clone() as Arc<dyn FoodLogRepository>;
    let product_lookup = food_log_repo_impl as Arc<dyn ProductLookup>;
    let summary_repo = Arc::new(PostgresSummaryRepository::new(pool.clone())) as Arc<dyn SummaryRepository>;

    let food_log_services = FoodLogServices::new(food_log_repo, product_lookup, summary_repo);

    let auth_state = AppState {
        identity_repo,
        session_repo,
        profile_repo,
        config: config.clone(),
        food_log_services: Some(food_log_services),
    };

    let catalog_state = CatalogState {
        services: CatalogServices::new(product_repo, nutrient_repo, unit_repo),
    };

    let api = Router::new()
        .route("/health", get(health))
        .route("/version", get(version));

    let app = Router::new()
        .nest("/api", api)
        .merge(auth_routes(auth_state.clone()))
        .merge(catalog_routes(catalog_state))
        .merge(food_log_routes(auth_state))
        .layer(CorsLayer::permissive());

    let addr = config.bind_addr;
    tracing::info!("listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn health() -> &'static str {
    "ok"
}

async fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

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
use crate::interfaces::http::auth::{auth_routes, AppState};

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

    let state = AppState {
        identity_repo,
        session_repo,
        profile_repo,
        config: config.clone(),
    };

    let api = Router::new()
        .route("/health", get(health))
        .route("/version", get(version));

    let app = Router::new()
        .nest("/api", api)
        .merge(auth_routes(state))
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

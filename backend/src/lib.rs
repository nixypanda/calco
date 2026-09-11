pub mod assistant;
pub mod auth;
pub mod config;
pub mod import;
pub mod nutrition;

use axum::http::{HeaderValue, Method, header};
use axum::{Router, routing::get};
use sqlx::PgPool;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::assistant::interfaces::assistant_routes;
use crate::assistant::module::AssistantModule;
use crate::auth::domain::SessionPolicy;
use crate::auth::interfaces::SessionCookieConfig;
use crate::auth::interfaces::http::auth_routes;
use crate::auth::module::AuthModule;
use crate::config::{AppConfig, ServerConfig};
use crate::import::interfaces::http::import_routes;
use crate::import::module::ImportModule;
use crate::nutrition::catalog::interfaces::catalog_routes;
use crate::nutrition::diary::interfaces::diary_preferences_routes;
use crate::nutrition::food_log::interfaces::food_log_routes;
use crate::nutrition::goals::interfaces::goal_target_routes;
use crate::nutrition::guidance::interfaces::nutrition_details_routes;
use crate::nutrition::meal::interfaces::meal_routes;
use crate::nutrition::module::NutritionModule;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// The composition root: one bounded-context module per top-level domain.
///
/// Handlers extract the module they need via [`FromRef`], so each context stays
/// decoupled from the others while sharing a single router state.
#[derive(Clone)]
pub struct AppState {
    pub auth: AuthModule,
    pub nutrition: NutritionModule,
    pub import: ImportModule,
    pub assistant: AssistantModule,
}

pub async fn build_app_state(pool: PgPool, config: AppConfig) -> Result<AppState, BoxError> {
    let auth = AuthModule::build(
        &pool,
        SessionCookieConfig {
            cookie_name: config.session.cookie_name.clone(),
            cookie_secure: config.session.cookie_secure,
        },
        SessionPolicy::new(chrono::Duration::seconds(config.session.ttl_seconds))?,
    );
    let nutrition = NutritionModule::build(&pool).await?;
    let import = ImportModule::build(&pool);
    let assistant = AssistantModule::build(&config.assistant, &nutrition.catalog)?;

    Ok(AppState {
        auth,
        nutrition,
        import,
        assistant,
    })
}

pub async fn build_router(pool: PgPool, config: AppConfig) -> Result<Router, BoxError> {
    let cors = build_cors_layer(&config.server);
    let auth_state = build_app_state(pool, config).await?;

    Ok(build_router_from_state(auth_state).layer(cors))
}

/// Builds the HTTP surface from an already-composed state. This keeps provider
/// substitution available to black-box tests without changing production
/// composition.
pub fn build_router_from_state(auth_state: AppState) -> Router {
    let api = Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .merge(auth_routes(auth_state.auth.clone()))
        .merge(catalog_routes(auth_state.clone()))
        .merge(food_log_routes(auth_state.clone()))
        .merge(diary_preferences_routes(auth_state.clone()))
        .merge(nutrition_details_routes(auth_state.clone()))
        .merge(meal_routes(auth_state.clone()))
        .merge(goal_target_routes(auth_state.clone()))
        .merge(import_routes(auth_state.clone()))
        .merge(assistant_routes(auth_state));

    Router::new().nest("/api", api)
}

fn build_cors_layer(config: &ServerConfig) -> CorsLayer {
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

    let origins: Vec<HeaderValue> = config.cors_allowed_origins.clone();

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

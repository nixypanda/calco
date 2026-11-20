pub mod assistant;
pub mod auth;
pub mod catalog;
pub mod config;
pub mod import;
pub mod journal;
use axum::http::{HeaderValue, Method, header};
use axum::{Router, routing::get};
use sqlx::PgPool;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::assistant::api::http::assistant_routes;
use crate::assistant::composition::AssistantComponents;
use crate::auth::api::SessionCookieConfig;
use crate::auth::api::http::auth_routes;
use crate::auth::domain::SessionPolicy;
use crate::auth::module::AuthModule;
use crate::catalog::api::http::catalog_routes;
use crate::catalog::module::CatalogModule;
use crate::config::{AppConfig, ServerConfig};
use crate::import::api::http::import_routes;
use crate::import::module::ImportModule;
use crate::journal::diary_prefs::api::http::diary_prefs_routes;
use crate::journal::food_log::api::http::food_log_routes;
use crate::journal::goals::api::http::goal_target_routes;
use crate::journal::guidance::api::http::nutrition_details_routes;
use crate::journal::meal::api::http::meal_routes;
use crate::journal::module::JournalModule;
pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// The composition root: one bounded-context module per top-level domain.
///
/// Handlers extract the module they need via [`FromRef`], so each context stays
/// decoupled from the others while sharing a single router state.
#[derive(Clone)]
pub struct AppState {
    pub auth: AuthModule,
    pub catalog: CatalogModule,
    pub journal: JournalModule,
    pub import: ImportModule,
    pub assistant: AssistantComponents,
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
    let catalog = CatalogModule::build(&pool).await?;
    let journal = JournalModule::build(&pool, &catalog).await?;
    let import = ImportModule::build(&pool, catalog.services.clone(), catalog.services.clone());
    let assistant = AssistantComponents::from_config(&config.assistant, &catalog)?;

    Ok(AppState {
        auth,
        catalog,
        journal,
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
        .merge(diary_prefs_routes(auth_state.clone()))
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
    let headers = [header::CONTENT_TYPE, header::ACCEPT, header::AUTHORIZATION];

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

#[cfg(test)]
mod architecture_tests {
    use std::fs;
    use std::path::Path;

    #[test]
    fn api_directories_have_http_entrypoints() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut violations = Vec::new();
        inspect(&src, &mut violations);
        violations.sort();
        assert!(
            violations.is_empty(),
            "api layout violations:\n{}",
            violations.join("\n")
        );
    }

    fn inspect(dir: &Path, violations: &mut Vec<String>) {
        for entry in fs::read_dir(dir).expect("read src tree") {
            let path = entry.expect("read src entry").path();
            let file_name = path.file_name().and_then(|name| name.to_str());

            if path.is_dir() {
                if file_name == Some("api") {
                    check_api_dir(&path, violations);
                }
                inspect(&path, violations);
            } else if file_name == Some("api.rs") {
                violations.push(format!(
                    "{}: api must be a directory, not a file",
                    path.display()
                ));
            }
        }
    }

    fn check_api_dir(dir: &Path, violations: &mut Vec<String>) {
        if !dir.join("mod.rs").is_file() {
            violations.push(format!(
                "{}: api directory must contain mod.rs",
                dir.display()
            ));
        }

        let has_http_file = dir.join("http.rs").is_file();
        let has_http_dir = dir.join("http").join("mod.rs").is_file();
        if has_http_file == has_http_dir {
            violations.push(format!(
                "{}: api directory must contain exactly one of http.rs or http/mod.rs",
                dir.display()
            ));
        }
    }
}

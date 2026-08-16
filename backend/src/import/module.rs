use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::import::application::ImportService;
use crate::import::domain::ImportRepository;
use crate::import::infrastructure::postgres::PostgresImportRepository;

#[derive(Clone)]
pub struct ImportModule {
    pub repo: Arc<dyn ImportRepository>,
    pub service: ImportService,
}

impl ImportModule {
    pub fn build(pool: &PgPool) -> Self {
        let repo =
            Arc::new(PostgresImportRepository::new(pool.clone())) as Arc<dyn ImportRepository>;
        let service = ImportService::new(repo.clone());
        Self { repo, service }
    }
}

impl FromRef<AppState> for ImportModule {
    fn from_ref(app: &AppState) -> Self {
        app.import.clone()
    }
}

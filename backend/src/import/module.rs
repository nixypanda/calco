use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::catalog::app::{ExternalProductWritePort, NutrientCatalogReadPort};
use crate::import::app::ImportService;
use crate::import::domain::ImportRepo;
use crate::import::infra::pg::PgImportRepo;

#[derive(Clone)]
pub struct ImportModule {
    pub repo: Arc<dyn ImportRepo>,
    pub service: ImportService,
}

impl ImportModule {
    pub fn build(
        pool: &PgPool,
        external_product_writer: Arc<dyn ExternalProductWritePort>,
        nutrient_catalog_reader: Arc<dyn NutrientCatalogReadPort>,
    ) -> Self {
        let repo = Arc::new(PgImportRepo::new(pool.clone())) as Arc<dyn ImportRepo>;
        let service = ImportService::new(
            repo.clone(),
            external_product_writer,
            nutrient_catalog_reader,
        );
        Self { repo, service }
    }
}

impl FromRef<AppState> for ImportModule {
    fn from_ref(app: &AppState) -> Self {
        app.import.clone()
    }
}

#[cfg(test)]
mod architecture_tests {}

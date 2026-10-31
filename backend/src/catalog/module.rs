use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::BoxError;
use crate::catalog::app::CatalogService;
use crate::catalog::app::ExternalProductCatalog;
use crate::catalog::domain::units::UnitConverter;
use crate::catalog::domain::{NutrientRepo, ProductRepo, UnitRepo};
use crate::catalog::infra::{OpenFoodFactsClient, PgNutrientRepo, PgProductRepo, PgUnitRepo};

/// The catalog kernel: products, nutrients, units, and the unit converter.
#[derive(Clone)]
pub struct CatalogModule {
    pub services: Arc<CatalogService>,
    pub unit_converter: Arc<UnitConverter>,
}

impl CatalogModule {
    pub async fn build(pool: &PgPool) -> Result<Self, BoxError> {
        let product_repo = Arc::new(PgProductRepo::new(pool.clone())) as Arc<dyn ProductRepo>;
        let nutrient_repo = Arc::new(PgNutrientRepo::new(pool.clone())) as Arc<dyn NutrientRepo>;
        let unit_repo = Arc::new(PgUnitRepo::new(pool.clone())) as Arc<dyn UnitRepo>;
        let external_catalog =
            Arc::new(OpenFoodFactsClient::new()?) as Arc<dyn ExternalProductCatalog>;

        let mass_factors = unit_repo.list_mass_factors().await?;
        let unit_converter = Arc::new(UnitConverter::from_entries(mass_factors));

        let catalog_services = Arc::new(CatalogService::new(
            product_repo.clone(),
            nutrient_repo.clone(),
            unit_repo,
            unit_converter.clone(),
            external_catalog,
        ));

        Ok(Self {
            services: catalog_services,
            unit_converter,
        })
    }
}

impl FromRef<AppState> for CatalogModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.catalog.clone()
    }
}

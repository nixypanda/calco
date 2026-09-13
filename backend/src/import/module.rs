use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::import::application::ImportService;
use crate::import::domain::ImportRepository;
use crate::import::infrastructure::postgres::PostgresImportRepository;
use crate::nutrition::catalog::application::{ExternalProductWritePort, NutrientCatalogReadPort};

#[derive(Clone)]
pub struct ImportModule {
    pub repo: Arc<dyn ImportRepository>,
    pub service: ImportService,
}

impl ImportModule {
    pub fn build(
        pool: &PgPool,
        external_product_writer: Arc<dyn ExternalProductWritePort>,
        nutrient_catalog_reader: Arc<dyn NutrientCatalogReadPort>,
    ) -> Self {
        let repo =
            Arc::new(PostgresImportRepository::new(pool.clone())) as Arc<dyn ImportRepository>;
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
mod architecture_tests {
    #[test]
    fn import_application_uses_catalog_application_ports_for_product_writes() {
        let source = include_str!("application.rs");

        assert!(!source.contains("ProductRepository"));
        assert!(!source.contains("NutrientRepository"));
        assert!(source.contains("ExternalProductWritePort"));
        assert!(source.contains("NutrientCatalogReadPort"));
    }

    #[test]
    fn postgres_import_repository_does_not_write_catalog_tables() {
        let source = include_str!("infrastructure/postgres.rs");
        let forbidden = [
            "INSERT INTO products ",
            "UPDATE products ",
            "DELETE FROM products ",
            "INSERT INTO product_nutrients",
            "UPDATE product_nutrients",
            "DELETE FROM product_nutrients",
            "INSERT INTO product_servings",
            "UPDATE product_servings",
            "DELETE FROM product_servings",
            " FROM products ",
            " JOIN products ",
            " FROM nutrients ",
            " JOIN nutrients ",
        ];

        for statement in forbidden {
            assert!(
                !source.contains(statement),
                "import repository crosses the catalog persistence boundary: {statement}"
            );
        }
    }
}

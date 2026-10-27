use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::import::app::ImportService;
use crate::import::domain::ImportRepo;
use crate::import::infra::pg::PgImportRepo;
use crate::nutrition::catalog::app::{ExternalProductWritePort, NutrientCatalogReadPort};

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
mod architecture_tests {
    #[test]
    fn import_app_uses_catalog_app_ports_for_product_writes() {
        let source = include_str!("app.rs");

        assert!(!source.contains("ProductRepo"));
        assert!(!source.contains("NutrientRepo"));
        assert!(source.contains("ExternalProductWritePort"));
        assert!(source.contains("NutrientCatalogReadPort"));
    }

    #[test]
    fn pg_import_repo_does_not_write_catalog_tables() {
        let source = include_str!("infra/pg.rs");
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
                "import repo crosses the catalog persistence boundary: {statement}"
            );
        }
    }
}

use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::import::application::ImportService;
use crate::import::domain::ImportRepository;
use crate::import::infrastructure::postgres::PostgresImportRepository;
use crate::nutrition::catalog::domain::{NutrientRepository, ProductRepository};

#[derive(Clone)]
pub struct ImportModule {
    pub repo: Arc<dyn ImportRepository>,
    pub service: ImportService,
}

impl ImportModule {
    pub fn build(
        pool: &PgPool,
        product_repo: Arc<dyn ProductRepository>,
        nutrient_repo: Arc<dyn NutrientRepository>,
    ) -> Self {
        let repo =
            Arc::new(PostgresImportRepository::new(pool.clone())) as Arc<dyn ImportRepository>;
        let service = ImportService::new(repo.clone(), product_repo, nutrient_repo);
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

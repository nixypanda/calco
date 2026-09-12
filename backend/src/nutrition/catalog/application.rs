use std::sync::Arc;

use async_trait::async_trait;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::*;

pub struct CustomFoodInput {
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrients: Vec<ProductNutrientInput>,
    pub servings: Vec<ProductServingInput>,
}

#[derive(Debug, Clone)]
pub struct ExternalProductInput {
    pub source_id: String,
    pub barcode: String,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrients: Vec<ProductNutrientInput>,
    pub servings: Vec<ProductServingInput>,
}

#[async_trait]
pub trait ExternalProductCatalog: Send + Sync {
    async fn find_by_barcode(
        &self,
        barcode: &str,
    ) -> Result<Option<ExternalProductInput>, NutritionError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BarcodeLookupOrigin {
    Local,
    OpenFoodFacts,
}

#[derive(Debug, Clone)]
pub struct BarcodeLookupResult {
    pub product: Product,
    pub origin: BarcodeLookupOrigin,
}

/// Narrow application-level access to products for downstream nutrition use cases.
///
/// Callers receive only products that the authenticated actor may view; persistence
/// details remain entirely inside the catalog application service.
#[async_trait]
pub trait CatalogReadPort: Send + Sync {
    async fn resolve_products(
        &self,
        actor_id: Uuid,
        ids: &[ProductId],
    ) -> Result<Vec<(ProductId, Product)>, NutritionError>;
}

#[derive(Clone)]
pub struct CatalogService {
    product_repo: Arc<dyn ProductRepository>,
    nutrient_repo: Arc<dyn NutrientRepository>,
    unit_repo: Arc<dyn UnitRepository>,
    unit_converter: Arc<UnitConverter>,
    external_catalog: Arc<dyn ExternalProductCatalog>,
    policy: CatalogPolicy,
}

impl CatalogService {
    pub fn new(
        product_repo: Arc<dyn ProductRepository>,
        nutrient_repo: Arc<dyn NutrientRepository>,
        unit_repo: Arc<dyn UnitRepository>,
        unit_converter: Arc<UnitConverter>,
        external_catalog: Arc<dyn ExternalProductCatalog>,
    ) -> Self {
        Self {
            product_repo,
            nutrient_repo,
            unit_repo,
            unit_converter,
            external_catalog,
            policy: CatalogPolicy,
        }
    }

    pub async fn search(
        &self,
        actor_id: Uuid,
        spec: ProductSearchSpec,
        scope: ProductSearchScope,
    ) -> Result<Vec<Product>, NutritionError> {
        self.product_repo.search(spec, scope, Some(actor_id)).await
    }

    pub async fn list_categories(
        &self,
        actor_id: Uuid,
        query: &str,
        limit: i64,
    ) -> Result<Vec<CategorySuggestion>, NutritionError> {
        self.product_repo
            .list_categories(query, Some(actor_id), limit)
            .await
    }

    pub async fn list_custom_foods(&self, actor_id: Uuid) -> Result<Vec<Product>, NutritionError> {
        let products = self.product_repo.list_custom_foods().await?;
        for product in &products {
            self.policy.authorize_view(actor_id, product)?;
        }
        Ok(products)
    }

    pub async fn find_by_barcode(
        &self,
        actor_id: Uuid,
        barcode: &str,
    ) -> Result<Option<BarcodeLookupResult>, NutritionError> {
        let barcode = barcode.trim();
        if let Some(product) = self
            .product_repo
            .find_by_barcode(barcode, Some(actor_id))
            .await?
        {
            return Ok(Some(BarcodeLookupResult {
                product,
                origin: BarcodeLookupOrigin::Local,
            }));
        }

        validate_external_barcode(barcode)?;
        tracing::info!(
            barcode,
            "barcode not found locally; querying Open Food Facts"
        );
        let external_result = self.external_catalog.find_by_barcode(barcode).await;
        let Some(input) = (match external_result {
            Ok(input) => input,
            Err(error) => {
                tracing::warn!(
                    barcode,
                    result = "error",
                    error = %error,
                    "Open Food Facts lookup completed"
                );
                return Err(error);
            }
        }) else {
            tracing::info!(
                barcode,
                result = "not_found",
                "Open Food Facts lookup completed"
            );
            return Ok(None);
        };
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        let product = Product::new_external(
            Source::Off,
            input.source_id,
            Some(input.barcode),
            input.name,
            input.brand,
            input.categories,
            input.default_quantity,
            input.default_unit,
            input.nutrients,
            input.servings,
            &nutrient_catalog,
        )
        .map_err(|_| NutritionError::ExternalInvalidResponse)?;

        // CalCo is a small homelab deployment, so a plain create is intentional.
        // Concurrent first scans could race on (source, source_id); if that becomes
        // realistic, replace this with an atomic create-or-load repository operation.
        self.product_repo.create(&product).await?;
        tracing::info!(
            barcode,
            product_id = %product.id.0,
            result = "imported",
            "Open Food Facts lookup completed"
        );
        Ok(Some(BarcodeLookupResult {
            product,
            origin: BarcodeLookupOrigin::OpenFoodFacts,
        }))
    }

    pub async fn get_product(
        &self,
        actor_id: Uuid,
        id: ProductId,
    ) -> Result<Product, NutritionError> {
        let product = self
            .product_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound(format!("product {} not found", id.0)))?;
        self.policy.authorize_view(actor_id, &product)?;
        Ok(product)
    }

    pub async fn create_custom_food(
        &self,
        actor_id: Uuid,
        input: CustomFoodInput,
    ) -> Result<Product, NutritionError> {
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        let product = Product::new_custom(
            actor_id,
            input.name,
            input.brand,
            input.categories,
            input.default_quantity,
            input.default_unit,
            input.nutrients,
            input.servings,
            &nutrient_catalog,
        )?;
        self.product_repo.create(&product).await?;
        Ok(product)
    }

    pub async fn validate_custom_food_draft(
        &self,
        input: CustomFoodInput,
    ) -> Result<(), NutritionError> {
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        Product::validate_custom_draft(
            input.name,
            input.brand,
            input.categories,
            input.default_quantity,
            input.default_unit,
            input.nutrients,
            input.servings,
            &nutrient_catalog,
        )
    }

    pub async fn update_custom_food(
        &self,
        actor_id: Uuid,
        id: ProductId,
        input: CustomFoodInput,
    ) -> Result<Product, NutritionError> {
        let existing = self.get_product(actor_id, id).await?;
        self.policy.authorize_mutation(actor_id, &existing)?;
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        let updated = existing.update_custom(
            input.name,
            input.brand,
            input.categories,
            input.default_quantity,
            input.default_unit,
            input.nutrients,
            input.servings,
            &nutrient_catalog,
        )?;
        self.product_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_custom_food(
        &self,
        actor_id: Uuid,
        id: ProductId,
    ) -> Result<(), NutritionError> {
        let product = self.get_product(actor_id, id).await?;
        self.policy.authorize_mutation(actor_id, &product)?;
        self.product_repo.delete(id).await
    }

    pub async fn list_nutrients(&self) -> Result<Vec<Nutrient>, NutritionError> {
        self.nutrient_repo.list_all().await
    }

    pub async fn get_nutrient(&self, code: &str) -> Result<Option<Nutrient>, NutritionError> {
        self.nutrient_repo.find_by_code(code).await
    }

    pub async fn list_units(&self) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
        self.unit_repo.list_all().await
    }

    pub fn required_custom_food_nutrient_codes(&self) -> Vec<String> {
        REQUIRED_CUSTOM_FOOD_NUTRIENT_CODES
            .iter()
            .map(|code| (*code).to_owned())
            .collect()
    }

    pub async fn allowed_units(
        &self,
        product: &Product,
    ) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
        let all_units = self.unit_repo.list_all().await?;
        let allowed = product.allowed_unit_codes(&self.unit_converter);
        Ok(all_units
            .into_iter()
            .filter(|(code, _, _)| allowed.contains(&code.0))
            .collect())
    }

    pub fn filter_allowed_units(
        &self,
        product: &Product,
        all_units: &[(UnitCode, String, String)],
    ) -> Vec<(UnitCode, String, String)> {
        let allowed = product.allowed_unit_codes(&self.unit_converter);
        all_units
            .iter()
            .filter(|(code, _, _)| allowed.contains(&code.0))
            .cloned()
            .collect()
    }

    async fn load_nutrient_catalog(&self) -> Result<NutrientCatalog, NutritionError> {
        Ok(self.nutrient_repo.list_all().await?.into_iter().collect())
    }
}

fn validate_external_barcode(barcode: &str) -> Result<(), NutritionError> {
    if !(4..=24).contains(&barcode.len()) || !barcode.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(NutritionError::Validation(
            "barcode must contain 4 to 24 digits".into(),
        ));
    }
    Ok(())
}

#[async_trait]
impl CatalogReadPort for CatalogService {
    async fn resolve_products(
        &self,
        actor_id: Uuid,
        ids: &[ProductId],
    ) -> Result<Vec<(ProductId, Product)>, NutritionError> {
        let mut products = Vec::with_capacity(ids.len());
        for id in ids {
            products.push((*id, self.get_product(actor_id, *id).await?));
        }
        Ok(products)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    struct MockProductRepository {
        found: Option<Product>,
        created: Mutex<Vec<Product>>,
    }

    #[async_trait]
    impl ProductRepository for MockProductRepository {
        async fn search(
            &self,
            _spec: ProductSearchSpec,
            _scope: ProductSearchScope,
            _user_id: Option<Uuid>,
        ) -> Result<Vec<Product>, NutritionError> {
            Ok(vec![])
        }

        async fn list_categories(
            &self,
            _query: &str,
            _user_id: Option<Uuid>,
            _limit: i64,
        ) -> Result<Vec<CategorySuggestion>, NutritionError> {
            Ok(vec![])
        }

        async fn find_by_id(&self, _id: ProductId) -> Result<Option<Product>, NutritionError> {
            Ok(None)
        }

        async fn existing_ids(
            &self,
            _ids: &[ProductId],
        ) -> Result<HashSet<ProductId>, NutritionError> {
            Ok(HashSet::new())
        }

        async fn find_by_barcode(
            &self,
            _barcode: &str,
            _user_id: Option<Uuid>,
        ) -> Result<Option<Product>, NutritionError> {
            Ok(self.found.clone())
        }

        async fn list_custom_foods(&self) -> Result<Vec<Product>, NutritionError> {
            Ok(vec![])
        }

        async fn create(&self, product: &Product) -> Result<(), NutritionError> {
            self.created.lock().unwrap().push(product.clone());
            Ok(())
        }

        async fn upsert_external_many(
            &self,
            _products: &[Product],
        ) -> Result<ProductUpsertResult, NutritionError> {
            Ok(ProductUpsertResult::default())
        }

        async fn update(&self, _product: &Product) -> Result<(), NutritionError> {
            Ok(())
        }

        async fn delete(&self, _id: ProductId) -> Result<(), NutritionError> {
            Ok(())
        }
    }

    struct MockNutrientRepository;

    #[async_trait]
    impl NutrientRepository for MockNutrientRepository {
        async fn list_all(&self) -> Result<Vec<Nutrient>, NutritionError> {
            Ok(vec![Nutrient {
                code: NutrientCode("PROTEIN_G".into()),
                name: "Protein".into(),
                unit: UnitCode("g".into()),
                category: "macro".into(),
            }])
        }

        async fn find_by_code(&self, _code: &str) -> Result<Option<Nutrient>, NutritionError> {
            Ok(None)
        }
    }

    struct MockUnitRepository;

    #[async_trait]
    impl UnitRepository for MockUnitRepository {
        async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
            Ok(vec![])
        }

        async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, NutritionError> {
            Ok(vec![])
        }
    }

    struct MockExternalCatalog {
        product: Option<ExternalProductInput>,
        calls: AtomicUsize,
    }

    #[async_trait]
    impl ExternalProductCatalog for MockExternalCatalog {
        async fn find_by_barcode(
            &self,
            _barcode: &str,
        ) -> Result<Option<ExternalProductInput>, NutritionError> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            Ok(self.product.clone())
        }
    }

    fn local_product(barcode: &str) -> Product {
        Product::new_external(
            Source::Off,
            barcode.into(),
            Some(barcode.into()),
            "Stored food".into(),
            None,
            vec![],
            None,
            None,
            vec![],
            vec![],
            &NutrientCatalog::default(),
        )
        .unwrap()
    }

    fn external_input(barcode: &str) -> ExternalProductInput {
        ExternalProductInput {
            source_id: barcode.into(),
            barcode: barcode.into(),
            name: "Fetched food".into(),
            brand: Some("Brand".into()),
            categories: vec!["snacks".into()],
            default_quantity: None,
            default_unit: None,
            nutrients: vec![ProductNutrientInput {
                code: "PROTEIN_G".into(),
                amount_per_100g: Decimal::from(7),
                source: Some("open_food_facts".into()),
                confidence: Some("unknown".into()),
            }],
            servings: vec![],
        }
    }

    fn service(
        product_repo: Arc<MockProductRepository>,
        external: Arc<MockExternalCatalog>,
    ) -> CatalogService {
        CatalogService::new(
            product_repo,
            Arc::new(MockNutrientRepository),
            Arc::new(MockUnitRepository),
            Arc::new(UnitConverter::from_entries([])),
            external,
        )
    }

    #[tokio::test]
    async fn barcode_lookup_returns_local_product_without_calling_off() {
        let repo = Arc::new(MockProductRepository {
            found: Some(local_product("3017620422003")),
            created: Mutex::new(vec![]),
        });
        let external = Arc::new(MockExternalCatalog {
            product: Some(external_input("3017620422003")),
            calls: AtomicUsize::new(0),
        });

        let product = service(repo.clone(), external.clone())
            .find_by_barcode(Uuid::new_v4(), "3017620422003")
            .await
            .unwrap()
            .unwrap();

        assert_eq!(product.product.name.as_str(), "Stored food");
        assert_eq!(product.origin, BarcodeLookupOrigin::Local);
        assert_eq!(external.calls.load(Ordering::Relaxed), 0);
        assert!(repo.created.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn barcode_lookup_fetches_creates_and_returns_off_product_on_miss() {
        let repo = Arc::new(MockProductRepository {
            found: None,
            created: Mutex::new(vec![]),
        });
        let external = Arc::new(MockExternalCatalog {
            product: Some(external_input("3017620422003")),
            calls: AtomicUsize::new(0),
        });

        let product = service(repo.clone(), external.clone())
            .find_by_barcode(Uuid::new_v4(), "3017620422003")
            .await
            .unwrap()
            .unwrap();

        assert_eq!(product.product.source, Source::Off);
        assert_eq!(product.product.name.as_str(), "Fetched food");
        assert_eq!(product.origin, BarcodeLookupOrigin::OpenFoodFacts);
        assert_eq!(external.calls.load(Ordering::Relaxed), 1);
        assert_eq!(repo.created.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn barcode_lookup_returns_none_when_off_has_no_product() {
        let repo = Arc::new(MockProductRepository {
            found: None,
            created: Mutex::new(vec![]),
        });
        let external = Arc::new(MockExternalCatalog {
            product: None,
            calls: AtomicUsize::new(0),
        });

        let product = service(repo.clone(), external.clone())
            .find_by_barcode(Uuid::new_v4(), "9999999999999")
            .await
            .unwrap();

        assert!(product.is_none());
        assert_eq!(external.calls.load(Ordering::Relaxed), 1);
        assert!(repo.created.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn invalid_uncached_barcode_does_not_call_off() {
        let repo = Arc::new(MockProductRepository {
            found: None,
            created: Mutex::new(vec![]),
        });
        let external = Arc::new(MockExternalCatalog {
            product: None,
            calls: AtomicUsize::new(0),
        });

        let result = service(repo, external.clone())
            .find_by_barcode(Uuid::new_v4(), "not-a-barcode")
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
        assert_eq!(external.calls.load(Ordering::Relaxed), 0);
    }
}

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
#[cfg(test)]
use rust_decimal::Decimal;
use uuid::Uuid;

#[cfg(test)]
use crate::catalog::domain::search_ranking::{
    CategoryCount, HistorySearchCandidate, ProductSearchFields,
};
use crate::catalog::domain::search_ranking::{
    PRODUCT_SEARCH_LIMIT, rank_catalog_candidates, rank_category_suggestions,
    rank_history_candidates,
};
use crate::catalog::domain::units::UnitConverter;
use crate::catalog::domain::*;

#[async_trait]
pub trait ExternalProductCatalog: Send + Sync {
    async fn find_by_barcode(
        &self,
        barcode: &str,
    ) -> Result<Option<ExternalProductBuilder>, CatalogError>;
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
    ) -> Result<Vec<(ProductId, Product)>, CatalogError>;
}

/// Application-level write access for replacing external catalog aggregates.
///
/// This boundary owns the invariants that must hold before persistence receives
/// a batch, allowing callers outside the catalog context to avoid depending on a
/// repository directly.
#[async_trait]
pub trait ExternalProductWritePort: Send + Sync {
    async fn upsert_external_many(
        &self,
        products: Vec<Product>,
    ) -> Result<ProductUpsertResult, CatalogError>;
}

/// Application-level access to the nutrient definitions used to construct
/// validated product aggregates outside the catalog context.
#[async_trait]
pub trait NutrientCatalogReadPort: Send + Sync {
    async fn nutrient_catalog(&self) -> Result<NutrientCatalog, CatalogError>;
}

#[derive(Clone)]
pub struct CatalogService {
    product_repo: Arc<dyn ProductRepo>,
    nutrient_repo: Arc<dyn NutrientRepo>,
    unit_repo: Arc<dyn UnitRepo>,
    unit_converter: Arc<UnitConverter>,
    external_catalog: Arc<dyn ExternalProductCatalog>,
    policy: CatalogPolicy,
}

impl CatalogService {
    pub fn new(
        product_repo: Arc<dyn ProductRepo>,
        nutrient_repo: Arc<dyn NutrientRepo>,
        unit_repo: Arc<dyn UnitRepo>,
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
    ) -> Result<Vec<Product>, CatalogError> {
        let ids = match scope.catalog_scope() {
            Some(catalog_scope) => {
                let candidates = self
                    .product_repo
                    .search_catalog_candidates(&spec, catalog_scope)
                    .await?;
                rank_catalog_candidates(&spec.text, candidates, PRODUCT_SEARCH_LIMIT)
            }
            None => {
                let candidates = self
                    .product_repo
                    .search_history_candidates(&spec, actor_id)
                    .await?;
                rank_history_candidates(&spec.text, candidates, PRODUCT_SEARCH_LIMIT)
            }
        };
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let products = self.product_repo.find_search_summaries(&ids).await?;
        if products.len() != ids.len() {
            tracing::warn!(
                requested = ids.len(),
                found = products.len(),
                "search summary hydration returned a partial result"
            );
        }
        Ok(order_products_by_ids(products, &ids))
    }

    pub async fn list_categories(
        &self,
        _actor_id: Uuid,
        query: &str,
        limit: i64,
    ) -> Result<Vec<CategorySuggestion>, CatalogError> {
        let counts = self.product_repo.category_counts().await?;
        Ok(rank_category_suggestions(
            query,
            counts,
            category_limit(limit),
        ))
    }

    pub async fn list_custom_foods(&self, actor_id: Uuid) -> Result<Vec<Product>, CatalogError> {
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
    ) -> Result<Option<BarcodeLookupResult>, CatalogError> {
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
        let product = Product::new_external(ExternalSource::Off, input, &nutrient_catalog)
            .map_err(|_| CatalogError::ExternalInvalidResponse)?;

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
    ) -> Result<Product, CatalogError> {
        let product = self
            .product_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| CatalogError::NotFound(format!("product {} not found", id.0)))?;
        self.policy.authorize_view(actor_id, &product)?;
        Ok(product)
    }

    pub async fn create_custom_food(
        &self,
        actor_id: Uuid,
        input: CustomProductBuilder,
    ) -> Result<Product, CatalogError> {
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        let product = Product::new_custom(actor_id, input, &nutrient_catalog)?;
        self.product_repo.create(&product).await?;
        Ok(product)
    }

    pub async fn validate_custom_food_draft(
        &self,
        input: CustomProductBuilder,
    ) -> Result<(), CatalogError> {
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        Product::validate_custom_draft(input, &nutrient_catalog)
    }

    pub async fn update_custom_food(
        &self,
        actor_id: Uuid,
        id: ProductId,
        input: CustomProductBuilder,
    ) -> Result<Product, CatalogError> {
        let existing = self.get_product(actor_id, id).await?;
        self.policy.authorize_mutation(actor_id, &existing)?;
        let nutrient_catalog = self.load_nutrient_catalog().await?;
        let updated = existing.update_custom(input, &nutrient_catalog)?;
        self.product_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_custom_food(
        &self,
        actor_id: Uuid,
        id: ProductId,
    ) -> Result<(), CatalogError> {
        let product = self.get_product(actor_id, id).await?;
        self.policy.authorize_mutation(actor_id, &product)?;
        self.product_repo.delete(id).await
    }

    pub async fn list_nutrients(&self) -> Result<Vec<Nutrient>, CatalogError> {
        self.nutrient_repo.list_all().await
    }

    pub async fn get_nutrient(&self, code: &str) -> Result<Option<Nutrient>, CatalogError> {
        self.nutrient_repo.find_by_code(code).await
    }

    pub async fn list_units(&self) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
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
    ) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
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

    async fn load_nutrient_catalog(&self) -> Result<NutrientCatalog, CatalogError> {
        Ok(self.nutrient_repo.list_all().await?.into_iter().collect())
    }
}

fn order_products_by_ids(products: Vec<Product>, ids: &[ProductId]) -> Vec<Product> {
    let mut products_by_id: HashMap<ProductId, Product> = products
        .into_iter()
        .map(|product| (product.id, product))
        .collect();
    ids.iter()
        .filter_map(|id| products_by_id.remove(id))
        .collect()
}

/// Category suggestions are capped at 50. The HTTP handler separately clamps
/// to `1..=50`; the service allows `0` so non-HTTP callers can request none.
fn category_limit(limit: i64) -> usize {
    usize::try_from(limit.clamp(0, 50)).unwrap_or_default()
}

#[async_trait]
impl ExternalProductWritePort for CatalogService {
    async fn upsert_external_many(
        &self,
        products: Vec<Product>,
    ) -> Result<ProductUpsertResult, CatalogError> {
        let batch = ExternalProductBatch::new(products)?;
        self.product_repo.upsert_external_many(&batch).await
    }
}

#[async_trait]
impl NutrientCatalogReadPort for CatalogService {
    async fn nutrient_catalog(&self) -> Result<NutrientCatalog, CatalogError> {
        self.load_nutrient_catalog().await
    }
}

fn validate_external_barcode(barcode: &str) -> Result<(), CatalogError> {
    if !(4..=24).contains(&barcode.len()) || !barcode.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(CatalogError::Validation(
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
    ) -> Result<Vec<(ProductId, Product)>, CatalogError> {
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

    struct MockProductRepo {
        found: Option<Product>,
        created: Mutex<Vec<Product>>,
        upserted: Mutex<Vec<Product>>,
    }

    #[async_trait]
    impl ProductRepo for MockProductRepo {
        async fn search_catalog_candidates(
            &self,
            _spec: &ProductSearchSpec,
            _scope: CatalogSearchScope,
        ) -> Result<Vec<ProductSearchFields>, CatalogError> {
            Ok(Vec::new())
        }

        async fn search_history_candidates(
            &self,
            _spec: &ProductSearchSpec,
            _user_id: Uuid,
        ) -> Result<Vec<HistorySearchCandidate>, CatalogError> {
            Ok(Vec::new())
        }

        async fn category_counts(&self) -> Result<Vec<CategoryCount>, CatalogError> {
            Ok(vec![])
        }

        async fn find_search_summaries(
            &self,
            _ids: &[ProductId],
        ) -> Result<Vec<Product>, CatalogError> {
            Ok(vec![])
        }

        async fn find_by_id(&self, _id: ProductId) -> Result<Option<Product>, CatalogError> {
            Ok(None)
        }

        async fn existing_ids(
            &self,
            _ids: &[ProductId],
        ) -> Result<HashSet<ProductId>, CatalogError> {
            Ok(HashSet::new())
        }

        async fn find_by_barcode(
            &self,
            _barcode: &str,
            _user_id: Option<Uuid>,
        ) -> Result<Option<Product>, CatalogError> {
            Ok(self.found.clone())
        }

        async fn list_custom_foods(&self) -> Result<Vec<Product>, CatalogError> {
            Ok(vec![])
        }

        async fn create(&self, product: &Product) -> Result<(), CatalogError> {
            self.created.lock().unwrap().push(product.clone());
            Ok(())
        }

        async fn upsert_external_many(
            &self,
            batch: &ExternalProductBatch,
        ) -> Result<ProductUpsertResult, CatalogError> {
            self.upserted
                .lock()
                .unwrap()
                .extend(batch.products().iter().cloned());
            Ok(ProductUpsertResult {
                created: batch.products().len() as i64,
                ..ProductUpsertResult::default()
            })
        }

        async fn update(&self, _product: &Product) -> Result<(), CatalogError> {
            Ok(())
        }

        async fn delete(&self, _id: ProductId) -> Result<(), CatalogError> {
            Ok(())
        }
    }

    struct MockNutrientRepo;

    #[async_trait]
    impl NutrientRepo for MockNutrientRepo {
        async fn list_all(&self) -> Result<Vec<Nutrient>, CatalogError> {
            Ok(vec![Nutrient {
                code: NutrientCode("PROTEIN_G".into()),
                name: "Protein".into(),
                unit: UnitCode("g".into()),
                category: "macro".into(),
            }])
        }

        async fn find_by_code(&self, _code: &str) -> Result<Option<Nutrient>, CatalogError> {
            Ok(None)
        }
    }

    struct MockUnitRepo;

    #[async_trait]
    impl UnitRepo for MockUnitRepo {
        async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
            Ok(vec![])
        }

        async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, CatalogError> {
            Ok(vec![])
        }
    }

    struct MockExternalCatalog {
        product: Option<ExternalProductBuilder>,
        calls: AtomicUsize,
    }

    #[async_trait]
    impl ExternalProductCatalog for MockExternalCatalog {
        async fn find_by_barcode(
            &self,
            _barcode: &str,
        ) -> Result<Option<ExternalProductBuilder>, CatalogError> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            Ok(self.product.clone())
        }
    }

    fn local_product(barcode: &str) -> Product {
        Product::new_external(
            ExternalSource::Off,
            ExternalProductBuilder::new(barcode, "Stored food").barcode(Some(barcode.into())),
            &NutrientCatalog::default(),
        )
        .unwrap()
    }

    fn external_input(barcode: &str) -> ExternalProductBuilder {
        ExternalProductBuilder::new(barcode, "Fetched food")
            .barcode(Some(barcode.into()))
            .brand(Some("Brand".into()))
            .categories(vec!["snacks".into()])
            .nutrients(vec![ProductNutrientInput {
                code: "PROTEIN_G".into(),
                amount_per_100g: Decimal::from(7),
                source: Some("open_food_facts".into()),
                confidence: Some("unknown".into()),
            }])
    }

    fn service(
        product_repo: Arc<MockProductRepo>,
        external: Arc<MockExternalCatalog>,
    ) -> CatalogService {
        CatalogService::new(
            product_repo,
            Arc::new(MockNutrientRepo),
            Arc::new(MockUnitRepo),
            Arc::new(UnitConverter::from_entries([])),
            external,
        )
    }

    #[tokio::test]
    async fn barcode_lookup_returns_local_product_without_calling_off() {
        let repo = Arc::new(MockProductRepo {
            found: Some(local_product("3017620422003")),
            created: Mutex::new(vec![]),
            upserted: Mutex::new(vec![]),
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
        let repo = Arc::new(MockProductRepo {
            found: None,
            created: Mutex::new(vec![]),
            upserted: Mutex::new(vec![]),
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

        assert!(matches!(
            product.product.origin,
            ProductOrigin::External {
                source: ExternalSource::Off,
                ..
            }
        ));
        assert_eq!(product.product.name.as_str(), "Fetched food");
        assert_eq!(product.origin, BarcodeLookupOrigin::OpenFoodFacts);
        assert_eq!(external.calls.load(Ordering::Relaxed), 1);
        assert_eq!(repo.created.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn barcode_lookup_returns_none_when_off_has_no_product() {
        let repo = Arc::new(MockProductRepo {
            found: None,
            created: Mutex::new(vec![]),
            upserted: Mutex::new(vec![]),
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
        let repo = Arc::new(MockProductRepo {
            found: None,
            created: Mutex::new(vec![]),
            upserted: Mutex::new(vec![]),
        });
        let external = Arc::new(MockExternalCatalog {
            product: None,
            calls: AtomicUsize::new(0),
        });

        let result = service(repo, external.clone())
            .find_by_barcode(Uuid::new_v4(), "not-a-barcode")
            .await;

        assert!(matches!(result, Err(CatalogError::Validation(_))));
        assert_eq!(external.calls.load(Ordering::Relaxed), 0);
    }
}

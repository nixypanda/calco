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
    pub serving_size_g: Option<Decimal>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrients: Vec<ProductNutrientInput>,
    pub servings: Vec<ProductServingInput>,
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
    policy: CatalogPolicy,
}

impl CatalogService {
    pub fn new(
        product_repo: Arc<dyn ProductRepository>,
        nutrient_repo: Arc<dyn NutrientRepository>,
        unit_repo: Arc<dyn UnitRepository>,
        unit_converter: Arc<UnitConverter>,
    ) -> Self {
        Self {
            product_repo,
            nutrient_repo,
            unit_repo,
            unit_converter,
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
    ) -> Result<Option<Product>, NutritionError> {
        self.product_repo
            .find_by_barcode(barcode, Some(actor_id))
            .await
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
            input.serving_size_g,
            input.default_quantity,
            input.default_unit,
            input.nutrients,
            input.servings,
            &nutrient_catalog,
            &self.unit_converter,
        )?;
        self.product_repo.create(&product).await?;
        Ok(product)
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
            input.serving_size_g,
            input.default_quantity,
            input.default_unit,
            input.nutrients,
            input.servings,
            &nutrient_catalog,
            &self.unit_converter,
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

    /// Returns the catalog policy codes a custom food must contain.
    ///
    /// This is reference data for application consumers. Catalog domain
    /// validation remains the authority that enforces the requirement.
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

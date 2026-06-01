use async_trait::async_trait;
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::units::UnitConverter;

// ─── Repository Ports ──────────────────────────────────────────

#[async_trait]
pub trait ProductRepository: Send + Sync {
    async fn search(
        &self,
        query: ProductSearchQuery,
        user_id: Option<Uuid>,
    ) -> Result<Vec<Product>, CatalogError>;
    async fn list_categories(
        &self,
        query: &str,
        user_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<CategorySuggestion>, CatalogError>;
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, CatalogError>;
    async fn find_by_barcode(&self, barcode: &str) -> Result<Option<Product>, CatalogError>;
    async fn create(&self, product: &Product) -> Result<(), CatalogError>;
    async fn update(&self, product: &Product) -> Result<(), CatalogError>;
    async fn soft_delete(&self, id: ProductId) -> Result<(), CatalogError>;
}

#[async_trait]
pub trait NutrientRepository: Send + Sync {
    async fn list_all(&self) -> Result<Vec<Nutrient>, CatalogError>;
    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, CatalogError>;
}

#[async_trait]
pub trait UnitRepository: Send + Sync {
    async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, CatalogError>;
    async fn mass_factors(&self) -> Result<Vec<(String, Decimal)>, CatalogError>;
}

// ─── Use Cases ─────────────────────────────────────────────────

pub struct SearchCriteria {
    pub query: String,
    pub user_id: Option<Uuid>,
}

#[derive(Debug, Clone, Default)]
pub struct ProductSearchQuery {
    pub text: String,
    pub include_categories: Vec<String>,
    pub exclude_categories: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CategorySuggestion {
    pub value: String,
    pub count: i64,
}

pub struct CatalogServices {
    pub product_repo: Arc<dyn ProductRepository>,
    pub nutrient_repo: Arc<dyn NutrientRepository>,
    pub unit_repo: Arc<dyn UnitRepository>,
    pub unit_converter: Arc<UnitConverter>,
}

impl Clone for CatalogServices {
    fn clone(&self) -> Self {
        Self {
            product_repo: self.product_repo.clone(),
            nutrient_repo: self.nutrient_repo.clone(),
            unit_repo: self.unit_repo.clone(),
            unit_converter: self.unit_converter.clone(),
        }
    }
}

impl CatalogServices {
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
        }
    }

    pub async fn allowed_units_for_product(
        &self,
        product: &Product,
    ) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
        let all_units = self.unit_repo.list_all().await?;

        let mut allowed: std::collections::HashSet<String> = std::collections::HashSet::new();
        for code in self.unit_converter.mass_unit_codes() {
            allowed.insert(code.to_string());
        }
        for serving in &product.servings {
            allowed.insert(serving.unit.0.clone());
        }
        if product.serving_size_g.is_some() {
            if let Some(default_unit) = product.default_unit.as_ref() {
                allowed.insert(default_unit.0.clone());
            }
        }

        Ok(all_units
            .into_iter()
            .filter(|(code, _, _)| allowed.contains(&code.0))
            .collect())
    }

    async fn validate_product_inputs(
        &self,
        nutrients: &[ProductNutrientInput],
        servings: &[ProductServingInput],
    ) -> Result<Vec<(ProductNutrientInput, UnitCode)>, CatalogError> {
        for serving in servings {
            if serving.quantity <= Decimal::ZERO || serving.grams <= Decimal::ZERO {
                return Err(CatalogError::Validation(
                    "serving quantity and grams must be positive".into(),
                ));
            }
        }

        let mut validated = Vec::with_capacity(nutrients.len());
        for nutrient in nutrients {
            if nutrient.amount_per_100g < Decimal::ZERO {
                return Err(CatalogError::Validation(
                    "nutrient amount must be non-negative".into(),
                ));
            }
            let reference = self
                .nutrient_repo
                .find_by_code(&nutrient.code)
                .await?
                .ok_or_else(|| {
                    CatalogError::Validation(format!("unknown nutrient code: {}", nutrient.code))
                })?;
            validated.push((nutrient.clone(), reference.unit().clone()));
        }
        Ok(validated)
    }

    pub async fn search_products(
        &self,
        criteria: SearchCriteria,
    ) -> Result<Vec<Product>, CatalogError> {
        self.product_repo
            .search(parse_search_query(&criteria.query), criteria.user_id)
            .await
    }

    pub async fn list_categories(
        &self,
        query: &str,
        user_id: Option<Uuid>,
        limit: Option<i64>,
    ) -> Result<Vec<CategorySuggestion>, CatalogError> {
        let limit = limit.unwrap_or(10).clamp(1, 50);
        self.product_repo
            .list_categories(query.trim(), user_id, limit)
            .await
    }

    pub async fn get_product(&self, id: ProductId) -> Result<Product, CatalogError> {
        self.product_repo
            .find_by_id(id)
            .await?
            .ok_or(CatalogError::NotFound("product not found".into()))
    }

    pub async fn get_product_by_barcode(&self, barcode: &str) -> Result<Product, CatalogError> {
        self.product_repo
            .find_by_barcode(barcode)
            .await?
            .ok_or(CatalogError::NotFound("product not found".into()))
    }

    pub async fn create_custom_food(
        &self,
        user_id: Uuid,
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        serving_size_g: Option<Decimal>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<ProductNutrientInput>,
        servings: Vec<ProductServingInput>,
    ) -> Result<Product, CatalogError> {
        if name.trim().is_empty() {
            return Err(CatalogError::Validation("food name is required".into()));
        }
        let validated_nutrients = self.validate_product_inputs(&nutrients, &servings).await?;

        let product = Product {
            id: ProductId::new(),
            source: Source::User,
            source_id: None,
            user_id: Some(user_id),
            visibility: ProductVisibility::UserPrivate,
            barcode: None,
            name: ProductName(name.trim().to_string()),
            brand: brand.map(Brand),
            categories: normalize_categories(categories)
                .into_iter()
                .map(Category)
                .collect(),
            default_quantity,
            default_unit: default_unit.map(UnitCode),
            serving_size_g,
            nutrients: validated_nutrients
                .into_iter()
                .map(|(n, unit)| ProductNutrient {
                    nutrient_code: NutrientCode(n.code),
                    amount_per_100g: AmountPer100g(n.amount_per_100g),
                    unit,
                    source: n.source,
                    confidence: n
                        .confidence
                        .and_then(|c| NutrientConfidence::from_str(&c).ok()),
                })
                .collect(),
            servings: servings
                .into_iter()
                .map(|s| ProductServing {
                    label: ServingLabel(s.label),
                    quantity: s.quantity,
                    unit: UnitCode(s.unit),
                    grams: s.grams,
                })
                .collect(),
        };
        self.product_repo.create(&product).await?;
        Ok(product)
    }

    pub async fn update_custom_food(
        &self,
        id: ProductId,
        user_id: Uuid,
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        serving_size_g: Option<Decimal>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<ProductNutrientInput>,
        servings: Vec<ProductServingInput>,
    ) -> Result<Product, CatalogError> {
        if name.trim().is_empty() {
            return Err(CatalogError::Validation("food name is required".into()));
        }
        let existing = self
            .product_repo
            .find_by_id(id)
            .await?
            .ok_or(CatalogError::NotFound("product not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(CatalogError::Forbidden("not your custom food".into()));
        }

        let validated_nutrients = self.validate_product_inputs(&nutrients, &servings).await?;

        let updated = Product {
            nutrients: validated_nutrients
                .into_iter()
                .map(|(n, unit)| ProductNutrient {
                    nutrient_code: NutrientCode(n.code),
                    amount_per_100g: AmountPer100g(n.amount_per_100g),
                    unit,
                    source: n.source,
                    confidence: n
                        .confidence
                        .and_then(|c| NutrientConfidence::from_str(&c).ok()),
                })
                .collect(),
            servings: servings
                .into_iter()
                .map(|s| ProductServing {
                    label: ServingLabel(s.label),
                    quantity: s.quantity,
                    unit: UnitCode(s.unit),
                    grams: s.grams,
                })
                .collect(),
            name: ProductName(name.trim().to_string()),
            brand: brand.map(Brand),
            categories: normalize_categories(categories)
                .into_iter()
                .map(Category)
                .collect(),
            serving_size_g,
            default_quantity,
            default_unit: default_unit.map(UnitCode),
            ..existing
        };
        self.product_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_custom_food(
        &self,
        id: ProductId,
        user_id: Uuid,
    ) -> Result<(), CatalogError> {
        let existing = self
            .product_repo
            .find_by_id(id)
            .await?
            .ok_or(CatalogError::NotFound("product not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(CatalogError::Forbidden("not your custom food".into()));
        }

        self.product_repo.soft_delete(id).await
    }

    pub async fn list_nutrients(&self) -> Result<Vec<Nutrient>, CatalogError> {
        self.nutrient_repo.list_all().await
    }

    pub async fn get_nutrient(&self, code: &str) -> Result<Nutrient, CatalogError> {
        self.nutrient_repo
            .find_by_code(code)
            .await?
            .ok_or(CatalogError::NotFound("nutrient not found".into()))
    }

    pub async fn list_units(&self) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
        self.unit_repo.list_all().await
    }
}

pub fn normalize_categories(categories: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    for category in categories {
        let normalized = category.trim().to_lowercase();
        if !normalized.is_empty() && !out.contains(&normalized) {
            out.push(normalized);
        }
    }
    out
}

fn parse_search_query(input: &str) -> ProductSearchQuery {
    let mut query = ProductSearchQuery::default();
    let mut text_terms = Vec::new();

    for token in tokenize_search(input) {
        if let Some(value) = token.strip_prefix("category:") {
            query
                .include_categories
                .extend(normalize_categories(vec![value.to_string()]));
        } else if let Some(value) = token.strip_prefix("-category:") {
            query
                .exclude_categories
                .extend(normalize_categories(vec![value.to_string()]));
        } else {
            text_terms.push(token);
        }
    }

    query.text = text_terms.join(" ");
    query
}

fn tokenize_search(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for ch in input.chars() {
        match ch {
            '"' => in_quotes = !in_quotes,
            c if c.is_whitespace() && !in_quotes => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c),
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

// ─── Input Types ───────────────────────────────────────────────

pub struct ProductNutrientInput {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

impl Clone for ProductNutrientInput {
    fn clone(&self) -> Self {
        Self {
            code: self.code.clone(),
            amount_per_100g: self.amount_per_100g,
            source: self.source.clone(),
            confidence: self.confidence.clone(),
        }
    }
}

pub struct ProductServingInput {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

// ─── Errors ────────────────────────────────────────────────────

#[derive(Debug)]
pub enum CatalogError {
    NotFound(String),
    Forbidden(String),
    Validation(String),
    Database(String),
    Internal(String),
}

impl std::fmt::Display for CatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CatalogError::NotFound(msg) => write!(f, "not found: {msg}"),
            CatalogError::Forbidden(msg) => write!(f, "forbidden: {msg}"),
            CatalogError::Validation(msg) => write!(f, "validation: {msg}"),
            CatalogError::Database(msg) => write!(f, "database: {msg}"),
            CatalogError::Internal(msg) => write!(f, "internal: {msg}"),
        }
    }
}

impl std::error::Error for CatalogError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_categories_trims_lowercases_and_deduplicates() {
        assert_eq!(
            normalize_categories(vec![
                " Snacks ".into(),
                "snacks".into(),
                "".into(),
                "Beverages".into(),
            ]),
            vec!["snacks", "beverages"]
        );
    }

    #[test]
    fn parse_search_query_extracts_category_filters() {
        let parsed = parse_search_query(r#"chicken category:meat -category:"processed food""#);

        assert_eq!(parsed.text, "chicken");
        assert_eq!(parsed.include_categories, vec!["meat"]);
        assert_eq!(parsed.exclude_categories, vec!["processed food"]);
    }
}

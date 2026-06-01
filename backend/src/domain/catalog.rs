use async_trait::async_trait;
use rust_decimal::Decimal;
use uuid::Uuid;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProductId(pub Uuid);

impl ProductId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl From<Uuid> for ProductId {
    fn from(id: Uuid) -> Self {
        Self(id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    User,
    Off,
    Usda,
    Ifct,
}

impl Source {
    pub fn as_str(&self) -> &'static str {
        match self {
            Source::User => "USER",
            Source::Off => "OFF",
            Source::Usda => "USDA",
            Source::Ifct => "IFCT",
        }
    }

    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "USER" => Ok(Source::User),
            "OFF" => Ok(Source::Off),
            "USDA" => Ok(Source::Usda),
            "IFCT" => Ok(Source::Ifct),
            _ => Err(format!("invalid source: {s}")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProductVisibility {
    Global,
    UserPrivate,
}

impl ProductVisibility {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProductVisibility::Global => "global",
            ProductVisibility::UserPrivate => "user_private",
        }
    }

    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "global" => Ok(ProductVisibility::Global),
            "user_private" => Ok(ProductVisibility::UserPrivate),
            _ => Err(format!("invalid visibility: {s}")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NutrientConfidence {
    Approved,
    Derived,
    Unknown,
}

impl NutrientConfidence {
    pub fn as_str(&self) -> &'static str {
        match self {
            NutrientConfidence::Approved => "approved",
            NutrientConfidence::Derived => "derived",
            NutrientConfidence::Unknown => "unknown",
        }
    }

    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "approved" => Ok(NutrientConfidence::Approved),
            "derived" => Ok(NutrientConfidence::Derived),
            "unknown" => Ok(NutrientConfidence::Unknown),
            _ => Err(format!("invalid confidence: {s}")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nutrient(pub NutrientCode, pub String, pub UnitCode, pub String);

impl Nutrient {
    pub fn code(&self) -> &NutrientCode {
        &self.0
    }

    pub fn name(&self) -> &str {
        &self.1
    }

    pub fn unit(&self) -> &UnitCode {
        &self.2
    }

    pub fn category(&self) -> &str {
        &self.3
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NutrientCode(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitCode(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Barcode(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductName(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Brand(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Category(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServingLabel(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AmountPer100g(pub Decimal);

#[derive(Debug, Clone)]
pub struct Product {
    pub id: ProductId,
    pub source: Source,
    pub source_id: Option<String>,
    pub user_id: Option<Uuid>,
    pub visibility: ProductVisibility,
    pub barcode: Option<Barcode>,
    pub name: ProductName,
    pub brand: Option<Brand>,
    pub categories: Vec<Category>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<UnitCode>,
    pub serving_size_g: Option<Decimal>,
    pub nutrients: Vec<ProductNutrient>,
    pub servings: Vec<ProductServing>,
}

impl Product {
    pub fn new_custom(
        user_id: Uuid,
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        serving_size_g: Option<Decimal>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<ProductNutrientUpdate>,
        servings: Vec<ProductServingUpdate>,
    ) -> Result<Self, CatalogError> {
        Self::validate_name(&name)?;

        Ok(Self {
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
            nutrients: build_product_nutrients(nutrients)?,
            servings: build_product_servings(servings)?,
        })
    }

    pub fn update_custom(
        &self,
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        serving_size_g: Option<Decimal>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<ProductNutrientUpdate>,
        servings: Vec<ProductServingUpdate>,
    ) -> Result<Self, CatalogError> {
        Self::validate_name(&name)?;

        Ok(Self {
            name: ProductName(name.trim().to_string()),
            brand: brand.map(Brand),
            categories: normalize_categories(categories)
                .into_iter()
                .map(Category)
                .collect(),
            serving_size_g,
            default_quantity,
            default_unit: default_unit.map(UnitCode),
            nutrients: build_product_nutrients(nutrients)?,
            servings: build_product_servings(servings)?,
            ..self.clone()
        })
    }

    pub fn validate_name(name: &str) -> Result<(), CatalogError> {
        if name.trim().is_empty() {
            return Err(CatalogError::Validation("food name is required".into()));
        }
        Ok(())
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == Some(user_id)
    }
}

#[derive(Debug, Clone)]
pub struct ProductNutrient {
    pub nutrient_code: NutrientCode,
    pub amount_per_100g: AmountPer100g,
    pub unit: UnitCode,
    pub source: Option<String>,
    pub confidence: Option<NutrientConfidence>,
}

#[derive(Debug, Clone)]
pub struct ProductNutrientUpdate {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub unit: UnitCode,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ProductServing {
    pub label: ServingLabel,
    pub quantity: Decimal,
    pub unit: UnitCode,
    pub grams: Decimal,
}

#[derive(Debug, Clone)]
pub struct ProductServingUpdate {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

impl ProductServing {
    pub fn validate_values(quantity: Decimal, grams: Decimal) -> Result<(), CatalogError> {
        if quantity <= Decimal::ZERO || grams <= Decimal::ZERO {
            return Err(CatalogError::Validation(
                "serving quantity and grams must be positive".into(),
            ));
        }
        Ok(())
    }
}

impl AmountPer100g {
    pub fn validate(amount: Decimal) -> Result<(), CatalogError> {
        if amount < Decimal::ZERO {
            return Err(CatalogError::Validation(
                "nutrient amount must be non-negative".into(),
            ));
        }
        Ok(())
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

fn build_product_nutrients(
    nutrients: Vec<ProductNutrientUpdate>,
) -> Result<Vec<ProductNutrient>, CatalogError> {
    nutrients
        .into_iter()
        .map(|nutrient| {
            AmountPer100g::validate(nutrient.amount_per_100g)?;
            Ok(ProductNutrient {
                nutrient_code: NutrientCode(nutrient.code),
                amount_per_100g: AmountPer100g(nutrient.amount_per_100g),
                unit: nutrient.unit,
                source: nutrient.source,
                confidence: nutrient
                    .confidence
                    .and_then(|confidence| NutrientConfidence::from_str(&confidence).ok()),
            })
        })
        .collect()
}

fn build_product_servings(
    servings: Vec<ProductServingUpdate>,
) -> Result<Vec<ProductServing>, CatalogError> {
    servings
        .into_iter()
        .map(|serving| {
            ProductServing::validate_values(serving.quantity, serving.grams)?;
            Ok(ProductServing {
                label: ServingLabel(serving.label),
                quantity: serving.quantity,
                unit: UnitCode(serving.unit),
                grams: serving.grams,
            })
        })
        .collect()
}

#[derive(Debug, thiserror::Error)]
pub enum CatalogError {
    #[error("not_found: {0}")]
    NotFound(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("validation: {0}")]
    Validation(String),
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error("internal: {0}")]
    Internal(String),
}

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

#[cfg(test)]
mod tests {
    use super::*;

    fn nutrient_update(amount_per_100g: Decimal) -> ProductNutrientUpdate {
        ProductNutrientUpdate {
            code: "ENERGY_KCAL".into(),
            amount_per_100g,
            unit: UnitCode("kcal".into()),
            source: Some("manual".into()),
            confidence: Some("approved".into()),
        }
    }

    fn serving_update(quantity: Decimal, grams: Decimal) -> ProductServingUpdate {
        ProductServingUpdate {
            label: "serving".into(),
            quantity,
            unit: "serving".into(),
            grams,
        }
    }

    #[test]
    fn custom_product_creation_normalizes_and_builds_children() {
        let product = Product::new_custom(
            Uuid::new_v4(),
            "  Rice Bowl  ".into(),
            Some("Kitchen".into()),
            vec![" Meals ".into(), "meals".into(), "Dinner".into()],
            Some(Decimal::new(250, 0)),
            Some(Decimal::new(1, 0)),
            Some("serving".into()),
            vec![nutrient_update(Decimal::new(120, 0))],
            vec![serving_update(Decimal::new(1, 0), Decimal::new(250, 0))],
        )
        .unwrap();

        assert_eq!(product.source, Source::User);
        assert_eq!(product.visibility, ProductVisibility::UserPrivate);
        assert_eq!(product.name.0, "Rice Bowl");
        assert_eq!(
            product
                .categories
                .iter()
                .map(|c| c.0.as_str())
                .collect::<Vec<_>>(),
            vec!["meals", "dinner"]
        );
        assert_eq!(
            product.nutrients[0].confidence,
            Some(NutrientConfidence::Approved)
        );
        assert_eq!(product.servings[0].grams, Decimal::new(250, 0));
    }

    #[test]
    fn custom_product_creation_rejects_invalid_values() {
        let user_id = Uuid::new_v4();

        assert!(
            Product::new_custom(
                user_id,
                " ".into(),
                None,
                vec![],
                None,
                None,
                None,
                vec![nutrient_update(Decimal::ZERO)],
                vec![serving_update(Decimal::new(1, 0), Decimal::new(100, 0))],
            )
            .is_err()
        );

        assert!(
            Product::new_custom(
                user_id,
                "Food".into(),
                None,
                vec![],
                None,
                None,
                None,
                vec![nutrient_update(Decimal::new(-1, 0))],
                vec![serving_update(Decimal::new(1, 0), Decimal::new(100, 0))],
            )
            .is_err()
        );

        assert!(
            Product::new_custom(
                user_id,
                "Food".into(),
                None,
                vec![],
                None,
                None,
                None,
                vec![nutrient_update(Decimal::ZERO)],
                vec![serving_update(Decimal::ZERO, Decimal::new(100, 0))],
            )
            .is_err()
        );
    }

    #[test]
    fn custom_product_update_preserves_identity_and_source_fields() {
        let user_id = Uuid::new_v4();
        let mut product = Product::new_custom(
            user_id,
            "Original".into(),
            None,
            vec!["old".into()],
            None,
            None,
            None,
            vec![nutrient_update(Decimal::new(10, 0))],
            vec![serving_update(Decimal::new(1, 0), Decimal::new(100, 0))],
        )
        .unwrap();
        product.source_id = Some("external-id".into());
        product.barcode = Some(Barcode("123".into()));

        let updated = product
            .update_custom(
                " Updated ".into(),
                Some("Brand".into()),
                vec!["New".into()],
                Some(Decimal::new(50, 0)),
                Some(Decimal::new(2, 0)),
                Some("piece".into()),
                vec![nutrient_update(Decimal::new(20, 0))],
                vec![serving_update(Decimal::new(2, 0), Decimal::new(50, 0))],
            )
            .unwrap();

        assert_eq!(updated.id, product.id);
        assert_eq!(updated.source, product.source);
        assert_eq!(updated.source_id, product.source_id);
        assert_eq!(updated.user_id, product.user_id);
        assert_eq!(updated.visibility, product.visibility);
        assert_eq!(updated.barcode, product.barcode);
        assert_eq!(updated.name.0, "Updated");
        assert_eq!(updated.brand.unwrap().0, "Brand");
        assert_eq!(updated.default_unit.unwrap().0, "piece");
    }
}

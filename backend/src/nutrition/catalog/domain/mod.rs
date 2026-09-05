pub mod calculation;
pub mod units;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use uuid::Uuid;

use crate::nutrition::catalog::domain::calculation::{
    CalculatedNutrition, NutritionCalculator, Quantity,
};
use crate::nutrition::catalog::domain::units::UnitConverter;

#[derive(Debug, Clone, Default)]
pub struct ProductSearchSpec {
    pub text: String,
    pub include_categories: Vec<Category>,
    pub exclude_categories: Vec<Category>,
}

impl ProductSearchSpec {
    pub fn parse(input: &str) -> Self {
        let mut spec = ProductSearchSpec::default();
        let mut text_terms = Vec::new();

        for token in tokenize_search_input(input) {
            if let Some(value) = token.strip_prefix("category:") {
                if let Some(category) = Category::new(value) {
                    spec.include_categories.push(category);
                }
            } else if let Some(value) = token.strip_prefix("-category:") {
                if let Some(category) = Category::new(value) {
                    spec.exclude_categories.push(category);
                }
            } else {
                text_terms.push(token);
            }
        }

        spec.text = text_terms.join(" ");
        spec
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProductSearchScope {
    All,
    Custom,
    History,
}

impl ProductSearchScope {
    pub fn parse(input: Option<&str>) -> Result<Self, NutritionError> {
        match input.unwrap_or("all") {
            "all" => Ok(Self::All),
            "custom" => Ok(Self::Custom),
            "history" => Ok(Self::History),
            other => Err(NutritionError::Validation(format!(
                "unknown food search scope: {other}"
            ))),
        }
    }
}

fn tokenize_search_input(input: &str) -> Vec<String> {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CategorySuggestion {
    pub value: String,
    pub count: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProductId(pub Uuid);

impl Default for ProductId {
    fn default() -> Self {
        Self::new()
    }
}

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
    Indb,
}

impl Source {
    pub fn as_str(&self) -> &'static str {
        match self {
            Source::User => "USER",
            Source::Off => "OFF",
            Source::Usda => "USDA",
            Source::Ifct => "IFCT",
            Source::Indb => "INDB",
        }
    }
}

impl FromStr for Source {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "USER" => Ok(Source::User),
            "OFF" => Ok(Source::Off),
            "USDA" => Ok(Source::Usda),
            "IFCT" => Ok(Source::Ifct),
            "INDB" => Ok(Source::Indb),
            _ => Err(format!("invalid source: {s}")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProductVisibility {
    Global,
}

impl ProductVisibility {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProductVisibility::Global => "global",
        }
    }
}

impl FromStr for ProductVisibility {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "global" => Ok(ProductVisibility::Global),
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
}

impl FromStr for NutrientConfidence {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "approved" => Ok(NutrientConfidence::Approved),
            "derived" => Ok(NutrientConfidence::Derived),
            "unknown" => Ok(NutrientConfidence::Unknown),
            _ => Err(format!("invalid confidence: {s}")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nutrient {
    pub code: NutrientCode,
    pub name: String,
    pub unit: UnitCode,
    pub category: String,
}

#[derive(Debug, Clone, Default)]
pub struct NutrientCatalog {
    by_code: HashMap<String, Nutrient>,
}

impl NutrientCatalog {
    pub fn get(&self, code: &str) -> Option<&Nutrient> {
        self.by_code.get(code)
    }
}

impl FromIterator<Nutrient> for NutrientCatalog {
    fn from_iter<I: IntoIterator<Item = Nutrient>>(nutrients: I) -> Self {
        Self {
            by_code: nutrients
                .into_iter()
                .map(|n| (n.code.0.clone(), n))
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NutrientCode(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitCode(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Barcode(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductName(String);

impl ProductName {
    pub fn new(value: &str) -> Result<Self, NutritionError> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err(NutritionError::Validation("food name is required".into()));
        }
        Ok(Self(trimmed.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Brand(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Category(pub String);

impl Category {
    pub fn new(value: &str) -> Option<Self> {
        let normalized = value.trim().to_lowercase();
        if normalized.is_empty() {
            None
        } else {
            Some(Category(normalized))
        }
    }

    pub fn normalize_list<I, S>(values: I) -> Vec<Category>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut out: Vec<Category> = Vec::new();
        for value in values {
            if let Some(category) = Category::new(value.as_ref())
                && !out.contains(&category)
            {
                out.push(category);
            }
        }
        out
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServingLabel(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefaultQuantity {
    pub amount: Decimal,
    pub unit: UnitCode,
}

impl DefaultQuantity {
    pub fn new(
        amount: Option<Decimal>,
        unit: Option<String>,
        servings: &[ProductServing],
    ) -> Result<Option<Self>, NutritionError> {
        match (amount, unit) {
            (None, None) => Ok(None),
            (Some(amount), Some(unit)) => {
                if amount <= Decimal::ZERO {
                    return Err(NutritionError::Validation(
                        "default quantity must be positive".into(),
                    ));
                }
                if unit != "g"
                    && !servings
                        .iter()
                        .any(|serving| serving.unit.0 == unit && serving.quantity == amount)
                {
                    return Err(NutritionError::Validation(format!(
                        "default portion must be grams or match a configured serving: {amount} {unit}"
                    )));
                }
                Ok(Some(Self {
                    amount,
                    unit: UnitCode(unit),
                }))
            }
            _ => Err(NutritionError::Validation(
                "default quantity and default unit must be provided together".into(),
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AmountPer100g(Decimal);

impl AmountPer100g {
    const SCALE: u32 = 6;

    pub fn new(amount: Decimal) -> Result<Self, NutritionError> {
        if amount < Decimal::ZERO {
            return Err(NutritionError::Validation(
                "nutrient amount must be non-negative".into(),
            ));
        }
        Ok(Self(amount.round_dp(Self::SCALE)))
    }

    pub fn value(&self) -> Decimal {
        self.0
    }
}

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
    pub nutrients: Vec<ProductNutrient>,
    pub servings: Vec<ProductServing>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Product {
    #[allow(clippy::too_many_arguments)]
    pub fn new_custom(
        user_id: Uuid,
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<ProductNutrientInput>,
        servings: Vec<ProductServingInput>,
        nutrient_catalog: &NutrientCatalog,
    ) -> Result<Self, NutritionError> {
        let name = ProductName::new(&name)?;
        let nutrients = build_product_nutrients(nutrients, nutrient_catalog)?;
        validate_required_nutrients(&nutrients)?;
        let servings = build_product_servings(servings)?;
        let default_quantity = DefaultQuantity::new(default_quantity, default_unit, &servings)?;

        let now = Utc::now();
        Ok(Self {
            id: ProductId::new(),
            source: Source::User,
            source_id: None,
            user_id: Some(user_id),
            visibility: ProductVisibility::Global,
            barcode: None,
            name,
            brand: brand.map(Brand),
            categories: Category::normalize_list(categories),
            default_quantity: default_quantity.as_ref().map(|q| q.amount),
            default_unit: default_quantity.map(|q| q.unit),
            nutrients,
            servings,
            created_at: now,
            updated_at: now,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_custom(
        &self,
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<ProductNutrientInput>,
        servings: Vec<ProductServingInput>,
        nutrient_catalog: &NutrientCatalog,
    ) -> Result<Self, NutritionError> {
        let name = ProductName::new(&name)?;
        let nutrients = build_product_nutrients(nutrients, nutrient_catalog)?;
        validate_required_nutrients(&nutrients)?;
        let servings = build_product_servings(servings)?;
        let default_quantity = DefaultQuantity::new(default_quantity, default_unit, &servings)?;

        Ok(Self {
            name,
            brand: brand.map(Brand),
            categories: Category::normalize_list(categories),
            default_quantity: default_quantity.as_ref().map(|q| q.amount),
            default_unit: default_quantity.map(|q| q.unit),
            nutrients,
            servings,
            ..self.clone()
        })
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == Some(user_id)
    }

    pub fn quantity_to_grams(
        &self,
        quantity: &Quantity,
        unit_converter: &UnitConverter,
    ) -> Result<Decimal, String> {
        let amount = quantity.amount();
        let unit = quantity.unit();
        if let Some(grams) = unit_converter.mass_to_grams(amount, unit) {
            return Ok(grams);
        }
        for serving in &self.servings {
            if serving.unit.0 == unit.0 && serving.quantity > Decimal::ZERO {
                return Ok(serving.grams * (amount / serving.quantity));
            }
        }
        Err(format!("cannot convert {} {} to grams", amount, unit.0))
    }

    pub fn nutrition_for(
        &self,
        quantity: &Quantity,
        unit_converter: &UnitConverter,
    ) -> Result<CalculatedNutrition, String> {
        let grams = self.quantity_to_grams(quantity, unit_converter)?;
        let nutrients: Vec<(NutrientCode, AmountPer100g, UnitCode)> = self
            .nutrients
            .iter()
            .map(|pn| {
                (
                    pn.nutrient_code.clone(),
                    pn.amount_per_100g.clone(),
                    pn.unit.clone(),
                )
            })
            .collect();
        Ok(NutritionCalculator::calculate(grams, &nutrients))
    }

    pub fn allowed_unit_codes(&self, converter: &UnitConverter) -> HashSet<String> {
        let mut allowed: HashSet<String> = HashSet::new();
        for code in converter.mass_unit_codes() {
            allowed.insert(code.to_string());
        }
        for serving in &self.servings {
            allowed.insert(serving.unit.0.clone());
        }
        allowed
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
pub struct ProductNutrientInput {
    pub code: String,
    pub amount_per_100g: Decimal,
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
pub struct ProductServingInput {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

impl ProductServing {
    pub fn validate_values(quantity: Decimal, grams: Decimal) -> Result<(), NutritionError> {
        if quantity <= Decimal::ZERO || grams <= Decimal::ZERO {
            return Err(NutritionError::Validation(
                "serving quantity and grams must be positive".into(),
            ));
        }
        Ok(())
    }
}

pub const REQUIRED_CUSTOM_FOOD_NUTRIENT_CODES: &[&str] =
    &["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"];

fn validate_required_nutrients(nutrients: &[ProductNutrient]) -> Result<(), NutritionError> {
    let missing: Vec<&str> = REQUIRED_CUSTOM_FOOD_NUTRIENT_CODES
        .iter()
        .copied()
        .filter(|code| !nutrients.iter().any(|n| n.nutrient_code.0 == *code))
        .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(NutritionError::Validation(format!(
            "custom food is missing required nutrient(s): {}",
            missing.join(", ")
        )))
    }
}

fn build_product_nutrients(
    nutrients: Vec<ProductNutrientInput>,
    catalog: &NutrientCatalog,
) -> Result<Vec<ProductNutrient>, NutritionError> {
    let mut seen: HashSet<String> = HashSet::new();
    nutrients
        .into_iter()
        .map(|nutrient| {
            let amount_per_100g = AmountPer100g::new(nutrient.amount_per_100g)?;
            let reference = catalog.get(&nutrient.code).ok_or_else(|| {
                NutritionError::Validation(format!("unknown nutrient code: {}", nutrient.code))
            })?;
            if !seen.insert(reference.code.0.clone()) {
                return Err(NutritionError::Validation(format!(
                    "duplicate nutrient code: {}",
                    reference.code.0
                )));
            }
            Ok(ProductNutrient {
                nutrient_code: reference.code.clone(),
                amount_per_100g,
                unit: reference.unit.clone(),
                source: nutrient.source,
                confidence: nutrient
                    .confidence
                    .and_then(|confidence| confidence.parse().ok()),
            })
        })
        .collect()
}

fn build_product_servings(
    servings: Vec<ProductServingInput>,
) -> Result<Vec<ProductServing>, NutritionError> {
    let mut seen_units = HashSet::new();
    servings
        .into_iter()
        .map(|serving| {
            ProductServing::validate_values(serving.quantity, serving.grams)?;
            if !seen_units.insert(serving.unit.clone()) {
                return Err(NutritionError::Validation(format!(
                    "duplicate serving unit: {}",
                    serving.unit
                )));
            }
            Ok(ProductServing {
                label: ServingLabel(serving.label),
                quantity: serving.quantity,
                unit: UnitCode(serving.unit),
                grams: serving.grams,
            })
        })
        .collect()
}

pub use crate::nutrition::error::NutritionError;

#[async_trait]
pub trait ProductRepository: Send + Sync {
    async fn search(
        &self,
        spec: ProductSearchSpec,
        scope: ProductSearchScope,
        user_id: Option<Uuid>,
    ) -> Result<Vec<Product>, NutritionError>;
    async fn list_categories(
        &self,
        query: &str,
        user_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<CategorySuggestion>, NutritionError>;
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, NutritionError>;
    async fn existing_ids(&self, ids: &[ProductId]) -> Result<HashSet<ProductId>, NutritionError>;
    async fn find_by_barcode(
        &self,
        barcode: &str,
        user_id: Option<Uuid>,
    ) -> Result<Option<Product>, NutritionError>;
    async fn list_custom_foods(&self) -> Result<Vec<Product>, NutritionError>;
    async fn create(&self, product: &Product) -> Result<(), NutritionError>;
    async fn update(&self, product: &Product) -> Result<(), NutritionError>;
    async fn delete(&self, id: ProductId) -> Result<(), NutritionError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct CatalogPolicy;

impl CatalogPolicy {
    pub fn authorize_view(
        &self,
        _actor_id: Uuid,
        _product: &Product,
    ) -> Result<(), NutritionError> {
        Ok(())
    }

    pub fn authorize_mutation(
        &self,
        actor_id: Uuid,
        product: &Product,
    ) -> Result<(), NutritionError> {
        if product.source != Source::User {
            return Err(NutritionError::Forbidden(
                "system catalog products are read-only".into(),
            ));
        }
        if !product.is_owned_by(actor_id) {
            return Err(NutritionError::Forbidden(
                "only the creator may modify this custom food".into(),
            ));
        }
        Ok(())
    }
}

#[async_trait]
pub trait NutrientRepository: Send + Sync {
    async fn list_all(&self) -> Result<Vec<Nutrient>, NutritionError>;
    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, NutritionError>;
}

#[async_trait]
pub trait UnitRepository: Send + Sync {
    async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, NutritionError>;
    async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, NutritionError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_search_query_parse_extracts_category_filters() {
        let parsed =
            ProductSearchSpec::parse(r#"chicken category:meat -category:"processed food""#);

        assert_eq!(parsed.text, "chicken");
        assert_eq!(parsed.include_categories, vec![Category("meat".into())]);
        assert_eq!(
            parsed.exclude_categories,
            vec![Category("processed food".into())]
        );
    }

    #[test]
    fn product_search_scope_defaults_to_all() {
        assert_eq!(
            ProductSearchScope::parse(None).unwrap(),
            ProductSearchScope::All
        );
    }

    #[test]
    fn product_search_scope_parse_accepts_supported_values() {
        assert_eq!(
            ProductSearchScope::parse(Some("all")).unwrap(),
            ProductSearchScope::All
        );
        assert_eq!(
            ProductSearchScope::parse(Some("custom")).unwrap(),
            ProductSearchScope::Custom
        );
        assert_eq!(
            ProductSearchScope::parse(Some("history")).unwrap(),
            ProductSearchScope::History
        );
    }

    #[test]
    fn product_search_scope_parse_rejects_unknown_values() {
        assert!(matches!(
            ProductSearchScope::parse(Some("private")),
            Err(NutritionError::Validation(_))
        ));
    }

    #[test]
    fn category_normalize_list_trims_lowercases_and_deduplicates() {
        let categories = Category::normalize_list([" Snacks ", "snacks", "", "Beverages"]);
        assert_eq!(
            categories.iter().map(|c| c.0.as_str()).collect::<Vec<_>>(),
            vec!["snacks", "beverages"]
        );
    }

    fn nutrient_input(amount_per_100g: Decimal) -> ProductNutrientInput {
        ProductNutrientInput {
            code: "ENERGY_KCAL".into(),
            amount_per_100g,
            source: Some("manual".into()),
            confidence: Some("approved".into()),
        }
    }

    fn nutrient_input_for(code: &str, amount_per_100g: Decimal) -> ProductNutrientInput {
        ProductNutrientInput {
            code: code.into(),
            amount_per_100g,
            source: Some("manual".into()),
            confidence: Some("approved".into()),
        }
    }

    fn required_nutrient_inputs(amount_per_100g: Decimal) -> Vec<ProductNutrientInput> {
        vec![
            nutrient_input_for("ENERGY_KCAL", amount_per_100g),
            nutrient_input_for("PROTEIN_G", amount_per_100g),
            nutrient_input_for("CARBS_G", amount_per_100g),
            nutrient_input_for("FAT_G", amount_per_100g),
        ]
    }

    fn serving_input(quantity: Decimal, grams: Decimal) -> ProductServingInput {
        ProductServingInput {
            label: "serving".into(),
            quantity,
            unit: "serving".into(),
            grams,
        }
    }

    fn test_catalog() -> NutrientCatalog {
        [
            Nutrient {
                code: NutrientCode("ENERGY_KCAL".into()),
                name: "Energy".into(),
                unit: UnitCode("kcal".into()),
                category: "energy".into(),
            },
            Nutrient {
                code: NutrientCode("PROTEIN_G".into()),
                name: "Protein".into(),
                unit: UnitCode("g".into()),
                category: "macros".into(),
            },
            Nutrient {
                code: NutrientCode("CARBS_G".into()),
                name: "Carbohydrates".into(),
                unit: UnitCode("g".into()),
                category: "macros".into(),
            },
            Nutrient {
                code: NutrientCode("FAT_G".into()),
                name: "Fat".into(),
                unit: UnitCode("g".into()),
                category: "macros".into(),
            },
        ]
        .into_iter()
        .collect()
    }

    #[test]
    fn custom_product_creation_normalizes_and_builds_children() {
        let catalog = test_catalog();
        let product = Product::new_custom(
            Uuid::new_v4(),
            "  Rice Bowl  ".into(),
            Some("Kitchen".into()),
            vec![" Meals ".into(), "meals".into(), "Dinner".into()],
            Some(Decimal::new(1, 0)),
            Some("g".into()),
            required_nutrient_inputs(Decimal::new(120, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(250, 0))],
            &catalog,
        )
        .unwrap();

        assert_eq!(product.source, Source::User);
        assert_eq!(product.visibility, ProductVisibility::Global);
        assert_eq!(product.name.as_str(), "Rice Bowl");
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
        let catalog = test_catalog();

        assert!(
            Product::new_custom(
                user_id,
                " ".into(),
                None,
                vec![],
                None,
                None,
                vec![nutrient_input(Decimal::ZERO)],
                vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
                &catalog,
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
                vec![nutrient_input(Decimal::new(-1, 0))],
                vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
                &catalog,
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
                vec![nutrient_input(Decimal::ZERO)],
                vec![serving_input(Decimal::ZERO, Decimal::new(100, 0))],
                &catalog,
            )
            .is_err()
        );
    }

    #[test]
    fn amount_per_100g_rounds_to_storage_scale() {
        let amount =
            AmountPer100g::new("0.08333333333333333333333333333".parse().unwrap()).unwrap();

        assert_eq!(amount.value(), Decimal::new(83333, 6));
    }

    #[test]
    fn custom_product_creation_rejects_unknown_nutrient_code() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let result = Product::new_custom(
            user_id,
            "Food".into(),
            None,
            vec![],
            None,
            None,
            vec![ProductNutrientInput {
                code: "NOT_A_CODE".into(),
                amount_per_100g: Decimal::new(10, 0),
                source: None,
                confidence: None,
            }],
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[test]
    fn custom_product_update_preserves_identity_and_source_fields() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let mut product = Product::new_custom(
            user_id,
            "Original".into(),
            None,
            vec!["old".into()],
            None,
            None,
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        )
        .unwrap();
        product.source_id = Some("external-id".into());
        product.barcode = Some(Barcode("123".into()));

        let updated = product
            .update_custom(
                " Updated ".into(),
                Some("Brand".into()),
                vec!["New".into()],
                Some(Decimal::new(2, 0)),
                Some("serving".into()),
                required_nutrient_inputs(Decimal::new(20, 0)),
                vec![serving_input(Decimal::new(2, 0), Decimal::new(50, 0))],
                &catalog,
            )
            .unwrap();

        assert_eq!(updated.id, product.id);
        assert_eq!(updated.source, product.source);
        assert_eq!(updated.source_id, product.source_id);
        assert_eq!(updated.user_id, product.user_id);
        assert_eq!(updated.visibility, product.visibility);
        assert_eq!(updated.barcode, product.barcode);
        assert_eq!(updated.name.as_str(), "Updated");
        assert_eq!(updated.brand.unwrap().0, "Brand");
        assert_eq!(updated.default_unit.unwrap().0, "serving");
    }

    #[test]
    fn custom_product_creation_rejects_missing_required_macros() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let result = Product::new_custom(
            user_id,
            "Food".into(),
            None,
            vec![],
            None,
            None,
            vec![nutrient_input(Decimal::new(100, 0))],
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        match result {
            Err(NutritionError::Validation(msg)) => {
                assert!(msg.contains("PROTEIN_G"), "msg: {msg}");
                assert!(msg.contains("CARBS_G"), "msg: {msg}");
                assert!(msg.contains("FAT_G"), "msg: {msg}");
                assert!(!msg.contains("ENERGY_KCAL"), "msg: {msg}");
            }
            other => panic!("expected Validation error, got {other:?}"),
        }
    }

    #[test]
    fn custom_product_update_rejects_missing_required_macros() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let product = Product::new_custom(
            user_id,
            "Original".into(),
            None,
            vec![],
            None,
            None,
            required_nutrient_inputs(Decimal::new(100, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        )
        .unwrap();

        let result = product.update_custom(
            "Updated".into(),
            None,
            vec![],
            None,
            None,
            vec![nutrient_input(Decimal::new(200, 0))],
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        match result {
            Err(NutritionError::Validation(msg)) => {
                assert!(msg.contains("PROTEIN_G"), "msg: {msg}");
                assert!(msg.contains("CARBS_G"), "msg: {msg}");
                assert!(msg.contains("FAT_G"), "msg: {msg}");
            }
            other => panic!("expected Validation error, got {other:?}"),
        }
    }

    #[test]
    fn custom_product_creation_rejects_duplicate_serving_units() {
        let catalog = test_catalog();
        let result = Product::new_custom(
            Uuid::new_v4(),
            "Food".into(),
            None,
            vec![],
            None,
            None,
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![
                serving_input(Decimal::new(1, 0), Decimal::new(100, 0)),
                serving_input(Decimal::new(2, 0), Decimal::new(200, 0)),
            ],
            &catalog,
        );
        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[test]
    fn custom_product_creation_rejects_half_default_quantity_pair() {
        let catalog = test_catalog();
        let missing_unit = Product::new_custom(
            Uuid::new_v4(),
            "Food".into(),
            None,
            vec![],
            Some(Decimal::new(1, 0)),
            None,
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        assert!(matches!(missing_unit, Err(NutritionError::Validation(_))));

        let missing_quantity = Product::new_custom(
            Uuid::new_v4(),
            "Food".into(),
            None,
            vec![],
            None,
            Some("serving".into()),
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        assert!(matches!(
            missing_quantity,
            Err(NutritionError::Validation(_))
        ));
    }

    #[test]
    fn custom_product_creation_rejects_default_that_does_not_match_serving() {
        let catalog = test_catalog();
        let result = Product::new_custom(
            Uuid::new_v4(),
            "Food".into(),
            None,
            vec![],
            Some(Decimal::new(2, 0)),
            Some("serving".into()),
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[test]
    fn custom_product_creation_accepts_valid_serving_and_default_quantity() {
        let catalog = test_catalog();
        let product = Product::new_custom(
            Uuid::new_v4(),
            "Food".into(),
            None,
            vec![],
            Some(Decimal::new(1, 0)),
            Some("g".into()),
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        )
        .unwrap();
        assert_eq!(product.default_quantity, Some(Decimal::new(1, 0)));
        assert_eq!(product.default_unit.unwrap().0, "g");
    }

    #[test]
    fn custom_product_creation_rejects_duplicate_nutrient_codes() {
        let catalog = test_catalog();
        let mut nutrients = required_nutrient_inputs(Decimal::new(10, 0));
        nutrients.push(nutrient_input_for("PROTEIN_G", Decimal::new(5, 0)));

        let result = Product::new_custom(
            Uuid::new_v4(),
            "Food".into(),
            None,
            vec![],
            None,
            None,
            nutrients,
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        match result {
            Err(NutritionError::Validation(msg)) => {
                assert!(msg.contains("duplicate"), "msg: {msg}");
                assert!(msg.contains("PROTEIN_G"), "msg: {msg}");
            }
            other => panic!("expected Validation error, got {other:?}"),
        }
    }

    #[test]
    fn custom_product_creation_keeps_unknown_code_error_first() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let result = Product::new_custom(
            user_id,
            "Food".into(),
            None,
            vec![],
            None,
            None,
            vec![ProductNutrientInput {
                code: "NOT_A_CODE".into(),
                amount_per_100g: Decimal::new(10, 0),
                source: None,
                confidence: None,
            }],
            vec![serving_input(Decimal::new(1, 0), Decimal::new(100, 0))],
            &catalog,
        );
        match result {
            Err(NutritionError::Validation(msg)) => {
                assert!(msg.contains("NOT_A_CODE"), "msg: {msg}");
                assert!(!msg.contains("missing required"), "msg: {msg}");
            }
            other => panic!("expected Validation error, got {other:?}"),
        }
    }

    #[test]
    fn catalog_policy_shares_reads_but_limits_custom_food_writes_to_creator() {
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();
        let product = Product::new_custom(
            owner,
            "Shared food".into(),
            None,
            vec![],
            None,
            None,
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![],
            &test_catalog(),
        )
        .unwrap();
        let policy = CatalogPolicy;

        assert!(policy.authorize_view(other, &product).is_ok());
        assert!(policy.authorize_mutation(owner, &product).is_ok());
        assert!(matches!(
            policy.authorize_mutation(other, &product),
            Err(NutritionError::Forbidden(_))
        ));
    }

    #[test]
    fn catalog_policy_keeps_imported_products_read_only() {
        let actor = Uuid::new_v4();
        let mut product = Product::new_custom(
            actor,
            "Imported food".into(),
            None,
            vec![],
            None,
            None,
            required_nutrient_inputs(Decimal::new(10, 0)),
            vec![],
            &test_catalog(),
        )
        .unwrap();
        product.source = Source::Off;
        product.user_id = None;

        assert!(matches!(
            CatalogPolicy.authorize_mutation(actor, &product),
            Err(NutritionError::Forbidden(_))
        ));
    }
}

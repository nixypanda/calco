pub mod calculation;
pub mod search_ranking;
pub mod units;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use uuid::Uuid;

use crate::catalog::domain::calculation::{
    CalculatedNutrition, NutritionCalculator, Quantity,
};
use crate::catalog::domain::search_ranking::{
    CategoryCount, HistorySearchCandidate, ProductSearchFields,
};
use crate::catalog::domain::units::UnitConverter;

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

/// Catalog-only search scopes. History candidates have a different shape, so
/// they cannot be requested through the catalog repository method.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CatalogSearchScope {
    All,
    Custom,
}

impl ProductSearchScope {
    pub fn parse(input: Option<&str>) -> Result<Self, CatalogError> {
        match input.unwrap_or("all") {
            "all" => Ok(Self::All),
            "custom" => Ok(Self::Custom),
            "history" => Ok(Self::History),
            other => Err(CatalogError::Validation(format!(
                "unknown food search scope: {other}"
            ))),
        }
    }

    pub fn catalog_scope(self) -> Option<CatalogSearchScope> {
        match self {
            Self::All => Some(CatalogSearchScope::All),
            Self::Custom => Some(CatalogSearchScope::Custom),
            Self::History => None,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ExternalSource {
    Off,
    Usda,
    Ifct,
    Indb,
}

impl ExternalSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            ExternalSource::Off => "OFF",
            ExternalSource::Usda => "USDA",
            ExternalSource::Ifct => "IFCT",
            ExternalSource::Indb => "INDB",
        }
    }

    pub fn default_nutrient_confidence(&self) -> NutrientConfidence {
        match self {
            ExternalSource::Usda | ExternalSource::Ifct | ExternalSource::Indb => {
                NutrientConfidence::Approved
            }
            ExternalSource::Off => NutrientConfidence::Derived,
        }
    }
}

impl FromStr for ExternalSource {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "OFF" => Ok(ExternalSource::Off),
            "USDA" => Ok(ExternalSource::Usda),
            "IFCT" => Ok(ExternalSource::Ifct),
            "INDB" => Ok(ExternalSource::Indb),
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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExternalProductId(String);

impl ExternalProductId {
    pub fn new(value: impl Into<String>) -> Result<Self, CatalogError> {
        let value = value.into().trim().to_owned();
        if value.is_empty() {
            return Err(CatalogError::Validation(
                "external food must have a source id".into(),
            ));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProductOrigin {
    Custom {
        user_id: Uuid,
    },
    External {
        source: ExternalSource,
        source_id: ExternalProductId,
        barcode: Option<Barcode>,
    },
}

impl ProductOrigin {
    pub fn source_code(&self) -> &'static str {
        match self {
            Self::Custom { .. } => "USER",
            Self::External { source, .. } => source.as_str(),
        }
    }

    pub fn source_id(&self) -> Option<&str> {
        match self {
            Self::Custom { .. } => None,
            Self::External { source_id, .. } => Some(source_id.as_str()),
        }
    }

    pub fn owner_id(&self) -> Option<Uuid> {
        match self {
            Self::Custom { user_id } => Some(*user_id),
            Self::External { .. } => None,
        }
    }

    pub fn barcode(&self) -> Option<&Barcode> {
        match self {
            Self::Custom { .. } => None,
            Self::External { barcode, .. } => barcode.as_ref(),
        }
    }

    pub fn external_identity(&self) -> Option<(ExternalSource, &ExternalProductId)> {
        match self {
            Self::Custom { .. } => None,
            Self::External {
                source, source_id, ..
            } => Some((*source, source_id)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductName(String);

impl ProductName {
    pub fn new(value: &str) -> Result<Self, CatalogError> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err(CatalogError::Validation("food name is required".into()));
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
pub struct DefaultQuantity {
    pub amount: Decimal,
    pub unit: UnitCode,
}

impl DefaultQuantity {
    pub fn new(
        amount: Option<Decimal>,
        unit: Option<String>,
        servings: &[ProductServing],
    ) -> Result<Option<Self>, CatalogError> {
        match (amount, unit) {
            (None, None) => Ok(None),
            (Some(amount), Some(unit)) => {
                if amount <= Decimal::ZERO {
                    return Err(CatalogError::Validation(
                        "default quantity must be positive".into(),
                    ));
                }
                if unit != "g" && !servings.iter().any(|serving| serving.unit.0 == unit) {
                    return Err(CatalogError::Validation(format!(
                        "default portion must be grams or use a configured serving unit: {unit}"
                    )));
                }
                Ok(Some(Self {
                    amount,
                    unit: UnitCode(unit),
                }))
            }
            _ => Err(CatalogError::Validation(
                "default quantity and default unit must be provided together".into(),
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AmountPer100g(Decimal);

impl AmountPer100g {
    const SCALE: u32 = 6;

    pub fn new(amount: Decimal) -> Result<Self, CatalogError> {
        if amount < Decimal::ZERO {
            return Err(CatalogError::Validation(
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
    pub origin: ProductOrigin,
    pub visibility: ProductVisibility,
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

#[derive(Debug, Clone)]
struct DefaultPortionInput {
    amount: Decimal,
    unit: String,
}

#[derive(Debug, Clone)]
pub struct CustomProductBuilder {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    default_portion: Option<DefaultPortionInput>,
    nutrients: Vec<ProductNutrientInput>,
    servings: Vec<ProductServingInput>,
}

impl CustomProductBuilder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            brand: None,
            categories: Vec::new(),
            default_portion: None,
            nutrients: Vec::new(),
            servings: Vec::new(),
        }
    }

    pub fn brand(mut self, brand: Option<String>) -> Self {
        self.brand = brand;
        self
    }

    pub fn categories(mut self, categories: Vec<String>) -> Self {
        self.categories = categories;
        self
    }

    pub fn default_portion(mut self, amount: Decimal, unit: impl Into<String>) -> Self {
        self.default_portion = Some(DefaultPortionInput {
            amount,
            unit: unit.into(),
        });
        self
    }

    pub fn optional_default_portion(
        self,
        amount: Option<Decimal>,
        unit: Option<String>,
    ) -> Result<Self, CatalogError> {
        match (amount, unit) {
            (None, None) => Ok(self),
            (Some(amount), Some(unit)) => Ok(self.default_portion(amount, unit)),
            _ => Err(CatalogError::Validation(
                "default quantity and default unit must be provided together".into(),
            )),
        }
    }

    pub fn nutrients(mut self, nutrients: Vec<ProductNutrientInput>) -> Self {
        self.nutrients = nutrients;
        self
    }

    pub fn servings(mut self, servings: Vec<ProductServingInput>) -> Self {
        self.servings = servings;
        self
    }
}

#[derive(Debug, Clone)]
pub struct ExternalProductBuilder {
    source_id: String,
    name: String,
    barcode: Option<String>,
    brand: Option<String>,
    categories: Vec<String>,
    default_portion: Option<DefaultPortionInput>,
    nutrients: Vec<ProductNutrientInput>,
    servings: Vec<ProductServingInput>,
}

impl ExternalProductBuilder {
    pub fn new(source_id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            source_id: source_id.into(),
            name: name.into(),
            barcode: None,
            brand: None,
            categories: Vec::new(),
            default_portion: None,
            nutrients: Vec::new(),
            servings: Vec::new(),
        }
    }

    pub fn barcode(mut self, barcode: Option<String>) -> Self {
        self.barcode = barcode;
        self
    }

    pub fn brand(mut self, brand: Option<String>) -> Self {
        self.brand = brand;
        self
    }

    pub fn categories(mut self, categories: Vec<String>) -> Self {
        self.categories = categories;
        self
    }

    pub fn default_portion(mut self, amount: Decimal, unit: impl Into<String>) -> Self {
        self.default_portion = Some(DefaultPortionInput {
            amount,
            unit: unit.into(),
        });
        self
    }

    pub fn optional_default_portion(
        self,
        amount: Option<Decimal>,
        unit: Option<String>,
    ) -> Result<Self, CatalogError> {
        match (amount, unit) {
            (None, None) => Ok(self),
            (Some(amount), Some(unit)) => Ok(self.default_portion(amount, unit)),
            _ => Err(CatalogError::Validation(
                "default quantity and default unit must be provided together".into(),
            )),
        }
    }

    pub fn nutrients(mut self, nutrients: Vec<ProductNutrientInput>) -> Self {
        self.nutrients = nutrients;
        self
    }

    pub fn servings(mut self, servings: Vec<ProductServingInput>) -> Self {
        self.servings = servings;
        self
    }
}

struct ValidatedCustomFood {
    name: ProductName,
    brand: Option<Brand>,
    categories: Vec<Category>,
    default_quantity: Option<DefaultQuantity>,
    nutrients: Vec<ProductNutrient>,
    servings: Vec<ProductServing>,
}

impl Product {
    pub fn new_external(
        source: ExternalSource,
        input: ExternalProductBuilder,
        nutrient_catalog: &NutrientCatalog,
    ) -> Result<Self, CatalogError> {
        let nutrients = build_product_nutrients(input.nutrients, nutrient_catalog)?;
        let servings = build_product_servings(input.servings)?;
        let (default_quantity, default_unit) = default_portion_parts(input.default_portion);
        let default_quantity = DefaultQuantity::new(default_quantity, default_unit, &servings)?;
        let now = Utc::now();

        Ok(Self {
            id: ProductId::new(),
            origin: ProductOrigin::External {
                source,
                source_id: ExternalProductId::new(input.source_id)?,
                barcode: input
                    .barcode
                    .map(|value| value.trim().to_owned())
                    .filter(|value| !value.is_empty())
                    .map(Barcode),
            },
            visibility: ProductVisibility::Global,
            name: ProductName::new(&input.name)?,
            brand: input
                .brand
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
                .map(Brand),
            categories: Category::normalize_list(input.categories),
            default_quantity: default_quantity.as_ref().map(|q| q.amount),
            default_unit: default_quantity.map(|q| q.unit),
            nutrients,
            servings,
            created_at: now,
            updated_at: now,
        })
    }

    pub fn new_custom(
        user_id: Uuid,
        input: CustomProductBuilder,
        nutrient_catalog: &NutrientCatalog,
    ) -> Result<Self, CatalogError> {
        let validated = validate_custom_food(input, nutrient_catalog)?;

        let now = Utc::now();
        Ok(Self {
            id: ProductId::new(),
            origin: ProductOrigin::Custom { user_id },
            visibility: ProductVisibility::Global,
            name: validated.name,
            brand: validated.brand,
            categories: validated.categories,
            default_quantity: validated.default_quantity.as_ref().map(|q| q.amount),
            default_unit: validated.default_quantity.map(|q| q.unit),
            nutrients: validated.nutrients,
            servings: validated.servings,
            created_at: now,
            updated_at: now,
        })
    }

    pub fn update_custom(
        &self,
        input: CustomProductBuilder,
        nutrient_catalog: &NutrientCatalog,
    ) -> Result<Self, CatalogError> {
        if !matches!(self.origin, ProductOrigin::Custom { .. }) {
            return Err(CatalogError::Validation(
                "external products cannot be updated as custom foods".into(),
            ));
        }
        let validated = validate_custom_food(input, nutrient_catalog)?;

        Ok(Self {
            name: validated.name,
            brand: validated.brand,
            categories: validated.categories,
            default_quantity: validated.default_quantity.as_ref().map(|q| q.amount),
            default_unit: validated.default_quantity.map(|q| q.unit),
            nutrients: validated.nutrients,
            servings: validated.servings,
            ..self.clone()
        })
    }

    pub fn validate_custom_draft(
        input: CustomProductBuilder,
        nutrient_catalog: &NutrientCatalog,
    ) -> Result<(), CatalogError> {
        validate_custom_food(input, nutrient_catalog)?;
        Ok(())
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        matches!(self.origin, ProductOrigin::Custom { user_id: owner_id } if owner_id == user_id)
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
            if serving.unit.0 == unit.0 {
                return Ok(serving.grams_per_unit * amount);
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

fn validate_custom_food(
    input: CustomProductBuilder,
    nutrient_catalog: &NutrientCatalog,
) -> Result<ValidatedCustomFood, CatalogError> {
    let name = ProductName::new(&input.name)?;
    let nutrients = build_product_nutrients(input.nutrients, nutrient_catalog)?;
    validate_required_nutrients(&nutrients)?;
    let servings = build_product_servings(input.servings)?;
    let (default_quantity, default_unit) = default_portion_parts(input.default_portion);
    let default_quantity = DefaultQuantity::new(default_quantity, default_unit, &servings)?;
    Ok(ValidatedCustomFood {
        name,
        brand: input.brand.map(Brand),
        categories: Category::normalize_list(input.categories),
        default_quantity,
        nutrients,
        servings,
    })
}

fn default_portion_parts(
    default_portion: Option<DefaultPortionInput>,
) -> (Option<Decimal>, Option<String>) {
    match default_portion {
        Some(default_portion) => (Some(default_portion.amount), Some(default_portion.unit)),
        None => (None, None),
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
#[cfg_attr(test, derive(PartialEq, Eq))]
pub struct ProductServing {
    pub unit: UnitCode,
    pub grams_per_unit: Decimal,
}

#[derive(Debug, Clone)]
pub struct ProductServingInput {
    pub unit: String,
    pub grams_per_unit: Decimal,
}

impl ProductServing {
    pub fn validate_grams_per_unit(grams_per_unit: Decimal) -> Result<(), CatalogError> {
        if grams_per_unit <= Decimal::ZERO {
            return Err(CatalogError::Validation(
                "serving grams per unit must be positive".into(),
            ));
        }
        Ok(())
    }
}

pub const REQUIRED_CUSTOM_FOOD_NUTRIENT_CODES: &[&str] =
    &["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"];

fn validate_required_nutrients(nutrients: &[ProductNutrient]) -> Result<(), CatalogError> {
    let missing: Vec<&str> = REQUIRED_CUSTOM_FOOD_NUTRIENT_CODES
        .iter()
        .copied()
        .filter(|code| !nutrients.iter().any(|n| n.nutrient_code.0 == *code))
        .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(CatalogError::Validation(format!(
            "custom food is missing required nutrient(s): {}",
            missing.join(", ")
        )))
    }
}

fn build_product_nutrients(
    nutrients: Vec<ProductNutrientInput>,
    catalog: &NutrientCatalog,
) -> Result<Vec<ProductNutrient>, CatalogError> {
    let mut seen: HashSet<String> = HashSet::new();
    nutrients
        .into_iter()
        .map(|nutrient| {
            let amount_per_100g = AmountPer100g::new(nutrient.amount_per_100g)?;
            let reference = catalog.get(&nutrient.code).ok_or_else(|| {
                CatalogError::Validation(format!("unknown nutrient code: {}", nutrient.code))
            })?;
            if !seen.insert(reference.code.0.clone()) {
                return Err(CatalogError::Validation(format!(
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
) -> Result<Vec<ProductServing>, CatalogError> {
    let mut seen_units = HashSet::new();
    servings
        .into_iter()
        .map(|serving| {
            ProductServing::validate_grams_per_unit(serving.grams_per_unit)?;
            if !seen_units.insert(serving.unit.clone()) {
                return Err(CatalogError::Validation(format!(
                    "duplicate serving unit: {}",
                    serving.unit
                )));
            }
            Ok(ProductServing {
                unit: UnitCode(serving.unit),
                grams_per_unit: serving.grams_per_unit,
            })
        })
        .collect()
}

pub use crate::catalog::error::CatalogError;
/// A validated collection of complete external product aggregates.
///
/// Construction enforces the invariants required by external catalog writes.
/// Persistence receives this type instead of raw products, so those invariants
/// cannot be bypassed by repository callers.
#[derive(Debug, Clone)]
pub struct ExternalProductBatch {
    products: Vec<Product>,
}

impl ExternalProductBatch {
    pub fn new(products: Vec<Product>) -> Result<Self, CatalogError> {
        let mut identities = HashSet::new();

        for product in &products {
            let Some((source, source_id)) = product.origin.external_identity() else {
                return Err(CatalogError::Validation(
                    "external product batch cannot contain custom products".into(),
                ));
            };
            if !identities.insert((source, source_id)) {
                return Err(CatalogError::Validation(format!(
                    "duplicate external product identity: ({}, {})",
                    source.as_str(),
                    source_id.as_str()
                )));
            }

            let mut nutrient_codes = HashSet::new();
            for nutrient in &product.nutrients {
                if !nutrient_codes.insert(nutrient.nutrient_code.0.as_str()) {
                    return Err(CatalogError::Validation(format!(
                        "duplicate nutrient code for external product: {}",
                        nutrient.nutrient_code.0
                    )));
                }
            }

            let mut serving_units = HashSet::new();
            for serving in &product.servings {
                if !serving_units.insert(serving.unit.0.as_str()) {
                    return Err(CatalogError::Validation(format!(
                        "duplicate serving unit for external product: {}",
                        serving.unit.0
                    )));
                }
            }
        }

        Ok(Self { products })
    }

    pub fn products(&self) -> &[Product] {
        &self.products
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProductUpsertResult {
    /// Parent rows inserted by this call.
    pub created: i64,
    /// Existing products whose stored parent columns changed in this call.
    /// Child-only changes are reported by the corresponding child counters.
    pub updated: i64,
    /// Nutrient rows inserted from the incoming authoritative collections.
    pub nutrients_written: i64,
    /// Serving rows inserted from the incoming authoritative collections.
    pub servings_written: i64,
}

#[async_trait]
pub trait ProductRepo: Send + Sync {
    async fn search_catalog_candidates(
        &self,
        spec: &ProductSearchSpec,
        scope: CatalogSearchScope,
    ) -> Result<Vec<ProductSearchFields>, CatalogError>;
    async fn search_history_candidates(
        &self,
        spec: &ProductSearchSpec,
        user_id: Uuid,
    ) -> Result<Vec<HistorySearchCandidate>, CatalogError>;
    async fn category_counts(&self) -> Result<Vec<CategoryCount>, CatalogError>;
    /// Loads search-result product summaries by ID. The caller owns the
    /// ranked ordering; the returned order is unspecified.
    async fn find_search_summaries(
        &self,
        ids: &[ProductId],
    ) -> Result<Vec<Product>, CatalogError>;
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, CatalogError>;
    async fn existing_ids(&self, ids: &[ProductId]) -> Result<HashSet<ProductId>, CatalogError>;
    async fn find_by_barcode(
        &self,
        barcode: &str,
        user_id: Option<Uuid>,
    ) -> Result<Option<Product>, CatalogError>;
    async fn list_custom_foods(&self) -> Result<Vec<Product>, CatalogError>;
    async fn create(&self, product: &Product) -> Result<(), CatalogError>;
    /// Creates or updates external products identified by `(source, source_id)`.
    ///
    /// Every product is the complete desired aggregate: its nutrients and servings replace the
    /// stored collections, and an empty collection clears the corresponding stored children.
    async fn upsert_external_many(
        &self,
        batch: &ExternalProductBatch,
    ) -> Result<ProductUpsertResult, CatalogError>;
    async fn update(&self, product: &Product) -> Result<(), CatalogError>;
    async fn delete(&self, id: ProductId) -> Result<(), CatalogError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct CatalogPolicy;

impl CatalogPolicy {
    pub fn authorize_view(
        &self,
        _actor_id: Uuid,
        _product: &Product,
    ) -> Result<(), CatalogError> {
        Ok(())
    }

    pub fn authorize_mutation(
        &self,
        actor_id: Uuid,
        product: &Product,
    ) -> Result<(), CatalogError> {
        match product.origin {
            ProductOrigin::External { .. } => Err(CatalogError::Forbidden(
                "system catalog products are read-only".into(),
            )),
            ProductOrigin::Custom { user_id } if user_id != actor_id => Err(
                CatalogError::Forbidden("only the creator may modify this custom food".into()),
            ),
            ProductOrigin::Custom { .. } => Ok(()),
        }
    }
}

#[async_trait]
pub trait NutrientRepo: Send + Sync {
    async fn list_all(&self) -> Result<Vec<Nutrient>, CatalogError>;
    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, CatalogError>;
}

#[async_trait]
pub trait UnitRepo: Send + Sync {
    async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, CatalogError>;
    async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, CatalogError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use rstest::rstest;

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
    fn product_search_scope_parse_rejects_unknown_values() {
        assert!(matches!(
            ProductSearchScope::parse(Some("private")),
            Err(CatalogError::Validation(_))
        ));
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

    fn serving_input(grams_per_unit: Decimal) -> ProductServingInput {
        ProductServingInput {
            unit: "serving".into(),
            grams_per_unit,
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
    fn external_product_creation_rejects_blank_source_id() {
        let blank_source_id = Product::new_external(
            ExternalSource::Off,
            ExternalProductBuilder::new("  ", "Food"),
            &test_catalog(),
        );
        assert!(matches!(
            blank_source_id,
            Err(CatalogError::Validation(_))
        ));
    }

    #[derive(Debug, Clone, Copy)]
    enum CustomProductOperation {
        Create,
        Update,
    }

    #[derive(Debug, Clone, Copy)]
    enum CustomProductMutation {
        BlankName,
        NegativeNutrientAmount,
        ZeroServing,
        MissingRequiredNutrients,
        DuplicateServingUnit,
        DefaultUnitNotConfigured,
        DuplicateNutrientCode,
    }

    impl CustomProductMutation {
        fn apply(self, input: CustomProductBuilder) -> CustomProductBuilder {
            match self {
                Self::BlankName => custom_product_input(" "),
                Self::NegativeNutrientAmount => {
                    input.nutrients(vec![nutrient_input(Decimal::new(-1, 0))])
                }
                Self::ZeroServing => input.servings(vec![serving_input(Decimal::ZERO)]),
                Self::MissingRequiredNutrients => {
                    input.nutrients(vec![nutrient_input(Decimal::new(100, 0))])
                }
                Self::DuplicateServingUnit => input.servings(vec![
                    serving_input(Decimal::new(100, 0)),
                    serving_input(Decimal::new(200, 0)),
                ]),
                Self::DefaultUnitNotConfigured => {
                    input.default_portion(Decimal::new(2, 0), "slice")
                }
                Self::DuplicateNutrientCode => {
                    let mut nutrients = required_nutrient_inputs(Decimal::new(10, 0));
                    nutrients.push(nutrient_input_for("PROTEIN_G", Decimal::new(5, 0)));
                    input.nutrients(nutrients)
                }
            }
        }
    }

    fn custom_product_input(name: &str) -> CustomProductBuilder {
        CustomProductBuilder::new(name)
            .nutrients(required_nutrient_inputs(Decimal::new(10, 0)))
            .servings(vec![serving_input(Decimal::new(100, 0))])
    }

    #[rstest]
    #[case::create_blank_name(
        CustomProductOperation::Create,
        CustomProductMutation::BlankName,
        &["food name is required"],
        None
    )]
    #[case::create_negative_nutrient_amount(
        CustomProductOperation::Create,
        CustomProductMutation::NegativeNutrientAmount,
        &["nutrient amount must be non-negative"],
        None
    )]
    #[case::create_zero_serving(
        CustomProductOperation::Create,
        CustomProductMutation::ZeroServing,
        &["serving grams per unit must be positive"],
        None
    )]
    #[case::create_missing_required_macros(
        CustomProductOperation::Create,
        CustomProductMutation::MissingRequiredNutrients,
        &[
            "custom food is missing required nutrient(s)",
            "PROTEIN_G",
            "CARBS_G",
            "FAT_G",
        ],
        Some("ENERGY_KCAL")
    )]
    #[case::update_missing_required_macros(
        CustomProductOperation::Update,
        CustomProductMutation::MissingRequiredNutrients,
        &[
            "custom food is missing required nutrient(s)",
            "PROTEIN_G",
            "CARBS_G",
            "FAT_G",
        ],
        Some("ENERGY_KCAL")
    )]
    #[case::create_duplicate_serving_unit(
        CustomProductOperation::Create,
        CustomProductMutation::DuplicateServingUnit,
        &["duplicate serving unit: serving"],
        None
    )]
    #[case::create_default_unit_not_configured(
        CustomProductOperation::Create,
        CustomProductMutation::DefaultUnitNotConfigured,
        &["default portion must be grams or use a configured serving unit: slice"],
        None
    )]
    #[case::create_duplicate_nutrient_code(
        CustomProductOperation::Create,
        CustomProductMutation::DuplicateNutrientCode,
        &["duplicate nutrient code: PROTEIN_G"],
        None
    )]
    fn custom_product_rejects_invalid_input(
        #[case] operation: CustomProductOperation,
        #[case] mutation: CustomProductMutation,
        #[case] expected_fragments: &[&str],
        #[case] unexpected_fragment: Option<&str>,
    ) {
        let catalog = test_catalog();
        let user_id = Uuid::new_v4();
        let input = mutation.apply(custom_product_input("Food"));
        let result = match operation {
            CustomProductOperation::Create => Product::new_custom(user_id, input, &catalog),
            CustomProductOperation::Update => {
                let product =
                    Product::new_custom(user_id, custom_product_input("Original"), &catalog)
                        .unwrap();
                product.update_custom(input, &catalog)
            }
        };

        match result {
            Err(CatalogError::Validation(message)) => {
                for expected in expected_fragments {
                    assert!(
                        message.contains(expected),
                        "expected {expected:?} in message: {message}"
                    );
                }
                if let Some(unexpected) = unexpected_fragment {
                    assert!(
                        !message.contains(unexpected),
                        "unexpected {unexpected:?} in message: {message}"
                    );
                }
            }
            other => panic!("expected validation error, got {other:?}"),
        }
    }

    #[test]
    fn custom_product_builder_rejects_half_default_quantity_pair() {
        let missing_unit = CustomProductBuilder::new("Food")
            .optional_default_portion(Some(Decimal::new(1, 0)), None);
        assert!(matches!(missing_unit, Err(CatalogError::Validation(_))));

        let missing_quantity = CustomProductBuilder::new("Food")
            .optional_default_portion(None, Some("serving".into()));
        assert!(matches!(
            missing_quantity,
            Err(CatalogError::Validation(_))
        ));
    }

    #[test]
    fn custom_product_creation_keeps_unknown_code_error_first() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let result = Product::new_custom(
            user_id,
            CustomProductBuilder::new("Food")
                .nutrients(vec![ProductNutrientInput {
                    code: "NOT_A_CODE".into(),
                    amount_per_100g: Decimal::new(10, 0),
                    source: None,
                    confidence: None,
                }])
                .servings(vec![serving_input(Decimal::new(100, 0))]),
            &catalog,
        );
        match result {
            Err(CatalogError::Validation(msg)) => {
                assert!(msg.contains("NOT_A_CODE"), "msg: {msg}");
                assert!(!msg.contains("missing required"), "msg: {msg}");
            }
            other => panic!("expected Validation error, got {other:?}"),
        }
    }

    const PROPERTY_NUTRIENT_CODES: &[&str] = &["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"];
    const PROPERTY_SERVING_UNITS: &[&str] = &["serving", "slice", "piece", "tbsp"];

    fn bounded_arbitrary_string() -> impl Strategy<Value = String> {
        proptest::collection::vec(any::<char>(), 0..=12)
            .prop_map(|chars| chars.into_iter().collect())
    }

    fn alphanumeric_string() -> impl Strategy<Value = String> {
        proptest::collection::vec(
            prop_oneof![
                proptest::char::range('a', 'z'),
                proptest::char::range('A', 'Z'),
                proptest::char::range('0', '9'),
            ],
            1..=8,
        )
        .prop_map(|chars| chars.into_iter().collect())
    }

    fn external_source() -> impl Strategy<Value = ExternalSource> {
        prop_oneof![
            Just(ExternalSource::Off),
            Just(ExternalSource::Usda),
            Just(ExternalSource::Ifct),
            Just(ExternalSource::Indb),
        ]
    }

    fn padded_source_id() -> impl Strategy<Value = String> {
        (
            alphanumeric_string(),
            proptest::collection::vec(prop_oneof![Just(' '), Just('\t')], 0..=2),
        )
            .prop_map(|(base, leading)| {
                let leading: String = leading.into_iter().collect();
                let trailing: String = leading.chars().rev().collect();
                format!("{leading}{base}{trailing}")
            })
    }

    fn nutrient_code_list() -> impl Strategy<Value = Vec<String>> {
        proptest::collection::vec(proptest::sample::select(PROPERTY_NUTRIENT_CODES), 0..=4)
            .prop_map(|codes| {
                let mut unique: Vec<String> = Vec::new();
                for code in codes {
                    if !unique.iter().any(|existing| existing == code) {
                        unique.push(code.to_owned());
                    }
                }
                unique
            })
    }

    fn serving_unit_list() -> impl Strategy<Value = Vec<String>> {
        proptest::collection::vec(proptest::sample::select(PROPERTY_SERVING_UNITS), 0..=4).prop_map(
            |units| {
                let mut unique: Vec<String> = Vec::new();
                for unit in units {
                    if !unique.iter().any(|existing| existing == unit) {
                        unique.push(unit.to_owned());
                    }
                }
                unique
            },
        )
    }

    fn decimal_amount() -> impl Strategy<Value = Decimal> {
        prop_oneof![
            4 => Just(Decimal::ZERO),
            3 => Just(Decimal::new(-1, 12)),
            3 => Just(Decimal::new(1, 12)),
            3 => Just(Decimal::new(-5, 7)),
            3 => Just(Decimal::new(5, 7)),
            16 => (-1_000_000_000i64..=1_000_000_000i64, 0u32..=6)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
            16 => (-1_000_000_000i64..=1_000_000_000i64, 7u32..=12)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
        ]
    }

    fn valid_external_product(
        source: ExternalSource,
        source_id: &str,
        name: &str,
        nutrient_codes: &[String],
        serving_units: &[String],
        catalog: &NutrientCatalog,
    ) -> Product {
        let nutrients = nutrient_codes
            .iter()
            .map(|code| nutrient_input_for(code, Decimal::new(10, 0)))
            .collect();
        let servings = serving_units
            .iter()
            .map(|unit| ProductServingInput {
                unit: unit.clone(),
                grams_per_unit: Decimal::new(100, 0),
            })
            .collect();

        Product::new_external(
            source,
            ExternalProductBuilder::new(source_id, name)
                .nutrients(nutrients)
                .servings(servings),
            catalog,
        )
        .expect("generated external product should be valid")
    }

    #[derive(Debug, Clone, Copy)]
    enum PolicyProductCase {
        CustomOwned,
        CustomForeign,
        External(ExternalSource),
    }

    fn policy_product_case() -> impl Strategy<Value = PolicyProductCase> {
        prop_oneof![
            Just(PolicyProductCase::CustomOwned),
            Just(PolicyProductCase::CustomForeign),
            external_source().prop_map(PolicyProductCase::External),
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        #[test]
        fn category_normalize_list_is_idempotent_and_normalized(
            generated_values in proptest::collection::vec(bounded_arbitrary_string(), 0..=12),
        ) {
            let mut values = generated_values;
            // Guarantee case/padding collisions so deduplication is always exercised.
            values.extend(
                ["Snacks", " snacks ", "SNACKS", " Beverages"]
                    .into_iter()
                    .map(str::to_owned),
            );

            let normalized = Category::normalize_list(values.iter().map(String::as_str));
            let renormalized =
                Category::normalize_list(normalized.iter().map(|category| category.0.as_str()));

            prop_assert_eq!(&renormalized, &normalized);

            let mut distinct_nonblank_inputs: Vec<String> = Vec::new();
            for value in &values {
                let normalized_input = value.trim().to_lowercase();
                if !normalized_input.is_empty()
                    && !distinct_nonblank_inputs.contains(&normalized_input)
                {
                    distinct_nonblank_inputs.push(normalized_input);
                }
            }

            let actual: Vec<String> = normalized
                .iter()
                .map(|category| category.0.clone())
                .collect();
            prop_assert_eq!(actual, distinct_nonblank_inputs);

            let mut seen: Vec<String> = Vec::new();
            for category in &normalized {
                let value = category.0.as_str();
                prop_assert!(!value.is_empty(), "normalized categories must not be blank");
                prop_assert_eq!(value.to_owned(), value.trim().to_owned());
                prop_assert_eq!(value.to_owned(), value.to_lowercase());
                prop_assert!(
                    seen.iter().all(|existing| existing != value),
                    "duplicate normalized category: {value}"
                );
                seen.push(value.to_owned());
            }
        }

        #[test]
        fn amount_per_100g_accepts_exactly_non_negative_values_at_six_places(
            amount in decimal_amount(),
        ) {
            match AmountPer100g::new(amount) {
                Ok(accepted) => {
                    prop_assert!(amount >= Decimal::ZERO);
                    prop_assert!(accepted.value() >= Decimal::ZERO);
                    prop_assert!(accepted.value().scale() <= 6);
                    prop_assert_eq!(accepted.value(), amount.round_dp(6));
                    if amount.scale() <= 6 {
                        prop_assert_eq!(accepted.value(), amount);
                    }
                }
                Err(error) => {
                    prop_assert!(
                        amount < Decimal::ZERO,
                        "only negative amounts should be rejected: amount {amount}, error {error:?}"
                    );
                    prop_assert!(matches!(error, CatalogError::Validation(_)));
                }
            }
        }

        #[test]
        fn external_product_batch_rejects_identities_colliding_after_trimming(
            source in external_source(),
            source_id in padded_source_id(),
            extra_count in 0usize..=3,
        ) {
            let catalog = test_catalog();
            let mut products = vec![
                valid_external_product(source, &source_id, "Food One", &[], &[], &catalog),
                valid_external_product(
                    source,
                    &format!(" \t {source_id} \t "),
                    "Food Two",
                    &[],
                    &[],
                    &catalog,
                ),
            ];
            for index in 0..extra_count {
                products.push(valid_external_product(
                    source,
                    &format!("extra-{source_id}-{index}"),
                    &format!("Extra {index}"),
                    &[],
                    &[],
                    &catalog,
                ));
            }

            let expected_message = format!(
                "duplicate external product identity: ({}, {})",
                source.as_str(),
                source_id.trim()
            );
            match ExternalProductBatch::new(products) {
                Err(CatalogError::Validation(message)) => {
                    prop_assert_eq!(message, expected_message);
                }
                other => prop_assert!(
                    false,
                    "expected duplicate identity validation error, got {other:?}"
                ),
            }
        }

        #[test]
        fn external_product_batch_rejects_duplicate_nutrient_codes(
            source in external_source(),
            nutrient_codes in nutrient_code_list()
                .prop_filter("at least one nutrient", |codes| !codes.is_empty()),
            duplicate_index in 0usize..=3,
            target_position in 0usize..=5,
            suffix in alphanumeric_string(),
            extra_count in 0usize..=4,
        ) {
            let catalog = test_catalog();
            let mut target = valid_external_product(
                source,
                &format!("target-{suffix}"),
                "Target food",
                &nutrient_codes,
                &[],
                &catalog,
            );
            // The public constructor already rejects duplicates. Mutate the aggregate
            // afterwards to exercise the batch's defense-in-depth validation, keeping
            // the code equal while changing the amount.
            let index = duplicate_index % target.nutrients.len();
            let original = target.nutrients[index].clone();
            let duplicated_code = original.nutrient_code.0.clone();
            let mut duplicate = original.clone();
            duplicate.amount_per_100g =
                AmountPer100g::new(duplicate.amount_per_100g.value() + Decimal::new(1, 0))
                    .expect("adjusted duplicate amount should be valid");
            prop_assert_ne!(
                duplicate.amount_per_100g.value(),
                original.amount_per_100g.value()
            );
            target.nutrients.push(duplicate);

            let mut products: Vec<Product> = (0..extra_count)
                .map(|index| {
                    valid_external_product(
                        source,
                        &format!("extra-{suffix}-{index}"),
                        &format!("Extra {index}"),
                        &[],
                        &[],
                        &catalog,
                    )
                })
                .collect();
            let target_position = target_position % (products.len() + 1);
            products.insert(target_position, target);

            let expected_message = format!(
                "duplicate nutrient code for external product: {duplicated_code}"
            );
            match ExternalProductBatch::new(products) {
                Err(CatalogError::Validation(message)) => {
                    prop_assert_eq!(message, expected_message);
                }
                other => prop_assert!(
                    false,
                    "expected duplicate nutrient validation error, got {other:?}"
                ),
            }
        }

        #[test]
        fn external_product_batch_rejects_duplicate_serving_units(
            source in external_source(),
            serving_units in serving_unit_list()
                .prop_filter("at least one serving", |units| !units.is_empty()),
            target_position in 0usize..=5,
            suffix in alphanumeric_string(),
            extra_count in 0usize..=4,
        ) {
            let catalog = test_catalog();
            let mut target = valid_external_product(
                source,
                &format!("target-{suffix}"),
                "Target food",
                &[],
                &serving_units,
                &catalog,
            );
            // As with nutrients, the constructor rejects duplicates; mutate the
            // aggregate to exercise the batch's defense-in-depth validation, keeping
            // the unit equal while changing the grams per unit.
            let original = target.servings[0].clone();
            let duplicated_unit = original.unit.0.clone();
            let mut duplicate = original.clone();
            duplicate.grams_per_unit += Decimal::new(1, 0);
            prop_assert_ne!(duplicate.grams_per_unit, original.grams_per_unit);
            target.servings.push(duplicate);

            let mut products: Vec<Product> = (0..extra_count)
                .map(|index| {
                    valid_external_product(
                        source,
                        &format!("extra-{suffix}-{index}"),
                        &format!("Extra {index}"),
                        &[],
                        &[],
                        &catalog,
                    )
                })
                .collect();
            let target_position = target_position % (products.len() + 1);
            products.insert(target_position, target);

            let expected_message =
                format!("duplicate serving unit for external product: {duplicated_unit}");
            match ExternalProductBatch::new(products) {
                Err(CatalogError::Validation(message)) => {
                    prop_assert_eq!(message, expected_message);
                }
                other => prop_assert!(
                    false,
                    "expected duplicate serving validation error, got {other:?}"
                ),
            }
        }

        #[test]
        fn external_product_batch_accepts_valid_products_and_preserves_order(
            product_count in 0usize..=5,
            prefix in alphanumeric_string(),
            nutrient_codes in nutrient_code_list(),
            serving_units in serving_unit_list(),
        ) {
            let catalog = test_catalog();
            // Reverse the generated order so a sort by name or source ID cannot
            // accidentally satisfy the order-preservation assertion.
            let mut products: Vec<Product> = (0..product_count)
                .map(|index| {
                    valid_external_product(
                        ExternalSource::Off,
                        &format!("{prefix}-{index}"),
                        &format!("Food {index}"),
                        &nutrient_codes,
                        &serving_units,
                        &catalog,
                    )
                })
                .collect();
            products.reverse();
            let expected: Vec<(Uuid, String)> = products
                .iter()
                .map(|product| (product.id.0, product.name.as_str().to_owned()))
                .collect();

            let batch = ExternalProductBatch::new(products)
                .expect("generated batch with unique identities should be accepted");
            let actual: Vec<(Uuid, String)> = batch
                .products()
                .iter()
                .map(|product| (product.id.0, product.name.as_str().to_owned()))
                .collect();

            prop_assert_eq!(actual, expected);
        }

        #[test]
        fn catalog_policy_allows_every_view_and_only_owner_custom_mutations(
            case in policy_product_case(),
            actor_bits in any::<u128>(),
        ) {
            let catalog = test_catalog();
            let actor = Uuid::from_u128(actor_bits);
            let (product, mutation_allowed) = match case {
                PolicyProductCase::CustomOwned => (
                    Product::new_custom(actor, custom_product_input("Owned food"), &catalog)
                        .expect("generated custom product should be valid"),
                    true,
                ),
                PolicyProductCase::CustomForeign => (
                    Product::new_custom(
                        Uuid::from_u128(actor_bits ^ 1),
                        custom_product_input("Foreign food"),
                        &catalog,
                    )
                    .expect("generated custom product should be valid"),
                    false,
                ),
                PolicyProductCase::External(source) => (
                    valid_external_product(
                        source,
                        &format!("external-{}", source.as_str().to_lowercase()),
                        &format!("External {} food", source.as_str()),
                        &[],
                        &[],
                        &catalog,
                    ),
                    false,
                ),
            };

            prop_assert!(
                CatalogPolicy.authorize_view(actor, &product).is_ok(),
                "every product should be viewable"
            );
            let mutation = CatalogPolicy.authorize_mutation(actor, &product);
            if mutation_allowed {
                prop_assert!(
                    mutation.is_ok(),
                    "owner should be allowed to mutate their custom product: {mutation:?}"
                );
            } else {
                let expected_message = match case {
                    PolicyProductCase::CustomForeign => {
                        "only the creator may modify this custom food"
                    }
                    PolicyProductCase::External(_) => "system catalog products are read-only",
                    PolicyProductCase::CustomOwned => {
                        unreachable!("owned custom products are allowed to mutate")
                    }
                };
                match mutation {
                    Err(CatalogError::Forbidden(message)) => {
                        prop_assert_eq!(message, expected_message.to_owned());
                    }
                    other => prop_assert!(
                        false,
                        "expected forbidden mutation error, got {other:?}"
                    ),
                }
            }
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        // High-value: branch selection across mass, configured serving, and unknown units.
        #[test]
        fn product_quantity_to_grams_branch_selection(
            amount in 1i64..=1000i64,
            mass_factor in 1i64..=100i64,
            serving_grams in 1i64..=100i64,
        ) {
            let amount = Decimal::from(amount);
            let uc = UnitConverter::from_entries([("g".to_string(), Decimal::from(mass_factor))]);
            let product = Product {
                id: ProductId(Uuid::new_v4()),
                origin: ProductOrigin::Custom { user_id: Uuid::nil() },
                visibility: ProductVisibility::Global,
                name: ProductName::new("Food").unwrap(),
                brand: None,
                categories: vec![],
                default_quantity: None,
                default_unit: None,
                nutrients: vec![],
                servings: vec![ProductServing {
                    unit: UnitCode("serving".into()),
                    grams_per_unit: Decimal::from(serving_grams),
                }],
                created_at: Utc::now(),
                updated_at: Utc::now(),
            };

            let mass_qty = Quantity::new(amount, UnitCode("g".into())).unwrap();
            prop_assert_eq!(
                product.quantity_to_grams(&mass_qty, &uc).unwrap(),
                amount * Decimal::from(mass_factor)
            );

            let serving_qty = Quantity::new(amount, UnitCode("serving".into())).unwrap();
            prop_assert_eq!(
                product.quantity_to_grams(&serving_qty, &uc).unwrap(),
                amount * Decimal::from(serving_grams)
            );

            let unknown_qty = Quantity::new(amount, UnitCode("unknown".into())).unwrap();
            prop_assert!(product.quantity_to_grams(&unknown_qty, &uc).is_err());
        }
    }
}

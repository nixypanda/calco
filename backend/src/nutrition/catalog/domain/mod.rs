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
    pub fn new(value: impl Into<String>) -> Result<Self, NutritionError> {
        let value = value.into().trim().to_owned();
        if value.is_empty() {
            return Err(NutritionError::Validation(
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
                if unit != "g" && !servings.iter().any(|serving| serving.unit.0 == unit) {
                    return Err(NutritionError::Validation(format!(
                        "default portion must be grams or use a configured serving unit: {unit}"
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
    ) -> Result<Self, NutritionError> {
        match (amount, unit) {
            (None, None) => Ok(self),
            (Some(amount), Some(unit)) => Ok(self.default_portion(amount, unit)),
            _ => Err(NutritionError::Validation(
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
    ) -> Result<Self, NutritionError> {
        match (amount, unit) {
            (None, None) => Ok(self),
            (Some(amount), Some(unit)) => Ok(self.default_portion(amount, unit)),
            _ => Err(NutritionError::Validation(
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
    ) -> Result<Self, NutritionError> {
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
    ) -> Result<Self, NutritionError> {
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
    ) -> Result<Self, NutritionError> {
        if !matches!(self.origin, ProductOrigin::Custom { .. }) {
            return Err(NutritionError::Validation(
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
    ) -> Result<(), NutritionError> {
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
) -> Result<ValidatedCustomFood, NutritionError> {
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
    pub fn validate_grams_per_unit(grams_per_unit: Decimal) -> Result<(), NutritionError> {
        if grams_per_unit <= Decimal::ZERO {
            return Err(NutritionError::Validation(
                "serving grams per unit must be positive".into(),
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
            ProductServing::validate_grams_per_unit(serving.grams_per_unit)?;
            if !seen_units.insert(serving.unit.clone()) {
                return Err(NutritionError::Validation(format!(
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

pub use crate::nutrition::error::NutritionError;

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
    pub fn new(products: Vec<Product>) -> Result<Self, NutritionError> {
        let mut identities = HashSet::new();

        for product in &products {
            let Some((source, source_id)) = product.origin.external_identity() else {
                return Err(NutritionError::Validation(
                    "external product batch cannot contain custom products".into(),
                ));
            };
            if !identities.insert((source, source_id)) {
                return Err(NutritionError::Validation(format!(
                    "duplicate external product identity: ({}, {})",
                    source.as_str(),
                    source_id.as_str()
                )));
            }

            let mut nutrient_codes = HashSet::new();
            for nutrient in &product.nutrients {
                if !nutrient_codes.insert(nutrient.nutrient_code.0.as_str()) {
                    return Err(NutritionError::Validation(format!(
                        "duplicate nutrient code for external product: {}",
                        nutrient.nutrient_code.0
                    )));
                }
            }

            let mut serving_units = HashSet::new();
            for serving in &product.servings {
                if !serving_units.insert(serving.unit.0.as_str()) {
                    return Err(NutritionError::Validation(format!(
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
    /// Creates or updates external products identified by `(source, source_id)`.
    ///
    /// Every product is the complete desired aggregate: its nutrients and servings replace the
    /// stored collections, and an empty collection clears the corresponding stored children.
    async fn upsert_external_many(
        &self,
        batch: &ExternalProductBatch,
    ) -> Result<ProductUpsertResult, NutritionError>;
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
        match product.origin {
            ProductOrigin::External { .. } => Err(NutritionError::Forbidden(
                "system catalog products are read-only".into(),
            )),
            ProductOrigin::Custom { user_id } if user_id != actor_id => Err(
                NutritionError::Forbidden("only the creator may modify this custom food".into()),
            ),
            ProductOrigin::Custom { .. } => Ok(()),
        }
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
    fn external_product_creation_normalizes_blank_barcode_to_none() {
        let product = Product::new_external(
            ExternalSource::Off,
            ExternalProductBuilder::new("source-id", "Food").barcode(Some("  ".into())),
            &test_catalog(),
        )
        .unwrap();

        assert_eq!(product.origin.barcode(), None);
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
            Err(NutritionError::Validation(_))
        ));
    }

    #[test]
    fn custom_product_creation_rejects_invalid_values() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();

        assert!(
            Product::new_custom(
                user_id,
                CustomProductBuilder::new(" ")
                    .nutrients(vec![nutrient_input(Decimal::ZERO)])
                    .servings(vec![serving_input(Decimal::new(100, 0))]),
                &catalog,
            )
            .is_err()
        );

        assert!(
            Product::new_custom(
                user_id,
                CustomProductBuilder::new("Food")
                    .nutrients(vec![nutrient_input(Decimal::new(-1, 0))])
                    .servings(vec![serving_input(Decimal::new(100, 0))]),
                &catalog,
            )
            .is_err()
        );

        assert!(
            Product::new_custom(
                user_id,
                CustomProductBuilder::new("Food")
                    .nutrients(vec![nutrient_input(Decimal::ZERO)])
                    .servings(vec![serving_input(Decimal::ZERO)]),
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
    fn custom_product_creation_rejects_missing_required_macros() {
        let user_id = Uuid::new_v4();
        let catalog = test_catalog();
        let result = Product::new_custom(
            user_id,
            CustomProductBuilder::new("Food")
                .nutrients(vec![nutrient_input(Decimal::new(100, 0))])
                .servings(vec![serving_input(Decimal::new(100, 0))]),
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
            CustomProductBuilder::new("Original")
                .nutrients(required_nutrient_inputs(Decimal::new(100, 0)))
                .servings(vec![serving_input(Decimal::new(100, 0))]),
            &catalog,
        )
        .unwrap();

        let input = CustomProductBuilder::new("Updated")
            .nutrients(vec![nutrient_input(Decimal::new(200, 0))])
            .servings(vec![serving_input(Decimal::new(100, 0))]);
        let result = product.update_custom(input, &catalog);
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
            CustomProductBuilder::new("Food")
                .nutrients(required_nutrient_inputs(Decimal::new(10, 0)))
                .servings(vec![
                    serving_input(Decimal::new(100, 0)),
                    serving_input(Decimal::new(200, 0)),
                ]),
            &catalog,
        );
        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[test]
    fn custom_product_builder_rejects_half_default_quantity_pair() {
        let missing_unit = CustomProductBuilder::new("Food")
            .optional_default_portion(Some(Decimal::new(1, 0)), None);
        assert!(matches!(missing_unit, Err(NutritionError::Validation(_))));

        let missing_quantity = CustomProductBuilder::new("Food")
            .optional_default_portion(None, Some("serving".into()));
        assert!(matches!(
            missing_quantity,
            Err(NutritionError::Validation(_))
        ));
    }

    #[test]
    fn custom_product_creation_rejects_default_with_unconfigured_serving_unit() {
        let catalog = test_catalog();
        let result = Product::new_custom(
            Uuid::new_v4(),
            CustomProductBuilder::new("Food")
                .default_portion(Decimal::new(2, 0), "slice")
                .nutrients(required_nutrient_inputs(Decimal::new(10, 0)))
                .servings(vec![serving_input(Decimal::new(100, 0))]),
            &catalog,
        );
        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[test]
    fn custom_product_creation_accepts_arbitrary_default_quantity_for_serving_unit() {
        let catalog = test_catalog();
        let product = Product::new_custom(
            Uuid::new_v4(),
            CustomProductBuilder::new("Food")
                .default_portion(Decimal::new(3, 0), "serving")
                .nutrients(required_nutrient_inputs(Decimal::new(10, 0)))
                .servings(vec![serving_input(Decimal::new(100, 0))]),
            &catalog,
        )
        .unwrap();
        assert_eq!(product.default_quantity, Some(Decimal::new(3, 0)));
        assert_eq!(product.default_unit.unwrap().0, "serving");
    }

    #[test]
    fn quantity_to_grams_multiplies_amount_by_grams_per_unit() {
        let product = Product::new_custom(
            Uuid::new_v4(),
            CustomProductBuilder::new("Food")
                .nutrients(required_nutrient_inputs(Decimal::new(10, 0)))
                .servings(vec![serving_input(Decimal::new(14, 0))]),
            &test_catalog(),
        )
        .unwrap();
        let quantity = Quantity::new(Decimal::new(3, 0), UnitCode("serving".into())).unwrap();
        let converter = UnitConverter::from_entries([]);

        assert_eq!(
            product.quantity_to_grams(&quantity, &converter),
            Ok(Decimal::new(42, 0))
        );
    }

    #[test]
    fn custom_product_creation_rejects_duplicate_nutrient_codes() {
        let catalog = test_catalog();
        let mut nutrients = required_nutrient_inputs(Decimal::new(10, 0));
        nutrients.push(nutrient_input_for("PROTEIN_G", Decimal::new(5, 0)));

        let result = Product::new_custom(
            Uuid::new_v4(),
            CustomProductBuilder::new("Food")
                .nutrients(nutrients)
                .servings(vec![serving_input(Decimal::new(100, 0))]),
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
            CustomProductBuilder::new("Shared food")
                .nutrients(required_nutrient_inputs(Decimal::new(10, 0))),
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
        let product = Product::new_external(
            ExternalSource::Off,
            ExternalProductBuilder::new("imported-food", "Imported food"),
            &test_catalog(),
        )
        .unwrap();

        assert!(matches!(
            CatalogPolicy.authorize_mutation(actor, &product),
            Err(NutritionError::Forbidden(_))
        ));
    }
}

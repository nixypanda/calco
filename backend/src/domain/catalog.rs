use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

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
    pub fn new(code: NutrientCode, name: String, unit: UnitCode, category: String) -> Self {
        Self(code, name, unit, category)
    }

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

impl NutrientCode {
    pub fn new(s: String) -> Self {
        Self(s)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitCode(pub String);

impl UnitCode {
    pub fn new(s: String) -> Self {
        Self(s)
    }
}

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
    pub category: Option<Category>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<UnitCode>,
    pub serving_size_g: Option<Decimal>,
    pub nutrients: Vec<ProductNutrient>,
    pub servings: Vec<ProductServing>,
    pub deleted_at: Option<DateTime<Utc>>,
}

impl Product {
    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == Some(user_id)
    }

    pub fn mark_deleted(&mut self) {
        self.deleted_at = Some(Utc::now());
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
pub struct ProductServing {
    pub label: ServingLabel,
    pub quantity: Decimal,
    pub unit: UnitCode,
    pub grams: Decimal,
}

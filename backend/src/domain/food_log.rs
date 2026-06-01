use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::str::FromStr;
use uuid::Uuid;

use super::catalog::{NutrientCode, Product, ProductId, UnitCode};
use super::meal::{Meal, MealId};
use super::nutrition::{CalculatedNutrition, Quantity};
use super::units::UnitConverter;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FoodLogId(pub Uuid);

impl Default for FoodLogId {
    fn default() -> Self {
        Self::new()
    }
}

impl FoodLogId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl From<Uuid> for FoodLogId {
    fn from(id: Uuid) -> Self {
        Self(id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MealSlot {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
}

impl MealSlot {
    pub fn as_str(&self) -> &'static str {
        match self {
            MealSlot::Breakfast => "breakfast",
            MealSlot::Lunch => "lunch",
            MealSlot::Dinner => "dinner",
            MealSlot::Snack => "snack",
        }
    }
}

impl FromStr for MealSlot {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "breakfast" => Ok(MealSlot::Breakfast),
            "lunch" => Ok(MealSlot::Lunch),
            "dinner" => Ok(MealSlot::Dinner),
            "snack" => Ok(MealSlot::Snack),
            _ => Err(format!("invalid meal slot: {s}")),
        }
    }
}

#[derive(Debug, Clone)]
pub enum LoggedItem {
    Product(ProductId),
    Meal(MealId),
}

#[derive(Debug, Clone)]
pub struct FoodLogNutrientSnapshot {
    pub nutrient_code: NutrientCode,
    pub amount: Decimal,
    pub unit: UnitCode,
}

#[derive(Debug, Clone)]
pub struct FoodLog {
    pub id: FoodLogId,
    pub user_id: Uuid,
    pub logged_at: DateTime<Utc>,
    pub meal_slot: Option<MealSlot>,
    pub item: LoggedItem,
    pub quantity_amount: Decimal,
    pub quantity_unit: UnitCode,
    pub nutrient_snapshots: Vec<FoodLogNutrientSnapshot>,
    pub notes: Option<String>,
}

impl FoodLog {
    pub fn new_product_log(
        user_id: Uuid,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        product: &Product,
        quantity: Quantity,
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, FoodLogError> {
        let nutrition = product
            .nutrition_for(&quantity, unit_converter)
            .map_err(FoodLogError::Validation)?;
        Ok(Self::new(
            user_id,
            logged_at,
            meal_slot,
            LoggedItem::Product(product.id),
            quantity,
            nutrition,
            notes,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_meal_log(
        user_id: Uuid,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        meal: &Meal,
        quantity: Quantity,
        products: &[(ProductId, Product)],
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, FoodLogError> {
        let nutrition = meal
            .nutrition_for(&quantity, products, unit_converter)
            .map_err(FoodLogError::Validation)?;
        Ok(Self::new(
            user_id,
            logged_at,
            meal_slot,
            LoggedItem::Meal(meal.id),
            quantity,
            nutrition,
            notes,
        ))
    }

    pub fn update_product_log(
        &self,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        product: &Product,
        quantity: Quantity,
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, FoodLogError> {
        let nutrition = product
            .nutrition_for(&quantity, unit_converter)
            .map_err(FoodLogError::Validation)?;
        Ok(self.update(
            logged_at,
            meal_slot,
            LoggedItem::Product(product.id),
            quantity,
            nutrition,
            notes,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_meal_log(
        &self,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        meal: &Meal,
        quantity: Quantity,
        products: &[(ProductId, Product)],
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, FoodLogError> {
        let nutrition = meal
            .nutrition_for(&quantity, products, unit_converter)
            .map_err(FoodLogError::Validation)?;
        Ok(self.update(
            logged_at,
            meal_slot,
            LoggedItem::Meal(meal.id),
            quantity,
            nutrition,
            notes,
        ))
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
    }

    fn new(
        user_id: Uuid,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        item: LoggedItem,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        Self {
            id: FoodLogId::new(),
            user_id,
            logged_at,
            meal_slot,
            item,
            quantity_amount: quantity.amount,
            quantity_unit: quantity.unit,
            nutrient_snapshots: snapshots_from_calculated(nutrition),
            notes,
        }
    }

    fn update(
        &self,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        item: LoggedItem,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        Self {
            id: self.id,
            user_id: self.user_id,
            logged_at,
            meal_slot,
            item,
            quantity_amount: quantity.amount,
            quantity_unit: quantity.unit,
            nutrient_snapshots: snapshots_from_calculated(nutrition),
            notes,
        }
    }
}

fn snapshots_from_calculated(nutrition: CalculatedNutrition) -> Vec<FoodLogNutrientSnapshot> {
    nutrition
        .amounts
        .into_iter()
        .map(|amount| FoodLogNutrientSnapshot {
            nutrient_code: amount.nutrient_code,
            amount: amount.amount,
            unit: amount.unit,
        })
        .collect()
}

#[derive(Debug, thiserror::Error)]
pub enum FoodLogError {
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

impl From<super::catalog::CatalogError> for FoodLogError {
    fn from(e: super::catalog::CatalogError) -> Self {
        match e {
            super::catalog::CatalogError::NotFound(msg) => FoodLogError::NotFound(msg),
            super::catalog::CatalogError::Forbidden(msg) => FoodLogError::Forbidden(msg),
            super::catalog::CatalogError::Validation(msg) => FoodLogError::Validation(msg),
            super::catalog::CatalogError::Database(err) => FoodLogError::Database(err),
            super::catalog::CatalogError::Internal(msg) => FoodLogError::Internal(msg),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SummaryEntry {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[async_trait]
pub trait FoodLogRepository: Send + Sync {
    async fn create(&self, log: &FoodLog) -> Result<(), FoodLogError>;
    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, FoodLogError>;
    async fn find_by_user_and_range(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<FoodLog>, FoodLogError>;
    async fn update(&self, log: &FoodLog) -> Result<(), FoodLogError>;
    async fn delete(&self, id: FoodLogId) -> Result<(), FoodLogError>;
}

#[async_trait]
pub trait ProductLookup: Send + Sync {
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, FoodLogError>;
}

#[async_trait]
pub trait MealLookup: Send + Sync {
    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, FoodLogError>;
}

#[async_trait]
pub trait SummaryRepository: Send + Sync {
    async fn get_summary(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        codes: Option<Vec<String>>,
    ) -> Result<Vec<SummaryEntry>, FoodLogError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::catalog::{
        AmountPer100g, ProductName, ProductNutrient, ProductVisibility, Source,
    };
    use crate::domain::meal::{MealComponent, MealComponentItem};
    use crate::domain::nutrition::Quantity;
    use std::str::FromStr;

    fn sample_product() -> Product {
        Product {
            id: ProductId(Uuid::nil()),
            source: Source::User,
            source_id: None,
            user_id: None,
            visibility: ProductVisibility::UserPrivate,
            barcode: None,
            name: ProductName("Test".into()),
            brand: None,
            categories: vec![],
            default_quantity: None,
            default_unit: None,
            serving_size_g: None,
            nutrients: vec![ProductNutrient {
                nutrient_code: NutrientCode("ENERGY_KCAL".to_string()),
                amount_per_100g: AmountPer100g(Decimal::new(250, 0)),
                unit: UnitCode("kcal".to_string()),
                source: None,
                confidence: None,
            }],
            servings: vec![],
        }
    }

    fn sample_meal() -> Meal {
        Meal {
            id: MealId(Uuid::nil()),
            user_id: Uuid::nil(),
            name: crate::domain::meal::MealName("Test".into()),
            notes: None,
            total_quantity_amount: Some(Decimal::new(100, 0)),
            total_quantity_unit: Some(UnitCode("g".into())),
            components: vec![MealComponent {
                id: Uuid::new_v4(),
                item: MealComponentItem::Product(ProductId(Uuid::nil())),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: UnitCode("g".into()),
            }],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn sample_unit_converter() -> UnitConverter {
        UnitConverter::from_entries([
            ("g".to_string(), Decimal::from(1)),
            ("kg".to_string(), Decimal::from(1000)),
            ("mg".to_string(), Decimal::from_str("0.001").unwrap()),
        ])
    }

    #[test]
    fn test_meal_slot_roundtrip() {
        let variants = [
            (MealSlot::Breakfast, "breakfast"),
            (MealSlot::Lunch, "lunch"),
            (MealSlot::Dinner, "dinner"),
            (MealSlot::Snack, "snack"),
        ];
        for (slot, expected_str) in &variants {
            assert_eq!(slot.as_str(), *expected_str);
            assert_eq!(expected_str.parse::<MealSlot>().unwrap(), *slot);
        }
    }

    #[test]
    fn test_meal_slot_from_str_invalid() {
        assert!("brunch".parse::<MealSlot>().is_err());
        assert!("".parse::<MealSlot>().is_err());
        assert!("LUNCH".parse::<MealSlot>().is_err());
    }

    #[test]
    fn product_log_construction_sets_item_quantity_and_snapshots() {
        let product = sample_product();
        let converter = sample_unit_converter();
        let log = FoodLog::new_product_log(
            Uuid::new_v4(),
            Utc::now(),
            Some(MealSlot::Breakfast),
            &product,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())),
            &converter,
            Some("notes".into()),
        )
        .unwrap();

        match log.item {
            LoggedItem::Product(id) => assert_eq!(id, product.id),
            LoggedItem::Meal(_) => panic!("expected product item"),
        }
        assert_eq!(log.quantity_amount, Decimal::new(100, 0));
        assert_eq!(log.quantity_unit.0, "g");
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(250, 0));
        assert_eq!(log.notes.as_deref(), Some("notes"));
    }

    #[test]
    fn meal_log_construction_sets_item_quantity_and_snapshots() {
        let product = sample_product();
        let meal = sample_meal();
        let converter = sample_unit_converter();
        let log = FoodLog::new_meal_log(
            Uuid::new_v4(),
            Utc::now(),
            Some(MealSlot::Dinner),
            &meal,
            Quantity::new(Decimal::new(50, 0), UnitCode("g".into())),
            &[(product.id, product.clone())],
            &converter,
            None,
        )
        .unwrap();

        match log.item {
            LoggedItem::Meal(id) => assert_eq!(id, meal.id),
            LoggedItem::Product(_) => panic!("expected meal item"),
        }
        assert_eq!(log.quantity_amount, Decimal::new(50, 0));
        // meal scaled to 50g of 100g = 0.5x → 250 kcal/100g * 100g comp / 100 = 250, scaled by 0.5 = 125
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(125, 0));
        assert!(log.notes.is_none());
    }

    #[test]
    fn update_product_log_preserves_identity_and_replaces_editable_fields() {
        let user_id = Uuid::new_v4();
        let product = sample_product();
        let meal = sample_meal();
        let converter = sample_unit_converter();
        let original = FoodLog::new_meal_log(
            user_id,
            Utc::now(),
            Some(MealSlot::Lunch),
            &meal,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())),
            &[(product.id, product.clone())],
            &converter,
            None,
        )
        .unwrap();
        let original_id = original.id;
        let logged_at = Utc::now();

        let updated = original
            .update_product_log(
                logged_at,
                Some(MealSlot::Snack),
                &product,
                Quantity::new(Decimal::new(50, 0), UnitCode("g".into())),
                &converter,
                Some("updated".into()),
            )
            .unwrap();

        assert_eq!(updated.id, original_id);
        assert_eq!(updated.user_id, user_id);
        assert_eq!(updated.logged_at, logged_at);
        assert_eq!(updated.meal_slot, Some(MealSlot::Snack));
        match updated.item {
            LoggedItem::Product(id) => assert_eq!(id, product.id),
            LoggedItem::Meal(_) => panic!("expected product item"),
        }
        assert_eq!(updated.quantity_amount, Decimal::new(50, 0));
        // 250 kcal/100g * 50g / 100 = 125
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(125, 0));
        assert_eq!(updated.notes.as_deref(), Some("updated"));
    }

    #[test]
    fn update_meal_log_preserves_identity_and_replaces_editable_fields() {
        let user_id = Uuid::new_v4();
        let product = sample_product();
        let meal = sample_meal();
        let converter = sample_unit_converter();
        let original = FoodLog::new_product_log(
            user_id,
            Utc::now(),
            None,
            &product,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())),
            &converter,
            None,
        )
        .unwrap();
        let original_id = original.id;
        let logged_at = Utc::now();

        let updated = original
            .update_meal_log(
                logged_at,
                Some(MealSlot::Dinner),
                &meal,
                Quantity::new(Decimal::new(50, 0), UnitCode("g".into())),
                &[(product.id, product.clone())],
                &converter,
                None,
            )
            .unwrap();

        assert_eq!(updated.id, original_id);
        assert_eq!(updated.user_id, user_id);
        assert_eq!(updated.logged_at, logged_at);
        assert_eq!(updated.meal_slot, Some(MealSlot::Dinner));
        match updated.item {
            LoggedItem::Meal(id) => assert_eq!(id, meal.id),
            LoggedItem::Product(_) => panic!("expected meal item"),
        }
        assert_eq!(updated.quantity_amount, Decimal::new(50, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(125, 0));
        assert!(updated.notes.is_none());
    }
}

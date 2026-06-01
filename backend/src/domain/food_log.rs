use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use super::catalog::{NutrientCode, Product, ProductId, UnitCode};
use super::meal::{Meal, MealId};
use super::nutrition::{CalculatedNutrition, Quantity};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FoodLogId(pub Uuid);

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

    pub fn from_str(s: &str) -> Result<Self, String> {
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
        product_id: ProductId,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        Self::new(
            user_id,
            logged_at,
            meal_slot,
            LoggedItem::Product(product_id),
            quantity,
            nutrition,
            notes,
        )
    }

    pub fn new_meal_log(
        user_id: Uuid,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        meal_id: MealId,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        Self::new(
            user_id,
            logged_at,
            meal_slot,
            LoggedItem::Meal(meal_id),
            quantity,
            nutrition,
            notes,
        )
    }

    pub fn update_product_log(
        &self,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        product_id: ProductId,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        self.update(
            logged_at,
            meal_slot,
            LoggedItem::Product(product_id),
            quantity,
            nutrition,
            notes,
        )
    }

    pub fn update_meal_log(
        &self,
        logged_at: DateTime<Utc>,
        meal_slot: Option<MealSlot>,
        meal_id: MealId,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        self.update(
            logged_at,
            meal_slot,
            LoggedItem::Meal(meal_id),
            quantity,
            nutrition,
            notes,
        )
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
    use crate::domain::nutrition::{CalculatedNutrition, NutrientAmount, Quantity};

    fn sample_nutrition(amount: Decimal) -> CalculatedNutrition {
        CalculatedNutrition {
            amounts: vec![NutrientAmount {
                nutrient_code: NutrientCode("ENERGY_KCAL".to_string()),
                amount,
                unit: UnitCode("kcal".to_string()),
            }],
        }
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
            assert_eq!(MealSlot::from_str(expected_str).unwrap(), *slot);
        }
    }

    #[test]
    fn test_meal_slot_from_str_invalid() {
        assert!(MealSlot::from_str("brunch").is_err());
        assert!(MealSlot::from_str("").is_err());
        assert!(MealSlot::from_str("LUNCH").is_err());
    }

    #[test]
    fn test_food_log_id_generates_unique_ids() {
        let id1 = FoodLogId::new();
        let id2 = FoodLogId::new();
        assert_ne!(id1, id2);
    }

    #[test]
    fn test_food_log_id_from_uuid() {
        let uuid = Uuid::new_v4();
        let id = FoodLogId::from(uuid);
        assert_eq!(id.0, uuid);
    }

    #[test]
    fn test_food_log_is_owned_by() {
        let user_a = Uuid::new_v4();
        let user_b = Uuid::new_v4();
        let log = FoodLog {
            id: FoodLogId::new(),
            user_id: user_a,
            logged_at: Utc::now(),
            meal_slot: Some(MealSlot::Lunch),
            item: LoggedItem::Product(ProductId(Uuid::new_v4())),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: UnitCode("g".to_string()),
            nutrient_snapshots: vec![],
            notes: None,
        };
        assert!(log.is_owned_by(user_a));
        assert!(!log.is_owned_by(user_b));
    }

    #[test]
    fn test_food_log_nutrient_snapshot() {
        let snap = FoodLogNutrientSnapshot {
            nutrient_code: NutrientCode("ENERGY_KCAL".to_string()),
            amount: Decimal::new(250, 0),
            unit: UnitCode("kcal".to_string()),
        };
        assert_eq!(snap.nutrient_code.0, "ENERGY_KCAL");
        assert_eq!(snap.amount, Decimal::new(250, 0));
        assert_eq!(snap.unit.0, "kcal");
    }

    #[test]
    fn product_log_construction_sets_item_quantity_and_snapshots() {
        let product_id = ProductId(Uuid::new_v4());
        let log = FoodLog::new_product_log(
            Uuid::new_v4(),
            Utc::now(),
            Some(MealSlot::Breakfast),
            product_id,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())),
            sample_nutrition(Decimal::new(250, 0)),
            Some("notes".into()),
        );

        match log.item {
            LoggedItem::Product(id) => assert_eq!(id, product_id),
            LoggedItem::Meal(_) => panic!("expected product item"),
        }
        assert_eq!(log.quantity_amount, Decimal::new(100, 0));
        assert_eq!(log.quantity_unit.0, "g");
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(250, 0));
        assert_eq!(log.notes.as_deref(), Some("notes"));
    }

    #[test]
    fn meal_log_construction_sets_item_quantity_and_snapshots() {
        let meal_id = MealId(Uuid::new_v4());
        let log = FoodLog::new_meal_log(
            Uuid::new_v4(),
            Utc::now(),
            Some(MealSlot::Dinner),
            meal_id,
            Quantity::new(Decimal::new(1, 0), UnitCode("serving".into())),
            sample_nutrition(Decimal::new(500, 0)),
            None,
        );

        match log.item {
            LoggedItem::Meal(id) => assert_eq!(id, meal_id),
            LoggedItem::Product(_) => panic!("expected meal item"),
        }
        assert_eq!(log.quantity_amount, Decimal::new(1, 0));
        assert_eq!(log.quantity_unit.0, "serving");
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(500, 0));
        assert!(log.notes.is_none());
    }

    #[test]
    fn update_product_log_preserves_identity_and_replaces_editable_fields() {
        let user_id = Uuid::new_v4();
        let original = FoodLog::new_meal_log(
            user_id,
            Utc::now(),
            Some(MealSlot::Lunch),
            MealId(Uuid::new_v4()),
            Quantity::new(Decimal::new(1, 0), UnitCode("serving".into())),
            sample_nutrition(Decimal::new(300, 0)),
            None,
        );
        let original_id = original.id;
        let product_id = ProductId(Uuid::new_v4());
        let logged_at = Utc::now();

        let updated = original.update_product_log(
            logged_at,
            Some(MealSlot::Snack),
            product_id,
            Quantity::new(Decimal::new(50, 0), UnitCode("g".into())),
            sample_nutrition(Decimal::new(100, 0)),
            Some("updated".into()),
        );

        assert_eq!(updated.id, original_id);
        assert_eq!(updated.user_id, user_id);
        assert_eq!(updated.logged_at, logged_at);
        assert_eq!(updated.meal_slot, Some(MealSlot::Snack));
        match updated.item {
            LoggedItem::Product(id) => assert_eq!(id, product_id),
            LoggedItem::Meal(_) => panic!("expected product item"),
        }
        assert_eq!(updated.quantity_amount, Decimal::new(50, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(100, 0));
        assert_eq!(updated.notes.as_deref(), Some("updated"));
    }

    #[test]
    fn update_meal_log_preserves_identity_and_replaces_editable_fields() {
        let user_id = Uuid::new_v4();
        let original = FoodLog::new_product_log(
            user_id,
            Utc::now(),
            None,
            ProductId(Uuid::new_v4()),
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())),
            sample_nutrition(Decimal::new(300, 0)),
            None,
        );
        let original_id = original.id;
        let meal_id = MealId(Uuid::new_v4());
        let logged_at = Utc::now();

        let updated = original.update_meal_log(
            logged_at,
            Some(MealSlot::Dinner),
            meal_id,
            Quantity::new(Decimal::new(2, 0), UnitCode("serving".into())),
            sample_nutrition(Decimal::new(800, 0)),
            None,
        );

        assert_eq!(updated.id, original_id);
        assert_eq!(updated.user_id, user_id);
        assert_eq!(updated.logged_at, logged_at);
        assert_eq!(updated.meal_slot, Some(MealSlot::Dinner));
        match updated.item {
            LoggedItem::Meal(id) => assert_eq!(id, meal_id),
            LoggedItem::Product(_) => panic!("expected meal item"),
        }
        assert_eq!(updated.quantity_amount, Decimal::new(2, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(800, 0));
        assert!(updated.notes.is_none());
    }
}

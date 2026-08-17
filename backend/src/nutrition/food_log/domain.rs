use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use std::ops::Bound;
use std::str::FromStr;
use uuid::Uuid;

use crate::nutrition::catalog::domain::calculation::{CalculatedNutrition, Quantity};
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::{NutrientCode, Product, ProductId, UnitCode};
use crate::nutrition::meal::domain::{Meal, MealId};

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum MealSlot {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
    LateNightSnack,
}

impl MealSlot {
    pub const ALL: [Self; 5] = [
        Self::Breakfast,
        Self::Lunch,
        Self::Dinner,
        Self::Snack,
        Self::LateNightSnack,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            MealSlot::Breakfast => "breakfast",
            MealSlot::Lunch => "lunch",
            MealSlot::Dinner => "dinner",
            MealSlot::Snack => "snack",
            MealSlot::LateNightSnack => "late_night_snack",
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
            "late_night_snack" => Ok(MealSlot::LateNightSnack),
            _ => Err(format!("invalid meal slot: {s}")),
        }
    }
}

#[derive(Debug, Clone)]
pub enum FoodLogItemRef {
    Product(ProductId),
    Meal(MealId),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FoodLogItemSnapshot {
    Product {
        id: ProductId,
        name: String,
        brand: Option<String>,
    },
    Meal {
        id: MealId,
        name: String,
    },
}

impl FoodLogItemSnapshot {
    pub fn from_product(product: &Product) -> Self {
        Self::Product {
            id: product.id,
            name: product.name.as_str().to_string(),
            brand: product.brand.as_ref().map(|brand| brand.0.clone()),
        }
    }

    pub fn from_meal(meal: &Meal) -> Self {
        Self::Meal {
            id: meal.id,
            name: meal.name.as_str().to_string(),
        }
    }

    pub fn as_ref(&self) -> FoodLogItemRef {
        match self {
            Self::Product { id, .. } => FoodLogItemRef::Product(*id),
            Self::Meal { id, .. } => FoodLogItemRef::Meal(*id),
        }
    }
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
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlot>,
    pub device_timezone: Option<String>,
    pub item: FoodLogItemSnapshot,
    pub quantity_amount: Decimal,
    pub quantity_unit: UnitCode,
    pub nutrient_snapshots: Vec<FoodLogNutrientSnapshot>,
    pub notes: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct RecentFoodLogItem {
    pub item: FoodLogItemSnapshot,
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlot>,
    pub quantity_amount: Decimal,
    pub quantity_unit: UnitCode,
    pub nutrient_snapshots: Vec<FoodLogNutrientSnapshot>,
    pub top_quantities: Vec<QuantityUsage>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuantityUsage {
    pub amount: Decimal,
    pub unit: UnitCode,
    pub log_count: u32,
}

#[derive(Debug, Clone)]
pub struct DateRange {
    pub start: Bound<NaiveDate>,
    pub end: Bound<NaiveDate>,
}

impl DateRange {
    pub fn inclusive(start: NaiveDate, end: NaiveDate) -> Result<Self, NutritionError> {
        if start > end {
            return Err(NutritionError::Validation(
                "from_date must be on or before to_date".into(),
            ));
        }

        Ok(Self {
            start: Bound::Included(start),
            end: Bound::Included(end),
        })
    }

    pub fn inclusive_to_exclusive(
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<Self, NutritionError> {
        if start >= end {
            return Err(NutritionError::Validation(
                "start_date must be before end_date".into(),
            ));
        }

        Ok(Self {
            start: Bound::Included(start),
            end: Bound::Excluded(end),
        })
    }
}

#[derive(Debug, Clone)]
pub struct FoodLogListFilter {
    pub user_id: Uuid,
    pub date_range: DateRange,
    pub meal_slot: Option<MealSlot>,
    pub items: Vec<FoodLogItemRef>,
}

impl FoodLog {
    #[allow(clippy::too_many_arguments)]
    pub fn new_product_log(
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        product: &Product,
        quantity: Quantity,
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, NutritionError> {
        let nutrition = product
            .nutrition_for(&quantity, unit_converter)
            .map_err(NutritionError::Validation)?;
        Ok(Self::new(
            user_id,
            log_date,
            meal_slot,
            device_timezone,
            FoodLogItemSnapshot::from_product(product),
            quantity,
            nutrition,
            notes,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_meal_log(
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        meal: &Meal,
        quantity: Quantity,
        products: &[(ProductId, Product)],
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, NutritionError> {
        let nutrition = meal
            .nutrition_for(&quantity, products, unit_converter)
            .map_err(NutritionError::Validation)?;
        Ok(Self::new(
            user_id,
            log_date,
            meal_slot,
            device_timezone,
            FoodLogItemSnapshot::from_meal(meal),
            quantity,
            nutrition,
            notes,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_product_log(
        &self,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        product: &Product,
        quantity: Quantity,
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, NutritionError> {
        let nutrition = product
            .nutrition_for(&quantity, unit_converter)
            .map_err(NutritionError::Validation)?;
        Ok(self.update(
            log_date,
            meal_slot,
            device_timezone,
            FoodLogItemSnapshot::from_product(product),
            quantity,
            nutrition,
            notes,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update_meal_log(
        &self,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        meal: &Meal,
        quantity: Quantity,
        products: &[(ProductId, Product)],
        unit_converter: &UnitConverter,
        notes: Option<String>,
    ) -> Result<Self, NutritionError> {
        let nutrition = meal
            .nutrition_for(&quantity, products, unit_converter)
            .map_err(NutritionError::Validation)?;
        Ok(self.update(
            log_date,
            meal_slot,
            device_timezone,
            FoodLogItemSnapshot::from_meal(meal),
            quantity,
            nutrition,
            notes,
        ))
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
    }

    #[allow(clippy::too_many_arguments)]
    fn new(
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        item: FoodLogItemSnapshot,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        let now = Utc::now();
        let (quantity_amount, quantity_unit) = quantity.into_parts();
        Self {
            id: FoodLogId::new(),
            user_id,
            log_date,
            meal_slot,
            device_timezone,
            item,
            quantity_amount,
            quantity_unit,
            nutrient_snapshots: snapshots_from_calculated(nutrition),
            notes,
            created_at: now,
            updated_at: now,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn update(
        &self,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        item: FoodLogItemSnapshot,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
        notes: Option<String>,
    ) -> Self {
        let (quantity_amount, quantity_unit) = quantity.into_parts();
        Self {
            id: self.id,
            user_id: self.user_id,
            log_date,
            meal_slot,
            device_timezone,
            item,
            quantity_amount,
            quantity_unit,
            nutrient_snapshots: snapshots_from_calculated(nutrition),
            notes,
            created_at: self.created_at,
            updated_at: Utc::now(),
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

pub use crate::nutrition::error::NutritionError;

#[async_trait]
pub trait FoodLogRepository: Send + Sync {
    async fn create(&self, log: &FoodLog) -> Result<(), NutritionError>;
    async fn create_many(&self, logs: &[FoodLog]) -> Result<(), NutritionError>;
    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, NutritionError>;
    async fn list_by_user_and_date(
        &self,
        user_id: Uuid,
        log_date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError>;
    async fn list_by_filter(
        &self,
        filter: FoodLogListFilter,
    ) -> Result<Vec<FoodLog>, NutritionError>;
    async fn update(&self, log: &FoodLog) -> Result<(), NutritionError>;
    async fn delete(&self, id: FoodLogId) -> Result<(), NutritionError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct FoodLogPolicy;

impl FoodLogPolicy {
    pub fn authorize_access(&self, actor_id: Uuid, log: &FoodLog) -> Result<(), NutritionError> {
        if log.is_owned_by(actor_id) {
            Ok(())
        } else {
            Err(NutritionError::NotFound("food log not found".into()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nutrition::catalog::domain::calculation::Quantity;
    use crate::nutrition::catalog::domain::{
        AmountPer100g, ProductName, ProductNutrient, ProductVisibility, Source,
    };
    use crate::nutrition::meal::domain::{MealComponent, MealComponentItem};
    use std::str::FromStr;

    fn sample_product() -> Product {
        Product {
            id: ProductId(Uuid::nil()),
            source: Source::User,
            source_id: None,
            user_id: None,
            visibility: ProductVisibility::Global,
            barcode: None,
            name: ProductName::new("Test").unwrap(),
            brand: None,
            categories: vec![],
            default_quantity: None,
            default_unit: None,
            serving_size_g: None,
            nutrients: vec![ProductNutrient {
                nutrient_code: NutrientCode("ENERGY_KCAL".to_string()),
                amount_per_100g: AmountPer100g::new(Decimal::new(250, 0)).unwrap(),
                unit: UnitCode("kcal".to_string()),
                source: None,
                confidence: None,
            }],
            servings: vec![],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn sample_meal() -> Meal {
        Meal {
            id: MealId(Uuid::nil()),
            user_id: Uuid::nil(),
            name: crate::nutrition::meal::domain::MealName::new("Test").unwrap(),
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

    fn sample_log_date() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 6, 1).unwrap()
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
            sample_log_date(),
            Some(MealSlot::Breakfast),
            Some("Asia/Kolkata".into()),
            &product,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())).unwrap(),
            &converter,
            Some("notes".into()),
        )
        .unwrap();

        assert_eq!(
            log.item,
            FoodLogItemSnapshot::Product {
                id: product.id,
                name: "Test".into(),
                brand: None,
            }
        );
        assert_eq!(log.quantity_amount, Decimal::new(100, 0));
        assert_eq!(log.quantity_unit.0, "g");
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(250, 0));
        assert_eq!(log.notes.as_deref(), Some("notes"));
        assert_eq!(log.device_timezone.as_deref(), Some("Asia/Kolkata"));
    }

    #[test]
    fn meal_log_construction_sets_item_quantity_and_snapshots() {
        let product = sample_product();
        let meal = sample_meal();
        let converter = sample_unit_converter();
        let log = FoodLog::new_meal_log(
            Uuid::new_v4(),
            sample_log_date(),
            Some(MealSlot::Dinner),
            None,
            &meal,
            Quantity::new(Decimal::new(50, 0), UnitCode("g".into())).unwrap(),
            &[(product.id, product.clone())],
            &converter,
            None,
        )
        .unwrap();

        assert_eq!(
            log.item,
            FoodLogItemSnapshot::Meal {
                id: meal.id,
                name: "Test".into(),
            }
        );
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
            sample_log_date(),
            Some(MealSlot::Lunch),
            None,
            &meal,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())).unwrap(),
            &[(product.id, product.clone())],
            &converter,
            None,
        )
        .unwrap();
        let original_id = original.id;
        let log_date = NaiveDate::from_ymd_opt(2026, 6, 2).unwrap();

        let updated = original
            .update_product_log(
                log_date,
                Some(MealSlot::Snack),
                Some("America/New_York".into()),
                &product,
                Quantity::new(Decimal::new(50, 0), UnitCode("g".into())).unwrap(),
                &converter,
                Some("updated".into()),
            )
            .unwrap();

        assert_eq!(updated.id, original_id);
        assert_eq!(updated.user_id, user_id);
        assert_eq!(updated.log_date, log_date);
        assert_eq!(updated.meal_slot, Some(MealSlot::Snack));
        assert_eq!(updated.device_timezone.as_deref(), Some("America/New_York"));
        assert_eq!(
            updated.item,
            FoodLogItemSnapshot::Product {
                id: product.id,
                name: "Test".into(),
                brand: None,
            }
        );
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
            sample_log_date(),
            None,
            Some("Asia/Kolkata".into()),
            &product,
            Quantity::new(Decimal::new(100, 0), UnitCode("g".into())).unwrap(),
            &converter,
            None,
        )
        .unwrap();
        let original_id = original.id;
        let log_date = NaiveDate::from_ymd_opt(2026, 6, 3).unwrap();

        let updated = original
            .update_meal_log(
                log_date,
                Some(MealSlot::Dinner),
                None,
                &meal,
                Quantity::new(Decimal::new(50, 0), UnitCode("g".into())).unwrap(),
                &[(product.id, product.clone())],
                &converter,
                None,
            )
            .unwrap();

        assert_eq!(updated.id, original_id);
        assert_eq!(updated.user_id, user_id);
        assert_eq!(updated.log_date, log_date);
        assert_eq!(updated.meal_slot, Some(MealSlot::Dinner));
        assert_eq!(updated.device_timezone, None);
        assert_eq!(
            updated.item,
            FoodLogItemSnapshot::Meal {
                id: meal.id,
                name: "Test".into(),
            }
        );
        assert_eq!(updated.quantity_amount, Decimal::new(50, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(125, 0));
        assert!(updated.notes.is_none());
    }
}

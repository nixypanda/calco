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
    AdHoc {
        name: String,
        brand: Option<String>,
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

    pub fn ad_hoc(name: String, brand: Option<String>) -> Result<Self, NutritionError> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(NutritionError::Validation(
                "ad-hoc food name must not be blank".into(),
            ));
        }

        Ok(Self::AdHoc {
            name,
            brand: brand.and_then(|value| {
                let trimmed = value.trim().to_string();
                (!trimmed.is_empty()).then_some(trimmed)
            }),
        })
    }

    pub fn as_ref(&self) -> Option<FoodLogItemRef> {
        match self {
            Self::Product { id, .. } => Some(FoodLogItemRef::Product(*id)),
            Self::Meal { id, .. } => Some(FoodLogItemRef::Meal(*id)),
            Self::AdHoc { .. } => None,
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
    id: FoodLogId,
    user_id: Uuid,
    log_date: NaiveDate,
    meal_slot: Option<MealSlot>,
    device_timezone: Option<String>,
    item: FoodLogItemSnapshot,
    quantity_amount: Decimal,
    quantity_unit: UnitCode,
    nutrient_snapshots: Vec<FoodLogNutrientSnapshot>,
    notes: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug)]
pub struct FoodLogBuilder {
    user_id: Uuid,
    log_date: NaiveDate,
    item: FoodLogItemSnapshot,
    quantity: Quantity,
    nutrition: CalculatedNutrition,
    meal_slot: Option<MealSlot>,
    device_timezone: Option<String>,
    notes: Option<String>,
}

impl FoodLogBuilder {
    pub fn new(
        user_id: Uuid,
        log_date: NaiveDate,
        item: FoodLogItemSnapshot,
        quantity: Quantity,
        nutrition: CalculatedNutrition,
    ) -> Self {
        Self {
            user_id,
            log_date,
            item,
            quantity,
            nutrition,
            meal_slot: None,
            device_timezone: None,
            notes: None,
        }
    }

    pub fn new_ad_hoc(
        user_id: Uuid,
        log_date: NaiveDate,
        name: String,
        brand: Option<String>,
        quantity: Quantity,
        nutrient_snapshots: Vec<FoodLogNutrientSnapshot>,
    ) -> Result<Self, NutritionError> {
        if quantity.unit().0.trim().is_empty() {
            return Err(NutritionError::Validation(
                "ad-hoc quantity unit must not be blank".into(),
            ));
        }
        validate_ad_hoc_nutrients(&nutrient_snapshots)?;
        Ok(Self {
            user_id,
            log_date,
            item: FoodLogItemSnapshot::ad_hoc(name, brand)?,
            quantity,
            nutrition: CalculatedNutrition {
                amounts: nutrient_snapshots
                    .into_iter()
                    .map(|snapshot| {
                        crate::nutrition::catalog::domain::calculation::NutrientAmount {
                            nutrient_code: snapshot.nutrient_code,
                            amount: snapshot.amount,
                            unit: snapshot.unit,
                        }
                    })
                    .collect(),
            },
            meal_slot: None,
            device_timezone: None,
            notes: None,
        })
    }

    pub fn meal_slot(mut self, meal_slot: Option<MealSlot>) -> Self {
        self.meal_slot = meal_slot;
        self
    }

    pub fn device_timezone(mut self, device_timezone: Option<String>) -> Self {
        self.device_timezone = device_timezone;
        self
    }

    pub fn notes(mut self, notes: Option<String>) -> Self {
        self.notes = notes;
        self
    }

    pub fn build(self) -> FoodLog {
        let now = Utc::now();
        let (quantity_amount, quantity_unit) = self.quantity.into_parts();

        FoodLog {
            id: FoodLogId::new(),
            user_id: self.user_id,
            log_date: self.log_date,
            meal_slot: self.meal_slot,
            device_timezone: self.device_timezone,
            item: self.item,
            quantity_amount,
            quantity_unit,
            nutrient_snapshots: snapshots_from_calculated(self.nutrition),
            notes: self.notes,
            created_at: now,
            updated_at: now,
        }
    }
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
    /// Time-decayed usage weight, summed over every log of this item in the
    /// requested range. Ranking input only; it is never serialized.
    pub score: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuantityUsage {
    pub amount: Decimal,
    pub unit: UnitCode,
    pub log_count: u32,
    pub score: u32,
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
    pub fn id(&self) -> FoodLogId {
        self.id
    }

    pub fn user_id(&self) -> Uuid {
        self.user_id
    }

    pub fn log_date(&self) -> NaiveDate {
        self.log_date
    }

    pub fn meal_slot(&self) -> Option<MealSlot> {
        self.meal_slot
    }

    pub fn device_timezone(&self) -> Option<&str> {
        self.device_timezone.as_deref()
    }

    pub fn item(&self) -> &FoodLogItemSnapshot {
        &self.item
    }

    pub fn quantity_amount(&self) -> Decimal {
        self.quantity_amount
    }

    pub fn quantity_unit(&self) -> &UnitCode {
        &self.quantity_unit
    }

    pub fn nutrient_snapshots(&self) -> &[FoodLogNutrientSnapshot] {
        &self.nutrient_snapshots
    }

    pub fn notes(&self) -> Option<&str> {
        self.notes.as_deref()
    }

    pub fn created_at(&self) -> DateTime<Utc> {
        self.created_at
    }

    pub fn updated_at(&self) -> DateTime<Utc> {
        self.updated_at
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

    #[allow(clippy::too_many_arguments)]
    pub fn update_ad_hoc_log(
        &self,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        quantity: Quantity,
        notes: Option<String>,
    ) -> Result<Self, NutritionError> {
        if !matches!(self.item, FoodLogItemSnapshot::AdHoc { .. }) {
            return Err(NutritionError::Validation(
                "food log is not an ad-hoc log".into(),
            ));
        }
        if quantity.unit() != &self.quantity_unit {
            return Err(NutritionError::Validation(
                "the unit of an ad-hoc food log cannot be changed".into(),
            ));
        }

        let scale = quantity.amount() / self.quantity_amount;
        let (quantity_amount, quantity_unit) = quantity.into_parts();
        Ok(Self {
            id: self.id,
            user_id: self.user_id,
            log_date,
            meal_slot,
            device_timezone,
            item: self.item.clone(),
            quantity_amount,
            quantity_unit,
            nutrient_snapshots: self
                .nutrient_snapshots
                .iter()
                .cloned()
                .map(|mut snapshot| {
                    snapshot.amount *= scale;
                    snapshot
                })
                .collect(),
            notes,
            created_at: self.created_at,
            updated_at: Utc::now(),
        })
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn restore(
        id: FoodLogId,
        user_id: Uuid,
        log_date: NaiveDate,
        meal_slot: Option<MealSlot>,
        device_timezone: Option<String>,
        item: FoodLogItemSnapshot,
        quantity_amount: Decimal,
        quantity_unit: UnitCode,
        nutrient_snapshots: Vec<FoodLogNutrientSnapshot>,
        notes: Option<String>,
        created_at: DateTime<Utc>,
        updated_at: DateTime<Utc>,
    ) -> Self {
        Self {
            id,
            user_id,
            log_date,
            meal_slot,
            device_timezone,
            item,
            quantity_amount,
            quantity_unit,
            nutrient_snapshots,
            notes,
            created_at,
            updated_at,
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

fn validate_ad_hoc_nutrients(snapshots: &[FoodLogNutrientSnapshot]) -> Result<(), NutritionError> {
    const REQUIRED: [(&str, &str); 4] = [
        ("ENERGY_KCAL", "kcal"),
        ("PROTEIN_G", "g"),
        ("CARBS_G", "g"),
        ("FAT_G", "g"),
    ];

    for (index, snapshot) in snapshots.iter().enumerate() {
        if snapshot.nutrient_code.0.trim().is_empty() {
            return Err(NutritionError::Validation(
                "ad-hoc nutrient code must not be blank".into(),
            ));
        }
        if snapshot.unit.0.trim().is_empty() {
            return Err(NutritionError::Validation(format!(
                "{} unit must not be blank",
                snapshot.nutrient_code.0
            )));
        }
        if snapshots[..index]
            .iter()
            .any(|other| other.nutrient_code == snapshot.nutrient_code)
        {
            return Err(NutritionError::Validation(format!(
                "duplicate ad-hoc nutrient: {}",
                snapshot.nutrient_code.0
            )));
        }
        if let Some((_, expected_unit)) = REQUIRED
            .iter()
            .find(|(code, _)| *code == snapshot.nutrient_code.0)
            && snapshot.unit.0 != *expected_unit
        {
            return Err(NutritionError::Validation(format!(
                "{} must use unit {}",
                snapshot.nutrient_code.0, expected_unit
            )));
        }
        if snapshot.amount < Decimal::ZERO {
            return Err(NutritionError::Validation(format!(
                "{} amount must not be negative",
                snapshot.nutrient_code.0
            )));
        }
    }

    for (code, _) in REQUIRED {
        let count = snapshots
            .iter()
            .filter(|snapshot| snapshot.nutrient_code.0 == code)
            .count();
        match count {
            0 => {
                return Err(NutritionError::Validation(format!(
                    "missing required ad-hoc nutrient: {code}"
                )));
            }
            1 => {}
            _ => unreachable!("duplicates are rejected above"),
        }
    }

    Ok(())
}

pub use crate::nutrition::error::NutritionError;

#[async_trait]
pub trait FoodLogRepo: Send + Sync {
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
    use proptest::prelude::*;
    use rstest::rstest;

    #[test]
    fn test_meal_slot_from_str_invalid() {
        assert!("brunch".parse::<MealSlot>().is_err());
        assert!("".parse::<MealSlot>().is_err());
        assert!("LUNCH".parse::<MealSlot>().is_err());
    }

    fn ad_hoc_date() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 9, 14).unwrap()
    }

    fn serving_quantity(amount: Decimal) -> Quantity {
        Quantity::new(amount, UnitCode("serving".into())).unwrap()
    }

    fn snapshot(code: &str, amount: Decimal, unit: &str) -> FoodLogNutrientSnapshot {
        FoodLogNutrientSnapshot {
            nutrient_code: NutrientCode(code.into()),
            amount,
            unit: UnitCode(unit.into()),
        }
    }

    fn required_snapshots() -> Vec<FoodLogNutrientSnapshot> {
        vec![
            snapshot("ENERGY_KCAL", Decimal::new(520, 0), "kcal"),
            snapshot("PROTEIN_G", Decimal::new(24, 0), "g"),
            snapshot("CARBS_G", Decimal::new(48, 0), "g"),
            snapshot("FAT_G", Decimal::new(25, 0), "g"),
        ]
    }

    fn build_ad_hoc_log() -> FoodLog {
        FoodLogBuilder::new_ad_hoc(
            Uuid::nil(),
            ad_hoc_date(),
            "Paneer tikka wrap".into(),
            None,
            serving_quantity(Decimal::ONE),
            required_snapshots(),
        )
        .unwrap()
        .build()
    }

    #[derive(Debug, Clone, Copy)]
    enum AdHocMutation {
        BlankName,
        MissingRequiredNutrient,
        DuplicateRequiredNutrient,
        WrongUnitForRequiredNutrient,
        NegativeNutrientAmount,
    }

    fn required_snapshot_mut<'a>(
        nutrients: &'a mut [FoodLogNutrientSnapshot],
        code: &str,
    ) -> &'a mut FoodLogNutrientSnapshot {
        nutrients
            .iter_mut()
            .find(|snapshot| snapshot.nutrient_code.0 == code)
            .expect("required snapshot should be present")
    }

    impl AdHocMutation {
        fn apply(self, name: &mut String, nutrients: &mut Vec<FoodLogNutrientSnapshot>) {
            match self {
                Self::BlankName => *name = "   ".into(),
                Self::MissingRequiredNutrient => {
                    nutrients.retain(|snapshot| snapshot.nutrient_code.0 != "FAT_G");
                }
                Self::DuplicateRequiredNutrient => {
                    nutrients.push(snapshot("ENERGY_KCAL", Decimal::new(10, 0), "kcal"));
                }
                Self::WrongUnitForRequiredNutrient => {
                    required_snapshot_mut(nutrients, "ENERGY_KCAL").unit = UnitCode("g".into());
                }
                Self::NegativeNutrientAmount => {
                    required_snapshot_mut(nutrients, "PROTEIN_G").amount = Decimal::new(-1, 0);
                }
            }
        }
    }

    #[rstest]
    #[case::blank_name(AdHocMutation::BlankName, "ad-hoc food name must not be blank")]
    #[case::missing_required_nutrient(
        AdHocMutation::MissingRequiredNutrient,
        "missing required ad-hoc nutrient: FAT_G"
    )]
    #[case::duplicate_required_nutrient(
        AdHocMutation::DuplicateRequiredNutrient,
        "duplicate ad-hoc nutrient: ENERGY_KCAL"
    )]
    #[case::wrong_unit_for_required_nutrient(
        AdHocMutation::WrongUnitForRequiredNutrient,
        "ENERGY_KCAL must use unit kcal"
    )]
    #[case::negative_nutrient_amount(
        AdHocMutation::NegativeNutrientAmount,
        "PROTEIN_G amount must not be negative"
    )]
    fn new_ad_hoc_rejects_invalid_input(
        #[case] mutation: AdHocMutation,
        #[case] expected_message: &str,
    ) {
        let mut name = "Paneer tikka wrap".to_string();
        let mut nutrients = required_snapshots();
        mutation.apply(&mut name, &mut nutrients);

        let result = FoodLogBuilder::new_ad_hoc(
            Uuid::nil(),
            ad_hoc_date(),
            name,
            None,
            serving_quantity(Decimal::ONE),
            nutrients,
        );

        match result {
            Err(NutritionError::Validation(message)) => {
                assert!(
                    message.contains(expected_message),
                    "unexpected message: {message}"
                );
            }
            other => panic!("expected validation error, got {other:?}"),
        }
    }

    #[test]
    fn new_ad_hoc_accepts_zero_required_amounts_and_optional_nutrient() {
        let mut nutrients = required_snapshots();
        for nutrient in &mut nutrients {
            nutrient.amount = Decimal::ZERO;
        }
        nutrients.push(snapshot("FIBER_G", Decimal::new(7, 0), "g"));

        let log = FoodLogBuilder::new_ad_hoc(
            Uuid::nil(),
            ad_hoc_date(),
            "Paneer tikka wrap".into(),
            None,
            serving_quantity(Decimal::ONE),
            nutrients,
        )
        .unwrap()
        .build();

        assert_eq!(log.nutrient_snapshots().len(), 5);
    }

    #[test]
    fn update_ad_hoc_log_rejects_changing_unit() {
        let log = build_ad_hoc_log();
        let grams = Quantity::new(Decimal::new(2, 0), UnitCode("g".into())).unwrap();

        let result = log.update_ad_hoc_log(ad_hoc_date(), None, None, grams, None);

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    const REQUIRED_NUTRIENTS: [(&str, &str); 4] = [
        ("ENERGY_KCAL", "kcal"),
        ("PROTEIN_G", "g"),
        ("CARBS_G", "g"),
        ("FAT_G", "g"),
    ];

    fn valid_ad_hoc_name() -> impl Strategy<Value = String> {
        "[A-Za-z][A-Za-z0-9 ]{0,24}"
    }

    type GeneratedNutrient = (NutrientCode, Decimal, UnitCode);

    /// Positive quantities in `0.000001..=10_000`, including real fractional values.
    fn positive_quantity_amount() -> impl Strategy<Value = Decimal> {
        prop_oneof![
            Just(Decimal::new(1, 6)),
            Just(Decimal::new(25, 1)),
            (1i64..=10_000i64, 0u32..=2)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
        ]
    }

    /// Non-negative required-nutrient amounts in `0..=1_000_000`, including fractions.
    fn bounded_required_amount() -> impl Strategy<Value = Decimal> {
        prop_oneof![
            Just(Decimal::ZERO),
            Just(Decimal::new(1, 6)),
            Just(Decimal::new(25, 1)),
            (0i64..=1_000_000i64, 0u32..=6)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
        ]
    }

    fn required_nutrients_strategy() -> impl Strategy<Value = Vec<GeneratedNutrient>> {
        (
            bounded_required_amount(),
            bounded_required_amount(),
            bounded_required_amount(),
            bounded_required_amount(),
        )
            .prop_map(|(energy, protein, carbs, fat)| {
                vec![
                    (
                        NutrientCode("ENERGY_KCAL".into()),
                        energy,
                        UnitCode("kcal".into()),
                    ),
                    (
                        NutrientCode("PROTEIN_G".into()),
                        protein,
                        UnitCode("g".into()),
                    ),
                    (NutrientCode("CARBS_G".into()), carbs, UnitCode("g".into())),
                    (NutrientCode("FAT_G".into()), fat, UnitCode("g".into())),
                ]
            })
    }

    fn shuffled_required_nutrients_strategy() -> impl Strategy<Value = Vec<GeneratedNutrient>> {
        (
            required_nutrients_strategy(),
            proptest::array::uniform4(any::<u8>()),
        )
            .prop_map(|(nutrients, keys)| {
                let mut order: Vec<usize> = (0..nutrients.len()).collect();
                order.sort_by_key(|&index| (keys[index], index));
                order
                    .into_iter()
                    .map(|index| nutrients[index].clone())
                    .collect()
            })
    }

    fn snapshots_from_generated(nutrients: &[GeneratedNutrient]) -> Vec<FoodLogNutrientSnapshot> {
        nutrients
            .iter()
            .map(|(code, amount, unit)| FoodLogNutrientSnapshot {
                nutrient_code: code.clone(),
                amount: *amount,
                unit: unit.clone(),
            })
            .collect()
    }

    fn build_log_with_quantity(
        name: String,
        quantity_amount: Decimal,
        nutrients: &[GeneratedNutrient],
    ) -> FoodLog {
        FoodLogBuilder::new_ad_hoc(
            Uuid::nil(),
            ad_hoc_date(),
            name,
            None,
            serving_quantity(quantity_amount),
            snapshots_from_generated(nutrients),
        )
        .expect("valid ad-hoc input must be accepted")
        .build()
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        #[test]
        fn new_ad_hoc_accepts_valid_required_nutrients(
            name in valid_ad_hoc_name(),
            quantity_amount in positive_quantity_amount(),
            nutrients in required_nutrients_strategy(),
        ) {
            let expected_name = name.trim().to_string();
            let log = build_log_with_quantity(name, quantity_amount, &nutrients);

            prop_assert_eq!(log.quantity_amount(), quantity_amount);
            prop_assert_eq!(log.quantity_unit(), &UnitCode("serving".into()));
            prop_assert_eq!(
                log.item(),
                &FoodLogItemSnapshot::AdHoc {
                    name: expected_name,
                    brand: None,
                }
            );
            prop_assert_eq!(log.nutrient_snapshots().len(), nutrients.len());
            for (snapshot, (code, amount, unit)) in
                log.nutrient_snapshots().iter().zip(nutrients.iter())
            {
                prop_assert_eq!(&snapshot.nutrient_code, code);
                prop_assert_eq!(snapshot.amount, *amount);
                prop_assert_eq!(&snapshot.unit, unit);
            }
            for (code, _) in REQUIRED_NUTRIENTS {
                let count = log
                    .nutrient_snapshots()
                    .iter()
                    .filter(|snapshot| snapshot.nutrient_code.0 == code)
                    .count();
                prop_assert_eq!(count, 1, "expected exactly one {}", code);
            }
            for snapshot in log.nutrient_snapshots() {
                prop_assert!(snapshot.amount >= Decimal::ZERO);
            }
        }

        #[test]
        fn new_ad_hoc_accepts_required_nutrients_in_shuffled_order(
            name in valid_ad_hoc_name(),
            quantity_amount in positive_quantity_amount(),
            nutrients in shuffled_required_nutrients_strategy(),
        ) {
            let log = build_log_with_quantity(name, quantity_amount, &nutrients);

            prop_assert_eq!(log.nutrient_snapshots().len(), nutrients.len());
            for (snapshot, (code, amount, unit)) in
                log.nutrient_snapshots().iter().zip(nutrients.iter())
            {
                prop_assert_eq!(&snapshot.nutrient_code, code);
                prop_assert_eq!(snapshot.amount, *amount);
                prop_assert_eq!(&snapshot.unit, unit);
            }
            for (code, _) in REQUIRED_NUTRIENTS {
                let count = log
                    .nutrient_snapshots()
                    .iter()
                    .filter(|snapshot| snapshot.nutrient_code.0 == code)
                    .count();
                prop_assert_eq!(count, 1, "expected exactly one {}", code);
            }
        }

        #[test]
        fn update_ad_hoc_log_preserves_snapshots_and_scales_by_quantity_ratio(
            name in valid_ad_hoc_name(),
            old_amount in positive_quantity_amount(),
            new_amount in positive_quantity_amount(),
            nutrients in required_nutrients_strategy(),
        ) {
            let log = build_log_with_quantity(name, old_amount, &nutrients);
            let original_item = log.item().clone();
            let original_unit = log.quantity_unit().clone();
            let original_snapshots = log.nutrient_snapshots().to_vec();

            let updated = log
                .update_ad_hoc_log(
                    ad_hoc_date(),
                    None,
                    None,
                    serving_quantity(new_amount),
                    None,
                )
                .expect("positive same-unit update must succeed");

            prop_assert_eq!(updated.item(), &original_item);
            prop_assert_eq!(updated.quantity_amount(), new_amount);
            prop_assert_eq!(updated.quantity_unit(), &original_unit);
            prop_assert_eq!(updated.nutrient_snapshots().len(), original_snapshots.len());

            let scale = new_amount / old_amount;
            for (snapshot, original) in updated
                .nutrient_snapshots()
                .iter()
                .zip(original_snapshots.iter())
            {
                prop_assert_eq!(&snapshot.nutrient_code, &original.nutrient_code);
                prop_assert_eq!(&snapshot.unit, &original.unit);
                prop_assert_eq!(snapshot.amount, original.amount * scale);
            }
        }
    }
}

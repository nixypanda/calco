use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::catalog::domain::calculation::Quantity;
use crate::catalog::domain::units::UnitConverter;
use crate::catalog::domain::{ProductId, UnitCode};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MealId(pub Uuid);

impl Default for MealId {
    fn default() -> Self {
        Self::new()
    }
}

impl MealId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl From<Uuid> for MealId {
    fn from(id: Uuid) -> Self {
        Self(id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MealName(String);

impl MealName {
    pub fn new(value: &str) -> Result<Self, JournalError> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err(JournalError::Validation("meal name is required".into()));
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
pub struct MealNotes(pub String);

/// A structurally validated meal quantity.
///
/// The amount is positive and the unit is nonblank. Catalog conversion is a
/// separate, dynamic concern: a structurally valid quantity can still become
/// unconvertible when a product serving disappears.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MealQuantity {
    amount: Decimal,
    unit: UnitCode,
}

impl MealQuantity {
    pub fn new(amount: Decimal, unit: UnitCode) -> Result<Self, JournalError> {
        if amount <= Decimal::ZERO {
            return Err(JournalError::Validation(
                "meal quantity amount must be positive".into(),
            ));
        }
        if unit.0.trim().is_empty() {
            return Err(JournalError::Validation(
                "meal quantity unit must not be blank".into(),
            ));
        }
        Ok(Self { amount, unit })
    }

    pub fn amount(&self) -> Decimal {
        self.amount
    }

    pub fn unit(&self) -> &UnitCode {
        &self.unit
    }

    pub fn to_quantity(&self) -> Result<Quantity, JournalError> {
        Quantity::new(self.amount, self.unit.clone()).map_err(JournalError::from)
    }

    pub fn into_parts(self) -> (Decimal, UnitCode) {
        (self.amount, self.unit)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MealTotalQuantityPatch {
    Unchanged,
    Clear,
    Set(MealQuantity),
}

impl MealTotalQuantityPatch {
    fn apply(&self, current: Option<MealQuantity>) -> Option<MealQuantity> {
        match self {
            Self::Unchanged => current,
            Self::Clear => None,
            Self::Set(quantity) => Some(quantity.clone()),
        }
    }
}

#[derive(Debug, Clone)]
pub enum MealComponentItem {
    Product(ProductId),
}

#[derive(Debug, Clone)]
pub struct MealComponent {
    id: Uuid,
    item: MealComponentItem,
    quantity: MealQuantity,
}

impl MealComponent {
    pub fn new(item: MealComponentItem, quantity: MealQuantity) -> Self {
        Self {
            id: Uuid::new_v4(),
            item,
            quantity,
        }
    }

    pub(crate) fn from_stored(id: Uuid, item: MealComponentItem, quantity: MealQuantity) -> Self {
        Self { id, item, quantity }
    }

    pub fn id(&self) -> Uuid {
        self.id
    }

    pub fn item(&self) -> &MealComponentItem {
        &self.item
    }

    pub fn quantity(&self) -> &MealQuantity {
        &self.quantity
    }
}

#[derive(Debug, Clone)]
pub struct Meal {
    id: MealId,
    user_id: Uuid,
    name: MealName,
    notes: Option<MealNotes>,
    total_quantity: Option<MealQuantity>,
    components: Vec<MealComponent>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

/// Validated fields read from the meal tables before aggregate reconstruction.
pub(crate) struct StoredMeal {
    pub(crate) id: MealId,
    pub(crate) user_id: Uuid,
    pub(crate) name: String,
    pub(crate) notes: Option<String>,
    pub(crate) total_quantity: Option<MealQuantity>,
    pub(crate) components: Vec<MealComponent>,
    pub(crate) created_at: DateTime<Utc>,
    pub(crate) updated_at: DateTime<Utc>,
}

impl Meal {
    pub fn create(
        user_id: Uuid,
        name: String,
        notes: Option<String>,
        total_quantity: Option<MealQuantity>,
        components: Vec<MealComponent>,
        now: DateTime<Utc>,
    ) -> Result<Self, JournalError> {
        let name = MealName::new(&name)?;
        validate_meal_components(&components)?;

        Ok(Self {
            id: MealId::new(),
            user_id,
            name,
            notes: notes.map(MealNotes),
            total_quantity,
            components,
            created_at: now,
            updated_at: now,
        })
    }

    pub(crate) fn from_stored(stored: StoredMeal) -> Result<Self, JournalError> {
        if stored.components.is_empty() {
            return Err(JournalError::Internal(
                "stored meal has no components".into(),
            ));
        }
        Ok(Self {
            id: stored.id,
            user_id: stored.user_id,
            name: MealName::new(&stored.name)?,
            notes: stored.notes.map(MealNotes),
            total_quantity: stored.total_quantity,
            components: stored.components,
            created_at: stored.created_at,
            updated_at: stored.updated_at,
        })
    }

    pub fn update(
        &self,
        name: Option<String>,
        notes: Option<Option<String>>,
        total_quantity: MealTotalQuantityPatch,
        components: Option<Vec<MealComponent>>,
        now: DateTime<Utc>,
    ) -> Result<Self, JournalError> {
        let name = match name {
            Some(name) => MealName::new(&name)?,
            None => self.name.clone(),
        };
        let components = match components {
            Some(components) => {
                validate_meal_components(&components)?;
                components
            }
            None => self.components.clone(),
        };
        let total_quantity = total_quantity.apply(self.total_quantity.clone());
        Ok(Self {
            id: self.id,
            user_id: self.user_id,
            name,
            notes: notes
                .map(|n| n.map(MealNotes))
                .unwrap_or(self.notes.clone()),
            total_quantity,
            components,
            created_at: self.created_at,
            updated_at: now,
        })
    }

    pub fn id(&self) -> MealId {
        self.id
    }

    pub fn user_id(&self) -> Uuid {
        self.user_id
    }

    pub fn name(&self) -> &MealName {
        &self.name
    }

    pub fn notes(&self) -> Option<&MealNotes> {
        self.notes.as_ref()
    }

    pub fn total_quantity(&self) -> Option<&MealQuantity> {
        self.total_quantity.as_ref()
    }

    pub fn components(&self) -> &[MealComponent] {
        &self.components
    }

    pub fn created_at(&self) -> DateTime<Utc> {
        self.created_at
    }

    pub fn updated_at(&self) -> DateTime<Utc> {
        self.updated_at
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
    }

    pub fn quantity_to_grams(
        &self,
        quantity: &Quantity,
        unit_converter: &UnitConverter,
    ) -> Result<Decimal, MealQuantityConversionError> {
        let amount = quantity.amount();
        let unit = quantity.unit();
        if let Some(grams) = unit_converter.mass_to_grams(amount, unit) {
            return Ok(grams);
        }
        match &self.total_quantity {
            Some(total) if total.unit().0 == unit.0 && total.amount() > Decimal::ZERO => {
                Ok(amount / total.amount() * self.declared_grams(unit_converter)?)
            }
            _ => Err(MealQuantityConversionError::UnsupportedQuantity),
        }
    }

    fn declared_grams(
        &self,
        unit_converter: &UnitConverter,
    ) -> Result<Decimal, MealQuantityConversionError> {
        let total = self
            .total_quantity
            .as_ref()
            .ok_or(MealQuantityConversionError::UnsupportedDeclaredTotal)?;
        if total.amount() <= Decimal::ZERO {
            return Err(MealQuantityConversionError::UnsupportedDeclaredTotal);
        }
        unit_converter
            .mass_to_grams(total.amount(), total.unit())
            .filter(|grams| *grams > Decimal::ZERO)
            .ok_or(MealQuantityConversionError::UnsupportedDeclaredTotal)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MealQuantityConversionError {
    UnsupportedQuantity,
    UnsupportedDeclaredTotal,
}

fn validate_meal_components(components: &[MealComponent]) -> Result<(), JournalError> {
    if components.is_empty() {
        return Err(JournalError::Validation(
            "meal must have at least one component".into(),
        ));
    }
    Ok(())
}

pub use crate::journal::error::JournalError;

#[async_trait]
pub trait MealRepo: Send + Sync {
    async fn create(&self, meal: &Meal) -> Result<(), JournalError>;
    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, JournalError>;
    async fn list_all(&self) -> Result<Vec<Meal>, JournalError>;
    async fn update(&self, meal: &Meal) -> Result<(), JournalError>;
    async fn delete(&self, id: MealId) -> Result<(), JournalError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct MealPolicy;

impl MealPolicy {
    pub fn authorize_view(&self, _actor_id: Uuid, _meal: &Meal) -> Result<(), JournalError> {
        Ok(())
    }

    pub fn authorize_mutation(&self, actor_id: Uuid, meal: &Meal) -> Result<(), JournalError> {
        if meal.is_owned_by(actor_id) {
            Ok(())
        } else {
            Err(JournalError::Forbidden(
                "only the creator may modify this meal".into(),
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use uuid::Uuid;

    fn sample_component() -> MealComponent {
        MealComponent::new(
            MealComponentItem::Product(ProductId(Uuid::nil())),
            MealQuantity::new(Decimal::ONE, UnitCode("g".into())).unwrap(),
        )
    }

    fn make_meal(total_quantity: Option<MealQuantity>) -> Meal {
        Meal::create(
            Uuid::nil(),
            "Meal".into(),
            None,
            total_quantity,
            vec![sample_component()],
            Utc::now(),
        )
        .expect("meal should be valid")
    }

    fn make_stored_meal(amount: Decimal, unit: UnitCode) -> Meal {
        let now = Utc::now();
        Meal::from_stored(StoredMeal {
            id: MealId::new(),
            user_id: Uuid::nil(),
            name: "Meal".into(),
            notes: None,
            total_quantity: Some(
                MealQuantity::new(amount, unit).expect("stored quantity should be valid"),
            ),
            components: vec![sample_component()],
            created_at: now,
            updated_at: now,
        })
        .expect("stored meal should load")
    }

    fn mass_converter() -> UnitConverter {
        UnitConverter::from_entries([
            ("g".to_string(), Decimal::ONE),
            ("kg".to_string(), Decimal::new(1000, 0)),
        ])
    }

    #[test]
    fn meal_quantity_rejects_nonpositive_amounts_and_blank_units() {
        assert!(matches!(
            MealQuantity::new(Decimal::ZERO, UnitCode("g".into())),
            Err(JournalError::Validation(_))
        ));
        assert!(matches!(
            MealQuantity::new(Decimal::new(-1, 0), UnitCode("g".into())),
            Err(JournalError::Validation(_))
        ));
        assert!(matches!(
            MealQuantity::new(Decimal::ONE, UnitCode("   ".into())),
            Err(JournalError::Validation(_))
        ));
    }

    #[test]
    fn stored_meal_quantity_can_preserve_nonmass_units() {
        let meal = make_stored_meal(Decimal::ONE, UnitCode("cup".into()));
        assert_eq!(
            meal.total_quantity().map(MealQuantity::unit),
            Some(&UnitCode("cup".into()))
        );
    }

    #[test]
    fn stored_meal_restore_rejects_empty_components() {
        let now = Utc::now();
        let error = Meal::from_stored(StoredMeal {
            id: MealId::new(),
            user_id: Uuid::nil(),
            name: "Empty".into(),
            notes: None,
            total_quantity: None,
            components: vec![],
            created_at: now,
            updated_at: now,
        })
        .expect_err("stored meals must contain at least one component");
        assert!(matches!(error, JournalError::Internal(_)));
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        // Property: Serving quantities fail gram conversion even when the meal declares
        // a matching positive serving total, because that total supplies no mass conversion.
        // Why: A serving count alone must not be mistaken for a known weight in grams.
        #[test]
        fn meal_quantity_to_grams_non_mass_matching_total_errors(
            amount in 1i64..=1_000_000i64,
            total_amount in 1i64..=1_000_000i64,
        ) {
            let amount = Decimal::new(amount, 0);
            let total_amount = Decimal::new(total_amount, 0);
            let meal = make_meal(Some(
                MealQuantity::new(total_amount, UnitCode("serving".into())).unwrap(),
            ));
            let uc = mass_converter();
            let quantity = Quantity::new(amount, UnitCode("serving".into())).unwrap();
            prop_assert!(meal.quantity_to_grams(&quantity, &uc).is_err());
        }

        // Property: Declared grams rejects missing totals and positive totals
        // expressed in servings.
        // Why: Weight-dependent calculations require a known, positive mass total.
        #[test]
        fn meal_declared_grams_rejects_non_mass_or_missing_total(
            total_amount in 1i64..=1_000_000i64,
        ) {
            let uc = mass_converter();
            let meal = make_meal(None);
            prop_assert!(meal.declared_grams(&uc).is_err());

            let meal = make_meal(Some(
                MealQuantity::new(
                    Decimal::new(total_amount, 0),
                    UnitCode("serving".into()),
                )
                .unwrap(),
            ));
            prop_assert!(meal.declared_grams(&uc).is_err());
        }
    }
}

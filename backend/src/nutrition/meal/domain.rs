use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::nutrition::catalog::domain::calculation::{
    CalculatedNutrition, NutrientAmount, Quantity,
};
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::{NutrientCode, Product, ProductId, UnitCode};

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
    pub fn new(value: &str) -> Result<Self, NutritionError> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err(NutritionError::Validation("meal name is required".into()));
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

#[derive(Debug, Clone)]
pub enum MealComponentItem {
    Product(ProductId),
}

#[derive(Debug, Clone)]
pub struct MealComponent {
    pub id: Uuid,
    pub item: MealComponentItem,
    pub quantity_amount: Decimal,
    pub quantity_unit: UnitCode,
}

impl MealComponent {
    pub fn new(item: MealComponentItem, quantity: Quantity) -> Self {
        let (quantity_amount, quantity_unit) = quantity.into_parts();
        Self {
            id: Uuid::new_v4(),
            item,
            quantity_amount,
            quantity_unit,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Meal {
    pub id: MealId,
    pub user_id: Uuid,
    pub name: MealName,
    pub notes: Option<MealNotes>,
    pub total_quantity_amount: Option<Decimal>,
    pub total_quantity_unit: Option<UnitCode>,
    pub components: Vec<MealComponent>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Meal {
    pub fn create(
        user_id: Uuid,
        name: String,
        notes: Option<String>,
        total_quantity_amount: Option<Decimal>,
        total_quantity_unit: Option<UnitCode>,
        components: Vec<MealComponent>,
        now: DateTime<Utc>,
    ) -> Result<Self, NutritionError> {
        let name = MealName::new(&name)?;
        validate_meal_components(&components)?;

        Ok(Self {
            id: MealId::new(),
            user_id,
            name,
            notes: notes.map(MealNotes),
            total_quantity_amount,
            total_quantity_unit,
            components,
            created_at: now,
            updated_at: now,
        })
    }

    pub fn update(
        &self,
        name: Option<String>,
        notes: Option<Option<String>>,
        total_quantity_amount: Option<Option<Decimal>>,
        total_quantity_unit: Option<Option<UnitCode>>,
        components: Option<Vec<MealComponent>>,
        now: DateTime<Utc>,
    ) -> Result<Self, NutritionError> {
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
        Ok(Self {
            id: self.id,
            user_id: self.user_id,
            name,
            notes: notes
                .map(|n| n.map(MealNotes))
                .unwrap_or(self.notes.clone()),
            total_quantity_amount: total_quantity_amount.unwrap_or(self.total_quantity_amount),
            total_quantity_unit: total_quantity_unit.unwrap_or(self.total_quantity_unit.clone()),
            components,
            created_at: self.created_at,
            updated_at: now,
        })
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
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
        match (&self.total_quantity_amount, &self.total_quantity_unit) {
            (Some(total_amount), Some(total_unit))
                if total_unit.0 == unit.0 && *total_amount > Decimal::ZERO =>
            {
                Ok(amount / *total_amount * self.declared_grams(unit_converter)?)
            }
            _ => Err(format!(
                "cannot convert {} {} to grams for meal logging",
                amount, unit.0
            )),
        }
    }

    fn declared_grams(&self, unit_converter: &UnitConverter) -> Result<Decimal, String> {
        match (&self.total_quantity_amount, &self.total_quantity_unit) {
            (Some(amount), Some(unit)) if *amount > Decimal::ZERO => {
                unit_converter.mass_to_grams(*amount, unit).ok_or_else(|| {
                    "meal total quantity must be defined in a mass unit for non-mass logging".into()
                })
            }
            _ => Err(
                "meal total quantity must be defined in a mass unit for non-mass logging".into(),
            ),
        }
    }

    pub fn nutrition_for(
        &self,
        scale_quantity: &Quantity,
        products: &[(ProductId, Product)],
        unit_converter: &UnitConverter,
    ) -> Result<CalculatedNutrition, String> {
        let scale_grams = self.quantity_to_grams(scale_quantity, unit_converter)?;

        let mut total_nutrients: Vec<(NutrientCode, Decimal, UnitCode)> = Vec::new();
        let mut total_component_grams = Decimal::ZERO;

        for component in &self.components {
            match &component.item {
                MealComponentItem::Product(product_id) => {
                    let product = products
                        .iter()
                        .find(|(id, _)| id == product_id)
                        .map(|(_, product)| product)
                        .ok_or_else(|| {
                            format!("product {} in meal {} not found", product_id.0, self.id.0)
                        })?;

                    let component_qty =
                        Quantity::new(component.quantity_amount, component.quantity_unit.clone())
                            .map_err(|e| e.to_string())?;
                    let component_grams =
                        product.quantity_to_grams(&component_qty, unit_converter)?;
                    total_component_grams += component_grams;

                    let contribution_ratio = component_grams / Decimal::new(100, 0);
                    for pn in &product.nutrients {
                        let contributed_amount = pn.amount_per_100g.value() * contribution_ratio;
                        match total_nutrients
                            .iter_mut()
                            .find(|(code, _, _)| code == &pn.nutrient_code)
                        {
                            Some((_, existing_amount, _)) => *existing_amount += contributed_amount,
                            None => total_nutrients.push((
                                pn.nutrient_code.clone(),
                                contributed_amount,
                                pn.unit.clone(),
                            )),
                        }
                    }
                }
            }
        }

        if total_component_grams <= Decimal::ZERO {
            return Err("meal total quantity must be positive".into());
        }

        let scale_factor = scale_grams / total_component_grams;
        Ok(CalculatedNutrition {
            amounts: total_nutrients
                .into_iter()
                .map(|(code, amount, unit)| NutrientAmount {
                    nutrient_code: code,
                    amount: amount * scale_factor,
                    unit,
                })
                .collect(),
        })
    }
}

fn validate_meal_components(components: &[MealComponent]) -> Result<(), NutritionError> {
    if components.is_empty() {
        return Err(NutritionError::Validation(
            "meal must have at least one component".into(),
        ));
    }
    Ok(())
}

pub use crate::nutrition::error::NutritionError;

#[async_trait]
pub trait MealRepository: Send + Sync {
    async fn create(&self, meal: &Meal) -> Result<(), NutritionError>;
    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, NutritionError>;
    async fn list_all(&self) -> Result<Vec<Meal>, NutritionError>;
    async fn update(&self, meal: &Meal) -> Result<(), NutritionError>;
    async fn delete(&self, id: MealId) -> Result<(), NutritionError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct MealPolicy;

impl MealPolicy {
    pub fn authorize_view(&self, _actor_id: Uuid, _meal: &Meal) -> Result<(), NutritionError> {
        Ok(())
    }

    pub fn authorize_mutation(&self, actor_id: Uuid, meal: &Meal) -> Result<(), NutritionError> {
        if meal.is_owned_by(actor_id) {
            Ok(())
        } else {
            Err(NutritionError::Forbidden(
                "only the creator may modify this meal".into(),
            ))
        }
    }
}

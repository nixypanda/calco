use rust_decimal::Decimal;

use super::{AmountPer100g, NutrientCode, UnitCode};
use crate::nutrition::error::NutritionError;

#[derive(Debug, Clone)]
pub struct Quantity {
    amount: Decimal,
    unit: UnitCode,
}

impl Quantity {
    pub fn new(amount: Decimal, unit: UnitCode) -> Result<Self, NutritionError> {
        if amount <= Decimal::ZERO {
            return Err(NutritionError::Validation(
                "quantity amount must be positive".into(),
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

    pub fn into_parts(self) -> (Decimal, UnitCode) {
        (self.amount, self.unit)
    }
}

#[derive(Debug, Clone)]
pub struct NutrientAmount {
    pub nutrient_code: NutrientCode,
    pub amount: Decimal,
    pub unit: UnitCode,
}

#[derive(Debug, Clone)]
pub struct CalculatedNutrition {
    pub amounts: Vec<NutrientAmount>,
}

pub struct NutritionCalculator;

impl NutritionCalculator {
    pub fn calculate(
        grams: Decimal,
        nutrients: &[(NutrientCode, AmountPer100g, UnitCode)],
    ) -> CalculatedNutrition {
        let amounts = nutrients
            .iter()
            .map(|(code, per_100g, unit)| {
                let amount = per_100g.value() * grams / Decimal::new(100, 0);
                NutrientAmount {
                    nutrient_code: code.clone(),
                    amount,
                    unit: unit.clone(),
                }
            })
            .collect();
        CalculatedNutrition { amounts }
    }
}

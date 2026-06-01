use rust_decimal::Decimal;

use super::catalog::{AmountPer100g, NutrientCode, UnitCode};

#[derive(Debug, thiserror::Error)]
pub enum NutritionError {
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

#[derive(Debug, Clone)]
pub struct Quantity {
    pub amount: Decimal,
    pub unit: UnitCode,
}

impl Quantity {
    pub fn new(amount: Decimal, unit: UnitCode) -> Self {
        Self { amount, unit }
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
                let amount = per_100g.0 * grams / Decimal::new(100, 0);
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

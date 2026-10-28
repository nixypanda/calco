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

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn quantity_rejects_non_positive_and_accepts_positive() {
        let unit = UnitCode("serving".into());

        for amount in [Decimal::ZERO, Decimal::new(-1, 0)] {
            assert!(matches!(
                Quantity::new(amount, unit.clone()),
                Err(NutritionError::Validation(_))
            ));
        }

        assert!(Quantity::new(Decimal::ONE, unit).is_ok());
    }

    fn quantity_amounts() -> impl Strategy<Value = Decimal> {
        prop_oneof![
            any::<i64>().prop_map(Decimal::from),
            Just(Decimal::ZERO),
            Just(Decimal::ONE),
            Just(Decimal::from(-1i64)),
            Just(Decimal::new(1, 6)),
            Just(Decimal::new(-1, 6)),
            Just(Decimal::new(25, 1)),
            Just(Decimal::new(-25, 1)),
            (-1_000_000i64..=1_000_000i64, 1u32..=10)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
        ]
    }

    /// Non-negative decimals in `0..=1_000_000`, including real fractional values.
    fn bounded_nutrient_amounts() -> impl Strategy<Value = Decimal> {
        prop_oneof![
            Just(Decimal::ZERO),
            Just(Decimal::new(1, 6)),
            Just(Decimal::new(25, 1)),
            (0i64..=1_000_000i64, 0u32..=6)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
        ]
    }

    /// Positive grams in `0.000001..=1_000_000`, including real fractional values.
    fn bounded_grams() -> impl Strategy<Value = Decimal> {
        prop_oneof![
            Just(Decimal::new(1, 6)),
            Just(Decimal::new(25, 1)),
            (1i64..=1_000_000i64, 0u32..=3)
                .prop_map(|(mantissa, scale)| Decimal::new(mantissa, scale)),
        ]
    }

    fn nutrient_entries() -> impl Strategy<Value = Vec<(NutrientCode, AmountPer100g, UnitCode)>> {
        prop::collection::vec(
            (0u16..1_000, bounded_nutrient_amounts(), 0usize..3).prop_map(
                |(index, amount, unit_index)| {
                    (
                        NutrientCode(format!("NUTRIENT_{index:04}")),
                        AmountPer100g::new(amount).expect("generated amount is non-negative"),
                        UnitCode(["kcal", "g", "mg"][unit_index].into()),
                    )
                },
            ),
            0..=12,
        )
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        #[test]
        fn quantity_new_accepts_exactly_positive_amounts(amount in quantity_amounts()) {
            let unit = UnitCode("g".into());
            let result = Quantity::new(amount, unit.clone());

            if amount > Decimal::ZERO {
                let quantity = result.expect("positive amount must be accepted");
                prop_assert_eq!(quantity.amount(), amount);
                prop_assert_eq!(quantity.unit(), &unit);
            } else {
                prop_assert!(matches!(result, Err(NutritionError::Validation(_))));
            }
        }

        #[test]
        fn calculate_with_zero_grams_yields_zero_amounts(nutrients in nutrient_entries()) {
            let calculated = NutritionCalculator::calculate(Decimal::ZERO, &nutrients);

            prop_assert_eq!(calculated.amounts.len(), nutrients.len());
            for (amount, (code, _, unit)) in calculated.amounts.iter().zip(nutrients.iter()) {
                prop_assert_eq!(amount.amount, Decimal::ZERO);
                prop_assert_eq!(&amount.nutrient_code, code);
                prop_assert_eq!(&amount.unit, unit);
            }
        }

        #[test]
        fn calculate_with_empty_nutrients_yields_empty_output(grams in bounded_grams()) {
            let calculated = NutritionCalculator::calculate(grams, &[]);

            prop_assert!(calculated.amounts.is_empty());
        }

        #[test]
        fn calculate_preserves_order_code_and_unit(
            grams in bounded_grams(),
            nutrients in nutrient_entries(),
        ) {
            let calculated = NutritionCalculator::calculate(grams, &nutrients);

            prop_assert_eq!(calculated.amounts.len(), nutrients.len());
            for (amount, (code, per_100g, unit)) in calculated.amounts.iter().zip(nutrients.iter()) {
                prop_assert_eq!(&amount.nutrient_code, code);
                prop_assert_eq!(&amount.unit, unit);
                prop_assert_eq!(
                    amount.amount,
                    per_100g.value() * grams / Decimal::new(100, 0)
                );
            }
        }

        #[test]
        fn calculate_is_linear_in_grams(
            grams in bounded_grams(),
            multiplier in 1i64..=10i64,
            nutrients in nutrient_entries(),
        ) {
            let factor = Decimal::from(multiplier);
            let scaled_grams = grams * factor;
            let base = NutritionCalculator::calculate(grams, &nutrients);
            let scaled = NutritionCalculator::calculate(scaled_grams, &nutrients);

            prop_assert_eq!(base.amounts.len(), nutrients.len());
            prop_assert_eq!(scaled.amounts.len(), nutrients.len());
            for ((scaled_nutrient, base_nutrient), (code, _, unit)) in scaled
                .amounts
                .iter()
                .zip(base.amounts.iter())
                .zip(nutrients.iter())
            {
                prop_assert_eq!(&scaled_nutrient.nutrient_code, code);
                prop_assert_eq!(&base_nutrient.nutrient_code, code);
                prop_assert_eq!(&scaled_nutrient.unit, unit);
                prop_assert_eq!(&base_nutrient.unit, unit);
                prop_assert_eq!(scaled_nutrient.amount, base_nutrient.amount * factor);
            }
        }
    }
}

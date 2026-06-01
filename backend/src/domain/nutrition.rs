use rust_decimal::Decimal;

use super::catalog::{AmountPer100g, NutrientCode, Product, ProductId, UnitCode};
use super::meal::{Meal, MealComponentItem};
use super::units::UnitConverter;

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

pub fn product_quantity_to_grams(
    quantity: &Quantity,
    product: &Product,
    unit_converter: &UnitConverter,
) -> Result<Decimal, String> {
    if quantity.amount <= Decimal::ZERO {
        return Err("quantity amount must be positive".into());
    }
    if let Some(grams) = unit_converter.mass_to_grams(quantity.amount, &quantity.unit) {
        return Ok(grams);
    }
    for serving in &product.servings {
        if serving.unit.0 == quantity.unit.0 && serving.quantity > Decimal::ZERO {
            return Ok(serving.grams * (quantity.amount / serving.quantity));
        }
    }
    if let Some(size_g) = product.serving_size_g {
        let default_unit = product
            .default_unit
            .as_ref()
            .map(|u| u.0.as_str())
            .unwrap_or("serving");
        if quantity.unit.0 == default_unit {
            return Ok(size_g * quantity.amount);
        }
    }
    Err(format!(
        "cannot convert {} {} to grams",
        quantity.amount, quantity.unit.0
    ))
}

pub fn calculate_product_nutrition(
    product: &Product,
    quantity: &Quantity,
    unit_converter: &UnitConverter,
) -> Result<CalculatedNutrition, String> {
    let grams = product_quantity_to_grams(quantity, product, unit_converter)?;
    let nutrients: Vec<(NutrientCode, AmountPer100g, UnitCode)> = product
        .nutrients
        .iter()
        .map(|pn| {
            (
                pn.nutrient_code.clone(),
                pn.amount_per_100g.clone(),
                pn.unit.clone(),
            )
        })
        .collect();
    Ok(NutritionCalculator::calculate(grams, &nutrients))
}

pub fn meal_quantity_to_grams(
    quantity: &Quantity,
    meal: &Meal,
    unit_converter: &UnitConverter,
) -> Result<Decimal, String> {
    if quantity.amount <= Decimal::ZERO {
        return Err("quantity amount must be positive".into());
    }
    if let Some(grams) = unit_converter.mass_to_grams(quantity.amount, &quantity.unit) {
        return Ok(grams);
    }
    match (&meal.total_quantity_amount, &meal.total_quantity_unit) {
        (Some(total_amount), Some(total_unit))
            if total_unit.0 == quantity.unit.0 && *total_amount > Decimal::ZERO =>
        {
            Ok(quantity.amount / *total_amount * total_meal_declared_grams(meal, unit_converter)?)
        }
        _ => Err(format!(
            "cannot convert {} {} to grams for meal logging",
            quantity.amount, quantity.unit.0
        )),
    }
}

fn total_meal_declared_grams(
    meal: &Meal,
    unit_converter: &UnitConverter,
) -> Result<Decimal, String> {
    match (&meal.total_quantity_amount, &meal.total_quantity_unit) {
        (Some(amount), Some(unit)) if *amount > Decimal::ZERO => {
            unit_converter.mass_to_grams(*amount, unit).ok_or_else(|| {
                "meal total quantity must be defined in a mass unit for non-mass logging".into()
            })
        }
        _ => Err("meal total quantity must be defined in a mass unit for non-mass logging".into()),
    }
}

pub fn calculate_meal_nutrition(
    meal: &Meal,
    scale_quantity: &Quantity,
    products: &[(ProductId, Product)],
    unit_converter: &UnitConverter,
) -> Result<CalculatedNutrition, String> {
    let scale_grams = meal_quantity_to_grams(scale_quantity, meal, unit_converter)?;

    let mut total_nutrients: Vec<(NutrientCode, Decimal, UnitCode)> = Vec::new();
    let mut total_component_grams = Decimal::ZERO;

    for component in &meal.components {
        match &component.item {
            MealComponentItem::Product(product_id) => {
                let product = products
                    .iter()
                    .find(|(id, _)| id == product_id)
                    .map(|(_, product)| product)
                    .ok_or_else(|| {
                        format!("product {} in meal {} not found", product_id.0, meal.id.0)
                    })?;

                let component_qty =
                    Quantity::new(component.quantity_amount, component.quantity_unit.clone());
                let component_grams =
                    product_quantity_to_grams(&component_qty, product, unit_converter)?;
                total_component_grams += component_grams;

                let contribution_ratio = component_grams / Decimal::new(100, 0);
                for pn in &product.nutrients {
                    let contributed_amount = pn.amount_per_100g.0 * contribution_ratio;
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

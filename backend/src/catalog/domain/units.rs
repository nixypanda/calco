use std::collections::HashMap;

use rust_decimal::Decimal;

use super::UnitCode;

#[derive(Debug, Clone)]
pub struct UnitConverter {
    mass_factors: HashMap<String, Decimal>,
}

impl UnitConverter {
    pub fn new(mass_factors: HashMap<String, Decimal>) -> Self {
        Self { mass_factors }
    }

    pub fn from_entries<I>(entries: I) -> Self
    where
        I: IntoIterator<Item = (String, Decimal)>,
    {
        Self::new(entries.into_iter().collect())
    }

    pub fn mass_to_grams(&self, amount: Decimal, unit: &UnitCode) -> Option<Decimal> {
        self.mass_factors
            .get(&unit.0)
            .map(|factor| amount * *factor)
    }

    pub fn mass_unit_codes(&self) -> impl Iterator<Item = &str> {
        self.mass_factors.keys().map(|s| s.as_str())
    }
}

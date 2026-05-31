use std::collections::HashMap;

use rust_decimal::Decimal;

use super::catalog::UnitCode;

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
        self.mass_factors.get(&unit.0).map(|factor| amount * *factor)
    }

    pub fn mass_unit_codes(&self) -> impl Iterator<Item = &str> {
        self.mass_factors.keys().map(|s| s.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal::Decimal;
    use std::str::FromStr;

    fn sample() -> UnitConverter {
        UnitConverter::from_entries([
            ("g".to_string(), Decimal::from(1)),
            ("kg".to_string(), Decimal::from(1000)),
            ("mg".to_string(), Decimal::from_str("0.001").unwrap()),
            ("ug".to_string(), Decimal::from_str("0.000001").unwrap()),
        ])
    }

    #[test]
    fn mass_to_grams_known_codes() {
        let c = sample();
        assert_eq!(
            c.mass_to_grams(Decimal::from(100), &UnitCode("g".into())),
            Some(Decimal::from(100))
        );
        assert_eq!(
            c.mass_to_grams(Decimal::from(2), &UnitCode("kg".into())),
            Some(Decimal::from(2000))
        );
        assert_eq!(
            c.mass_to_grams(Decimal::from(500), &UnitCode("mg".into())),
            Some(Decimal::from_str("0.500").unwrap())
        );
    }

    #[test]
    fn mass_to_grams_unknown_code() {
        let c = sample();
        assert_eq!(c.mass_to_grams(Decimal::from(1), &UnitCode("cup".into())), None);
        assert_eq!(c.mass_to_grams(Decimal::from(1), &UnitCode("".into())), None);
    }

    #[test]
    fn preserves_decimal_precision() {
        let c = sample();
        let result = c
            .mass_to_grams(Decimal::from_str("2.5").unwrap(), &UnitCode("kg".into()))
            .unwrap();
        assert_eq!(result, Decimal::from_str("2500.0").unwrap());
    }

    #[test]
    fn is_intrinsic_mass() {
        fn is_intrinsic_mass(converter: &UnitConverter, unit: &UnitCode) -> bool {
            converter.mass_to_grams(Decimal::from(1), unit).is_some()
        }

        let c = sample();
        assert!(is_intrinsic_mass(&c, &UnitCode("g".into())));
        assert!(is_intrinsic_mass(&c, &UnitCode("mg".into())));
        assert!(!is_intrinsic_mass(&c, &UnitCode("cup".into())));
        assert!(!is_intrinsic_mass(&c, &UnitCode("serving".into())));
    }
}

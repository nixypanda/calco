use rust_decimal::Decimal;

use crate::nutrition::catalog::domain::{NutrientCode, UnitCode};
use crate::nutrition::error::NutritionError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NutrientDetailsSection {
    Overview,
    Carbohydrates,
    Fats,
    Limits,
    VitaminsMinerals,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NutrientGuidanceKind {
    Informational,
    Adequacy,
    Maximum,
}

/// A value object in an immutable, authoritative nutrition-details specification.
#[derive(Debug, Clone, PartialEq)]
pub struct NutrientGuidance {
    nutrient_code: NutrientCode,
    display_name: String,
    unit: UnitCode,
    section: NutrientDetailsSection,
    kind: NutrientGuidanceKind,
    reference_amount: Option<Decimal>,
}

impl NutrientGuidance {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        nutrient_code: NutrientCode,
        display_name: impl Into<String>,
        unit: UnitCode,
        section: NutrientDetailsSection,
        kind: NutrientGuidanceKind,
        reference_amount: Option<Decimal>,
    ) -> Result<Self, NutritionError> {
        match (kind, reference_amount) {
            (NutrientGuidanceKind::Informational, None) => {}
            (NutrientGuidanceKind::Informational, Some(_)) => {
                return Err(NutritionError::Validation(
                    "informational nutrient guidance cannot have a reference amount".into(),
                ));
            }
            (_, Some(amount)) if amount > Decimal::ZERO => {}
            _ => {
                return Err(NutritionError::Validation(
                    "adequacy and maximum nutrient guidance require a positive reference amount"
                        .into(),
                ));
            }
        }
        Ok(Self {
            nutrient_code,
            display_name: display_name.into(),
            unit,
            section,
            kind,
            reference_amount,
        })
    }

    pub fn nutrient_code(&self) -> &NutrientCode {
        &self.nutrient_code
    }
    pub fn display_name(&self) -> &str {
        &self.display_name
    }
    pub fn unit(&self) -> &UnitCode {
        &self.unit
    }
    pub fn section(&self) -> NutrientDetailsSection {
        self.section
    }
    pub fn kind(&self) -> NutrientGuidanceKind {
        self.kind
    }
    pub fn reference_amount(&self) -> Option<Decimal> {
        self.reference_amount
    }
}

/// The static FDA-backed configuration aggregate used to derive nutrition details.
#[derive(Debug, Clone, PartialEq)]
pub struct NutrientGuidanceSet {
    code: String,
    name: String,
    authority: String,
    jurisdiction: String,
    population_label: String,
    source_url: String,
    guidance: Vec<NutrientGuidance>,
}

impl NutrientGuidanceSet {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        code: impl Into<String>,
        name: impl Into<String>,
        authority: impl Into<String>,
        jurisdiction: impl Into<String>,
        population_label: impl Into<String>,
        source_url: impl Into<String>,
        guidance: Vec<NutrientGuidance>,
    ) -> Result<Self, NutritionError> {
        if guidance.is_empty() {
            return Err(NutritionError::Validation(
                "nutrient guidance set must contain at least one entry".into(),
            ));
        }
        let mut codes = std::collections::HashSet::new();
        if guidance
            .iter()
            .any(|entry| !codes.insert(entry.nutrient_code().0.clone()))
        {
            return Err(NutritionError::Validation(
                "nutrient guidance set cannot contain duplicate nutrient codes".into(),
            ));
        }
        Ok(Self {
            code: code.into(),
            name: name.into(),
            authority: authority.into(),
            jurisdiction: jurisdiction.into(),
            population_label: population_label.into(),
            source_url: source_url.into(),
            guidance,
        })
    }
    pub fn code(&self) -> &str {
        &self.code
    }
    pub fn name(&self) -> &str {
        &self.name
    }
    pub fn authority(&self) -> &str {
        &self.authority
    }
    pub fn jurisdiction(&self) -> &str {
        &self.jurisdiction
    }
    pub fn population_label(&self) -> &str {
        &self.population_label
    }
    pub fn source_url(&self) -> &str {
        &self.source_url
    }
    pub fn guidance(&self) -> &[NutrientGuidance] {
        &self.guidance
    }
}

pub trait NutrientGuidanceRepo: Send + Sync {
    fn current(&self) -> NutrientGuidanceSet;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guidance_enforces_reference_invariants() {
        let code = NutrientCode("IRON_MG".into());
        let unit = UnitCode("mg".into());
        assert!(
            NutrientGuidance::new(
                code.clone(),
                "Iron",
                unit.clone(),
                NutrientDetailsSection::VitaminsMinerals,
                NutrientGuidanceKind::Informational,
                Some(Decimal::ONE)
            )
            .is_err()
        );
        assert!(
            NutrientGuidance::new(
                code.clone(),
                "Iron",
                unit.clone(),
                NutrientDetailsSection::VitaminsMinerals,
                NutrientGuidanceKind::Adequacy,
                None
            )
            .is_err()
        );
        assert!(
            NutrientGuidance::new(
                code,
                "Iron",
                unit,
                NutrientDetailsSection::VitaminsMinerals,
                NutrientGuidanceKind::Maximum,
                Some(Decimal::ZERO)
            )
            .is_err()
        );
    }
}

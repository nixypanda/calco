use rust_decimal::Decimal;

use crate::nutrition::catalog::domain::{NutrientCode, UnitCode};
use crate::nutrition::guidance::domain::{
    NutrientDetailsSection, NutrientGuidance, NutrientGuidanceKind, NutrientGuidanceRepository,
    NutrientGuidanceSet,
};

#[derive(Clone, Default)]
pub struct StaticNutrientGuidanceRepository;

impl StaticNutrientGuidanceRepository {
    pub fn new() -> Self {
        Self
    }
}

impl NutrientGuidanceRepository for StaticNutrientGuidanceRepository {
    fn current(&self) -> NutrientGuidanceSet {
        NutrientGuidanceSet::new(
            "us_fda_dv_adult_2020", "FDA Nutrition Facts Daily Values", "U.S. Food and Drug Administration", "US", "Adults and children 4 years and older",
            "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels",
            vec![
                guidance("ENERGY_KCAL", "Energy", "kcal", NutrientDetailsSection::Overview, NutrientGuidanceKind::Informational, None),
                guidance("PROTEIN_G", "Protein", "g", NutrientDetailsSection::Overview, NutrientGuidanceKind::Informational, None),
                guidance("CARBS_G", "Carbohydrates", "g", NutrientDetailsSection::Overview, NutrientGuidanceKind::Informational, None),
                guidance("FAT_G", "Total Fat", "g", NutrientDetailsSection::Overview, NutrientGuidanceKind::Informational, None),
                guidance("FIBER_G", "Dietary Fiber", "g", NutrientDetailsSection::Carbohydrates, NutrientGuidanceKind::Adequacy, Some(Decimal::from(28))),
                guidance("SUGAR_G", "Total Sugars", "g", NutrientDetailsSection::Carbohydrates, NutrientGuidanceKind::Informational, None),
                guidance("ADDED_SUGAR_G", "Added Sugars", "g", NutrientDetailsSection::Carbohydrates, NutrientGuidanceKind::Maximum, Some(Decimal::from(50))),
                guidance("SATURATED_FAT_G", "Saturated Fat", "g", NutrientDetailsSection::Fats, NutrientGuidanceKind::Maximum, Some(Decimal::from(20))),
                guidance("TRANS_FAT_G", "Trans Fat", "g", NutrientDetailsSection::Fats, NutrientGuidanceKind::Informational, None),
                guidance("MONOUNSATURATED_FAT_G", "Monounsaturated Fat", "g", NutrientDetailsSection::Fats, NutrientGuidanceKind::Informational, None),
                guidance("POLYUNSATURATED_FAT_G", "Polyunsaturated Fat", "g", NutrientDetailsSection::Fats, NutrientGuidanceKind::Informational, None),
                guidance("SODIUM_MG", "Sodium", "mg", NutrientDetailsSection::Limits, NutrientGuidanceKind::Maximum, Some(Decimal::from(2300))),
                guidance("CHOLESTEROL_MG", "Cholesterol", "mg", NutrientDetailsSection::Limits, NutrientGuidanceKind::Maximum, Some(Decimal::from(300))),
                guidance("POTASSIUM_MG", "Potassium", "mg", NutrientDetailsSection::VitaminsMinerals, NutrientGuidanceKind::Adequacy, Some(Decimal::from(4700))),
                guidance("CALCIUM_MG", "Calcium", "mg", NutrientDetailsSection::VitaminsMinerals, NutrientGuidanceKind::Adequacy, Some(Decimal::from(1300))),
                guidance("IRON_MG", "Iron", "mg", NutrientDetailsSection::VitaminsMinerals, NutrientGuidanceKind::Adequacy, Some(Decimal::from(18))),
                guidance("MAGNESIUM_MG", "Magnesium", "mg", NutrientDetailsSection::VitaminsMinerals, NutrientGuidanceKind::Adequacy, Some(Decimal::from(420))),
                guidance("VITAMIN_D_UG", "Vitamin D", "ug", NutrientDetailsSection::VitaminsMinerals, NutrientGuidanceKind::Adequacy, Some(Decimal::from(20))),
                guidance("VITAMIN_B12_UG", "Vitamin B12", "ug", NutrientDetailsSection::VitaminsMinerals, NutrientGuidanceKind::Adequacy, Some(Decimal::new(24, 1))),
            ],
        ).expect("static FDA nutrient guidance must be valid")
    }
}

fn guidance(
    code: &str,
    name: &str,
    unit: &str,
    section: NutrientDetailsSection,
    kind: NutrientGuidanceKind,
    amount: Option<Decimal>,
) -> NutrientGuidance {
    NutrientGuidance::new(
        NutrientCode(code.into()),
        name,
        UnitCode(unit.into()),
        section,
        kind,
        amount,
    )
    .expect("static FDA nutrient guidance must be valid")
}

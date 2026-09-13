use std::collections::{HashMap, HashSet};

use rust_decimal::Decimal;

pub const MAX_CONVERSATION_TURNS: usize = 20;
pub const MAX_CONVERSATION_MESSAGE_CHARS: usize = 4_000;
pub const MAX_ASSISTANT_MESSAGE_CHARS: usize = 4_000;
pub const MAX_DRAFT_NAME_CHARS: usize = 200;
pub const MAX_DRAFT_CODE_CHARS: usize = 100;
pub const MAX_DRAFT_UNIT_CHARS: usize = 100;
pub const MAX_DRAFT_CATEGORIES: usize = 20;
pub const MAX_DRAFT_CATEGORY_CHARS: usize = 200;
pub const MAX_DRAFT_NUTRIENTS: usize = 100;
pub const MAX_DRAFT_SERVINGS: usize = 20;
pub const MAX_DRAFT_WARNINGS: usize = 20;
pub const MAX_DRAFT_WARNING_CHARS: usize = 500;

const MAX_NUTRIENT_G: Decimal = Decimal::from_parts(100, 0, 0, false, 0);
const MAX_NUTRIENT_MG: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_NUTRIENT_UG: Decimal = Decimal::from_parts(100_000_000, 0, 0, false, 0);
const MAX_NUTRIENT_KCAL: Decimal = Decimal::from_parts(1_000, 0, 0, false, 0);
const MAX_NUTRIENT_OTHER: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_SERVING_VALUE: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("assistant draft is invalid")]
pub struct DraftValidationError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ConversationValidationError {
    #[error("conversation must contain a turn")]
    Empty,
    #[error("conversation has too many turns")]
    TooManyTurns,
    #[error("conversation message must not be empty")]
    EmptyMessage,
    #[error("conversation message is too long")]
    MessageTooLong,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Conversation {
    turns: Vec<ConversationTurn>,
}

impl Conversation {
    pub fn new(turns: Vec<ConversationTurn>) -> Result<Self, ConversationValidationError> {
        if turns.is_empty() {
            return Err(ConversationValidationError::Empty);
        }
        if turns.len() > MAX_CONVERSATION_TURNS {
            return Err(ConversationValidationError::TooManyTurns);
        }
        Ok(Self { turns })
    }

    pub fn turns(&self) -> &[ConversationTurn] {
        &self.turns
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ConversationTurn {
    role: ConversationRole,
    text: String,
}

impl ConversationTurn {
    pub fn new(
        role: ConversationRole,
        text: impl Into<String>,
    ) -> Result<Self, ConversationValidationError> {
        let text = text.into().trim().to_owned();
        if text.is_empty() {
            return Err(ConversationValidationError::EmptyMessage);
        }
        if text.chars().count() > MAX_CONVERSATION_MESSAGE_CHARS {
            return Err(ConversationValidationError::MessageTooLong);
        }
        Ok(Self { role, text })
    }

    pub fn role(&self) -> ConversationRole {
        self.role
    }

    pub fn text(&self) -> &str {
        &self.text
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationRole {
    User,
    Assistant,
}

#[derive(Clone, PartialEq, Eq)]
pub enum FoodDraftTurn {
    NeedsClarification {
        assistant_message: String,
    },
    DraftReady {
        assistant_message: String,
        draft: FoodDraft,
        warnings: Vec<String>,
    },
}

impl FoodDraftTurn {
    pub fn clarification(message: impl Into<String>) -> Result<Self, DraftValidationError> {
        Ok(Self::NeedsClarification {
            assistant_message: bounded_text(message.into(), MAX_ASSISTANT_MESSAGE_CHARS)?,
        })
    }

    pub fn ready(
        message: impl Into<String>,
        draft: FoodDraft,
        warnings: Vec<String>,
    ) -> Result<Self, DraftValidationError> {
        if warnings.len() > MAX_DRAFT_WARNINGS
            || warnings
                .iter()
                .any(|value| value.chars().count() > MAX_DRAFT_WARNING_CHARS)
        {
            return Err(DraftValidationError);
        }
        Ok(Self::DraftReady {
            assistant_message: bounded_text(message.into(), MAX_ASSISTANT_MESSAGE_CHARS)?,
            draft,
            warnings: warnings
                .into_iter()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
                .collect(),
        })
    }
}

/// Domain policy for validating a draft against the current CalCo vocabulary.
///
/// The vocabulary is supplied at runtime, but the decision about whether a
/// model-produced draft is acceptable remains independent of any model adapter.
pub struct FoodDraftPolicy {
    nutrient_units: HashMap<String, String>,
    serving_units: HashSet<String>,
    required_nutrient_codes: HashSet<String>,
}

impl FoodDraftPolicy {
    pub fn new(
        nutrient_units: impl IntoIterator<Item = (String, String)>,
        serving_units: impl IntoIterator<Item = String>,
        required_nutrient_codes: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            nutrient_units: nutrient_units.into_iter().collect(),
            serving_units: serving_units.into_iter().collect(),
            required_nutrient_codes: required_nutrient_codes.into_iter().collect(),
        }
    }

    pub fn validate(&self, turn: &FoodDraftTurn) -> Result<(), DraftValidationError> {
        let FoodDraftTurn::DraftReady { draft, .. } = turn else {
            return Ok(());
        };

        let nutrient_codes: HashSet<&str> = draft
            .nutrients
            .iter()
            .map(|nutrient| nutrient.code.as_str())
            .collect();
        if self
            .required_nutrient_codes
            .iter()
            .any(|code| !nutrient_codes.contains(code.as_str()))
        {
            return Err(DraftValidationError);
        }
        for nutrient in &draft.nutrients {
            let unit = self
                .nutrient_units
                .get(&nutrient.code)
                .ok_or(DraftValidationError)?;
            if nutrient.amount_per_100g > maximum_nutrient(unit) {
                return Err(DraftValidationError);
            }
        }
        if draft
            .servings
            .iter()
            .any(|serving| !self.serving_units.contains(&serving.unit))
        {
            return Err(DraftValidationError);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct FoodDraft {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<DraftNutrient>,
    servings: Vec<DraftServing>,
}

pub struct FoodDraftBuilder {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<DraftNutrient>,
    servings: Vec<DraftServing>,
}

impl FoodDraftBuilder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            brand: None,
            categories: Vec::new(),
            default_quantity: None,
            default_unit: None,
            nutrients: Vec::new(),
            servings: Vec::new(),
        }
    }

    pub fn brand(mut self, brand: impl Into<String>) -> Self {
        self.brand = Some(brand.into());
        self
    }

    pub(crate) fn optional_brand(mut self, brand: Option<String>) -> Self {
        self.brand = brand;
        self
    }

    pub fn categories<I, S>(mut self, categories: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.categories = categories.into_iter().map(Into::into).collect();
        self
    }

    pub fn default_quantity(mut self, quantity: Decimal, unit: impl Into<String>) -> Self {
        self.default_quantity = Some(quantity);
        self.default_unit = Some(unit.into());
        self
    }

    pub(crate) fn optional_default_quantity(
        mut self,
        quantity: Option<Decimal>,
        unit: Option<String>,
    ) -> Self {
        self.default_quantity = quantity;
        self.default_unit = unit;
        self
    }

    pub fn nutrients(mut self, nutrients: impl IntoIterator<Item = DraftNutrient>) -> Self {
        self.nutrients = nutrients.into_iter().collect();
        self
    }

    pub fn servings(mut self, servings: impl IntoIterator<Item = DraftServing>) -> Self {
        self.servings = servings.into_iter().collect();
        self
    }

    pub fn build(self) -> Result<FoodDraft, DraftValidationError> {
        let Self {
            name,
            brand,
            categories,
            default_quantity,
            default_unit,
            nutrients,
            servings,
        } = self;
        if categories.len() > MAX_DRAFT_CATEGORIES
            || nutrients.len() > MAX_DRAFT_NUTRIENTS
            || servings.len() > MAX_DRAFT_SERVINGS
            || categories
                .iter()
                .any(|value| value.chars().count() > MAX_DRAFT_CATEGORY_CHARS)
        {
            return Err(DraftValidationError);
        }
        let name = bounded_text(name, MAX_DRAFT_NAME_CHARS)?;
        let brand = optional_bounded_text(brand, MAX_DRAFT_NAME_CHARS)?;
        let default_unit = optional_bounded_text(default_unit, MAX_DRAFT_UNIT_CHARS)?;
        if default_quantity.is_some_and(|value| value <= Decimal::ZERO)
            || default_quantity.is_some() != default_unit.is_some()
        {
            return Err(DraftValidationError);
        }
        if let Some(unit) = default_unit.as_deref()
            && unit != "g"
            && !servings.iter().any(|serving| serving.unit == unit)
        {
            return Err(DraftValidationError);
        }
        let mut normalized_categories = Vec::new();
        for category in categories {
            let category = category.trim().to_lowercase();
            if !category.is_empty() && !normalized_categories.contains(&category) {
                normalized_categories.push(category);
            }
        }
        let mut codes = HashSet::new();
        if nutrients
            .iter()
            .any(|value| !codes.insert(value.code.clone()))
        {
            return Err(DraftValidationError);
        }
        let mut serving_units = HashSet::new();
        if servings
            .iter()
            .any(|value| !serving_units.insert(value.unit.clone()))
        {
            return Err(DraftValidationError);
        }
        Ok(FoodDraft {
            name,
            brand,
            categories: normalized_categories,
            default_quantity,
            default_unit,
            nutrients,
            servings,
        })
    }
}

impl FoodDraft {
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn brand(&self) -> Option<&str> {
        self.brand.as_deref()
    }

    pub fn categories(&self) -> &[String] {
        &self.categories
    }

    pub fn default_quantity(&self) -> Option<Decimal> {
        self.default_quantity
    }

    pub fn default_unit(&self) -> Option<&str> {
        self.default_unit.as_deref()
    }

    pub fn nutrients(&self) -> &[DraftNutrient] {
        &self.nutrients
    }

    pub fn servings(&self) -> &[DraftServing] {
        &self.servings
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct DraftNutrient {
    code: String,
    amount_per_100g: Decimal,
}

impl DraftNutrient {
    pub fn new(code: String, amount_per_100g: Decimal) -> Result<Self, DraftValidationError> {
        let code = bounded_text(code, MAX_DRAFT_CODE_CHARS)?;
        if amount_per_100g < Decimal::ZERO {
            return Err(DraftValidationError);
        }
        Ok(Self {
            code,
            amount_per_100g: amount_per_100g.round_dp(6),
        })
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn amount_per_100g(&self) -> Decimal {
        self.amount_per_100g
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct DraftServing {
    unit: String,
    grams_per_unit: Decimal,
}

impl DraftServing {
    pub fn new(unit: String, grams_per_unit: Decimal) -> Result<Self, DraftValidationError> {
        let unit = bounded_text(unit, MAX_DRAFT_UNIT_CHARS)?;
        if grams_per_unit <= Decimal::ZERO || grams_per_unit > MAX_SERVING_VALUE {
            return Err(DraftValidationError);
        }
        Ok(Self {
            unit,
            grams_per_unit: grams_per_unit.round_dp(6),
        })
    }

    pub fn unit(&self) -> &str {
        &self.unit
    }

    pub fn grams_per_unit(&self) -> Decimal {
        self.grams_per_unit
    }
}

fn maximum_nutrient(unit: &str) -> Decimal {
    match unit.to_ascii_lowercase().as_str() {
        "g" => MAX_NUTRIENT_G,
        "mg" => MAX_NUTRIENT_MG,
        "ug" | "µg" => MAX_NUTRIENT_UG,
        "kcal" => MAX_NUTRIENT_KCAL,
        _ => MAX_NUTRIENT_OTHER,
    }
}

fn bounded_text(value: String, maximum: usize) -> Result<String, DraftValidationError> {
    let value = value.trim().to_owned();
    if value.is_empty() || value.chars().count() > maximum {
        return Err(DraftValidationError);
    }
    Ok(value)
}

fn optional_bounded_text(
    value: Option<String>,
    maximum: usize,
) -> Result<Option<String>, DraftValidationError> {
    value.map(|value| bounded_text(value, maximum)).transpose()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_is_non_empty_and_bounded() {
        assert!(matches!(
            Conversation::new(vec![]),
            Err(ConversationValidationError::Empty)
        ));
        let long = "x".repeat(MAX_CONVERSATION_MESSAGE_CHARS + 1);
        assert!(matches!(
            ConversationTurn::new(ConversationRole::User, long),
            Err(ConversationValidationError::MessageTooLong)
        ));
    }

    #[test]
    fn clarification_cannot_be_empty() {
        assert!(matches!(
            FoodDraftTurn::clarification("  "),
            Err(DraftValidationError)
        ));
    }

    #[test]
    fn draft_structure_limits_are_domain_invariants() {
        let categories = vec!["category".to_owned(); MAX_DRAFT_CATEGORIES + 1];
        assert!(matches!(
            FoodDraftBuilder::new("Dal").categories(categories).build(),
            Err(DraftValidationError)
        ));

        let serving = DraftServing::new("cup".into(), Decimal::ONE).unwrap();
        assert!(matches!(
            FoodDraftBuilder::new("Dal")
                .servings([serving.clone(), serving])
                .build(),
            Err(DraftValidationError)
        ));
    }

    #[test]
    fn draft_builder_defaults_optional_fields_and_normalizes_categories() {
        let draft = FoodDraftBuilder::new(" Dal ")
            .brand(" Amul ")
            .categories([" Dairy ", "dairy", " "])
            .default_quantity(Decimal::from(200), "g")
            .build()
            .unwrap();

        assert_eq!(draft.name(), "Dal");
        assert_eq!(draft.brand(), Some("Amul"));
        assert_eq!(draft.categories(), &["dairy"]);
        assert_eq!(draft.default_quantity(), Some(Decimal::from(200)));
        assert_eq!(draft.default_unit(), Some("g"));
        assert!(draft.nutrients().is_empty());
        assert!(draft.servings().is_empty());
    }

    #[test]
    fn draft_builder_enforces_default_quantity_and_duplicate_code_invariants() {
        assert!(matches!(
            FoodDraftBuilder::new("Dal")
                .optional_default_quantity(Some(Decimal::ONE), None)
                .build(),
            Err(DraftValidationError)
        ));

        let nutrient = DraftNutrient::new("PROTEIN_G".into(), Decimal::ONE).unwrap();
        assert!(matches!(
            FoodDraftBuilder::new("Dal")
                .nutrients([nutrient.clone(), nutrient])
                .build(),
            Err(DraftValidationError)
        ));
    }

    #[test]
    fn draft_policy_enforces_runtime_vocabulary_and_plausibility() {
        let policy = FoodDraftPolicy::new(
            [("ENERGY_KCAL".into(), "kcal".into())],
            ["cup".into()],
            ["ENERGY_KCAL".into()],
        );
        let excessive_energy =
            DraftNutrient::new("ENERGY_KCAL".into(), Decimal::from(1_001)).unwrap();
        let draft = FoodDraftBuilder::new("Dal")
            .nutrients([excessive_energy])
            .build()
            .unwrap();
        let turn = FoodDraftTurn::ready("Review", draft, vec![]).unwrap();

        assert!(matches!(policy.validate(&turn), Err(DraftValidationError)));
    }
}

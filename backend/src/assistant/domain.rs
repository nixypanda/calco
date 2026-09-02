use std::collections::HashSet;

use rust_decimal::Decimal;

/// Product-level constraints for transient assistant conversation data.
pub const MAX_CONVERSATION_TURNS: usize = 20;
pub const MAX_CONVERSATION_MESSAGE_CHARS: usize = 4_000;
pub const MAX_ASSISTANT_MESSAGE_CHARS: usize = 4_000;
pub const MAX_DRAFT_NAME_CHARS: usize = 200;
pub const MAX_DRAFT_CODE_CHARS: usize = 100;
pub const MAX_DRAFT_UNIT_CHARS: usize = 100;
pub const MAX_DRAFT_SERVING_LABEL_CHARS: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AssistantError {
    #[error("assistant is disabled")]
    Disabled,
    #[error("assistant validation failed: {0}")]
    Validation(String),
    #[error("assistant model is unavailable")]
    ModelUnavailable,
    #[error("food-assistant request rate is limited")]
    RateLimited,
    #[error("food assistant is busy")]
    Busy,
    #[error("assistant model returned an invalid response")]
    InvalidModelResponse,
    #[error("assistant operation failed")]
    Internal,
}

/// A short-lived conversation supplied by the caller for one draft request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conversation {
    pub turns: Vec<ConversationTurn>,
}

impl Conversation {
    pub fn new(turns: Vec<ConversationTurn>) -> Result<Self, AssistantError> {
        if turns.is_empty() {
            return Err(AssistantError::Validation(
                "conversation must contain at least one turn".into(),
            ));
        }
        if turns.len() > MAX_CONVERSATION_TURNS {
            return Err(AssistantError::Validation(format!(
                "conversation cannot contain more than {MAX_CONVERSATION_TURNS} turns"
            )));
        }

        Ok(Self { turns })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationTurn {
    pub role: ConversationRole,
    pub text: String,
}

impl ConversationTurn {
    pub fn new(role: ConversationRole, text: impl Into<String>) -> Result<Self, AssistantError> {
        let text = text.into().trim().to_owned();
        if text.is_empty() {
            return Err(AssistantError::Validation(
                "conversation text is required".into(),
            ));
        }
        if text.chars().count() > MAX_CONVERSATION_MESSAGE_CHARS {
            return Err(AssistantError::Validation(format!(
                "conversation text cannot exceed {MAX_CONVERSATION_MESSAGE_CHARS} characters"
            )));
        }

        Ok(Self { role, text })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DraftStatus {
    NeedsClarification,
    DraftReady,
}

/// A draft of the fields CalCo's ordinary custom-food form can accept.
///
/// This is intentionally distinct from nutrition's `CustomFoodInput`: model
/// output is a transient, untrusted assistant concept until the later
/// application policy validates it against CalCo's live vocabulary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoodDraft {
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub serving_size_g: Option<Decimal>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrients: Vec<DraftNutrient>,
    pub servings: Vec<DraftServing>,
}

impl FoodDraft {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        name: impl Into<String>,
        brand: Option<String>,
        categories: Vec<String>,
        serving_size_g: Option<Decimal>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<DraftNutrient>,
        servings: Vec<DraftServing>,
    ) -> Result<Self, AssistantError> {
        let name = required_text("draft name", name.into(), MAX_DRAFT_NAME_CHARS)?;
        let brand = optional_text("draft brand", brand, MAX_DRAFT_NAME_CHARS)?;
        let default_unit = optional_text("default unit", default_unit, MAX_DRAFT_UNIT_CHARS)?;

        if serving_size_g.is_some_and(|grams| grams <= Decimal::ZERO) {
            return Err(AssistantError::Validation(
                "serving size in grams must be positive".into(),
            ));
        }
        if default_quantity.is_some_and(|quantity| quantity <= Decimal::ZERO) {
            return Err(AssistantError::Validation(
                "default quantity must be positive".into(),
            ));
        }
        if default_quantity.is_some() != default_unit.is_some() {
            return Err(AssistantError::Validation(
                "default quantity and default unit must be provided together".into(),
            ));
        }

        let categories = normalize_categories(categories);
        let mut nutrient_codes = HashSet::with_capacity(nutrients.len());
        for nutrient in &nutrients {
            if !nutrient_codes.insert(nutrient.code.clone()) {
                return Err(AssistantError::Validation(format!(
                    "duplicate nutrient code: {}",
                    nutrient.code
                )));
            }
        }

        Ok(Self {
            name,
            brand,
            categories,
            serving_size_g,
            default_quantity,
            default_unit,
            nutrients,
            servings,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DraftNutrient {
    pub code: String,
    pub amount_per_100g: Decimal,
}

impl DraftNutrient {
    pub fn new(code: impl Into<String>, amount_per_100g: Decimal) -> Result<Self, AssistantError> {
        let code = required_text("nutrient code", code.into(), MAX_DRAFT_CODE_CHARS)?;
        if amount_per_100g < Decimal::ZERO {
            return Err(AssistantError::Validation(
                "nutrient amount per 100 grams cannot be negative".into(),
            ));
        }

        Ok(Self {
            code,
            amount_per_100g,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DraftServing {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

impl DraftServing {
    pub fn new(
        label: impl Into<String>,
        quantity: Decimal,
        unit: impl Into<String>,
        grams: Decimal,
    ) -> Result<Self, AssistantError> {
        let label = required_text("serving label", label.into(), MAX_DRAFT_SERVING_LABEL_CHARS)?;
        let unit = required_text("serving unit", unit.into(), MAX_DRAFT_UNIT_CHARS)?;
        if quantity <= Decimal::ZERO {
            return Err(AssistantError::Validation(
                "serving quantity must be positive".into(),
            ));
        }
        if grams <= Decimal::ZERO {
            return Err(AssistantError::Validation(
                "serving grams must be positive".into(),
            ));
        }

        Ok(Self {
            label,
            quantity,
            unit,
            grams,
        })
    }
}

/// The assistant's reply for one turn. A completed draft is either present or
/// absent according to the response status; no partial completion is allowed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoodDraftTurn {
    pub assistant_message: String,
    pub status: DraftStatus,
    pub draft: Option<FoodDraft>,
    pub warnings: Vec<String>,
}

impl FoodDraftTurn {
    pub fn new(
        assistant_message: impl Into<String>,
        status: DraftStatus,
        draft: Option<FoodDraft>,
        warnings: Vec<String>,
    ) -> Result<Self, AssistantError> {
        let assistant_message = required_text(
            "assistant message",
            assistant_message.into(),
            MAX_ASSISTANT_MESSAGE_CHARS,
        )?;

        match (status, draft.is_some()) {
            (DraftStatus::DraftReady, false) => {
                return Err(AssistantError::Validation(
                    "draft-ready response requires a draft".into(),
                ));
            }
            (DraftStatus::NeedsClarification, true) => {
                return Err(AssistantError::Validation(
                    "clarification response cannot contain a completed draft".into(),
                ));
            }
            _ => {}
        }

        Ok(Self {
            assistant_message,
            status,
            draft,
            warnings: warnings
                .into_iter()
                .map(|warning| warning.trim().to_owned())
                .filter(|warning| !warning.is_empty())
                .collect(),
        })
    }
}

fn required_text(
    field: &str,
    value: String,
    maximum_chars: usize,
) -> Result<String, AssistantError> {
    let value = value.trim().to_owned();
    if value.is_empty() {
        return Err(AssistantError::Validation(format!("{field} is required")));
    }
    if value.chars().count() > maximum_chars {
        return Err(AssistantError::Validation(format!(
            "{field} cannot exceed {maximum_chars} characters"
        )));
    }
    Ok(value)
}

fn optional_text(
    field: &str,
    value: Option<String>,
    maximum_chars: usize,
) -> Result<Option<String>, AssistantError> {
    value
        .map(|value| required_text(field, value, maximum_chars))
        .transpose()
}

fn normalize_categories(categories: Vec<String>) -> Vec<String> {
    let mut normalized = Vec::new();
    for category in categories {
        let category = category.trim().to_lowercase();
        if !category.is_empty() && !normalized.contains(&category) {
            normalized.push(category);
        }
    }
    normalized
}

#[cfg(test)]
mod tests {
    use rust_decimal::Decimal;

    use super::{
        AssistantError, Conversation, ConversationRole, ConversationTurn, DraftNutrient,
        DraftServing, DraftStatus, FoodDraft, FoodDraftTurn, MAX_CONVERSATION_TURNS,
    };

    fn draft() -> FoodDraft {
        FoodDraft::new(
            "Dal rice",
            None,
            vec![" Indian ".into(), "indian".into()],
            Some(Decimal::new(250, 0)),
            Some(Decimal::ONE),
            Some("serving".into()),
            vec![DraftNutrient::new("ENERGY_KCAL", Decimal::new(120, 0)).unwrap()],
            vec![
                DraftServing::new("1 bowl", Decimal::ONE, "serving", Decimal::new(250, 0)).unwrap(),
            ],
        )
        .unwrap()
    }

    #[test]
    fn clarification_and_draft_statuses_are_consistent() {
        let ready_without_draft =
            FoodDraftTurn::new("Ready", DraftStatus::DraftReady, None, vec![]);
        let clarification_with_draft = FoodDraftTurn::new(
            "How much?",
            DraftStatus::NeedsClarification,
            Some(draft()),
            vec![],
        );

        assert!(matches!(
            ready_without_draft,
            Err(AssistantError::Validation(_))
        ));
        assert!(matches!(
            clarification_with_draft,
            Err(AssistantError::Validation(_))
        ));
        assert!(
            FoodDraftTurn::new("Ready", DraftStatus::DraftReady, Some(draft()), vec![]).is_ok()
        );
    }

    #[test]
    fn draft_rejects_duplicate_nutrients_and_incomplete_default_quantity() {
        let duplicate = FoodDraft::new(
            "Food",
            None,
            vec![],
            None,
            None,
            None,
            vec![
                DraftNutrient::new("ENERGY_KCAL", Decimal::ONE).unwrap(),
                DraftNutrient::new("ENERGY_KCAL", Decimal::ZERO).unwrap(),
            ],
            vec![],
        );
        let incomplete_quantity = FoodDraft::new(
            "Food",
            None,
            vec![],
            None,
            Some(Decimal::ONE),
            None,
            vec![],
            vec![],
        );

        assert!(matches!(duplicate, Err(AssistantError::Validation(_))));
        assert!(matches!(
            incomplete_quantity,
            Err(AssistantError::Validation(_))
        ));
    }

    #[test]
    fn draft_values_reject_invalid_amounts_and_normalize_categories() {
        assert!(DraftNutrient::new("PROTEIN_G", Decimal::NEGATIVE_ONE).is_err());
        assert!(DraftServing::new("1 bowl", Decimal::ZERO, "serving", Decimal::ONE).is_err());

        let draft = draft();
        assert_eq!(draft.categories, vec!["indian"]);
    }

    #[test]
    fn conversations_are_bounded() {
        let turns = (0..=MAX_CONVERSATION_TURNS)
            .map(|_| ConversationTurn::new(ConversationRole::User, "Food").unwrap())
            .collect();

        assert!(matches!(
            Conversation::new(turns),
            Err(AssistantError::Validation(_))
        ));
    }
}

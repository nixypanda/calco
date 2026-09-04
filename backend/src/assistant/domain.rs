use std::collections::HashSet;

use rust_decimal::Decimal;
use serde::Serialize;

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
    #[error("assistant input is invalid")]
    InvalidInput,
    #[error("assistant model is unavailable")]
    ModelUnavailable,
    #[error("assistant model returned an invalid response")]
    InvalidModelResponse,
    #[error("assistant operation failed")]
    Internal,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Conversation {
    turns: Vec<ConversationTurn>,
}

impl Conversation {
    pub fn new(turns: Vec<ConversationTurn>) -> Result<Self, AssistantError> {
        if turns.is_empty() || turns.len() > MAX_CONVERSATION_TURNS {
            return Err(AssistantError::InvalidInput);
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
    pub fn new(role: ConversationRole, text: impl Into<String>) -> Result<Self, AssistantError> {
        let text = text.into().trim().to_owned();
        if text.is_empty() || text.chars().count() > MAX_CONVERSATION_MESSAGE_CHARS {
            return Err(AssistantError::InvalidInput);
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
    pub fn clarification(message: impl Into<String>) -> Result<Self, AssistantError> {
        Ok(Self::NeedsClarification {
            assistant_message: bounded_text(message.into(), MAX_ASSISTANT_MESSAGE_CHARS)?,
        })
    }

    pub fn ready(
        message: impl Into<String>,
        draft: FoodDraft,
        warnings: Vec<String>,
    ) -> Result<Self, AssistantError> {
        Ok(Self::DraftReady {
            assistant_message: bounded_text(message.into(), MAX_ASSISTANT_MESSAGE_CHARS)?,
            draft,
            warnings,
        })
    }
}

#[derive(Clone, PartialEq, Eq, Serialize)]
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
        name: String,
        brand: Option<String>,
        categories: Vec<String>,
        serving_size_g: Option<Decimal>,
        default_quantity: Option<Decimal>,
        default_unit: Option<String>,
        nutrients: Vec<DraftNutrient>,
        servings: Vec<DraftServing>,
    ) -> Result<Self, AssistantError> {
        let name = bounded_text(name, MAX_DRAFT_NAME_CHARS)?;
        let brand = optional_bounded_text(brand, MAX_DRAFT_NAME_CHARS)?;
        let default_unit = optional_bounded_text(default_unit, MAX_DRAFT_UNIT_CHARS)?;
        if serving_size_g.is_some_and(|value| value <= Decimal::ZERO)
            || default_quantity.is_some_and(|value| value <= Decimal::ZERO)
            || default_quantity.is_some() != default_unit.is_some()
        {
            return Err(AssistantError::InvalidModelResponse);
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
            return Err(AssistantError::InvalidModelResponse);
        }
        Ok(Self {
            name,
            brand,
            categories: normalized_categories,
            serving_size_g,
            default_quantity,
            default_unit,
            nutrients,
            servings,
        })
    }
}

#[derive(Clone, PartialEq, Eq, Serialize)]
pub struct DraftNutrient {
    pub code: String,
    pub amount_per_100g: Decimal,
}

impl DraftNutrient {
    pub fn new(code: String, amount_per_100g: Decimal) -> Result<Self, AssistantError> {
        let code = bounded_text(code, MAX_DRAFT_CODE_CHARS)?;
        if amount_per_100g < Decimal::ZERO {
            return Err(AssistantError::InvalidModelResponse);
        }
        Ok(Self {
            code,
            amount_per_100g: amount_per_100g.round_dp(6),
        })
    }
}

#[derive(Clone, PartialEq, Eq, Serialize)]
pub struct DraftServing {
    pub label: String,
    pub quantity: Decimal,
    pub unit: String,
    pub grams: Decimal,
}

impl DraftServing {
    pub fn new(
        label: String,
        quantity: Decimal,
        unit: String,
        grams: Decimal,
    ) -> Result<Self, AssistantError> {
        let label = bounded_text(label, MAX_DRAFT_SERVING_LABEL_CHARS)?;
        let unit = bounded_text(unit, MAX_DRAFT_UNIT_CHARS)?;
        if quantity <= Decimal::ZERO || grams <= Decimal::ZERO {
            return Err(AssistantError::InvalidModelResponse);
        }
        Ok(Self {
            label,
            quantity,
            unit,
            grams,
        })
    }
}

fn bounded_text(value: String, maximum: usize) -> Result<String, AssistantError> {
    let value = value.trim().to_owned();
    if value.is_empty() || value.chars().count() > maximum {
        return Err(AssistantError::InvalidModelResponse);
    }
    Ok(value)
}

fn optional_bounded_text(
    value: Option<String>,
    maximum: usize,
) -> Result<Option<String>, AssistantError> {
    value.map(|value| bounded_text(value, maximum)).transpose()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_is_non_empty_and_bounded() {
        assert!(matches!(
            Conversation::new(vec![]),
            Err(AssistantError::InvalidInput)
        ));
        let long = "x".repeat(MAX_CONVERSATION_MESSAGE_CHARS + 1);
        assert!(matches!(
            ConversationTurn::new(ConversationRole::User, long),
            Err(AssistantError::InvalidInput)
        ));
    }

    #[test]
    fn clarification_cannot_be_empty() {
        assert!(matches!(
            FoodDraftTurn::clarification("  "),
            Err(AssistantError::InvalidModelResponse)
        ));
    }
}

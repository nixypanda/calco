use rust_decimal::Decimal;
use serde::Deserialize;

use crate::assistant::domain::{
    AssistantError, DraftNutrient, DraftServing, FoodDraft, FoodDraftTurn,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireTurn {
    assistant_message: String,
    status: WireStatus,
    draft: Option<WireDraft>,
    warnings: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum WireStatus {
    NeedsClarification,
    DraftReady,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireDraft {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<WireNutrient>,
    servings: Vec<WireServing>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireNutrient {
    code: String,
    amount_per_100g: Decimal,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireServing {
    unit: String,
    grams_per_unit: Decimal,
}

pub(super) fn parse_model_turn(content: &str) -> Result<FoodDraftTurn, AssistantError> {
    let wire: WireTurn = serde_json::from_str(content).map_err(|error| {
        tracing::error!(content = %content, error = %error, "failed to parse model response");
        AssistantError::InvalidModelResponse
    })?;
    match wire.status {
        WireStatus::NeedsClarification if wire.draft.is_none() && wire.warnings.is_empty() => {
            FoodDraftTurn::clarification(wire.assistant_message)
        }
        WireStatus::DraftReady => {
            let draft = parse_draft(wire.draft.ok_or(AssistantError::InvalidModelResponse)?)?;
            FoodDraftTurn::ready(wire.assistant_message, draft, wire.warnings)
        }
        _ => Err(AssistantError::InvalidModelResponse),
    }
}

fn parse_draft(wire: WireDraft) -> Result<FoodDraft, AssistantError> {
    let mut nutrients = Vec::with_capacity(wire.nutrients.len());
    for value in wire.nutrients {
        nutrients.push(DraftNutrient::new(value.code, value.amount_per_100g)?);
    }
    let mut servings = Vec::with_capacity(wire.servings.len());
    for value in wire.servings {
        servings.push(DraftServing::new(value.unit, value.grams_per_unit)?);
    }
    FoodDraft::new(
        wire.name,
        wire.brand,
        wire.categories,
        wire.default_quantity,
        wire.default_unit,
        nutrients,
        servings,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_clarification_directly_to_final_type() {
        let value = parse_model_turn(r#"{"assistant_message":"How many grams?","status":"needs_clarification","draft":null,"warnings":[]}"#).unwrap();
        assert!(matches!(value, FoodDraftTurn::NeedsClarification { .. }));
    }

    #[test]
    fn rejects_unknown_fields_and_incomplete_drafts() {
        assert!(parse_model_turn(r#"{"assistant_message":"x","status":"needs_clarification","draft":null,"warnings":[],"extra":1}"#).is_err());
        assert!(
            parse_model_turn(
                r#"{"assistant_message":"ready","status":"draft_ready","draft":null,"warnings":[]}"#
            )
            .is_err()
        );
    }

    #[test]
    fn parses_complete_draft_directly_to_reviewable_domain_type() {
        let value = parse_model_turn(r#"{"assistant_message":"Review this estimate","status":"draft_ready","draft":{"name":" Dal ","brand":null,"categories":[" Indian "],"default_quantity":1,"default_unit":"g","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":"120.1234567"}],"servings":[]},"warnings":["Estimated"]}"#).unwrap();
        let FoodDraftTurn::DraftReady { draft, .. } = value else {
            panic!("expected a complete draft")
        };
        assert_eq!(draft.name(), "Dal");
        assert_eq!(draft.categories(), &["indian"]);
        assert_eq!(
            draft.nutrients()[0].amount_per_100g(),
            Decimal::new(120_123457, 6)
        );
    }

    #[test]
    fn default_unit_must_be_grams_or_use_a_configured_serving_unit() {
        let default_cup = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":1,"default_unit":"cup","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":120}],"servings":[]},"warnings":[]}"#;
        assert!(parse_model_turn(default_cup).is_err());
        let serving_cup = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":2,"default_unit":"cup","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":120}],"servings":[{"unit":"cup","grams_per_unit":240}]},"warnings":[]}"#;
        let turn = parse_model_turn(serving_cup).unwrap();
        let FoodDraftTurn::DraftReady { draft, .. } = turn else {
            panic!("expected ready draft")
        };
        assert_eq!(draft.servings()[0].unit(), "cup");
        assert_eq!(draft.default_quantity(), Some(Decimal::new(2, 0)));
        assert_eq!(draft.default_unit(), Some("cup"));
    }
}

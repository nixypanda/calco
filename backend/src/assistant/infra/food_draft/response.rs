use rust_decimal::Decimal;
use serde::Deserialize;

use crate::assistant::app::AssistantError;
use crate::assistant::domain::{
    DraftNutrient, DraftServing, DraftValidationError, FoodDraft, FoodDraftBuilder,
    FoodDraftPurpose, FoodDraftTurn, SuggestedLog,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireTurn {
    assistant_message: String,
    status: WireStatus,
    draft: Option<WireDraft>,
    #[serde(default)]
    suggested_log: Option<WireSuggestedLog>,
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireSuggestedLog {
    amount: Decimal,
    unit: String,
    total_weight_grams: Decimal,
}

pub(super) fn parse(
    purpose: FoodDraftPurpose,
    content: &str,
) -> Result<FoodDraftTurn, AssistantError> {
    let wire: WireTurn = serde_json::from_str(content).map_err(|error| {
        tracing::error!(content = %content, error = %error, "failed to parse model response");
        AssistantError::InvalidModelResponse
    })?;
    match wire.status {
        WireStatus::NeedsClarification
            if wire.draft.is_none() && wire.suggested_log.is_none() && wire.warnings.is_empty() =>
        {
            FoodDraftTurn::clarification(wire.assistant_message).map_err(invalid_draft)
        }
        WireStatus::DraftReady => {
            let draft = parse_draft(wire.draft.ok_or(AssistantError::InvalidModelResponse)?)?;
            match (purpose, wire.suggested_log) {
                (FoodDraftPurpose::CustomFood, None) => {
                    FoodDraftTurn::ready(wire.assistant_message, draft, wire.warnings)
                        .map_err(invalid_draft)
                }
                (FoodDraftPurpose::AdHocLog, Some(value)) => FoodDraftTurn::ready_for_log(
                    wire.assistant_message,
                    draft,
                    SuggestedLog::new(value.amount, value.unit, value.total_weight_grams)
                        .map_err(invalid_draft)?,
                    wire.warnings,
                )
                .map_err(invalid_draft),
                _ => Err(AssistantError::InvalidModelResponse),
            }
        }
        _ => Err(AssistantError::InvalidModelResponse),
    }
}

fn parse_draft(wire: WireDraft) -> Result<FoodDraft, AssistantError> {
    let mut nutrients = Vec::with_capacity(wire.nutrients.len());
    for value in wire.nutrients {
        nutrients
            .push(DraftNutrient::new(value.code, value.amount_per_100g).map_err(invalid_draft)?);
    }
    let mut servings = Vec::with_capacity(wire.servings.len());
    for value in wire.servings {
        servings.push(DraftServing::new(value.unit, value.grams_per_unit).map_err(invalid_draft)?);
    }
    FoodDraftBuilder::new(wire.name)
        .optional_brand(wire.brand)
        .categories(wire.categories)
        .optional_default_quantity(wire.default_quantity, wire.default_unit)
        .nutrients(nutrients)
        .servings(servings)
        .build()
        .map_err(invalid_draft)
}

fn invalid_draft(_error: DraftValidationError) -> AssistantError {
    AssistantError::InvalidModelResponse
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unknown_fields_and_incomplete_drafts() {
        assert!(parse(FoodDraftPurpose::CustomFood, r#"{"assistant_message":"x","status":"needs_clarification","draft":null,"warnings":[],"extra":1}"#).is_err());
        assert!(
            parse(
                FoodDraftPurpose::CustomFood,
                r#"{"assistant_message":"ready","status":"draft_ready","draft":null,"warnings":[]}"#
            )
            .is_err()
        );
    }

    #[test]
    fn parses_complete_draft_directly_to_reviewable_domain_type() {
        let value = parse(FoodDraftPurpose::CustomFood, r#"{"assistant_message":"Review this estimate","status":"draft_ready","draft":{"name":" Dal ","brand":null,"categories":[" Indian "],"default_quantity":1,"default_unit":"g","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":"120.1234567"}],"servings":[]},"warnings":["Estimated"]}"#).unwrap();
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
        assert!(parse(FoodDraftPurpose::CustomFood, default_cup).is_err());
        let serving_cup = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":2,"default_unit":"cup","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":120}],"servings":[{"unit":"cup","grams_per_unit":240}]},"warnings":[]}"#;
        let turn = parse(FoodDraftPurpose::CustomFood, serving_cup).unwrap();
        let FoodDraftTurn::DraftReady { draft, .. } = turn else {
            panic!("expected ready draft")
        };
        assert_eq!(draft.servings()[0].unit(), "cup");
        assert_eq!(draft.default_quantity(), Some(Decimal::new(2, 0)));
        assert_eq!(draft.default_unit(), Some("cup"));
    }

    #[test]
    fn ad_hoc_draft_requires_a_suggested_log() {
        let without = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":1,"default_unit":"g","nutrients":[],"servings":[]},"warnings":[]}"#;
        assert!(parse(FoodDraftPurpose::AdHocLog, without).is_err());
        let with = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":1,"default_unit":"bowl","nutrients":[],"servings":[{"unit":"bowl","grams_per_unit":250}]},"suggested_log":{"amount":1,"unit":"bowl","total_weight_grams":250},"warnings":[]}"#;
        assert!(parse(FoodDraftPurpose::AdHocLog, with).is_ok());
    }
}

use std::collections::{HashMap, HashSet};

use rust_decimal::Decimal;
use serde::Deserialize;

use crate::assistant::application::FoodVocabulary;
use crate::assistant::domain::{
    AssistantError, DraftNutrient, DraftServing, FoodDraft, FoodDraftTurn,
};

const MAX_CATEGORIES: usize = 20;
const MAX_NUTRIENTS: usize = 100;
const MAX_SERVINGS: usize = 20;
const MAX_WARNINGS: usize = 20;
const MAX_WARNING_CHARS: usize = 500;
const MAX_CATEGORY_CHARS: usize = 200;
const MAX_NUTRIENT_G: Decimal = Decimal::from_parts(100, 0, 0, false, 0);
const MAX_NUTRIENT_MG: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_NUTRIENT_UG: Decimal = Decimal::from_parts(100_000_000, 0, 0, false, 0);
const MAX_NUTRIENT_KCAL: Decimal = Decimal::from_parts(1_000, 0, 0, false, 0);
const MAX_NUTRIENT_OTHER: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_SERVING_VALUE: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);

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
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

pub(super) fn parse_model_turn(
    content: &str,
    vocabulary: &FoodVocabulary,
) -> Result<FoodDraftTurn, AssistantError> {
    let wire: WireTurn = serde_json::from_str(content).map_err(|error| {
        tracing::error!(content = %content, error = %error, "failed to parse model response");
        AssistantError::InvalidModelResponse
    })?;
    match wire.status {
        WireStatus::NeedsClarification if wire.draft.is_none() && wire.warnings.is_empty() => {
            FoodDraftTurn::clarification(wire.assistant_message)
        }
        WireStatus::DraftReady => {
            let draft = parse_draft(
                wire.draft.ok_or(AssistantError::InvalidModelResponse)?,
                vocabulary,
            )?;
            FoodDraftTurn::ready(
                wire.assistant_message,
                draft,
                parse_warnings(wire.warnings)?,
            )
        }
        _ => Err(AssistantError::InvalidModelResponse),
    }
}

fn parse_draft(wire: WireDraft, vocabulary: &FoodVocabulary) -> Result<FoodDraft, AssistantError> {
    if wire.categories.len() > MAX_CATEGORIES
        || wire.nutrients.len() > MAX_NUTRIENTS
        || wire.servings.len() > MAX_SERVINGS
        || wire
            .categories
            .iter()
            .any(|value| value.chars().count() > MAX_CATEGORY_CHARS)
    {
        return Err(AssistantError::InvalidModelResponse);
    }
    let nutrient_units: HashMap<&str, &str> = vocabulary
        .nutrients
        .iter()
        .map(|value| (value.code.as_str(), value.unit.as_str()))
        .collect();
    let serving_units: HashSet<&str> = vocabulary
        .serving_units
        .iter()
        .map(|value| value.code.as_str())
        .collect();
    let mut seen = HashSet::new();
    let mut nutrients = Vec::with_capacity(wire.nutrients.len());
    for value in wire.nutrients {
        let unit = nutrient_units
            .get(value.code.as_str())
            .ok_or(AssistantError::InvalidModelResponse)?;
        if !seen.insert(value.code.clone()) || value.amount_per_100g > maximum_nutrient(unit) {
            return Err(AssistantError::InvalidModelResponse);
        }
        nutrients.push(DraftNutrient::new(value.code, value.amount_per_100g)?);
    }
    if vocabulary
        .required_nutrient_codes
        .iter()
        .any(|code| !seen.contains(code))
    {
        return Err(AssistantError::InvalidModelResponse);
    }
    let mut servings = Vec::with_capacity(wire.servings.len());
    let mut seen_serving_units = HashSet::new();
    for value in wire.servings {
        if !serving_units.contains(value.unit.as_str())
            || !seen_serving_units.insert(value.unit.clone())
            || value.quantity > MAX_SERVING_VALUE
            || value.grams > MAX_SERVING_VALUE
        {
            return Err(AssistantError::InvalidModelResponse);
        }
        servings.push(DraftServing::new(
            value.label,
            value.quantity,
            value.unit,
            value.grams,
        )?);
    }
    if let (Some(quantity), Some(unit)) = (wire.default_quantity, wire.default_unit.as_deref())
        && unit != "g"
        && !servings
            .iter()
            .any(|serving| serving.unit == unit && serving.quantity == quantity)
    {
        return Err(AssistantError::InvalidModelResponse);
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

fn parse_warnings(warnings: Vec<String>) -> Result<Vec<String>, AssistantError> {
    if warnings.len() > MAX_WARNINGS
        || warnings
            .iter()
            .any(|value| value.chars().count() > MAX_WARNING_CHARS)
    {
        return Err(AssistantError::InvalidModelResponse);
    }
    Ok(warnings
        .into_iter()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .collect())
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assistant::application::{SupportedNutrient, SupportedUnit};

    fn vocabulary() -> FoodVocabulary {
        FoodVocabulary {
            nutrients: vec![SupportedNutrient {
                code: "ENERGY_KCAL".into(),
                name: "Energy".into(),
                unit: "kcal".into(),
            }],
            default_units: vec![SupportedUnit {
                code: "g".into(),
                name: "Gram".into(),
                kind: "mass".into(),
            }],
            serving_units: vec![
                SupportedUnit {
                    code: "g".into(),
                    name: "Gram".into(),
                    kind: "mass".into(),
                },
                SupportedUnit {
                    code: "cup".into(),
                    name: "Cup".into(),
                    kind: "volume".into(),
                },
            ],
            required_nutrient_codes: vec!["ENERGY_KCAL".into()],
        }
    }

    #[test]
    fn parses_clarification_directly_to_final_type() {
        let value = parse_model_turn(r#"{"assistant_message":"How many grams?","status":"needs_clarification","draft":null,"warnings":[]}"#, &vocabulary()).unwrap();
        assert!(matches!(value, FoodDraftTurn::NeedsClarification { .. }));
    }

    #[test]
    fn rejects_unknown_fields_and_incomplete_drafts() {
        assert!(parse_model_turn(r#"{"assistant_message":"x","status":"needs_clarification","draft":null,"warnings":[],"extra":1}"#, &vocabulary()).is_err());
        assert!(parse_model_turn(r#"{"assistant_message":"ready","status":"draft_ready","draft":null,"warnings":[]}"#, &vocabulary()).is_err());
    }

    #[test]
    fn parses_complete_draft_directly_to_reviewable_domain_type() {
        let value = parse_model_turn(r#"{"assistant_message":"Review this estimate","status":"draft_ready","draft":{"name":" Dal ","brand":null,"categories":[" Indian "],"default_quantity":1,"default_unit":"g","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":"120.1234567"}],"servings":[]},"warnings":["Estimated"]}"#, &vocabulary()).unwrap();
        let FoodDraftTurn::DraftReady { draft, .. } = value else {
            panic!("expected a complete draft")
        };
        assert_eq!(draft.name, "Dal");
        assert_eq!(draft.categories, vec!["indian"]);
        assert_eq!(
            draft.nutrients[0].amount_per_100g,
            Decimal::new(120_123457, 6)
        );
    }

    #[test]
    fn default_unit_must_be_grams_or_match_a_serving() {
        let default_cup = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":1,"default_unit":"cup","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":120}],"servings":[]},"warnings":[]}"#;
        assert!(parse_model_turn(default_cup, &vocabulary()).is_err());
        let serving_cup = r#"{"assistant_message":"ready","status":"draft_ready","draft":{"name":"Dal","brand":null,"categories":[],"default_quantity":1,"default_unit":"cup","nutrients":[{"code":"ENERGY_KCAL","amount_per_100g":120}],"servings":[{"label":"one cup","quantity":1,"unit":"cup","grams":240}]},"warnings":[]}"#;
        let turn = parse_model_turn(serving_cup, &vocabulary()).unwrap();
        let FoodDraftTurn::DraftReady { draft, .. } = turn else {
            panic!("expected ready draft")
        };
        assert_eq!(draft.servings[0].unit, "cup");
        assert_eq!(draft.default_unit.as_deref(), Some("cup"));
    }
}

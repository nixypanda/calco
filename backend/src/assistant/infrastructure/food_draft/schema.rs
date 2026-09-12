use serde_json::{Value, json};

use crate::assistant::application::FoodVocabulary;
use crate::assistant::domain::{
    MAX_ASSISTANT_MESSAGE_CHARS, MAX_DRAFT_CATEGORIES, MAX_DRAFT_CATEGORY_CHARS,
    MAX_DRAFT_CODE_CHARS, MAX_DRAFT_NAME_CHARS, MAX_DRAFT_NUTRIENTS, MAX_DRAFT_SERVINGS,
    MAX_DRAFT_UNIT_CHARS, MAX_DRAFT_WARNING_CHARS, MAX_DRAFT_WARNINGS,
};

pub(super) fn build(vocabulary: &FoodVocabulary) -> Value {
    let default_units = vocabulary
        .default_units
        .iter()
        .map(|unit| unit.code.as_str())
        .collect::<Vec<_>>();
    let serving_units = vocabulary
        .serving_units
        .iter()
        .map(|unit| unit.code.as_str())
        .collect::<Vec<_>>();
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["assistant_message", "status", "draft", "warnings"],
        "properties": {
            "assistant_message": { "type": "string", "maxLength": MAX_ASSISTANT_MESSAGE_CHARS },
            "status": { "type": "string", "enum": ["needs_clarification", "draft_ready"] },
            "draft": {
                "oneOf": [
                    { "type": "null" },
                    {
                        "type": "object", "additionalProperties": false,
                        "required": ["name", "brand", "categories", "default_quantity", "default_unit", "nutrients", "servings"],
                        "properties": {
                            "name": { "type": "string", "maxLength": MAX_DRAFT_NAME_CHARS },
                            "brand": { "type": ["string", "null"], "maxLength": MAX_DRAFT_NAME_CHARS },
                            "categories": { "type": "array", "maxItems": MAX_DRAFT_CATEGORIES, "items": { "type": "string", "maxLength": MAX_DRAFT_CATEGORY_CHARS } },
                            "default_quantity": { "type": ["number", "null"], "exclusiveMinimum": 0 },
                            "default_unit": { "type": ["string", "null"], "maxLength": MAX_DRAFT_UNIT_CHARS, "enum": default_units.into_iter().map(Some).chain(std::iter::once(None)).collect::<Vec<_>>() },
                            "nutrients": { "type": "array", "maxItems": MAX_DRAFT_NUTRIENTS, "items": {
                                "type": "object", "additionalProperties": false,
                                "required": ["code", "amount_per_100g"],
                                "properties": {
                                    "code": { "type": "string", "maxLength": MAX_DRAFT_CODE_CHARS },
                                    "amount_per_100g": { "type": "number", "minimum": 0 }
                                }
                            }},
                            "servings": { "type": "array", "maxItems": MAX_DRAFT_SERVINGS, "items": {
                                "type": "object", "additionalProperties": false,
                                "required": ["unit", "grams_per_unit"],
                                "properties": {
                                    "unit": { "type": "string", "maxLength": MAX_DRAFT_UNIT_CHARS, "enum": serving_units },
                                    "grams_per_unit": { "type": "number", "exclusiveMinimum": 0 }
                                }
                            }}
                        }
                    }
                ]
            },
            "warnings": { "type": "array", "maxItems": MAX_DRAFT_WARNINGS, "items": { "type": "string", "maxLength": MAX_DRAFT_WARNING_CHARS } }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assistant::application::SupportedUnit;

    fn vocabulary() -> FoodVocabulary {
        FoodVocabulary {
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
            ..FoodVocabulary::default()
        }
    }

    #[test]
    fn schema_rejects_unknown_fields_at_each_object_level() {
        let value = build(&vocabulary());
        assert_eq!(value["additionalProperties"], false);
        assert_eq!(
            value["properties"]["draft"]["oneOf"][1]["additionalProperties"],
            false
        );
        assert_eq!(
            value["properties"]["draft"]["oneOf"][1]["properties"]["nutrients"]["items"]["additionalProperties"],
            false
        );
        assert_eq!(
            value["properties"]["draft"]["oneOf"][1]["properties"]["default_unit"]["enum"],
            json!(["g", null])
        );
        assert_eq!(
            value["properties"]["draft"]["oneOf"][1]["properties"]["servings"]["items"]["properties"]
                ["unit"]["enum"],
            json!(["g", "cup"])
        );
        assert_eq!(
            value["properties"]["assistant_message"]["maxLength"],
            MAX_ASSISTANT_MESSAGE_CHARS
        );
        assert_eq!(
            value["properties"]["draft"]["oneOf"][1]["properties"]["categories"]["maxItems"],
            MAX_DRAFT_CATEGORIES
        );
        assert_eq!(
            value["properties"]["warnings"]["items"]["maxLength"],
            MAX_DRAFT_WARNING_CHARS
        );
    }
}

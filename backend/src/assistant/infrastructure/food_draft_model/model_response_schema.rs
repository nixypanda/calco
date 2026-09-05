use serde_json::{Value, json};

use crate::assistant::application::FoodVocabulary;

pub(super) fn food_draft_response_schema(vocabulary: &FoodVocabulary) -> Value {
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
            "assistant_message": { "type": "string", "maxLength": 4000 },
            "status": { "type": "string", "enum": ["needs_clarification", "draft_ready"] },
            "draft": {
                "oneOf": [
                    { "type": "null" },
                    {
                        "type": "object", "additionalProperties": false,
                        "required": ["name", "brand", "categories", "default_quantity", "default_unit", "nutrients", "servings"],
                        "properties": {
                            "name": { "type": "string", "maxLength": 200 },
                            "brand": { "type": ["string", "null"], "maxLength": 200 },
                            "categories": { "type": "array", "maxItems": 20, "items": { "type": "string", "maxLength": 200 } },
                            "default_quantity": { "type": ["number", "null"], "exclusiveMinimum": 0 },
                            "default_unit": { "type": ["string", "null"], "maxLength": 100, "enum": default_units.into_iter().map(Some).chain(std::iter::once(None)).collect::<Vec<_>>() },
                            "nutrients": { "type": "array", "maxItems": 100, "items": {
                                "type": "object", "additionalProperties": false,
                                "required": ["code", "amount_per_100g"],
                                "properties": {
                                    "code": { "type": "string", "maxLength": 100 },
                                    "amount_per_100g": { "type": "number", "minimum": 0 }
                                }
                            }},
                            "servings": { "type": "array", "maxItems": 20, "items": {
                                "type": "object", "additionalProperties": false,
                                "required": ["label", "quantity", "unit", "grams"],
                                "properties": {
                                    "label": { "type": "string", "maxLength": 200 },
                                    "quantity": { "type": "number", "exclusiveMinimum": 0 },
                                    "unit": { "type": "string", "maxLength": 100, "enum": serving_units },
                                    "grams": { "type": "number", "exclusiveMinimum": 0 }
                                }
                            }}
                        }
                    }
                ]
            },
            "warnings": { "type": "array", "maxItems": 20, "items": { "type": "string", "maxLength": 500 } }
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
        let value = food_draft_response_schema(&vocabulary());
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
    }
}

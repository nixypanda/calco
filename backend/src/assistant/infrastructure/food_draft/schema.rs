use serde_json::{Value, json};

use crate::assistant::application::FoodVocabulary;
use crate::assistant::domain::{
    FoodDraftPurpose, MAX_ASSISTANT_MESSAGE_CHARS, MAX_DRAFT_CATEGORIES, MAX_DRAFT_CATEGORY_CHARS,
    MAX_DRAFT_CODE_CHARS, MAX_DRAFT_NAME_CHARS, MAX_DRAFT_NUTRIENTS, MAX_DRAFT_SERVINGS,
    MAX_DRAFT_UNIT_CHARS, MAX_DRAFT_WARNING_CHARS, MAX_DRAFT_WARNINGS,
};

/// Builds the provider-facing JSON Schema for a food-draft response.
///
/// The response is a discriminated union on `status`, expressed as a root-level
/// `oneOf`. Each branch fully specifies its object so the schema stays valid for
/// strict constrained decoding (every object sets `additionalProperties: false`
/// and lists all of its properties in `required`).
///
/// The union is what keeps the wire contract aligned with the parser in
/// [`super::response`]: a `needs_clarification` turn can never carry a draft or
/// warnings, and a `draft_ready` turn always carries a draft object.
pub(super) fn build(purpose: FoodDraftPurpose, vocabulary: &FoodVocabulary) -> Value {
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
    let draft = json!({
        "type": "object",
        "additionalProperties": false,
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
    });

    let mut clarification_required = vec!["assistant_message", "status", "draft", "warnings"];
    let mut draft_ready_required = clarification_required.clone();
    let mut clarification_properties = json!({
        "assistant_message": { "type": "string", "maxLength": MAX_ASSISTANT_MESSAGE_CHARS },
        "status": { "type": "string", "enum": ["needs_clarification"] },
        "draft": { "type": "null" },
        "warnings": { "type": "array", "maxItems": 0, "items": { "type": "string", "maxLength": MAX_DRAFT_WARNING_CHARS } }
    });
    let mut draft_ready_properties = json!({
        "assistant_message": { "type": "string", "maxLength": MAX_ASSISTANT_MESSAGE_CHARS },
        "status": { "type": "string", "enum": ["draft_ready"] },
        "draft": draft,
        "warnings": { "type": "array", "maxItems": MAX_DRAFT_WARNINGS, "items": { "type": "string", "maxLength": MAX_DRAFT_WARNING_CHARS } }
    });

    if purpose == FoodDraftPurpose::AdHocLog {
        // A logged portion is either absent (clarification) or a concrete
        // positive amount convertible through grams (draft_ready).
        clarification_required.push("suggested_log");
        draft_ready_required.push("suggested_log");
        clarification_properties["suggested_log"] = json!({ "type": "null" });
        draft_ready_properties["suggested_log"] = json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["amount", "unit", "total_weight_grams"],
            "properties": {
                "amount": { "type": "number", "exclusiveMinimum": 0 },
                "unit": { "type": "string", "maxLength": MAX_DRAFT_UNIT_CHARS },
                "total_weight_grams": { "type": "number", "exclusiveMinimum": 0 }
            }
        });
    }

    json!({
        "oneOf": [
            {
                "type": "object",
                "additionalProperties": false,
                "required": clarification_required,
                "properties": clarification_properties
            },
            {
                "type": "object",
                "additionalProperties": false,
                "required": draft_ready_required,
                "properties": draft_ready_properties
            }
        ]
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

    /// Every object in a schema used with `strict: true` must set
    /// `additionalProperties: false` and mark all of its properties required.
    /// Groq rejects the request otherwise.
    fn assert_strict_objects(value: &Value) {
        match value {
            Value::Object(map) => {
                let is_object =
                    map.get("type") == Some(&json!("object")) || map.contains_key("properties");
                if is_object {
                    assert_eq!(
                        map.get("additionalProperties"),
                        Some(&json!(false)),
                        "object must set additionalProperties:false: {value}"
                    );
                    if let Some(properties) = map.get("properties").and_then(Value::as_object) {
                        let required = map
                            .get("required")
                            .and_then(Value::as_array)
                            .unwrap_or_else(|| {
                                panic!("object must have a required array: {value}")
                            });
                        for key in properties.keys() {
                            assert!(
                                required.iter().any(|value| value == key),
                                "property {key} must be required: {value}"
                            );
                        }
                    }
                }
                for child in map.values() {
                    assert_strict_objects(child);
                }
            }
            Value::Array(items) => {
                for item in items {
                    assert_strict_objects(item);
                }
            }
            _ => {}
        }
    }

    #[test]
    fn schema_rejects_unknown_fields_at_each_object_level() {
        let value = build(FoodDraftPurpose::CustomFood, &vocabulary());
        assert_eq!(value["oneOf"][1]["additionalProperties"], false);
        assert_eq!(
            value["oneOf"][1]["properties"]["draft"]["additionalProperties"],
            false
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["draft"]["properties"]["nutrients"]["items"]["additionalProperties"],
            false
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["draft"]["properties"]["default_unit"]["enum"],
            json!(["g", null])
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["draft"]["properties"]["servings"]["items"]["properties"]
                ["unit"]["enum"],
            json!(["g", "cup"])
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["assistant_message"]["maxLength"],
            MAX_ASSISTANT_MESSAGE_CHARS
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["draft"]["properties"]["categories"]["maxItems"],
            MAX_DRAFT_CATEGORIES
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["warnings"]["items"]["maxLength"],
            MAX_DRAFT_WARNING_CHARS
        );
    }

    #[test]
    fn clarification_branch_forbids_a_draft_and_warnings() {
        let value = build(FoodDraftPurpose::CustomFood, &vocabulary());
        let branch = &value["oneOf"][0];
        assert_eq!(
            branch["properties"]["status"]["enum"],
            json!(["needs_clarification"])
        );
        assert_eq!(branch["properties"]["draft"], json!({ "type": "null" }));
        assert_eq!(branch["properties"]["warnings"]["maxItems"], 0);
    }

    #[test]
    fn draft_ready_branch_requires_an_object_draft() {
        let value = build(FoodDraftPurpose::CustomFood, &vocabulary());
        let branch = &value["oneOf"][1];
        assert_eq!(
            branch["properties"]["status"]["enum"],
            json!(["draft_ready"])
        );
        assert_eq!(branch["properties"]["draft"]["type"], json!("object"));
        assert_eq!(
            branch["properties"]["warnings"]["maxItems"],
            MAX_DRAFT_WARNINGS
        );
    }

    #[test]
    fn ad_hoc_schema_requires_a_suggested_log() {
        let value = build(FoodDraftPurpose::AdHocLog, &vocabulary());
        for branch in value["oneOf"].as_array().unwrap() {
            assert!(
                branch["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("suggested_log"))
            );
        }
        assert_eq!(
            value["oneOf"][0]["properties"]["suggested_log"],
            json!({ "type": "null" })
        );
        assert_eq!(
            value["oneOf"][1]["properties"]["suggested_log"]["additionalProperties"],
            false
        );
    }

    #[test]
    fn custom_food_schema_omits_the_suggested_log() {
        let value = build(FoodDraftPurpose::CustomFood, &vocabulary());
        for branch in value["oneOf"].as_array().unwrap() {
            assert!(
                !branch["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("suggested_log"))
            );
            assert!(branch["properties"].get("suggested_log").is_none());
        }
    }

    #[test]
    fn schema_conforms_to_strict_decoding_requirements() {
        for purpose in [FoodDraftPurpose::CustomFood, FoodDraftPurpose::AdHocLog] {
            assert_strict_objects(&build(purpose, &vocabulary()));
        }
    }
}

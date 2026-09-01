use serde_json::json;

/// The provider-neutral JSON Schema for an assistant turn.
pub fn food_draft_response_schema() -> String {
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
                        "required": ["name", "brand", "categories", "serving_size_g", "default_quantity", "default_unit", "nutrients", "servings"],
                        "properties": {
                            "name": { "type": "string", "maxLength": 200 },
                            "brand": { "type": ["string", "null"], "maxLength": 200 },
                            "categories": { "type": "array", "maxItems": 20, "items": { "type": "string", "maxLength": 200 } },
                            "serving_size_g": { "type": ["number", "null"], "exclusiveMinimum": 0 },
                            "default_quantity": { "type": ["number", "null"], "exclusiveMinimum": 0 },
                            "default_unit": { "type": ["string", "null"], "maxLength": 100 },
                            "nutrients": {
                                "type": "array", "minItems": 4, "maxItems": 100,
                                "items": {
                                    "type": "object", "additionalProperties": false,
                                    "required": ["code", "amount_per_100g"],
                                    "properties": {
                                        "code": { "type": "string", "maxLength": 100 },
                                        "amount_per_100g": { "type": "number", "minimum": 0 }
                                    }
                                }
                            },
                            "servings": {
                                "type": "array", "maxItems": 20,
                                "items": {
                                    "type": "object", "additionalProperties": false,
                                    "required": ["label", "quantity", "unit", "grams"],
                                    "properties": {
                                        "label": { "type": "string", "maxLength": 200 },
                                        "quantity": { "type": "number", "exclusiveMinimum": 0 },
                                        "unit": { "type": "string", "maxLength": 100 },
                                        "grams": { "type": "number", "exclusiveMinimum": 0 }
                                    }
                                }
                            }
                        }
                    }
                ]
            },
            "warnings": { "type": "array", "maxItems": 20, "items": { "type": "string", "maxLength": 500 } }
        }
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::food_draft_response_schema;
    use serde_json::Value;

    #[test]
    fn schema_is_strict_at_every_draft_level() {
        let schema: Value = serde_json::from_str(&food_draft_response_schema()).unwrap();
        assert_eq!(schema["additionalProperties"], false);
        assert_eq!(
            schema["properties"]["draft"]["oneOf"][1]["additionalProperties"],
            false
        );
        assert_eq!(
            schema["properties"]["draft"]["oneOf"][1]["properties"]["nutrients"]["items"]["additionalProperties"],
            false
        );
        assert_eq!(
            schema["properties"]["draft"]["oneOf"][1]["properties"]["servings"]["items"]["additionalProperties"],
            false
        );
    }
}

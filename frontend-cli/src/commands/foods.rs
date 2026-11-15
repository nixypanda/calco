//! Food search and detail arguments, execution, and human rendering.

use serde_json::{Value, json};

use crate::client;
use crate::output::{
    CliError, CommandOutput, empty_meta, field_text, human_decimal, render_table, scalar_text,
    serialize_json,
};

use super::{GlobalArgs, Runtime, api_client, parse_full_uuid};

#[derive(Debug, clap::Args)]
pub struct FoodsArgs {
    #[command(subcommand)]
    pub command: FoodsCommand,
}

#[derive(Debug, clap::Subcommand)]
pub enum FoodsCommand {
    Search {
        query: String,
        #[arg(long, value_enum, default_value = "all")]
        scope: client::FoodScope,
    },
    Show {
        id: String,
    },
}

pub(super) async fn run(
    command: FoodsCommand,
    global: &GlobalArgs,
    runtime: &Runtime,
) -> Result<CommandOutput, CliError> {
    match command {
        FoodsCommand::Search { query, scope } => {
            let api = api_client(global, runtime)?;
            let response = api.search_foods(&query, scope).await?;
            let data = json!({"items": serialize_json(&response.items)?});

            Ok(CommandOutput {
                data: data.clone(),
                meta: empty_meta(),
                human: render_product_search(&data),
            })
        }
        FoodsCommand::Show { id } => {
            let id = parse_full_uuid(&id)?;
            let api = api_client(global, runtime)?;
            let product = api.get_food(id).await?;
            let data = serialize_json(&product)?;

            Ok(CommandOutput {
                data: data.clone(),
                meta: empty_meta(),
                human: render_product_detail(&data) + "\n",
            })
        }
    }
}

// ─── Human rendering ───────────────────────────────────────────

const PER_100G_MACROS: [(&str, &str, &str); 5] = [
    ("energy_kcal", "Calories", "kcal"),
    ("protein_g", "Protein", "g"),
    ("carbs_g", "Carbs", "g"),
    ("fat_g", "Fat", "g"),
    ("fiber_g", "Fiber", "g"),
];

fn nutrient_value_text(value: Option<&Value>, unit: &str) -> String {
    let amount = human_decimal(value);
    if amount == "-" {
        "-".to_string()
    } else {
        format!("{amount} {unit}")
    }
}

fn per_100g_text(value: Option<&Value>) -> String {
    let Some(summary) = value else {
        return "-".to_string();
    };
    if summary.is_null() {
        return "-".to_string();
    }
    let summary = summary.get("per_100g").unwrap_or(summary);
    if summary.is_null() {
        return "-".to_string();
    }

    PER_100G_MACROS
        .iter()
        .map(|&(key, label, unit)| {
            format!("{label} {}", nutrient_value_text(summary.get(key), unit))
        })
        .collect::<Vec<_>>()
        .join(" · ")
}

fn servings_text(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return "-".to_string();
    };
    let Some(items) = value.as_array() else {
        return scalar_text(Some(value));
    };
    if items.is_empty() {
        return "-".to_string();
    }

    items
        .iter()
        .map(|item| {
            let unit = field_text(item, "unit");
            let grams = human_decimal(item.get("grams_per_unit"));
            match (unit.as_str(), grams.as_str()) {
                ("-", "-") => "-".to_string(),
                ("-", _) => format!("{grams} g"),
                (_, "-") => unit,
                _ => format!("{unit} = {grams} g"),
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn logging_units_text(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return "-".to_string();
    };
    let Some(items) = value.as_array() else {
        return scalar_text(Some(value));
    };
    if items.is_empty() {
        return "-".to_string();
    }

    items
        .iter()
        .map(|item| {
            let code = field_text(item, "code");
            let name = field_text(item, "name");
            if name == "-" || name == code {
                code
            } else {
                format!("{code} ({name})")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn render_product_search(data: &Value) -> String {
    let Some(items) = data.get("items").and_then(Value::as_array) else {
        return "No foods found.\n".to_string();
    };
    if items.is_empty() {
        return "No foods found.\n".to_string();
    }

    let rows = items
        .iter()
        .map(|item| {
            let energy = item
                .get("nutrition_summary")
                .and_then(|summary| summary.get("per_100g"))
                .and_then(|summary| summary.get("energy_kcal"));
            vec![
                field_text(item, "name"),
                field_text(item, "brand"),
                human_decimal(energy),
                field_text(item, "id"),
            ]
        })
        .collect::<Vec<_>>();
    let count = items.len();
    let noun = if count == 1 { "match" } else { "matches" };

    format!(
        "{count} {noun}\n{}\n",
        render_table(&["NAME", "BRAND", "KCAL/100G", "ID"], &rows)
    )
}

fn render_product_detail(data: &Value) -> String {
    let name = field_text(data, "name");
    [
        if name.is_empty() {
            "-".to_string()
        } else {
            name
        },
        format!("{} · {}", field_text(data, "brand"), field_text(data, "id")),
        format!(
            "Per 100 g: {}",
            per_100g_text(data.get("nutrition_summary"))
        ),
        format!("Servings: {}", servings_text(data.get("servings"))),
        format!(
            "Logging units: {}",
            logging_units_text(data.get("allowed_units"))
        ),
    ]
    .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    use rust_decimal::Decimal;
    use uuid::Uuid;

    use crate::output;

    fn dto_nutrients() -> client::NutrientSummary {
        client::NutrientSummary {
            energy_kcal: Some(Decimal::from_str("389").expect("test decimal")),
            protein_g: Some(Decimal::from_str("12.5").expect("test decimal")),
            carbs_g: Some(Decimal::from_str("60").expect("test decimal")),
            fat_g: Some(Decimal::from_str("7").expect("test decimal")),
            fiber_g: Some(Decimal::from_str("9").expect("test decimal")),
        }
    }

    #[test]
    fn human_output_escapes_untrusted_strings_and_keeps_full_ids() {
        let id = "123e4567-e89b-12d3-a456-426614174000";
        let untrusted = "name\u{1b}[31m\u{202e}spoof\u{200b}";
        let data = json!({
            "items": [{
                "id": id,
                "source": "OFF",
                "source_id": null,
                "barcode": null,
                "name": untrusted,
                "brand": null,
                "categories": [],
                "nutrition_summary": {
                    "per_100g": {
                        "energy_kcal": "100",
                        "protein_g": null,
                        "carbs_g": "1",
                        "fat_g": "2",
                        "fiber_g": "3"
                    }
                },
                "created_at": "2026-11-15T00:00:00Z",
                "updated_at": "2026-11-15T00:00:00Z"
            }]
        });

        let human = render_product_search(&data);
        let escaped = output::escape_human_text(untrusted).into_owned();

        assert!(human.contains("1 match"));
        assert!(human.contains("KCAL/100G"));
        assert!(human.contains(id));
        let row = human
            .lines()
            .find(|line| line.contains(&escaped))
            .expect("escaped product row");
        assert!(row.contains(" - "));
        assert!(row.contains("100"));
        assert!(row.ends_with(id));
        assert!(!human.contains("source"));
        assert!(!human.contains("created_at"));
        assert!(!human.contains('\u{1b}'));
        assert!(!human.contains('\u{202e}'));
        assert!(!human.contains('\u{200b}'));
    }

    #[test]
    fn human_product_output_follows_serialized_dtos() {
        let product_id = "11111111-1111-1111-1111-111111111111";
        let search = client::ProductSearchResponse {
            items: vec![client::ProductSearchItem {
                id: Uuid::parse_str(product_id).unwrap(),
                source: "OFF".to_string(),
                source_id: Some("src-1".to_string()),
                barcode: Some("0123456789".to_string()),
                name: "Oats".to_string(),
                brand: Some("Home".to_string()),
                categories: vec!["breakfast".to_string(), "snack".to_string()],
                nutrition_summary: client::ProductNutritionSummary {
                    per_100g: dto_nutrients(),
                },
                created_at: "2026-11-15T00:00:00Z".to_string(),
                updated_at: "2026-11-15T01:00:00Z".to_string(),
            }],
        };
        let data = json!({"items": serialize_json(&search.items).unwrap()});
        let human = render_product_search(&data);

        assert_eq!(
            human,
            format!("1 match\nNAME  BRAND  KCAL/100G  ID\nOats  Home   389        {product_id}\n")
        );
        assert_eq!(
            render_product_search(&json!({"items": []})),
            "No foods found.\n"
        );
        assert!(!human.contains("source"));
        assert!(!human.contains("barcode"));
        assert!(!human.contains("created_at"));

        let detail = client::ProductDetail {
            id: Uuid::parse_str(product_id).unwrap(),
            source: "USER".to_string(),
            source_id: None,
            visibility: "global".to_string(),
            barcode: None,
            name: "Custom oats".to_string(),
            brand: None,
            categories: vec!["breakfast".to_string()],
            default_quantity: Some(Decimal::from_str("30").expect("test decimal")),
            default_unit: Some("g".to_string()),
            nutrition_summary: client::ProductNutritionSummary {
                per_100g: dto_nutrients(),
            },
            nutrients: vec![client::ProductNutrient {
                code: "ENERGY_KCAL".to_string(),
                amount_per_100g: Decimal::from_str("389").expect("test decimal"),
                unit: "kcal".to_string(),
                source: Some("label".to_string()),
                confidence: Some("approved".to_string()),
            }],
            servings: vec![client::ProductServing {
                unit: "cup".to_string(),
                grams_per_unit: Decimal::from_str("80").expect("test decimal"),
            }],
            allowed_units: vec![client::UnitItem {
                code: "g".to_string(),
                name: "gram".to_string(),
                kind: "mass".to_string(),
            }],
            created_at: "2026-11-15T00:00:00Z".to_string(),
            updated_at: "2026-11-15T01:00:00Z".to_string(),
        };
        let data = serialize_json(&detail).unwrap();
        let human = render_product_detail(&data);

        assert_eq!(
            human,
            format!(
                "Custom oats\n\
                 - · {product_id}\n\
                 Per 100 g: Calories 389 kcal · Protein 12.5 g · Carbs 60 g · Fat 7 g · Fiber 9 g\n\
                 Servings: cup = 80 g\n\
                 Logging units: g (gram)"
            )
        );
        assert!(!human.contains("visibility"));
        assert!(!human.contains("source"));
        assert!(!human.contains("created_at"));
        assert!(!human.contains("amount_per_100g"));
    }
}

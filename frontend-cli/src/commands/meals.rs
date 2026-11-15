//! Meal list and detail arguments, execution, and human rendering.

use serde_json::{Value, json};

use crate::output::{
    CliError, CommandOutput, empty_meta, field_text, human_decimal, item_reference_text,
    optional_text, quantity_text, render_table, serialize_json,
};

use super::{GlobalArgs, Runtime, api_client, parse_full_uuid};

#[derive(Debug, clap::Args)]
pub struct MealsArgs {
    #[command(subcommand)]
    pub command: MealsCommand,
}

#[derive(Debug, clap::Subcommand)]
pub enum MealsCommand {
    List,
    Show { id: String },
}

pub(super) async fn run(
    command: MealsCommand,
    global: &GlobalArgs,
    runtime: &Runtime,
) -> Result<CommandOutput, CliError> {
    match command {
        MealsCommand::List => {
            let api = api_client(global, runtime)?;
            let response = api.list_meals().await?;
            let data = json!({"items": serialize_json(&response.items)?});

            Ok(CommandOutput {
                data: data.clone(),
                meta: empty_meta(),
                human: render_meal_list(&data),
            })
        }
        MealsCommand::Show { id } => {
            let id = parse_full_uuid(&id)?;
            let api = api_client(global, runtime)?;
            let meal = api.get_meal(id).await?;
            let data = serialize_json(&meal)?;

            Ok(CommandOutput {
                data: data.clone(),
                meta: empty_meta(),
                human: render_meal(&data) + "\n",
            })
        }
    }
}

// ─── Human rendering ───────────────────────────────────────────

fn summary_energy_text(value: Option<&Value>) -> String {
    let Some(summary) = value else {
        return "-".to_string();
    };
    if summary.is_null() {
        return "-".to_string();
    }

    let amount = human_decimal(summary.get("energy_kcal"));
    if amount == "-" {
        "-".to_string()
    } else {
        format!("{amount} kcal")
    }
}

fn render_meal_list(data: &Value) -> String {
    let Some(items) = data.get("items").and_then(Value::as_array) else {
        return "No meals.\n".to_string();
    };
    if items.is_empty() {
        return "No meals.\n".to_string();
    }

    let rows = items
        .iter()
        .map(|meal| {
            vec![
                field_text(meal, "name"),
                quantity_text(meal.get("total_quantity")),
                human_decimal(
                    meal.get("nutrition_summary")
                        .and_then(|summary| summary.get("energy_kcal")),
                ),
                field_text(meal, "id"),
            ]
        })
        .collect::<Vec<_>>();

    render_table(&["NAME", "QUANTITY", "KCAL", "ID"], &rows) + "\n"
}

fn render_meal(data: &Value) -> String {
    let mut lines = vec![
        field_text(data, "name"),
        field_text(data, "id"),
        format!(
            "Total: {} · {}",
            quantity_text(data.get("total_quantity")),
            summary_energy_text(data.get("nutrition_summary"))
        ),
    ];
    if let Some(notes) = optional_text(data.get("notes")) {
        lines.push(format!("Notes: {notes}"));
    }

    let mut output = lines.join("\n");
    output.push('\n');
    match data.get("components").and_then(Value::as_array) {
        Some(components) if !components.is_empty() => {
            let rows = components
                .iter()
                .map(|component| {
                    vec![
                        field_text(component, "id"),
                        item_reference_text(component.get("item"))
                            .unwrap_or_else(|| "-".to_string()),
                        quantity_text(component.get("quantity")),
                    ]
                })
                .collect::<Vec<_>>();
            output.push_str("Components\n");
            output.push_str(&render_table(&["ID", "ITEM", "QUANTITY"], &rows));
        }
        _ => output.push_str("Components: -"),
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    use rust_decimal::Decimal;
    use uuid::Uuid;

    use crate::client;

    fn decimal(raw: &str) -> Decimal {
        Decimal::from_str(raw).expect("test decimal")
    }

    fn dto_nutrients() -> client::NutrientSummary {
        client::NutrientSummary {
            energy_kcal: Some(decimal("389")),
            protein_g: Some(decimal("12.5")),
            carbs_g: Some(decimal("60")),
            fat_g: Some(decimal("7")),
            fiber_g: Some(decimal("9")),
        }
    }

    #[test]
    fn human_meal_output_follows_serialized_dto() {
        let meal_id = "22222222-2222-2222-2222-222222222222";
        let component_id = "44444444-4444-4444-4444-444444444444";
        let meal = client::Meal {
            id: Uuid::parse_str(meal_id).unwrap(),
            name: "Breakfast bowl".to_string(),
            notes: Some("assembled".to_string()),
            total_quantity: Some(client::Quantity {
                amount: decimal("250"),
                unit: "g".to_string(),
            }),
            nutrition_summary: Some(client::NutrientSummary {
                energy_kcal: Some(decimal("450")),
                protein_g: Some(decimal("20")),
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
            }),
            components: vec![client::MealComponent {
                id: Uuid::parse_str(component_id).unwrap(),
                item: client::MealComponentItem {
                    item_type: "product".to_string(),
                    id: Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap(),
                },
                quantity: client::Quantity {
                    amount: decimal("50"),
                    unit: "g".to_string(),
                },
                nutrition_summary: Some(dto_nutrients()),
            }],
            created_at: "2026-11-15T00:00:00Z".to_string(),
            updated_at: "2026-11-15T01:00:00Z".to_string(),
        };
        let data = serialize_json(&meal).unwrap();
        let human = render_meal(&data);

        assert!(human.starts_with(&format!(
            "Breakfast bowl\n{meal_id}\nTotal: 250 g · 450 kcal\nNotes: assembled\nComponents\n"
        )));
        assert!(human.contains(component_id));
        assert!(human.contains("Product 11111111-1111-1111-1111-111111111111"));
        assert!(human.contains("50 g"));
        assert!(!human.contains("Oats"));
        assert!(!human.contains("created_at"));
        assert!(!human.contains("updated_at"));

        let list = json!({"items": [serialize_json(&meal).unwrap()]});
        assert_eq!(
            render_meal_list(&list),
            format!(
                "NAME            QUANTITY  KCAL  ID\nBreakfast bowl  250 g     450   {meal_id}\n"
            )
        );
        assert_eq!(render_meal_list(&json!({"items": []})), "No meals.\n");
    }
}

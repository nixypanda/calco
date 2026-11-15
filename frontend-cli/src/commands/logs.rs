//! Log list/show/add/delete arguments, validation, execution, and rendering.
//!
//! Delete confirmation lives here because it is a log-only destructive gate.
//! The parent module supplies the injected runtime, connection creation, and
//! canonical UUID parsing.

use std::io::{self, BufRead, Write};

use chrono::NaiveDate;
use clap::ArgGroup;
use rust_decimal::Decimal;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::client;
use crate::dates::DateSpan;
use crate::output::{
    self, CliError, CommandOutput, arguments_error, date_label, date_meta, empty_meta, escape_text,
    field_date_label, field_text, human_decimal, item_reference_text, optional_text, quantity_text,
    range_meta, replay_meta, scalar_text, serialize_json,
};

use super::{GlobalArgs, Runtime, api_client, parse_full_uuid};

#[derive(Debug, clap::Args)]
pub struct LogsArgs {
    #[command(subcommand)]
    pub command: LogsCommand,
}

#[derive(Debug, clap::Subcommand)]
pub enum LogsCommand {
    List {
        date: Option<String>,
        #[arg(long, value_enum)]
        slot: Option<client::MealSlot>,
    },
    Show {
        id: String,
    },
    Add(LogAddArgs),
    Delete {
        id: String,
        #[arg(long)]
        yes: bool,
    },
}

#[derive(Debug, clap::Args)]
#[command(group = ArgGroup::new("item").required(true).multiple(false))]
pub struct LogAddArgs {
    #[arg(long, group = "item")]
    pub food: Option<String>,
    #[arg(long, group = "item")]
    pub meal: Option<String>,
    #[arg(long)]
    pub amount: Decimal,
    #[arg(long)]
    pub unit: String,
    #[arg(long)]
    pub date: Option<String>,
    #[arg(long, value_enum)]
    pub slot: Option<client::MealSlot>,
    #[arg(long)]
    pub notes: Option<String>,
    #[arg(long)]
    pub device_timezone: Option<String>,
    #[arg(long)]
    pub idempotency_key: String,
}

/// Injectable confirmation gate for destructive human-mode commands.
pub trait DeleteConfirmation: Send + Sync {
    /// Return `true` only when the user explicitly confirms deletion.
    fn confirm_delete(&self, id: Uuid) -> Result<bool, CliError>;
}

/// Terminal confirmation used by the real binary.
pub struct TtyDeleteConfirmation;

impl DeleteConfirmation for TtyDeleteConfirmation {
    fn confirm_delete(&self, id: Uuid) -> Result<bool, CliError> {
        let mut stderr = io::stderr().lock();
        write!(stderr, "Delete log {id}? [y/N] ").map_err(confirmation_error)?;
        stderr.flush().map_err(confirmation_error)?;
        drop(stderr);

        let mut answer = String::new();
        let read = io::stdin()
            .lock()
            .read_line(&mut answer)
            .map_err(confirmation_error)?;
        if read == 0 {
            return Ok(false);
        }

        Ok(confirmation_answer_is_yes(&answer))
    }
}

fn confirmation_answer_is_yes(answer: &str) -> bool {
    matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

fn confirmation_error(source: io::Error) -> CliError {
    CliError::new(
        output::ErrorOrigin::Internal,
        "internal_error",
        format!("could not read delete confirmation: {source}"),
    )
}

pub(super) async fn run(
    command: LogsCommand,
    global: &GlobalArgs,
    runtime: &Runtime,
) -> Result<CommandOutput, CliError> {
    match command {
        LogsCommand::List { date, slot } => {
            let span = DateSpan::parse(date.as_deref(), runtime.today)?;
            let api = api_client(global, runtime)?;

            if span.is_single() {
                let response = api.list_logs(span.from).await?;
                let items = filter_logs_by_slot(response.items, slot)?;
                let data = json!({"items": items});

                Ok(CommandOutput {
                    data: data.clone(),
                    meta: date_meta(span.from),
                    human: render_log_items(&data, span.from, runtime.today),
                })
            } else {
                let mut days = Vec::with_capacity(span.len());
                for date in span.dates() {
                    let response = api.list_logs(date).await?;
                    let items = filter_logs_by_slot(response.items, slot)?;
                    days.push(json!({"date": date, "items": items}));
                }
                let data = json!({"days": days});

                Ok(CommandOutput {
                    data: data.clone(),
                    meta: range_meta(span.from, span.to),
                    human: render_log_days(&data, span, runtime.today),
                })
            }
        }
        LogsCommand::Show { id } => {
            let id = parse_full_uuid(&id)?;
            let api = api_client(global, runtime)?;
            let log = api.get_log(id).await?;
            let date = log.log_date;
            let data = serialize_json(&log)?;

            Ok(CommandOutput {
                data: data.clone(),
                meta: date_meta(date),
                human: render_log_detail(&data, runtime.today) + "\n",
            })
        }
        LogsCommand::Add(args) => {
            let validated = validate_log_add(&args, runtime.today)?;
            let request = build_create_log_request(validated);
            let api = api_client(global, runtime)?;
            let outcome = api.create_log(&request).await?;
            let replayed = outcome.replayed;
            // A replay returns the existing log, which may have been edited to
            // a different date since the original request. Report the stored
            // entry date, not the resolved request date.
            let log_date = outcome.log.log_date;
            let data = serialize_json(&outcome.log)?;

            Ok(CommandOutput {
                data: data.clone(),
                meta: replay_meta(log_date, replayed),
                human: render_log_write(&data, replayed, runtime.today) + "\n",
            })
        }
        LogsCommand::Delete { id, yes } => {
            let id = parse_full_uuid(&id)?;
            if !confirm_delete(id, yes, global.json, runtime)? {
                let data = json!({
                    "id": id.to_string(),
                    "deleted": false,
                    "cancelled": true,
                });

                return Ok(CommandOutput {
                    data: data.clone(),
                    meta: empty_meta(),
                    human: render_delete_cancelled(&id),
                });
            }

            let api = api_client(global, runtime)?;
            api.delete_log(id).await?;
            let data = json!({"id": id.to_string(), "deleted": true});

            Ok(CommandOutput {
                data: data.clone(),
                meta: empty_meta(),
                human: render_delete(&id),
            })
        }
    }
}

fn confirm_delete(id: Uuid, yes: bool, json: bool, runtime: &Runtime) -> Result<bool, CliError> {
    if yes {
        return Ok(true);
    }
    if json {
        return Err(arguments_error(
            "invalid_arguments",
            "logs delete requires --yes in JSON mode",
        ));
    }
    if !runtime.stdin_is_tty {
        return Err(arguments_error(
            "invalid_arguments",
            "logs delete requires --yes when stdin is not interactive",
        ));
    }

    runtime.confirm.confirm_delete(id)
}

fn filter_logs_by_slot(
    logs: Vec<client::FoodLog>,
    slot: Option<client::MealSlot>,
) -> Result<Vec<Value>, CliError> {
    logs.into_iter()
        .filter(|log| slot.is_none() || log.meal_slot == slot)
        .map(|log| serialize_json(&log))
        .collect()
}

#[derive(Debug)]
struct ValidatedLogAdd {
    date: NaiveDate,
    item: client::LogItemRef,
    amount: Decimal,
    unit: String,
    slot: Option<client::MealSlot>,
    notes: Option<String>,
    device_timezone: Option<String>,
    idempotency_key: String,
}

fn validate_log_add(args: &LogAddArgs, today: NaiveDate) -> Result<ValidatedLogAdd, CliError> {
    let item = match (args.food.as_deref(), args.meal.as_deref()) {
        (Some(food), None) => client::LogItemRef::Product {
            id: parse_full_uuid(food)?,
        },
        (None, Some(meal)) => client::LogItemRef::Meal {
            id: parse_full_uuid(meal)?,
        },
        _ => {
            return Err(arguments_error(
                "invalid_arguments",
                "exactly one of --food or --meal is required",
            ));
        }
    };

    if args.amount <= Decimal::ZERO {
        return Err(arguments_error(
            "invalid_arguments",
            "amount must be a positive decimal",
        ));
    }

    if args.unit.trim().is_empty() {
        return Err(arguments_error(
            "invalid_arguments",
            "unit must not be empty",
        ));
    }

    if let Some(timezone) = &args.device_timezone
        && timezone.trim().is_empty()
    {
        return Err(arguments_error(
            "invalid_arguments",
            "device timezone must not be empty",
        ));
    }

    validate_idempotency_key(&args.idempotency_key)?;

    Ok(ValidatedLogAdd {
        date: DateSpan::parse_single(args.date.as_deref(), today)?,
        item,
        amount: args.amount,
        unit: args.unit.clone(),
        slot: args.slot,
        notes: args.notes.clone(),
        device_timezone: args.device_timezone.clone(),
        idempotency_key: args.idempotency_key.clone(),
    })
}

fn validate_idempotency_key(raw: &str) -> Result<(), CliError> {
    if raw.trim().is_empty() {
        return Err(arguments_error(
            "invalid_arguments",
            "idempotency key must not be blank",
        ));
    }
    if raw.chars().count() > 128 {
        return Err(arguments_error(
            "invalid_arguments",
            "idempotency key must be at most 128 characters",
        ));
    }
    if raw.chars().any(char::is_control) {
        return Err(arguments_error(
            "invalid_arguments",
            "idempotency key must not contain control characters",
        ));
    }

    Ok(())
}

fn build_create_log_request(validated: ValidatedLogAdd) -> client::CreateLogRequest {
    client::CreateLogRequest {
        log_date: validated.date,
        meal_slot: validated.slot,
        device_timezone: validated.device_timezone,
        item: validated.item,
        quantity: client::Quantity {
            amount: validated.amount,
            unit: validated.unit,
        },
        notes: validated.notes,
        idempotency_key: validated.idempotency_key,
    }
}

// ─── Human rendering ───────────────────────────────────────────

const SLOT_GROUPS: [(&str, &str); 5] = [
    ("breakfast", "Breakfast"),
    ("lunch", "Lunch"),
    ("dinner", "Dinner"),
    ("snack", "Snack"),
    ("late_night_snack", "Late night snack"),
];

const LOG_MACROS: [(&str, &str); 5] = [
    ("ENERGY_KCAL", "Calories"),
    ("PROTEIN_G", "Protein"),
    ("CARBS_G", "Carbs"),
    ("FAT_G", "Fat"),
    ("FIBER_G", "Fiber"),
];

fn nutrient_amount_text(nutrient: &Value) -> String {
    let amount = human_decimal(nutrient.get("amount"));
    if amount == "-" {
        return "-".to_string();
    }
    let unit = field_text(nutrient, "unit");
    if unit == "-" {
        amount
    } else {
        format!("{amount} {unit}")
    }
}

fn energy_nutrient_text(value: Option<&Value>) -> String {
    let Some(items) = value.and_then(Value::as_array) else {
        return "-".to_string();
    };

    items
        .iter()
        .find(|item| item.get("code").and_then(Value::as_str) == Some("ENERGY_KCAL"))
        .map(nutrient_amount_text)
        .unwrap_or_else(|| "-".to_string())
}

fn macros_text(value: Option<&Value>) -> String {
    let Some(items) = value.and_then(Value::as_array) else {
        return "-".to_string();
    };

    let segments = LOG_MACROS
        .iter()
        .filter_map(|&(code, label)| {
            items
                .iter()
                .find(|item| item.get("code").and_then(Value::as_str) == Some(code))
                .map(|item| format!("{label} {}", nutrient_amount_text(item)))
        })
        .collect::<Vec<_>>();

    if segments.is_empty() {
        "-".to_string()
    } else {
        segments.join(" · ")
    }
}

fn slot_label(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "Unspecified".to_string(),
        Some(Value::String(raw)) => match raw.as_str() {
            "breakfast" => "Breakfast".to_string(),
            "lunch" => "Lunch".to_string(),
            "dinner" => "Dinner".to_string(),
            "snack" => "Snack".to_string(),
            "late_night_snack" => "Late night snack".to_string(),
            other => escape_text(other),
        },
        Some(other) => scalar_text(Some(other)),
    }
}

fn is_specified_slot(value: Option<&Value>) -> bool {
    let Some(slot) = value.and_then(Value::as_str) else {
        return false;
    };

    SLOT_GROUPS.iter().any(|(known, _)| *known == slot)
}

fn item_name_text(value: Option<&Value>) -> String {
    match value {
        Some(item) if item.is_object() => {
            let name = field_text(item, "name");
            if name.is_empty() {
                "-".to_string()
            } else {
                name
            }
        }
        Some(other) => scalar_text(Some(other)),
        None => "-".to_string(),
    }
}

fn render_log_items(data: &Value, date: NaiveDate, today: NaiveDate) -> String {
    let items = data
        .get("items")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let lines = render_log_day_lines(items, date_label(date, today));

    lines.join("\n") + "\n"
}

fn render_log_day_lines(items: &[Value], header: String) -> Vec<String> {
    let mut lines = vec![header];
    if items.is_empty() {
        lines.push("  No logs.".to_string());
        return lines;
    }

    for (slot, label) in SLOT_GROUPS {
        let matching = items
            .iter()
            .filter(|item| item.get("meal_slot").and_then(Value::as_str) == Some(slot))
            .collect::<Vec<_>>();
        if matching.is_empty() {
            continue;
        }

        lines.push(format!("  {label}"));
        for item in matching {
            push_log_row(&mut lines, item);
        }
    }

    let unspecified = items
        .iter()
        .filter(|item| !is_specified_slot(item.get("meal_slot")))
        .collect::<Vec<_>>();
    if !unspecified.is_empty() {
        lines.push("  Unspecified".to_string());
        for item in unspecified {
            push_log_row(&mut lines, item);
        }
    }

    lines
}

fn push_log_row(lines: &mut Vec<String>, log: &Value) {
    lines.push(format!(
        "    {} · {} · {}",
        item_name_text(log.get("item")),
        quantity_text(log.get("quantity")),
        energy_nutrient_text(log.get("nutrients"))
    ));
    lines.push(format!("    id: {}", field_text(log, "id")));
}

fn render_log_days(data: &Value, span: DateSpan, today: NaiveDate) -> String {
    let Some(days) = data.get("days").and_then(Value::as_array) else {
        return format!("Logs · {} .. {}\n  No logs.\n", span.from, span.to);
    };
    if days.is_empty() {
        return format!("Logs · {} .. {}\n  No logs.\n", span.from, span.to);
    }

    let blocks = days
        .iter()
        .map(|day| {
            let items = day
                .get("items")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            render_log_day_lines(items, field_date_label(day, "date", today)).join("\n")
        })
        .collect::<Vec<_>>();

    format!(
        "Logs · {} .. {}\n\n{}\n",
        span.from,
        span.to,
        blocks.join("\n\n")
    )
}

fn render_log_detail(data: &Value, today: NaiveDate) -> String {
    let mut lines = vec![
        item_name_text(data.get("item")),
        format!(
            "{} · {} · {}",
            quantity_text(data.get("quantity")),
            field_date_label(data, "log_date", today),
            slot_label(data.get("meal_slot"))
        ),
        format!("Macros: {}", macros_text(data.get("nutrients"))),
    ];
    if let Some(item) = item_reference_text(data.get("item")) {
        lines.push(format!("Item: {item}"));
    }
    if let Some(notes) = optional_text(data.get("notes")) {
        lines.push(format!("Notes: {notes}"));
    }
    lines.push(format!("id: {}", field_text(data, "id")));

    lines.join("\n")
}

fn render_log_write(data: &Value, replayed: bool, today: NaiveDate) -> String {
    let action = if replayed {
        "Already recorded"
    } else {
        "Added"
    };
    let mut lines = vec![format!(
        "{action}: {} · {} · {}",
        item_name_text(data.get("item")),
        quantity_text(data.get("quantity")),
        energy_nutrient_text(data.get("nutrients"))
    )];
    if replayed {
        lines.push("No new entry created.".to_string());
    }
    lines.push(format!(
        "{} · {}",
        field_date_label(data, "log_date", today),
        slot_label(data.get("meal_slot"))
    ));
    lines.push(format!("id: {}", field_text(data, "id")));

    lines.join("\n")
}

fn render_delete(id: &Uuid) -> String {
    format!("Deleted log {}.\n", escape_text(&id.to_string()))
}

fn render_delete_cancelled(id: &Uuid) -> String {
    format!(
        "Cancelled. Log {} was not deleted.\n",
        escape_text(&id.to_string())
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::commands::{Command, run as run_command};
    use crate::test_support::{
        FakeConfirmation, FakeEnvironment, FakePrompt, FakeStores, date, decimal, global, runtime,
        runtime_with_confirmation, today,
    };

    fn valid_add_args() -> LogAddArgs {
        LogAddArgs {
            food: Some("123e4567-e89b-12d3-a456-426614174000".to_string()),
            meal: None,
            amount: decimal("150"),
            unit: "g".to_string(),
            date: None,
            slot: Some(client::MealSlot::Lunch),
            notes: None,
            device_timezone: None,
            idempotency_key: "lunch-2026-11-15-1".to_string(),
        }
    }

    #[test]
    fn add_validation_requires_exactly_one_item_and_positive_amount() {
        let mut args = valid_add_args();
        args.food = None;
        args.meal = None;
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.meal = Some("123e4567-e89b-12d3-a456-426614174001".to_string());
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.amount = Decimal::ZERO;
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.amount = decimal("-1");
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );
    }

    #[test]
    fn add_validation_checks_unit_timezone_key_and_date() {
        let mut args = valid_add_args();
        args.unit = "   ".to_string();
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.device_timezone = Some("  ".to_string());
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.idempotency_key = "   ".to_string();
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.idempotency_key = "key\nwith-control".to_string();
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.idempotency_key = "x".repeat(129);
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "invalid_arguments"
        );

        let mut args = valid_add_args();
        args.idempotency_key = "x".repeat(128);
        assert!(validate_log_add(&args, today()).is_ok());

        let mut args = valid_add_args();
        args.date = Some("today..yesterday".to_string());
        assert_eq!(
            validate_log_add(&args, today())
                .expect_err("expected an error")
                .code,
            "date_range_not_allowed"
        );
    }

    #[test]
    fn add_request_keeps_the_caller_key_in_the_body_and_omits_absent_fields() {
        let args = valid_add_args();
        let validated = validate_log_add(&args, today()).unwrap();
        let request = build_create_log_request(validated);
        let body = serde_json::to_value(&request).unwrap();

        assert_eq!(body["log_date"], "2026-11-15");
        assert_eq!(body["meal_slot"], "lunch");
        assert_eq!(
            body["item"],
            json!({"type": "product", "id": "123e4567-e89b-12d3-a456-426614174000"})
        );
        assert_eq!(body["quantity"], json!({"amount": "150", "unit": "g"}));
        assert_eq!(body["idempotency_key"], "lunch-2026-11-15-1");
        assert!(body.get("device_timezone").is_none());
        assert!(body.get("notes").is_none());
    }

    #[test]
    fn add_request_uses_the_meal_item_and_optional_fields_when_present() {
        let mut args = valid_add_args();
        args.food = None;
        args.meal = Some("123e4567-e89b-12d3-a456-426614174001".to_string());
        args.slot = None;
        args.notes = Some("note".to_string());
        args.device_timezone = Some("Asia/Kolkata".to_string());

        let validated = validate_log_add(&args, today()).unwrap();
        let body = serde_json::to_value(build_create_log_request(validated)).unwrap();

        assert_eq!(
            body["item"],
            json!({"type": "meal", "id": "123e4567-e89b-12d3-a456-426614174001"})
        );
        assert_eq!(body["notes"], "note");
        assert_eq!(body["device_timezone"], "Asia/Kolkata");
        assert!(body.get("meal_slot").is_none());
    }

    #[test]
    fn human_output_uses_placeholders_and_empty_list_text() {
        let id = "123e4567-e89b-12d3-a456-426614174000";
        let log = json!({
            "id": id,
            "log_date": "2026-11-15",
            "meal_slot": null,
            "device_timezone": null,
            "item": {"type": "product", "id": "123e4567-e89b-12d3-a456-426614174001", "name": "Food", "brand": null},
            "quantity": {"amount": "150", "unit": "g"},
            "nutrients": [],
            "notes": null,
            "created_at": "2026-11-15T00:00:00Z",
            "updated_at": "2026-11-15T00:00:00Z"
        });

        let human = render_log_detail(&log, today());
        assert!(human.starts_with("Food\n150 g · Today · 2026-11-15 · Unspecified\n"));
        assert!(human.contains("Macros: -"));
        assert!(!human.contains("Notes:"));
        assert!(human.contains(&format!("id: {id}")));
        assert!(!human.contains("brand"));
        assert!(!human.contains("device_timezone"));
        assert_eq!(
            render_log_items(&json!({"items": []}), date("2026-11-14"), today()),
            "Yesterday · 2026-11-14\n  No logs.\n"
        );
    }

    #[test]
    fn human_output_distinguishes_created_and_replayed_logs() {
        let log = json!({
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "log_date": "2026-11-14",
            "meal_slot": "lunch",
            "device_timezone": null,
            "item": {"type": "meal", "id": "123e4567-e89b-12d3-a456-426614174001", "name": "Lunch"},
            "quantity": {"amount": "1", "unit": "serving"},
            "nutrients": [{"code": "ENERGY_KCAL", "amount": "500", "unit": "kcal"}],
            "notes": null,
            "created_at": "2026-11-15T00:00:00Z",
            "updated_at": "2026-11-15T00:00:00Z"
        });

        let created = render_log_write(&log, false, today());
        assert!(created.starts_with("Added: Lunch · 1 serving · 500 kcal\n"));
        assert!(created.contains("Yesterday · 2026-11-14 · Lunch"));
        assert!(created.contains("id: 123e4567-e89b-12d3-a456-426614174000"));

        let replayed = render_log_write(&log, true, today());
        assert!(replayed.starts_with("Already recorded: Lunch · 1 serving · 500 kcal\n"));
        assert!(replayed.contains("No new entry created."));
        assert!(replayed.contains("Yesterday · 2026-11-14 · Lunch"));
        assert!(!replayed.contains("2026-11-15"));
    }

    #[test]
    fn human_log_energy_uses_only_the_recorded_energy_nutrient() {
        let log = json!({
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "log_date": "2026-11-15",
            "meal_slot": "lunch",
            "item": {"type": "product", "id": "123e4567-e89b-12d3-a456-426614174001", "name": "Food", "brand": null},
            "quantity": {"amount": "100", "unit": "g"},
            "nutrients": [{"code": "PROTEIN_G", "amount": "12", "unit": "g"}]
        });
        let human = render_log_items(&json!({"items": [log]}), date("2026-11-15"), today());
        assert!(human.contains("Food · 100 g · -"));
        assert!(!human.contains("0 kcal"));

        let log = json!({
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "log_date": "2026-11-15",
            "meal_slot": "lunch",
            "item": {"type": "product", "id": "123e4567-e89b-12d3-a456-426614174001", "name": "Food", "brand": null},
            "quantity": {"amount": "100", "unit": "g"},
            "nutrients": [{"code": "ENERGY_KCAL", "amount": "0", "unit": "kcal"}]
        });
        let human = render_log_items(&json!({"items": [log]}), date("2026-11-15"), today());
        assert!(human.contains("Food · 100 g · 0 kcal"));
    }

    #[test]
    fn human_log_output_follows_serialized_dtos() {
        let product_log = client::FoodLog {
            id: Uuid::parse_str("33333333-3333-3333-3333-333333333333").unwrap(),
            log_date: date("2026-11-15"),
            meal_slot: Some(client::MealSlot::Lunch),
            device_timezone: Some("Asia/Kolkata".to_string()),
            item: client::FoodLogItem::Product {
                id: Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap(),
                name: "Oats".to_string(),
                brand: Some("Home".to_string()),
            },
            quantity: client::Quantity {
                amount: decimal("150.5"),
                unit: "g".to_string(),
            },
            nutrients: vec![client::NutrientAmount {
                code: "ENERGY_KCAL".to_string(),
                amount: decimal("580"),
                unit: "kcal".to_string(),
            }],
            notes: Some("lunch note".to_string()),
            created_at: "2026-11-15T00:00:00Z".to_string(),
            updated_at: "2026-11-15T01:00:00Z".to_string(),
        };
        let meal_log = client::FoodLog {
            id: Uuid::parse_str("33333333-3333-3333-3333-333333333334").unwrap(),
            log_date: date("2026-11-15"),
            meal_slot: Some(client::MealSlot::Dinner),
            device_timezone: None,
            item: client::FoodLogItem::Meal {
                id: Uuid::parse_str("22222222-2222-2222-2222-222222222222").unwrap(),
                name: "Breakfast bowl".to_string(),
            },
            quantity: client::Quantity {
                amount: decimal("1"),
                unit: "serving".to_string(),
            },
            nutrients: Vec::new(),
            notes: None,
            created_at: "2026-11-15T00:00:00Z".to_string(),
            updated_at: "2026-11-15T01:00:00Z".to_string(),
        };
        let ad_hoc_log = client::FoodLog {
            id: Uuid::parse_str("33333333-3333-3333-3333-333333333335").unwrap(),
            log_date: date("2026-11-15"),
            meal_slot: None,
            device_timezone: None,
            item: client::FoodLogItem::AdHoc {
                name: "Tea".to_string(),
                brand: None,
            },
            quantity: client::Quantity {
                amount: decimal("0"),
                unit: "g".to_string(),
            },
            nutrients: Vec::new(),
            notes: None,
            created_at: "2026-11-15T00:00:00Z".to_string(),
            updated_at: "2026-11-15T01:00:00Z".to_string(),
        };

        let logs = vec![product_log.clone(), meal_log, ad_hoc_log];
        let items = filter_logs_by_slot(logs.clone(), None).unwrap();
        let data = json!({"items": items});
        let human = render_log_items(&data, date("2026-11-15"), today());

        assert_eq!(
            human,
            concat!(
                "Today · 2026-11-15\n",
                "  Lunch\n",
                "    Oats · 150.5 g · 580 kcal\n",
                "    id: 33333333-3333-3333-3333-333333333333\n",
                "  Dinner\n",
                "    Breakfast bowl · 1 serving · -\n",
                "    id: 33333333-3333-3333-3333-333333333334\n",
                "  Unspecified\n",
                "    Tea · 0 g · -\n",
                "    id: 33333333-3333-3333-3333-333333333335\n"
            )
        );
        assert!(!human.contains("Home"));
        assert!(!human.contains("Asia/Kolkata"));
        assert!(!human.contains("created_at"));

        let detail = render_log_detail(&serialize_json(&product_log).unwrap(), today());
        assert_eq!(
            detail,
            concat!(
                "Oats\n",
                "150.5 g · Today · 2026-11-15 · Lunch\n",
                "Macros: Calories 580 kcal\n",
                "Item: Product 11111111-1111-1111-1111-111111111111\n",
                "Notes: lunch note\n",
                "id: 33333333-3333-3333-3333-333333333333"
            )
        );

        let lunch_only = filter_logs_by_slot(logs, Some(client::MealSlot::Lunch)).unwrap();
        assert_eq!(lunch_only.len(), 1);
        assert_eq!(lunch_only[0]["meal_slot"], "lunch");

        let span = DateSpan::parse(Some("2026-11-15..2026-11-16"), today()).unwrap();
        let days = json!({
            "days": [
                {
                    "date": "2026-11-15",
                    "items": filter_logs_by_slot(vec![product_log], None).unwrap(),
                },
                {
                    "date": "2026-11-16",
                    "items": [],
                }
            ]
        });
        let human = render_log_days(&days, span, today());
        assert!(human.starts_with("Logs · 2026-11-15 .. 2026-11-16\n\nToday · 2026-11-15\n"));
        assert!(human.contains("Oats · 150.5 g · 580 kcal"));
        assert!(human.contains("\n2026-11-16\n  No logs.\n"));
    }

    #[tokio::test]
    async fn delete_prompts_in_interactive_human_mode_and_cancels_without_a_request() {
        let id = "123e4567-e89b-12d3-a456-426614174000";

        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("unused"));
        let confirm = Arc::new(FakeConfirmation::new(true));
        let runtime = runtime_with_confirmation(env, stores, prompt, confirm.clone(), true);

        let error = run_command(
            Command::Logs(LogsArgs {
                command: LogsCommand::Delete {
                    id: id.to_string(),
                    yes: false,
                },
            }),
            &global(false, None),
            &runtime,
        )
        .await
        .expect_err("confirmation proceeds to connection resolution");

        assert_eq!(error.code, "base_url_missing");
        assert_eq!(confirm.calls(), 1);

        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("unused"));
        let confirm = Arc::new(FakeConfirmation::new(false));
        let runtime = runtime_with_confirmation(env, stores, prompt, confirm.clone(), true);

        let output = run_command(
            Command::Logs(LogsArgs {
                command: LogsCommand::Delete {
                    id: id.to_string(),
                    yes: false,
                },
            }),
            &global(false, None),
            &runtime,
        )
        .await
        .expect("declining confirmation cancels safely");

        assert_eq!(confirm.calls(), 1);
        assert_eq!(output.data["id"], id);
        assert_eq!(output.data["deleted"], false);
        assert_eq!(output.data["cancelled"], true);
        assert!(
            output
                .human
                .contains(&format!("Cancelled. Log {id} was not deleted."))
        );
    }

    #[test]
    fn delete_confirmation_accepts_only_explicit_yes() {
        for answer in ["y", "Y", "yes", "YES", " yes \n"] {
            assert!(confirmation_answer_is_yes(answer), "{answer:?}");
        }
        for answer in ["", "\n", "n", "no", "yeah", "yep", "true", "1"] {
            assert!(!confirmation_answer_is_yes(answer), "{answer:?}");
        }
    }

    #[tokio::test]
    async fn delete_requires_yes_in_json_and_noninteractive_modes_before_prompting() {
        let id = "123e4567-e89b-12d3-a456-426614174000";

        for (json_mode, stdin_is_tty) in [(false, false), (true, true)] {
            let env = Arc::new(FakeEnvironment::default());
            let stores = Arc::new(FakeStores::default());
            let prompt = Arc::new(FakePrompt::new("unused"));
            let confirm = Arc::new(FakeConfirmation::new(true));
            let runtime =
                runtime_with_confirmation(env, stores, prompt, confirm.clone(), stdin_is_tty);

            let error = run_command(
                Command::Logs(LogsArgs {
                    command: LogsCommand::Delete {
                        id: id.to_string(),
                        yes: false,
                    },
                }),
                &global(json_mode, None),
                &runtime,
            )
            .await
            .expect_err("expected an error");

            assert_eq!(error.code, "invalid_arguments");
            assert!(error.message.contains("--yes"));
            assert_eq!(confirm.calls(), 0);
        }

        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("unused"));
        let confirm = Arc::new(FakeConfirmation::new(false));
        let runtime = runtime_with_confirmation(env, stores, prompt, confirm.clone(), false);

        let error = run_command(
            Command::Logs(LogsArgs {
                command: LogsCommand::Delete {
                    id: id.to_string(),
                    yes: true,
                },
            }),
            &global(false, None),
            &runtime,
        )
        .await
        .expect_err("explicit yes proceeds without prompting");

        assert_eq!(error.code, "base_url_missing");
        assert_eq!(confirm.calls(), 0);
    }

    #[tokio::test]
    async fn add_validation_runs_before_base_url_resolution() {
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("unused"));
        let runtime = runtime(env, stores, prompt, true);

        let mut args = valid_add_args();
        args.amount = Decimal::ZERO;

        let error = run_command(
            Command::Logs(LogsArgs {
                command: LogsCommand::Add(args),
            }),
            &global(false, None),
            &runtime,
        )
        .await
        .expect_err("expected an error");

        assert_eq!(error.code, "invalid_arguments");
    }
}

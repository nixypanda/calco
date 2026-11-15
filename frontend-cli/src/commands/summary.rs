//! Daily and ranged summary arguments, merging, aggregation, and rendering.
//!
//! The backend returns only days with logs. This module zero-fills the resolved
//! calendar range, records whether logs existed, and aggregates without floats.

use std::collections::BTreeMap;

use chrono::NaiveDate;
use rust_decimal::{Decimal, RoundingStrategy};
use serde::Serialize;
use serde_json::{Value, json};

use crate::client;
use crate::dates::DateSpan;
use crate::output::{
    CliError, CommandOutput, date_label, escape_text, field_bool, field_text, human_decimal,
    invalid_response, range_meta, render_table, serialize_json,
};

use super::{GlobalArgs, Runtime, api_client};

const SUMMARY_TOTAL_KEYS: [&str; 4] = ["energy_kcal", "protein_g", "carbs_g", "fat_g"];

#[derive(Debug, clap::Args)]
pub struct SummaryArgs {
    pub date: Option<String>,
}

fn merge_summary(
    span: DateSpan,
    server_days: Vec<client::SummaryDay>,
) -> Result<Vec<client::SummaryDayOutput>, CliError> {
    let mut by_date = BTreeMap::new();

    for day in server_days {
        if day.date < span.from || day.date > span.to {
            return Err(invalid_response(format!(
                "summary response contained date {} outside the requested range",
                day.date
            )));
        }
        if by_date.insert(day.date, day).is_some() {
            return Err(invalid_response(
                "summary response contained a duplicate date",
            ));
        }
    }

    Ok(span
        .dates()
        .map(|date| match by_date.remove(&date) {
            Some(day) => client::SummaryDayOutput {
                date,
                has_logs: true,
                energy_kcal: day.energy_kcal,
                protein_g: day.protein_g,
                carbs_g: day.carbs_g,
                fat_g: day.fat_g,
            },
            None => client::SummaryDayOutput {
                date,
                has_logs: false,
                energy_kcal: Decimal::ZERO,
                protein_g: Decimal::ZERO,
                carbs_g: Decimal::ZERO,
                fat_g: Decimal::ZERO,
            },
        })
        .collect())
}

/// Summed nutrient values for a summary range.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct SummaryNutrients {
    energy_kcal: Decimal,
    protein_g: Decimal,
    carbs_g: Decimal,
    fat_g: Decimal,
}

impl SummaryNutrients {
    fn totals(days: &[client::SummaryDayOutput]) -> Result<Self, CliError> {
        let mut totals = Self {
            energy_kcal: Decimal::ZERO,
            protein_g: Decimal::ZERO,
            carbs_g: Decimal::ZERO,
            fat_g: Decimal::ZERO,
        };

        for day in days {
            totals.energy_kcal = checked_nutrient_add(totals.energy_kcal, day.energy_kcal)?;
            totals.protein_g = checked_nutrient_add(totals.protein_g, day.protein_g)?;
            totals.carbs_g = checked_nutrient_add(totals.carbs_g, day.carbs_g)?;
            totals.fat_g = checked_nutrient_add(totals.fat_g, day.fat_g)?;
        }

        Ok(totals.normalized())
    }

    fn calendar_day_averages(&self, calendar_days: usize) -> Result<Self, CliError> {
        let divisor = Decimal::from(calendar_days.max(1) as u64);
        Ok(Self {
            energy_kcal: average(self.energy_kcal, divisor)?,
            protein_g: average(self.protein_g, divisor)?,
            carbs_g: average(self.carbs_g, divisor)?,
            fat_g: average(self.fat_g, divisor)?,
        })
    }

    fn normalized(self) -> Self {
        Self {
            energy_kcal: self.energy_kcal.normalize(),
            protein_g: self.protein_g.normalize(),
            carbs_g: self.carbs_g.normalize(),
            fat_g: self.fat_g.normalize(),
        }
    }
}

/// Add a server-controlled nutrient value without panicking on decimal overflow.
fn checked_nutrient_add(total: Decimal, value: Decimal) -> Result<Decimal, CliError> {
    total.checked_add(value).ok_or_else(|| {
        invalid_response("summary nutrient totals exceed the supported decimal range")
    })
}

fn average(total: Decimal, divisor: Decimal) -> Result<Decimal, CliError> {
    let quotient = total.checked_div(divisor).ok_or_else(|| {
        invalid_response("summary nutrient averages exceed the supported decimal range")
    })?;
    Ok(quotient
        .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
        .normalize())
}

pub(super) async fn run(
    args: SummaryArgs,
    global: &GlobalArgs,
    runtime: &Runtime,
) -> Result<CommandOutput, CliError> {
    let span = DateSpan::parse(args.date.as_deref(), runtime.today)?;
    let api = api_client(global, runtime)?;
    let response = api.summary(span.from, span.to).await?;
    let days = merge_summary(span, response.days)?;
    let data = summary_data(&days, span.len())?;

    Ok(CommandOutput {
        data: data.clone(),
        meta: range_meta(span.from, span.to),
        human: render_summary(&data, span, runtime.today),
    })
}

fn summary_data(
    days: &[client::SummaryDayOutput],
    calendar_days: usize,
) -> Result<Value, CliError> {
    let totals = SummaryNutrients::totals(days)?;
    let averages = totals.calendar_day_averages(calendar_days)?;
    Ok(json!({
        "days": serialize_json(days)?,
        "totals": serialize_json(&totals)?,
        "averages": serialize_json(&averages)?,
    }))
}

fn render_summary(data: &Value, span: DateSpan, today: NaiveDate) -> String {
    let Some(days) = data.get("days").and_then(Value::as_array) else {
        return "No summary data.\n".to_string();
    };
    if days.is_empty() {
        return "No summary data.\n".to_string();
    }

    if span.is_single() {
        let day = &days[0];
        let mut lines = vec![date_label(span.from, today)];
        if field_bool(day, "has_logs") == Some(true) {
            for key in SUMMARY_TOTAL_KEYS {
                lines.push(format!(
                    "  {}: {}",
                    summary_label(key),
                    summary_value_text(day, key)
                ));
            }
        } else {
            lines.push("  no logs (not zero intake)".to_string());
        }
        return lines.join("\n") + "\n";
    }

    let mut rows = Vec::with_capacity(days.len() + 2);
    for day in days {
        if field_bool(day, "has_logs") == Some(true) {
            rows.push(vec![
                field_text(day, "date"),
                human_decimal(day.get("energy_kcal")),
                human_decimal(day.get("protein_g")),
                human_decimal(day.get("carbs_g")),
                human_decimal(day.get("fat_g")),
            ]);
        } else {
            rows.push(vec![
                field_text(day, "date"),
                "no logs (not zero intake)".to_string(),
            ]);
        }
    }

    let null = Value::Null;
    let totals = data.get("totals").unwrap_or(&null);
    let averages = data.get("averages").unwrap_or(&null);
    rows.push(summary_row("Total", totals));
    rows.push(summary_row("Daily avg", averages));

    let mut output = format!("Summary · {} .. {}\n", span.from, span.to);
    output.push_str(&render_table(
        &["DATE", "KCAL", "PROTEIN", "CARBS", "FAT"],
        &rows,
    ));
    output.push('\n');
    output
}

fn summary_row(label: &str, nutrients: &Value) -> Vec<String> {
    let mut row = vec![label.to_string()];
    for key in SUMMARY_TOTAL_KEYS {
        row.push(human_decimal(nutrients.get(key)));
    }
    row
}

fn summary_label(key: &str) -> String {
    match key {
        "energy_kcal" => "Logged calories".to_string(),
        "protein_g" => "Protein".to_string(),
        "carbs_g" => "Carbs".to_string(),
        "fat_g" => "Fat".to_string(),
        other => escape_text(other),
    }
}

fn summary_value_text(day: &Value, key: &str) -> String {
    let amount = human_decimal(day.get(key));
    if amount == "-" {
        return amount;
    }

    if key == "energy_kcal" {
        format!("{amount} kcal")
    } else {
        format!("{amount} g")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::auth;
    use crate::commands::{Command, run as run_command};
    use crate::test_support::{
        FakeEnvironment, FakePrompt, FakeStores, MockServer, date, decimal, global, runtime, today,
    };

    fn summary_day(raw_date: &str, energy: &str) -> client::SummaryDay {
        client::SummaryDay {
            date: date(raw_date),
            energy_kcal: decimal(energy),
            protein_g: decimal("90"),
            carbs_g: decimal("210"),
            fat_g: decimal("60"),
        }
    }

    #[test]
    fn summary_merge_zero_fills_every_calendar_date() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-16"), today()).unwrap();
        let merged = merge_summary(span, vec![summary_day("2026-11-15", "1850")]).unwrap();

        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].date, date("2026-11-14"));
        assert!(!merged[0].has_logs);
        assert_eq!(merged[0].energy_kcal, Decimal::ZERO);
        assert_eq!(merged[0].protein_g, Decimal::ZERO);
        assert_eq!(merged[0].carbs_g, Decimal::ZERO);
        assert_eq!(merged[0].fat_g, Decimal::ZERO);

        assert_eq!(merged[1].date, date("2026-11-15"));
        assert!(merged[1].has_logs);
        assert_eq!(merged[1].energy_kcal, decimal("1850"));
        assert_eq!(merged[1].protein_g, decimal("90"));

        assert_eq!(merged[2].date, date("2026-11-16"));
        assert!(!merged[2].has_logs);
    }

    #[test]
    fn summary_merge_orders_server_days_and_serializes_decimals_as_strings() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-16"), today()).unwrap();
        let merged = merge_summary(
            span,
            vec![
                summary_day("2026-11-16", "10"),
                summary_day("2026-11-14", "20"),
            ],
        )
        .unwrap();

        assert_eq!(merged[0].date, date("2026-11-14"));
        assert_eq!(merged[1].date, date("2026-11-15"));
        assert_eq!(merged[2].date, date("2026-11-16"));

        let value = serde_json::to_value(&merged).unwrap();
        assert_eq!(value[0]["has_logs"], true);
        assert_eq!(value[0]["energy_kcal"], "20");
        assert_eq!(value[1]["has_logs"], false);
        assert_eq!(value[1]["energy_kcal"], "0");
    }

    #[test]
    fn summary_merge_rejects_duplicate_and_out_of_range_dates() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-16"), today()).unwrap();

        let duplicate = merge_summary(
            span,
            vec![
                summary_day("2026-11-15", "1"),
                summary_day("2026-11-15", "2"),
            ],
        )
        .expect_err("expected an error");
        assert_eq!(duplicate.code, "invalid_response");

        let outside = merge_summary(span, vec![summary_day("2026-11-13", "1")])
            .expect_err("expected an error");
        assert_eq!(outside.code, "invalid_response");
    }

    #[test]
    fn summary_merge_zero_fills_an_empty_server_response() {
        let span = DateSpan::parse(Some("2026-11-15"), today()).unwrap();
        let merged = merge_summary(span, Vec::new()).unwrap();

        assert_eq!(merged.len(), 1);
        assert!(!merged[0].has_logs);
        assert_eq!(merged[0].energy_kcal, Decimal::ZERO);
    }

    #[test]
    fn summary_human_output_never_shows_innocent_zeroes_for_no_log_days() {
        let data = json!({
            "days": [
                {
                    "date": "2026-11-14",
                    "has_logs": true,
                    "energy_kcal": "1850",
                    "protein_g": "90",
                    "carbs_g": "210",
                    "fat_g": "60"
                },
                {
                    "date": "2026-11-15",
                    "has_logs": false,
                    "energy_kcal": "0",
                    "protein_g": "0",
                    "carbs_g": "0",
                    "fat_g": "0"
                }
            ],
            "totals": {
                "energy_kcal": "1850",
                "protein_g": "90",
                "carbs_g": "210",
                "fat_g": "60"
            },
            "averages": {
                "energy_kcal": "925",
                "protein_g": "45",
                "carbs_g": "105",
                "fat_g": "30"
            }
        });

        let span = DateSpan::parse(Some("2026-11-14..2026-11-15"), today()).unwrap();
        let human = render_summary(&data, span, today());
        assert!(human.contains("2026-11-14  1850"));
        assert!(human.contains("2026-11-15  no logs (not zero intake)"));
        assert!(human.contains("Total       1850"));
        assert!(human.contains("Daily avg   925"));
        assert!(!human.contains("energy_kcal"));
    }

    #[test]
    fn summary_single_day_human_output_is_labelled() {
        let span = DateSpan::parse(Some("today"), today()).unwrap();
        let days = merge_summary(span, vec![summary_day("2026-11-15", "1850")]).unwrap();
        let data = summary_data(&days, span.len()).unwrap();
        let human = render_summary(&data, span, today());

        assert_eq!(
            human,
            concat!(
                "Today · 2026-11-15\n",
                "  Logged calories: 1850 kcal\n",
                "  Protein: 90 g\n",
                "  Carbs: 210 g\n",
                "  Fat: 60 g\n"
            )
        );
    }

    #[test]
    fn human_summary_output_follows_serialized_output_dtos() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-15"), today()).unwrap();
        let days = merge_summary(span, vec![summary_day("2026-11-14", "1850")]).unwrap();
        let data = summary_data(&days, span.len()).unwrap();
        let human = render_summary(&data, span, today());

        assert_eq!(
            human,
            concat!(
                "Summary · 2026-11-14 .. 2026-11-15\n",
                "DATE        KCAL  PROTEIN  CARBS  FAT\n",
                "2026-11-14  1850  90       210    60\n",
                "2026-11-15  no logs (not zero intake)\n",
                "Total       1850  90       210    60\n",
                "Daily avg   925   45       105    30\n"
            )
        );
    }

    #[test]
    fn summary_totals_and_calendar_day_averages_include_empty_days() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-16"), today()).unwrap();
        let days = merge_summary(
            span,
            vec![
                summary_day("2026-11-14", "100"),
                summary_day("2026-11-16", "200"),
            ],
        )
        .unwrap();

        let totals = SummaryNutrients::totals(&days).unwrap();
        let averages = totals.calendar_day_averages(span.len()).unwrap();

        let totals = serde_json::to_value(&totals).unwrap();
        let averages = serde_json::to_value(&averages).unwrap();
        let data = summary_data(&days, span.len()).unwrap();

        assert_eq!(data["days"][0]["has_logs"], true);
        assert_eq!(data["days"][1]["has_logs"], false);
        assert_eq!(data["totals"], totals);
        assert_eq!(data["averages"], averages);

        assert_eq!(totals["energy_kcal"], "300");
        assert_eq!(totals["protein_g"], "180");
        assert_eq!(totals["carbs_g"], "420");
        assert_eq!(totals["fat_g"], "120");

        assert_eq!(averages["energy_kcal"], "100");
        assert_eq!(averages["protein_g"], "60");
        assert_eq!(averages["carbs_g"], "140");
        assert_eq!(averages["fat_g"], "40");
    }

    #[test]
    fn summary_averages_round_without_floats() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-16"), today()).unwrap();
        let days = merge_summary(span, vec![summary_day("2026-11-15", "100")]).unwrap();

        let totals = SummaryNutrients::totals(&days).unwrap();
        let averages = totals.calendar_day_averages(span.len()).unwrap();
        let averages = serde_json::to_value(&averages).unwrap();

        assert_eq!(averages["energy_kcal"], "33.33");
        assert_eq!(averages["protein_g"], "30");
        assert_eq!(averages["carbs_g"], "70");
        assert_eq!(averages["fat_g"], "20");
    }

    fn summary_day_at_max(raw_date: &str, nutrient: &str) -> client::SummaryDay {
        let mut day = client::SummaryDay {
            date: date(raw_date),
            energy_kcal: Decimal::ZERO,
            protein_g: Decimal::ZERO,
            carbs_g: Decimal::ZERO,
            fat_g: Decimal::ZERO,
        };
        match nutrient {
            "energy_kcal" => day.energy_kcal = Decimal::MAX,
            "protein_g" => day.protein_g = Decimal::MAX,
            "carbs_g" => day.carbs_g = Decimal::MAX,
            "fat_g" => day.fat_g = Decimal::MAX,
            _ => unreachable!("summary nutrient key"),
        }
        day
    }

    #[test]
    fn summary_totals_reject_server_controlled_decimal_overflow() {
        let span = DateSpan::parse(Some("2026-11-14..2026-11-15"), today()).unwrap();

        for nutrient in SUMMARY_TOTAL_KEYS {
            let days = merge_summary(
                span,
                vec![
                    summary_day_at_max("2026-11-14", nutrient),
                    summary_day_at_max("2026-11-15", nutrient),
                ],
            )
            .unwrap();

            let error = SummaryNutrients::totals(&days).expect_err("expected overflow");
            assert_eq!(error.code, "invalid_response");
            assert_eq!(error.exit_code(), 6);

            let error = summary_data(&days, span.len()).expect_err("expected overflow");
            assert_eq!(error.code, "invalid_response");
            assert_eq!(error.exit_code(), 6);
        }

        let single = merge_summary(
            DateSpan::parse(Some("2026-11-15"), today()).unwrap(),
            vec![summary_day_at_max("2026-11-15", "energy_kcal")],
        )
        .unwrap();
        let totals = SummaryNutrients::totals(&single).unwrap();
        assert_eq!(totals.energy_kcal, Decimal::MAX);
        let data = summary_data(&single, 1).unwrap();
        assert_eq!(data["totals"]["energy_kcal"], Decimal::MAX.to_string());
        assert_eq!(data["averages"]["energy_kcal"], Decimal::MAX.to_string());

        let data = summary_data(&single, 3).unwrap();
        assert!(data["averages"]["energy_kcal"].is_string());
    }

    #[tokio::test]
    async fn summary_overflow_is_reported_as_invalid_response_without_panicking() {
        let body = json!({
            "days": [
                {
                    "date": "2026-11-14",
                    "energy_kcal": Decimal::MAX.to_string(),
                    "protein_g": "0",
                    "carbs_g": "0",
                    "fat_g": "0"
                },
                {
                    "date": "2026-11-15",
                    "energy_kcal": Decimal::MAX.to_string(),
                    "protein_g": "0",
                    "carbs_g": "0",
                    "fat_g": "0"
                }
            ]
        })
        .to_string();
        let server = MockServer::start(200, body);
        let env = Arc::new(FakeEnvironment::new(&[(auth::ENV_API_KEY, "test-token")]));
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("unused"));
        let runtime = runtime(env, stores, prompt, true);

        let error = run_command(
            Command::Summary(SummaryArgs {
                date: Some("2026-11-14..2026-11-15".to_string()),
            }),
            &global(false, Some(server.base_url())),
            &runtime,
        )
        .await
        .expect_err("overflow must fail instead of panicking");

        assert!(matches!(error.origin, crate::output::ErrorOrigin::Response));
        assert_eq!(error.code, "invalid_response");
        assert_eq!(error.exit_code(), 6);

        let requests = server.expect_requests(1);
        assert_eq!(
            requests[0].target,
            "/api/logs/summary?from_date=2026-11-14&to_date=2026-11-15"
        );
        server.join();
    }
}

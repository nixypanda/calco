//! Structured errors, output modes and envelopes, and shared human formatting.
//!
//! Command modules own category-specific rendering. This module owns only the
//! stable success/error contracts and the formatting primitives shared across
//! commands.

use std::borrow::Cow;
use std::fmt;
use std::io::{self, Write as IoWrite};

use chrono::{Duration, NaiveDate};
use rust_decimal::{Decimal, RoundingStrategy};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SCHEMA_VERSION: u32 = 1;

// ─── Output mode ─────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputMode {
    Human,
    JsonCompact,
    JsonPretty,
}

impl OutputMode {
    pub fn resolve(json: bool, pretty: bool) -> Result<Self, CliError> {
        match (json, pretty) {
            (false, false) => Ok(Self::Human),
            (true, false) => Ok(Self::JsonCompact),
            (true, true) => Ok(Self::JsonPretty),
            (false, true) => Err(CliError::new(
                ErrorOrigin::Arguments,
                "invalid_arguments",
                "--pretty requires --json",
            )),
        }
    }
}

// ─── Errors ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorOrigin {
    Arguments,
    Config,
    Credentials,
    Keyring,
    Transport,
    Server,
    Response,
    Internal,
}

impl ErrorOrigin {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Arguments => "arguments",
            Self::Config => "config",
            Self::Credentials => "credentials",
            Self::Keyring => "keyring",
            Self::Transport => "transport",
            Self::Server => "server",
            Self::Response => "response",
            Self::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ErrorRequest {
    pub method: &'static str,
    pub url: String,
    pub body: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct CliError {
    pub origin: ErrorOrigin,
    pub code: String,
    pub message: String,
    pub http_status: Option<u16>,
    pub uncertain: bool,
    pub request: Option<Box<ErrorRequest>>,
    pub recovery: Option<String>,
}

impl CliError {
    pub fn new(origin: ErrorOrigin, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            origin,
            code: code.into(),
            message: message.into(),
            http_status: None,
            uncertain: false,
            request: None,
            recovery: None,
        }
    }

    pub fn exit_code(&self) -> u8 {
        match self.origin {
            ErrorOrigin::Arguments => 2,
            ErrorOrigin::Config | ErrorOrigin::Keyring | ErrorOrigin::Internal => 1,
            ErrorOrigin::Credentials => 3,
            ErrorOrigin::Transport | ErrorOrigin::Response => 6,
            ErrorOrigin::Server => self.http_status.map(exit_code_for_http_status).unwrap_or(6),
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for CliError {}

fn exit_code_for_http_status(status: u16) -> u8 {
    match status {
        400 => 2,
        401 | 403 => 3,
        404 => 4,
        409 => 5,
        _ => 6,
    }
}

// ─── Output envelopes ────────────────────────────────────────

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputMeta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<NaiveDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_date: Option<NaiveDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_date: Option<NaiveDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replayed: Option<bool>,
}

#[derive(Debug)]
pub struct CommandOutput {
    pub data: Value,
    pub meta: OutputMeta,
    pub human: String,
}

#[derive(Serialize)]
struct SuccessEnvelope<'a> {
    schema_version: u32,
    data: &'a Value,
    meta: &'a OutputMeta,
}

#[derive(Serialize)]
struct ErrorEnvelope<'a> {
    schema_version: u32,
    error: ErrorBodyJson<'a>,
}

#[derive(Serialize)]
struct ErrorBodyJson<'a> {
    origin: ErrorOrigin,
    code: &'a str,
    message: &'a str,
    http_status: Option<u16>,
    uncertain: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    request: Option<ErrorRequestJson<'a>>,
    recovery: Option<&'a str>,
}

#[derive(Serialize)]
struct ErrorRequestJson<'a> {
    method: &'a str,
    url: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    body: Option<&'a Value>,
}

pub fn write_success(output: &CommandOutput, mode: OutputMode) -> std::io::Result<()> {
    let rendered = render_success(output, mode).map_err(io::Error::other)?;
    let mut stdout = io::stdout().lock();
    stdout.write_all(rendered.as_bytes())?;
    if !rendered.is_empty() && !rendered.ends_with('\n') {
        stdout.write_all(b"\n")?;
    }
    stdout.flush()
}

pub fn write_error(error: &CliError, mode: OutputMode) -> std::io::Result<()> {
    let rendered = match mode {
        OutputMode::Human => format_error_human(error),
        OutputMode::JsonCompact => {
            render_error(error, OutputMode::JsonCompact).map_err(io::Error::other)?
        }
        OutputMode::JsonPretty => {
            render_error(error, OutputMode::JsonPretty).map_err(io::Error::other)?
        }
    };
    let mut stderr = io::stderr().lock();
    stderr.write_all(rendered.as_bytes())?;
    if !rendered.ends_with('\n') {
        stderr.write_all(b"\n")?;
    }
    stderr.flush()
}

fn render_success(output: &CommandOutput, mode: OutputMode) -> Result<String, serde_json::Error> {
    if mode == OutputMode::Human {
        return Ok(output.human.clone());
    }
    let envelope = SuccessEnvelope {
        schema_version: SCHEMA_VERSION,
        data: &output.data,
        meta: &output.meta,
    };
    match mode {
        OutputMode::JsonPretty => serde_json::to_string_pretty(&envelope),
        _ => serde_json::to_string(&envelope),
    }
}

pub(crate) fn render_error(
    error: &CliError,
    mode: OutputMode,
) -> Result<String, serde_json::Error> {
    let request = error.request.as_ref().map(|request| ErrorRequestJson {
        method: request.method,
        url: &request.url,
        body: request.body.as_ref(),
    });
    let envelope = ErrorEnvelope {
        schema_version: SCHEMA_VERSION,
        error: ErrorBodyJson {
            origin: error.origin,
            code: &error.code,
            message: &error.message,
            http_status: error.http_status,
            uncertain: error.uncertain,
            request,
            recovery: error.recovery.as_deref(),
        },
    };
    match mode {
        OutputMode::JsonPretty => serde_json::to_string_pretty(&envelope),
        _ => serde_json::to_string(&envelope),
    }
}

pub(crate) fn format_error_human(error: &CliError) -> String {
    let mut lines = Vec::with_capacity(8);
    lines.push(format!("error: {}", escape_human_text(&error.message)));
    lines.push(format!("  origin: {}", error.origin.label()));
    lines.push(format!("  code: {}", escape_human_text(&error.code)));
    lines.push(format!(
        "  http_status: {}",
        error
            .http_status
            .map(|status| status.to_string())
            .unwrap_or_else(|| "null".to_owned())
    ));
    lines.push(format!("  uncertain: {}", error.uncertain));
    if let Some(request) = &error.request {
        lines.push("  request:".to_owned());
        lines.push(format!("    method: {}", request.method));
        lines.push(format!("    url: {}", escape_human_text(&request.url)));
        let body = request
            .body
            .as_ref()
            .and_then(|body| serde_json::to_string(body).ok())
            .unwrap_or_else(|| "null".to_owned());
        lines.push(format!("    body: {}", escape_human_text(&body)));
    }
    lines.push(format!(
        "  recovery: {}",
        error
            .recovery
            .as_deref()
            .map(escape_human_text)
            .unwrap_or(Cow::Borrowed("null"))
    ));
    lines.join("\n")
}

pub fn escape_human_text(input: &str) -> Cow<'_, str> {
    if !input.chars().any(is_unsafe_terminal_char) {
        return Cow::Borrowed(input);
    }

    let mut escaped = String::with_capacity(input.len());
    for character in input.chars() {
        if is_unsafe_terminal_char(character) {
            use std::fmt::Write as _;
            let _ = write!(escaped, "\\u{{{:04X}}}", character as u32);
        } else {
            escaped.push(character);
        }
    }
    Cow::Owned(escaped)
}

fn is_unsafe_terminal_char(character: char) -> bool {
    if character.is_control() {
        return true;
    }
    matches!(
        character as u32,
        0x00AD
            | 0x061C
            | 0x180E
            | 0x200B..=0x200F
            | 0x2028
            | 0x2029
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x206F
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0xE0001
            | 0xE0020..=0xE007F
    )
}

pub(crate) fn serialize_json<T: Serialize + ?Sized>(value: &T) -> Result<Value, CliError> {
    serde_json::to_value(value).map_err(|error| {
        CliError::new(
            ErrorOrigin::Internal,
            "internal_error",
            format!("failed to serialize command output: {error}"),
        )
    })
}

pub(crate) fn empty_meta() -> OutputMeta {
    OutputMeta {
        date: None,
        from_date: None,
        to_date: None,
        replayed: None,
    }
}

pub(crate) fn date_meta(date: NaiveDate) -> OutputMeta {
    OutputMeta {
        date: Some(date),
        from_date: None,
        to_date: None,
        replayed: None,
    }
}

pub(crate) fn range_meta(from: NaiveDate, to: NaiveDate) -> OutputMeta {
    OutputMeta {
        date: None,
        from_date: Some(from),
        to_date: Some(to),
        replayed: None,
    }
}

pub(crate) fn replay_meta(date: NaiveDate, replayed: bool) -> OutputMeta {
    OutputMeta {
        date: Some(date),
        from_date: None,
        to_date: None,
        replayed: Some(replayed),
    }
}

pub(crate) fn arguments_error(code: &'static str, message: impl Into<String>) -> CliError {
    CliError::new(ErrorOrigin::Arguments, code, message)
}

pub(crate) fn invalid_response(message: impl Into<String>) -> CliError {
    CliError::new(ErrorOrigin::Response, "invalid_response", message)
}

pub(crate) fn escape_text(value: &str) -> String {
    escape_human_text(value).into_owned()
}

pub(crate) fn scalar_text(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "-".to_string(),
        Some(Value::String(text)) => escape_text(text),
        Some(Value::Bool(flag)) => flag.to_string(),
        Some(Value::Number(number)) => escape_text(&number.to_string()),
        Some(other) => serde_json::to_string(other)
            .map(|raw| escape_text(&raw))
            .unwrap_or_else(|_| "-".to_string()),
    }
}

pub(crate) fn field_text(value: &Value, key: &str) -> String {
    scalar_text(value.get(key))
}

pub(crate) fn field_bool(value: &Value, key: &str) -> Option<bool> {
    value.get(key).and_then(Value::as_bool)
}

pub(crate) fn optional_text(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::String(text)) if !text.is_empty() => Some(escape_text(text)),
        Some(Value::Null) | Some(Value::String(_)) | None => None,
        Some(other) => Some(scalar_text(Some(other))),
    }
}

fn format_decimal(value: Decimal) -> String {
    value
        .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
        .normalize()
        .to_string()
}

pub(crate) fn human_decimal(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(raw)) => raw
            .parse::<Decimal>()
            .map(format_decimal)
            .unwrap_or_else(|_| escape_text(raw)),
        Some(Value::Number(number)) => number
            .to_string()
            .parse::<Decimal>()
            .map(format_decimal)
            .unwrap_or_else(|_| escape_text(&number.to_string())),
        Some(Value::Null) | None => "-".to_string(),
        Some(other) => scalar_text(Some(other)),
    }
}

pub(crate) fn quantity_text(value: Option<&Value>) -> String {
    let Some(quantity) = value else {
        return "-".to_string();
    };
    if !quantity.is_object() {
        return scalar_text(Some(quantity));
    }

    let amount = human_decimal(quantity.get("amount"));
    let unit = field_text(quantity, "unit");
    if amount == "-" {
        return unit;
    }
    if unit == "-" {
        return amount;
    }
    format!("{amount} {unit}")
}

pub(crate) fn item_reference_text(value: Option<&Value>) -> Option<String> {
    let item = value.filter(|item| item.is_object())?;
    let item_type = item.get("type").and_then(Value::as_str)?;
    let id = item.get("id")?;
    if id.is_null() {
        return None;
    }
    let id = scalar_text(Some(id));
    let label = match item_type {
        "product" => "Product".to_string(),
        "meal" => "Meal".to_string(),
        "ad_hoc" => "Ad hoc".to_string(),
        other => escape_text(other),
    };

    Some(format!("{label} {id}"))
}

pub(crate) fn date_label(date: NaiveDate, today: NaiveDate) -> String {
    let prefix = if date == today {
        "Today"
    } else if date == today - Duration::days(1) {
        "Yesterday"
    } else {
        return date.to_string();
    };

    format!("{prefix} · {date}")
}

pub(crate) fn field_date_label(value: &Value, key: &str, today: NaiveDate) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|raw| NaiveDate::parse_from_str(raw, "%Y-%m-%d").ok())
        .map(|date| date_label(date, today))
        .unwrap_or_else(|| field_text(value, key))
}

fn table_line(cells: &[&str], widths: &[usize]) -> String {
    let mut line = String::new();
    for (index, cell) in cells.iter().enumerate() {
        line.push_str(cell);
        if index + 1 < cells.len() {
            let width = widths.get(index).copied().unwrap_or(0);
            line.push_str(&" ".repeat(width.saturating_sub(cell.chars().count()) + 2));
        }
    }
    line
}

pub(crate) fn render_table(headers: &[&str], rows: &[Vec<String>]) -> String {
    let mut widths = headers
        .iter()
        .map(|header| header.chars().count())
        .collect::<Vec<_>>();
    for row in rows {
        // A short row is an annotation row, such as a no-log day, and must
        // not widen the numeric columns.
        if row.len() != headers.len() {
            continue;
        }
        for (index, cell) in row.iter().enumerate() {
            if let Some(width) = widths.get_mut(index) {
                *width = (*width).max(cell.chars().count());
            }
        }
    }

    let mut lines = Vec::with_capacity(rows.len() + 1);
    lines.push(table_line(headers, &widths));
    for row in rows {
        let cells = row.iter().map(String::as_str).collect::<Vec<_>>();
        lines.push(table_line(&cells, &widths));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Serialize;
    use serde_json::json;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    #[test]
    fn output_mode_rules() {
        assert_eq!(
            OutputMode::resolve(false, false).unwrap(),
            OutputMode::Human
        );
        assert_eq!(
            OutputMode::resolve(true, false).unwrap(),
            OutputMode::JsonCompact
        );
        assert_eq!(
            OutputMode::resolve(true, true).unwrap(),
            OutputMode::JsonPretty
        );
        let error = OutputMode::resolve(false, true).unwrap_err();
        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.code, "invalid_arguments");
    }

    #[test]
    fn success_envelope_has_schema_data_and_meta() {
        let output = CommandOutput {
            data: json!({"items": [], "amount": "150"}),
            meta: OutputMeta {
                date: Some(date(2026, 11, 15)),
                ..OutputMeta::default()
            },
            human: "human output".to_owned(),
        };
        let compact = render_success(&output, OutputMode::JsonCompact).unwrap();
        assert!(!compact.contains('\n'));
        let value: Value = serde_json::from_str(&compact).unwrap();
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["data"]["amount"], "150");
        assert_eq!(value["meta"], json!({"date": "2026-11-15"}));
        assert!(value["meta"].get("from_date").is_none());

        let pretty = render_success(&output, OutputMode::JsonPretty).unwrap();
        assert!(pretty.contains("\n  \"schema_version\": 1"));
        assert_eq!(
            serde_json::from_str::<Value>(&pretty).unwrap()["data"],
            output.data
        );

        assert_eq!(
            render_success(&output, OutputMode::Human).unwrap(),
            "human output"
        );
    }

    #[test]
    fn error_envelope_always_has_status_uncertainty_and_recovery() {
        let request_error = CliError {
            origin: ErrorOrigin::Server,
            code: "conflict".to_owned(),
            message: "bad\nmessage".to_owned(),
            http_status: Some(409),
            uncertain: false,
            request: Some(Box::new(ErrorRequest {
                method: "POST",
                url: "https://calco.example/api/logs".to_owned(),
                body: Some(json!({"idempotency_key": "key", "note": "\u{202E}x"})),
            })),
            recovery: Some("retry the original request".to_owned()),
        };
        let rendered = render_error(&request_error, OutputMode::JsonCompact).unwrap();
        assert!(!rendered.contains('\n'));
        let value: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["error"]["origin"], "server");
        assert_eq!(value["error"]["code"], "conflict");
        assert_eq!(value["error"]["http_status"], 409);
        assert_eq!(value["error"]["uncertain"], false);
        assert_eq!(value["error"]["request"]["method"], "POST");
        assert_eq!(value["error"]["request"]["body"]["idempotency_key"], "key");
        assert_eq!(value["error"]["recovery"], "retry the original request");

        let human = format_error_human(&request_error);
        assert!(human.starts_with("error: bad\\u{000A}message"));
        assert!(human.contains("  origin: server"));
        assert!(human.contains("  code: conflict"));
        assert!(human.contains("  http_status: 409"));
        assert!(human.contains("  uncertain: false"));
        assert!(human.contains("  recovery: retry the original request"));
        assert!(human.contains("    method: POST"));
        assert!(human.contains("\\u{202E}"));
        assert!(!human.contains("Authorization"));

        let bare = CliError::new(ErrorOrigin::Arguments, "invalid_arguments", "bad");
        let value: Value =
            serde_json::from_str(&render_error(&bare, OutputMode::JsonCompact).unwrap()).unwrap();
        assert!(value["error"]["http_status"].is_null());
        assert!(value["error"]["recovery"].is_null());
        assert!(value["error"].get("request").is_none());
        assert_eq!(value["error"]["uncertain"], false);
        assert!(format_error_human(&bare).contains("  recovery: null"));
    }

    #[test]
    fn error_exit_codes_follow_status_mapping() {
        let cases = [
            (400, 2),
            (401, 3),
            (403, 3),
            (404, 4),
            (409, 5),
            (429, 6),
            (500, 6),
            (302, 6),
        ];
        for (status, expected) in cases {
            let mut error = CliError::new(ErrorOrigin::Server, "code", "message");
            error.http_status = Some(status);
            assert_eq!(error.exit_code(), expected, "status {status}");
        }
        for (origin, expected) in [
            (ErrorOrigin::Arguments, 2),
            (ErrorOrigin::Config, 1),
            (ErrorOrigin::Credentials, 3),
            (ErrorOrigin::Keyring, 1),
            (ErrorOrigin::Transport, 6),
            (ErrorOrigin::Response, 6),
            (ErrorOrigin::Internal, 1),
        ] {
            assert_eq!(
                CliError::new(origin, "code", "message").exit_code(),
                expected
            );
        }
    }

    #[test]
    fn escaping_removes_terminal_controls_but_preserves_unicode() {
        assert!(matches!(
            escape_human_text("Café — 日本語"),
            Cow::Borrowed(_)
        ));
        assert_eq!(escape_human_text("a\nb\tc"), "a\\u{000A}b\\u{0009}c");
        assert_eq!(escape_human_text("\u{001B}[31m"), "\\u{001B}[31m");
        assert_eq!(
            escape_human_text("\u{007F}\u{0085}\u{009F}"),
            "\\u{007F}\\u{0085}\\u{009F}"
        );
        assert_eq!(
            escape_human_text("\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}"),
            "\\u{200B}\\u{200C}\\u{200D}\\u{200E}\\u{200F}"
        );
        assert_eq!(
            escape_human_text("\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"),
            "\\u{202A}\\u{202B}\\u{202C}\\u{202D}\\u{202E}"
        );
        assert_eq!(
            escape_human_text("\u{2066}\u{2067}\u{2068}\u{2069}"),
            "\\u{2066}\\u{2067}\\u{2068}\\u{2069}"
        );
        assert_eq!(
            escape_human_text("\u{FEFF}\u{00AD}\u{061C}\u{180E}"),
            "\\u{FEFF}\\u{00AD}\\u{061C}\\u{180E}"
        );
        assert_eq!(escape_human_text("\u{2028}\u{2029}"), "\\u{2028}\\u{2029}");
    }
    #[test]
    fn human_decimals_round_to_two_places_without_inferring_zeroes() {
        assert_eq!(human_decimal(Some(&json!("12.345"))), "12.35");
        assert_eq!(human_decimal(Some(&json!("0"))), "0");
        assert_eq!(human_decimal(Some(&json!(null))), "-");
        assert_eq!(human_decimal(None), "-");
    }
    struct FailingSerialize;

    impl Serialize for FailingSerialize {
        fn serialize<S>(&self, _serializer: S) -> Result<S::Ok, S::Error>
        where
            S: serde::Serializer,
        {
            Err(serde::ser::Error::custom("forced serialization failure"))
        }
    }

    #[test]
    fn serialize_json_failure_uses_the_internal_error_code() {
        let error = serialize_json(&FailingSerialize).expect_err("expected serialization failure");
        assert!(matches!(error.origin, ErrorOrigin::Internal));
        assert_eq!(error.code, "internal_error");
        assert_eq!(error.exit_code(), 1);
        assert!(error.message.contains("failed to serialize command output"));
    }
}

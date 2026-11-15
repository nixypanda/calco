//! HTTP transport, backend wire DTOs, and write request recovery.
//!
//! Configuration, credentials, output envelopes, and date parsing live in
//! their own modules. This module keeps the documented `/api` client surface
//! and the exact resolved request snapshots used for uncertain writes.

use std::time::Duration;

use chrono::NaiveDate;
use clap::ValueEnum;
use reqwest::Method;
use reqwest::StatusCode;
use reqwest::header::{ACCEPT, CONTENT_TYPE};
use rust_decimal::Decimal;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;
use uuid::Uuid;

use crate::auth::SecretToken;
use crate::output::{CliError, ErrorOrigin, ErrorRequest};

pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

const USER_AGENT: &str = concat!("calco/", env!("CARGO_PKG_VERSION"));
const WRITE_RECOVERY_CREATE: &str = "Retry the identical request with the same idempotency key. A 200 response means the original write succeeded.";
const WRITE_RECOVERY_DELETE: &str = "The delete outcome is unknown. Run `calco logs show <id>`: 404 means the delete succeeded, while 200 means the log still exists.";
const WRITE_RECOVERY_CREATE_NOT_SENT: &str =
    "The request was not sent. Retry the identical request with the same idempotency key.";
const WRITE_RECOVERY_DELETE_NOT_SENT: &str =
    "The request was not sent. It is safe to retry the delete.";
const AUTH_RECOVERY: &str = "Check the API key and its scope, or run `calco auth login` again.";
const CONFLICT_RECOVERY: &str = "This key is bound to a different request. Retry the original body and key, or inspect the day's logs before choosing a new key.";

// ─── HTTP client ─────────────────────────────────────────────

pub fn build_http_client() -> Result<reqwest::Client, CliError> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        // Proxy configuration is unsupported so the bearer token can only be
        // sent to the selected base URL, never to an environment proxy.
        .no_proxy()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|_| {
            CliError::new(
                ErrorOrigin::Internal,
                "internal_error",
                "could not build the HTTP client",
            )
        })
}

// ─── Wire DTOs ───────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "snake_case")]
pub enum FoodScope {
    All,
    History,
    Custom,
}

impl FoodScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::History => "history",
            Self::Custom => "custom",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
pub enum MealSlot {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
    LateNightSnack,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductSearchResponse {
    pub items: Vec<ProductSearchItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductSearchItem {
    pub id: Uuid,
    pub source: String,
    pub source_id: Option<String>,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub nutrition_summary: ProductNutritionSummary,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductNutritionSummary {
    pub per_100g: NutrientSummary,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NutrientSummary {
    pub energy_kcal: Option<Decimal>,
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductDetail {
    pub id: Uuid,
    pub source: String,
    pub source_id: Option<String>,
    pub visibility: String,
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub default_quantity: Option<Decimal>,
    pub default_unit: Option<String>,
    pub nutrition_summary: ProductNutritionSummary,
    pub nutrients: Vec<ProductNutrient>,
    pub servings: Vec<ProductServing>,
    pub allowed_units: Vec<UnitItem>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductNutrient {
    pub code: String,
    pub amount_per_100g: Decimal,
    pub unit: String,
    pub source: Option<String>,
    pub confidence: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProductServing {
    pub unit: String,
    pub grams_per_unit: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitItem {
    pub code: String,
    pub name: String,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitListResponse {
    pub items: Vec<UnitItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MealListResponse {
    pub items: Vec<Meal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Meal {
    pub id: Uuid,
    pub name: String,
    pub notes: Option<String>,
    pub total_quantity: Option<Quantity>,
    pub nutrition_summary: Option<NutrientSummary>,
    pub components: Vec<MealComponent>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MealComponent {
    pub id: Uuid,
    pub item: MealComponentItem,
    pub quantity: Quantity,
    pub nutrition_summary: Option<NutrientSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MealComponentItem {
    #[serde(rename = "type")]
    pub item_type: String,
    pub id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Quantity {
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogListResponse {
    pub log_date: NaiveDate,
    pub items: Vec<FoodLog>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FoodLog {
    pub id: Uuid,
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlot>,
    pub device_timezone: Option<String>,
    pub item: FoodLogItem,
    pub quantity: Quantity,
    pub nutrients: Vec<NutrientAmount>,
    pub notes: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FoodLogItem {
    Product {
        id: Uuid,
        name: String,
        brand: Option<String>,
    },
    Meal {
        id: Uuid,
        name: String,
    },
    AdHoc {
        name: String,
        brand: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NutrientAmount {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LogItemRef {
    Product { id: Uuid },
    Meal { id: Uuid },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateLogRequest {
    pub log_date: NaiveDate,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meal_slot: Option<MealSlot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_timezone: Option<String>,
    pub item: LogItemRef,
    pub quantity: Quantity,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    pub idempotency_key: String,
}

#[derive(Debug, Clone)]
pub struct CreateLogOutcome {
    pub log: FoodLog,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SummaryResponse {
    pub days: Vec<SummaryDay>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SummaryDay {
    pub date: NaiveDate,
    pub energy_kcal: Decimal,
    pub protein_g: Decimal,
    pub carbs_g: Decimal,
    pub fat_g: Decimal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SummaryDayOutput {
    pub date: NaiveDate,
    pub has_logs: bool,
    pub energy_kcal: Decimal,
    pub protein_g: Decimal,
    pub carbs_g: Decimal,
    pub fat_g: Decimal,
}

// ─── API client ──────────────────────────────────────────────

pub struct ApiClient {
    base_url: Url,
    token: SecretToken,
    http: reqwest::Client,
}

impl ApiClient {
    pub fn with_http(base_url: Url, token: SecretToken, http: reqwest::Client) -> Self {
        Self {
            base_url,
            token,
            http,
        }
    }

    pub async fn units(&self) -> Result<UnitListResponse, CliError> {
        let url = self.api_url(&["units"], &[])?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    pub async fn search_foods(
        &self,
        query: &str,
        scope: FoodScope,
    ) -> Result<ProductSearchResponse, CliError> {
        let url = self.api_url(
            &["foods", "search"],
            &[("q", query), ("scope", scope.as_str())],
        )?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    pub async fn get_food(&self, id: Uuid) -> Result<ProductDetail, CliError> {
        let id = id.to_string();
        let url = self.api_url(&["foods", &id], &[])?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    pub async fn list_meals(&self) -> Result<MealListResponse, CliError> {
        let url = self.api_url(&["meals"], &[])?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    pub async fn get_meal(&self, id: Uuid) -> Result<Meal, CliError> {
        let id = id.to_string();
        let url = self.api_url(&["meals", &id], &[])?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    pub async fn list_logs(&self, date: NaiveDate) -> Result<LogListResponse, CliError> {
        let date_string = date.to_string();
        let url = self.api_url(&["logs"], &[("log_date", &date_string)])?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        let response: LogListResponse = self.decode(&body, &context, status)?;
        if response.log_date != date {
            return Err(self.redacted(invalid_response(
                &context,
                status,
                "server returned logs for a different date",
            )));
        }
        Ok(response)
    }

    pub async fn get_log(&self, id: Uuid) -> Result<FoodLog, CliError> {
        let id = id.to_string();
        let url = self.api_url(&["logs", &id], &[])?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    pub async fn create_log(
        &self,
        request: &CreateLogRequest,
    ) -> Result<CreateLogOutcome, CliError> {
        let url = self.api_url(&["logs"], &[])?;
        let body = serde_json::to_value(request).map_err(|_| {
            CliError::new(
                ErrorOrigin::Internal,
                "internal_error",
                "could not serialize the log request",
            )
        })?;
        let context = RequestContext::write("POST", &url, Some(body.clone()), WriteKind::CreateLog);
        let (status, response_body) = self
            .send(
                Method::POST,
                url,
                Some(&body),
                &context,
                Expected::CreateLog,
            )
            .await?;
        let log = self.decode(&response_body, &context, status)?;
        Ok(CreateLogOutcome {
            log,
            replayed: status == StatusCode::OK,
        })
    }

    pub async fn delete_log(&self, id: Uuid) -> Result<(), CliError> {
        let id = id.to_string();
        let url = self.api_url(&["logs", &id], &[])?;
        let context = RequestContext::write("DELETE", &url, None, WriteKind::DeleteLog);
        self.send(
            Method::DELETE,
            url,
            None,
            &context,
            Expected::Exactly(StatusCode::NO_CONTENT),
        )
        .await?;
        Ok(())
    }

    pub async fn summary(
        &self,
        from: NaiveDate,
        to: NaiveDate,
    ) -> Result<SummaryResponse, CliError> {
        let from_string = from.to_string();
        let to_string = to.to_string();
        let url = self.api_url(
            &["logs", "summary"],
            &[("from_date", &from_string), ("to_date", &to_string)],
        )?;
        let context = RequestContext::read("GET", &url);
        let (status, body) = self
            .send(
                Method::GET,
                url,
                None,
                &context,
                Expected::Exactly(StatusCode::OK),
            )
            .await?;
        self.decode(&body, &context, status)
    }

    fn api_url(&self, segments: &[&str], query: &[(&str, &str)]) -> Result<Url, CliError> {
        let mut url = self.base_url.clone();
        {
            let mut path = url.path_segments_mut().map_err(|_| {
                CliError::new(
                    ErrorOrigin::Internal,
                    "internal_error",
                    "base URL cannot be used as an HTTP base",
                )
            })?;
            path.pop_if_empty();
            path.push("api");
            for segment in segments {
                path.push(segment);
            }
        }
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (name, value) in query {
                pairs.append_pair(name, value);
            }
        }
        Ok(url)
    }

    async fn send(
        &self,
        method: Method,
        url: Url,
        body: Option<&Value>,
        context: &RequestContext,
        expected: Expected,
    ) -> Result<(StatusCode, Vec<u8>), CliError> {
        let mut request = self
            .http
            .request(method, url)
            .header(ACCEPT, "application/json");

        if let Some(body) = body {
            let bytes = serde_json::to_vec(body).map_err(|_| {
                CliError::new(
                    ErrorOrigin::Internal,
                    "internal_error",
                    "could not serialize the request body",
                )
            })?;
            request = request.header(CONTENT_TYPE, "application/json").body(bytes);
        }

        // The token is only turned into a header at request time.
        request = request.bearer_auth(self.token.expose());

        let response = request
            .send()
            .await
            .map_err(|error| self.redacted(transport_error(&error, context)))?;
        let status = response.status();

        if !expected.accepts(status) {
            if status.is_redirection() {
                return Err(self.redacted(invalid_response(
                    context,
                    status,
                    "server returned a redirect",
                )));
            }
            if status.is_success() {
                return Err(self.redacted(invalid_response(
                    context,
                    status,
                    "server returned an unexpected success status",
                )));
            }
            let body = response.bytes().await.unwrap_or_default();
            return Err(server_error(status, &body, context, self.token.expose()));
        }

        if status == StatusCode::NO_CONTENT {
            return Ok((status, Vec::new()));
        }

        match response.bytes().await {
            Ok(body) => Ok((status, body.to_vec())),
            Err(_) => Err(self.redacted(invalid_response(
                context,
                status,
                "server response could not be read",
            ))),
        }
    }

    fn decode<T: DeserializeOwned>(
        &self,
        body: &[u8],
        context: &RequestContext,
        status: StatusCode,
    ) -> Result<T, CliError> {
        serde_json::from_slice(body).map_err(|_| {
            self.redacted(invalid_response(
                context,
                status,
                "server returned a malformed response body",
            ))
        })
    }

    /// Apply the known-token redaction to every error that can carry resolved
    /// request context. The token is not part of the request snapshot, but a
    /// caller-supplied note or query can contain it, and a transport failure can
    /// preserve the full request.
    fn redacted(&self, mut error: CliError) -> CliError {
        redact_error_secret(&mut error, self.token.expose());
        error
    }
}

#[derive(Debug, Clone, Copy)]
enum Expected {
    Exactly(StatusCode),
    CreateLog,
}

impl Expected {
    fn accepts(self, status: StatusCode) -> bool {
        match self {
            Self::Exactly(expected) => status == expected,
            Self::CreateLog => status == StatusCode::CREATED || status == StatusCode::OK,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WriteKind {
    CreateLog,
    DeleteLog,
}

#[derive(Debug)]
struct RequestContext {
    method: &'static str,
    url: String,
    body: Option<Value>,
    write: Option<WriteKind>,
}

impl RequestContext {
    fn read(method: &'static str, url: &Url) -> Self {
        Self {
            method,
            url: url.as_str().to_owned(),
            body: None,
            write: None,
        }
    }

    fn write(method: &'static str, url: &Url, body: Option<Value>, write: WriteKind) -> Self {
        Self {
            method,
            url: url.as_str().to_owned(),
            body,
            write: Some(write),
        }
    }

    fn is_write(&self) -> bool {
        self.write.is_some()
    }

    fn error_request(&self) -> Box<ErrorRequest> {
        Box::new(ErrorRequest {
            method: self.method,
            url: self.url.clone(),
            body: self.body.clone(),
        })
    }

    fn recovery(&self) -> Option<&'static str> {
        match self.write {
            Some(WriteKind::CreateLog) => Some(WRITE_RECOVERY_CREATE),
            Some(WriteKind::DeleteLog) => Some(WRITE_RECOVERY_DELETE),
            None => None,
        }
    }

    fn not_sent_recovery(&self) -> Option<&'static str> {
        match self.write {
            Some(WriteKind::CreateLog) => Some(WRITE_RECOVERY_CREATE_NOT_SENT),
            Some(WriteKind::DeleteLog) => Some(WRITE_RECOVERY_DELETE_NOT_SENT),
            None => None,
        }
    }
}

fn transport_error(error: &reqwest::Error, context: &RequestContext) -> CliError {
    // A connect or request-builder failure proves that no HTTP request reached
    // the server, even when the underlying cause is a timeout.
    let request_not_sent = error.is_connect() || error.is_builder();
    let timed_out = error.is_timeout();
    let (code, message) = if timed_out {
        ("timeout", "request timed out")
    } else if request_not_sent {
        ("network_error", "could not connect to the server")
    } else {
        ("network_error", "network request failed")
    };
    let write = context.is_write();
    let recovery = if request_not_sent {
        context.not_sent_recovery()
    } else {
        context.recovery()
    };
    CliError {
        origin: ErrorOrigin::Transport,
        code: code.to_owned(),
        message: message.to_owned(),
        http_status: None,
        uncertain: write && !request_not_sent,
        request: write.then(|| context.error_request()),
        recovery: recovery.map(str::to_owned),
    }
}

fn invalid_response(
    context: &RequestContext,
    status: StatusCode,
    message: &'static str,
) -> CliError {
    let write = context.is_write();
    CliError {
        origin: ErrorOrigin::Response,
        code: "invalid_response".to_owned(),
        message: message.to_owned(),
        http_status: Some(status.as_u16()),
        uncertain: write,
        request: write.then(|| context.error_request()),
        recovery: write
            .then(|| context.recovery())
            .flatten()
            .map(str::to_owned),
    }
}

fn server_error(
    status: StatusCode,
    body: &[u8],
    context: &RequestContext,
    token: &str,
) -> CliError {
    let parsed = parse_backend_error(body);
    let code = parsed
        .as_ref()
        .map(|(code, _)| code.clone())
        .unwrap_or_else(|| "http_error".to_owned());
    let message = parsed
        .map(|(_, message)| message)
        .filter(|message| !message.is_empty())
        .unwrap_or_else(|| format!("request failed with HTTP status {}", status.as_u16()));

    let credential_error = match status {
        StatusCode::UNAUTHORIZED => true,
        StatusCode::FORBIDDEN => matches!(
            code.as_str(),
            "invalid_api_key" | "unauthorized" | "insufficient_scope"
        ),
        _ => false,
    };
    let origin = if credential_error {
        ErrorOrigin::Credentials
    } else {
        ErrorOrigin::Server
    };

    // A 5xx response can arrive after the server started handling a write.
    // A 408 is equally ambiguous: the server (or an intermediary) may have
    // processed the request before reporting the timeout. Keep the exact
    // request and uncertainty, unlike a clear 4xx rejection.
    let uncertain = context.is_write()
        && (status.is_server_error()
            || status.is_redirection()
            || status == StatusCode::REQUEST_TIMEOUT);
    let recovery = if credential_error {
        Some(AUTH_RECOVERY)
    } else if status == StatusCode::CONFLICT && context.write == Some(WriteKind::CreateLog) {
        Some(CONFLICT_RECOVERY)
    } else if uncertain {
        context.recovery()
    } else {
        None
    };

    let mut error = CliError {
        origin,
        code,
        message,
        http_status: Some(status.as_u16()),
        uncertain,
        request: uncertain.then(|| context.error_request()),
        recovery: recovery.map(str::to_owned),
    };
    redact_error_secret(&mut error, token);
    error
}

/// Never let a known API token survive in any error field, even if a server
/// reflects it into an error code or message.
fn redact_error_secret(error: &mut CliError, token: &str) {
    if token.is_empty() {
        return;
    }
    redact_string_secret(&mut error.code, token);
    redact_string_secret(&mut error.message, token);
    if let Some(recovery) = error.recovery.as_mut() {
        redact_string_secret(recovery, token);
    }
    if let Some(request) = error.request.as_mut() {
        redact_string_secret(&mut request.url, token);
        if let Some(body) = request.body.as_mut() {
            redact_json_secret(body, token);
        }
    }
}

fn redact_json_secret(value: &mut Value, token: &str) {
    match value {
        Value::String(text) => redact_string_secret(text, token),
        Value::Array(items) => {
            for item in items {
                redact_json_secret(item, token);
            }
        }
        Value::Object(fields) => {
            for value in fields.values_mut() {
                redact_json_secret(value, token);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn redact_string_secret(value: &mut String, token: &str) {
    if !value.contains(token) {
        return;
    }
    let mut redacted = value.replace(token, "[REDACTED]");
    // A very short token may also occur inside the replacement marker. Removing
    // it cannot introduce new occurrences, so a second pass finishes the job.
    if redacted.contains(token) {
        redacted = redacted.replace(token, "");
    }
    *value = redacted;
}

fn parse_backend_error(body: &[u8]) -> Option<(String, String)> {
    #[derive(Deserialize)]
    struct Envelope {
        error: Body,
    }
    #[derive(Deserialize)]
    struct Body {
        code: String,
        message: String,
    }

    let envelope: Envelope = serde_json::from_slice(body).ok()?;
    if envelope.error.code.is_empty() {
        return None;
    }
    Some((envelope.error.code, envelope.error.message))
}

#[cfg(test)]
mod tests {
    use std::io::{self, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::str::FromStr;
    use std::sync::{Arc, Mutex};
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, Instant};

    use super::*;
    use crate::auth::normalize_base_url;
    use crate::output::{OutputMode, format_error_human, render_error};

    fn parse_url(raw: &str) -> Url {
        normalize_base_url(raw).unwrap()
    }

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    // ─── DTO wire shapes ────────────────────────────────────

    const PRODUCT_ID: &str = "11111111-1111-1111-1111-111111111111";
    const MEAL_ID: &str = "22222222-2222-2222-2222-222222222222";
    const LOG_ID: &str = "33333333-3333-3333-3333-333333333333";
    const COMPONENT_ID: &str = "44444444-4444-4444-4444-444444444444";

    #[test]
    fn product_wire_decimals_stay_strings() {
        let raw = format!(
            r#"{{
                "items": [{{
                    "id": "{PRODUCT_ID}",
                    "source": "OFF",
                    "source_id": "12345",
                    "barcode": null,
                    "name": "Oats",
                    "brand": null,
                    "categories": [],
                    "nutrition_summary": {{
                        "per_100g": {{
                            "energy_kcal": "389",
                            "protein_g": "12.5",
                            "carbs_g": null,
                            "fat_g": null,
                            "fiber_g": null
                        }}
                    }},
                    "created_at": "2026-11-15T10:00:00Z",
                    "updated_at": "2026-11-15T10:00:00Z"
                }}]
            }}"#
        );
        let response: ProductSearchResponse = serde_json::from_str(&raw).unwrap();
        let item = &response.items[0];
        assert_eq!(item.id, Uuid::parse_str(PRODUCT_ID).unwrap());
        assert_eq!(item.source, "OFF");
        assert_eq!(item.barcode, None);
        assert_eq!(item.categories, Vec::<String>::new());
        assert_eq!(
            item.nutrition_summary.per_100g.energy_kcal,
            Some(Decimal::new(389, 0))
        );
        assert_eq!(
            item.nutrition_summary.per_100g.protein_g,
            Some(Decimal::new(125, 1))
        );
        assert_eq!(item.nutrition_summary.per_100g.carbs_g, None);

        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(
            value["items"][0]["nutrition_summary"]["per_100g"]["energy_kcal"],
            "389"
        );
        assert!(value["items"][0]["nutrition_summary"]["per_100g"]["carbs_g"].is_null());
        assert!(value["items"][0]["brand"].is_null());
    }

    #[test]
    fn product_detail_includes_optional_portion_and_allowed_units() {
        let raw = format!(
            r#"{{
                "id": "{PRODUCT_ID}",
                "source": "USER",
                "source_id": null,
                "visibility": "global",
                "barcode": null,
                "name": "Custom oats",
                "brand": "Home",
                "categories": ["breakfast"],
                "default_quantity": "30",
                "default_unit": "g",
                "nutrition_summary": {{
                    "per_100g": {{
                        "energy_kcal": "380",
                        "protein_g": null,
                        "carbs_g": null,
                        "fat_g": null,
                        "fiber_g": null
                    }}
                }},
                "nutrients": [{{
                    "code": "ENERGY_KCAL",
                    "amount_per_100g": "380",
                    "unit": "kcal",
                    "source": null,
                    "confidence": "approved"
                }}],
                "servings": [{{"unit": "cup", "grams_per_unit": "80"}}],
                "allowed_units": [{{"code": "g", "name": "gram", "kind": "mass"}}],
                "created_at": "2026-11-15T10:00:00Z",
                "updated_at": "2026-11-15T10:00:00Z"
            }}"#
        );
        let detail: ProductDetail = serde_json::from_str(&raw).unwrap();
        assert_eq!(detail.default_quantity, Some(Decimal::new(30, 0)));
        assert_eq!(detail.default_unit.as_deref(), Some("g"));
        assert_eq!(detail.visibility, "global");
        assert_eq!(detail.nutrients[0].confidence.as_deref(), Some("approved"));
        assert_eq!(detail.servings[0].grams_per_unit, Decimal::new(80, 0));
        assert_eq!(detail.allowed_units[0].code, "g");
    }

    #[test]
    fn meal_shape_uses_component_ids_without_names() {
        let raw = format!(
            r#"{{
                "items": [{{
                    "id": "{MEAL_ID}",
                    "name": "Breakfast bowl",
                    "notes": null,
                    "total_quantity": {{"amount": "250", "unit": "g"}},
                    "nutrition_summary": {{
                        "energy_kcal": "450",
                        "protein_g": "20",
                        "carbs_g": null,
                        "fat_g": null,
                        "fiber_g": null
                    }},
                    "components": [{{
                        "id": "{COMPONENT_ID}",
                        "item": {{"type": "product", "id": "{PRODUCT_ID}"}},
                        "quantity": {{"amount": "50", "unit": "g"}},
                        "nutrition_summary": null
                    }}],
                    "created_at": "2026-11-15T10:00:00Z",
                    "updated_at": "2026-11-15T10:00:00Z"
                }}]
            }}"#
        );
        let response: MealListResponse = serde_json::from_str(&raw).unwrap();
        let meal = &response.items[0];
        assert_eq!(meal.name, "Breakfast bowl");
        assert_eq!(
            meal.total_quantity.as_ref().unwrap().amount,
            Decimal::new(250, 0)
        );
        assert_eq!(
            meal.nutrition_summary.as_ref().unwrap().energy_kcal,
            Some(Decimal::new(450, 0))
        );
        assert_eq!(meal.components[0].item.item_type, "product");
        assert_eq!(
            meal.components[0].item.id,
            Uuid::parse_str(PRODUCT_ID).unwrap()
        );
        assert!(meal.components[0].nutrition_summary.is_none());

        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(
            value["items"][0]["components"][0]["item"]["type"],
            "product"
        );
        assert_eq!(value["items"][0]["total_quantity"]["amount"], "250");
    }

    #[test]
    fn food_log_wire_items_and_decimal_strings_round_trip() {
        let raw = format!(
            r#"{{
                "log_date": "2026-11-15",
                "items": [
                    {{
                        "id": "{LOG_ID}",
                        "log_date": "2026-11-15",
                        "meal_slot": "lunch",
                        "device_timezone": null,
                        "item": {{
                            "type": "product",
                            "id": "{PRODUCT_ID}",
                            "name": "Oats",
                            "brand": null
                        }},
                        "quantity": {{"amount": "150.5", "unit": "g"}},
                        "nutrients": [
                            {{"code": "ENERGY_KCAL", "amount": "389", "unit": "kcal"}}
                        ],
                        "notes": null,
                        "created_at": "2026-11-15T10:00:00Z",
                        "updated_at": "2026-11-15T10:00:00Z"
                    }},
                    {{
                        "id": "{LOG_ID}",
                        "log_date": "2026-11-15",
                        "meal_slot": "late_night_snack",
                        "device_timezone": "Asia/Kolkata",
                        "item": {{
                            "type": "meal",
                            "id": "{MEAL_ID}",
                            "name": "Breakfast bowl"
                        }},
                        "quantity": {{"amount": "1", "unit": "serving"}},
                        "nutrients": [],
                        "notes": "note",
                        "created_at": "2026-11-15T10:00:00Z",
                        "updated_at": "2026-11-15T10:00:00Z"
                    }},
                    {{
                        "id": "{LOG_ID}",
                        "log_date": "2026-11-15",
                        "meal_slot": null,
                        "device_timezone": null,
                        "item": {{
                            "type": "ad_hoc",
                            "name": "Tea",
                            "brand": null
                        }},
                        "quantity": {{"amount": "0", "unit": "g"}},
                        "nutrients": [],
                        "notes": null,
                        "created_at": "2026-11-15T10:00:00Z",
                        "updated_at": "2026-11-15T10:00:00Z"
                    }}
                ]
            }}"#
        );
        let response: LogListResponse = serde_json::from_str(&raw).unwrap();
        assert_eq!(response.log_date, date(2026, 11, 15));
        assert_eq!(response.items.len(), 3);
        assert!(matches!(
            response.items[0].item,
            FoodLogItem::Product { .. }
        ));
        assert_eq!(response.items[0].meal_slot, Some(MealSlot::Lunch));
        assert_eq!(response.items[0].quantity.amount, Decimal::new(1505, 1));
        assert!(matches!(response.items[1].item, FoodLogItem::Meal { .. }));
        assert_eq!(response.items[1].meal_slot, Some(MealSlot::LateNightSnack));
        assert!(matches!(response.items[2].item, FoodLogItem::AdHoc { .. }));
        assert!(response.items[2].meal_slot.is_none());

        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["items"][0]["quantity"]["amount"], "150.5");
        assert_eq!(value["items"][0]["item"]["type"], "product");
        assert_eq!(value["items"][1]["item"]["type"], "meal");
        assert_eq!(value["items"][2]["item"]["type"], "ad_hoc");
        assert!(value["items"][0]["item"]["brand"].is_null());
        assert!(value["items"][0]["device_timezone"].is_null());
        assert_eq!(value["items"][1]["device_timezone"], "Asia/Kolkata");
    }

    #[test]
    fn create_log_request_omits_absent_optionals() {
        let request = CreateLogRequest {
            log_date: date(2026, 11, 15),
            meal_slot: Some(MealSlot::Lunch),
            device_timezone: None,
            item: LogItemRef::Product {
                id: Uuid::parse_str(PRODUCT_ID).unwrap(),
            },
            quantity: Quantity {
                amount: Decimal::from_str("150").unwrap(),
                unit: "g".to_owned(),
            },
            notes: None,
            idempotency_key: "lunch-2026-11-15-1".to_owned(),
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["log_date"], "2026-11-15");
        assert_eq!(value["meal_slot"], "lunch");
        assert!(value.get("device_timezone").is_none());
        assert!(value.get("notes").is_none());
        assert_eq!(value["item"]["type"], "product");
        assert_eq!(value["item"]["id"], PRODUCT_ID);
        assert_eq!(value["quantity"]["amount"], "150");
        assert_eq!(value["quantity"]["unit"], "g");
        assert_eq!(value["idempotency_key"], "lunch-2026-11-15-1");
        assert!(value.get("idempotency-key").is_none());

        let meal = LogItemRef::Meal {
            id: Uuid::parse_str(MEAL_ID).unwrap(),
        };
        let value = serde_json::to_value(meal).unwrap();
        assert_eq!(value["type"], "meal");
        assert_eq!(value["id"], MEAL_ID);
    }

    #[test]
    fn summary_decimal_strings_and_zero_filled_output() {
        let raw = r#"{
                "days": [{
                    "date": "2026-11-15",
                    "energy_kcal": "1850",
                    "protein_g": "90",
                    "carbs_g": "210",
                    "fat_g": "60"
                }]
            }"#;
        let response: SummaryResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(response.days[0].energy_kcal, Decimal::new(1850, 0));
        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["days"][0]["energy_kcal"], "1850");

        let output = SummaryDayOutput {
            date: date(2026, 11, 15),
            has_logs: false,
            energy_kcal: Decimal::ZERO,
            protein_g: Decimal::ZERO,
            carbs_g: Decimal::ZERO,
            fat_g: Decimal::ZERO,
        };
        let value = serde_json::to_value(&output).unwrap();
        assert_eq!(value["has_logs"], false);
        assert_eq!(value["energy_kcal"], "0");
        assert_eq!(value["protein_g"], "0");
    }

    #[test]
    fn units_decode_wire_shape() {
        let response: UnitListResponse =
            serde_json::from_str(r#"{"items":[{"code":"g","name":"gram","kind":"mass"}]}"#)
                .unwrap();
        assert_eq!(response.items[0].code, "g");
        assert_eq!(response.items[0].name, "gram");
        assert_eq!(response.items[0].kind, "mass");
    }

    // ─── Token, output, errors, escaping ────────────────────
    // ─── HTTP behavior ──────────────────────────────────────

    #[derive(Debug, Clone)]
    struct MockRequest {
        method: String,
        target: String,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    }

    impl MockRequest {
        fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(header, _)| header.eq_ignore_ascii_case(name))
                .map(|(_, value)| value.as_str())
        }
    }

    #[derive(Debug, Clone)]
    struct MockResponse {
        status: u16,
        body: &'static str,
        headers: Vec<(&'static str, &'static str)>,
        delay: Duration,
    }

    impl MockResponse {
        fn new(status: u16, body: &'static str) -> Self {
            Self {
                status,
                body,
                headers: Vec::new(),
                delay: Duration::ZERO,
            }
        }

        fn with_header(mut self, name: &'static str, value: &'static str) -> Self {
            self.headers.push((name, value));
            self
        }

        fn with_delay(mut self, delay: Duration) -> Self {
            self.delay = delay;
            self
        }
    }

    fn spawn_mock(
        responses: Vec<MockResponse>,
        linger: Duration,
    ) -> (String, Arc<Mutex<Vec<MockRequest>>>, JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let base_url = format!("http://{address}");
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&requests);

        let handle = thread::spawn(move || {
            let started = Instant::now();
            let mut idle_deadline = started + Duration::from_secs(2);
            let hard_deadline = started + Duration::from_secs(5);
            let mut index = 0usize;

            loop {
                if index >= responses.len() && linger.is_zero() {
                    break;
                }
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let request = read_http_request(&mut stream).unwrap();
                        recorded.lock().unwrap().push(request);
                        let response = responses
                            .get(index)
                            .cloned()
                            .unwrap_or_else(|| MockResponse::new(500, "{}"));
                        if !response.delay.is_zero() {
                            thread::sleep(response.delay);
                        }
                        let _ = write_http_response(&mut stream, &response);
                        index += 1;
                        if index >= responses.len() {
                            if linger.is_zero() {
                                break;
                            }
                            idle_deadline = Instant::now() + linger;
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        let now = Instant::now();
                        if now >= idle_deadline || now >= hard_deadline {
                            break;
                        }
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
        });

        (base_url, requests, handle)
    }

    fn read_http_request(stream: &mut TcpStream) -> io::Result<MockRequest> {
        stream.set_nonblocking(false)?;
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 1024];
        let header_end = loop {
            if let Some(position) = find_bytes(&buffer, b"\r\n\r\n") {
                break position + 4;
            }
            let read = stream.read(&mut chunk)?;
            if read == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "request ended before headers",
                ));
            }
            buffer.extend_from_slice(&chunk[..read]);
        };

        let head = String::from_utf8_lossy(&buffer[..header_end]).to_string();
        let mut lines = head.split("\r\n");
        let request_line = lines.next().unwrap_or_default();
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or_default().to_owned();
        let target = parts.next().unwrap_or_default().to_owned();

        let mut headers = Vec::new();
        let mut content_length = 0usize;
        for line in lines {
            if line.is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                let name = name.trim().to_ascii_lowercase();
                let value = value.trim().to_owned();
                if name == "content-length" {
                    content_length = value.parse().unwrap_or(0);
                }
                headers.push((name, value));
            }
        }

        while buffer.len() < header_end + content_length {
            let read = stream.read(&mut chunk)?;
            if read == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..read]);
        }
        let body_start = header_end.min(buffer.len());
        let body_end = (header_end + content_length).min(buffer.len());
        let body = buffer[body_start..body_end].to_vec();

        Ok(MockRequest {
            method,
            target,
            headers,
            body,
        })
    }

    fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
    }

    fn write_http_response(stream: &mut TcpStream, response: &MockResponse) -> io::Result<()> {
        let reason = match response.status {
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            204 => "No Content",
            302 => "Found",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            409 => "Conflict",
            500 => "Internal Server Error",
            _ => "Response",
        };
        let mut head = format!(
            "HTTP/1.1 {} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n",
            response.status,
            response.body.len()
        );
        for (name, value) in &response.headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str("\r\n");
        stream.write_all(head.as_bytes())?;
        stream.write_all(response.body.as_bytes())?;
        stream.flush()
    }

    fn test_http(timeout: Duration) -> reqwest::Client {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(timeout)
            .build()
            .unwrap()
    }

    fn api_client(base_url: &str, token: &str, timeout: Duration) -> ApiClient {
        ApiClient::with_http(
            parse_url(base_url),
            SecretToken::new(token).unwrap(),
            test_http(timeout),
        )
    }

    fn write_log_request() -> CreateLogRequest {
        CreateLogRequest {
            log_date: date(2026, 11, 15),
            meal_slot: Some(MealSlot::Lunch),
            device_timezone: None,
            item: LogItemRef::Product {
                id: Uuid::parse_str(PRODUCT_ID).unwrap(),
            },
            quantity: Quantity {
                amount: Decimal::from_str("150").unwrap(),
                unit: "g".to_owned(),
            },
            notes: None,
            idempotency_key: "lunch-2026-11-15-1".to_owned(),
        }
    }

    fn food_log_json() -> String {
        format!(
            r#"{{
                "id": "{LOG_ID}",
                "log_date": "2026-11-15",
                "meal_slot": "lunch",
                "device_timezone": null,
                "item": {{
                    "type": "product",
                    "id": "{PRODUCT_ID}",
                    "name": "Oats",
                    "brand": null
                }},
                "quantity": {{"amount": "150", "unit": "g"}},
                "nutrients": [],
                "notes": null,
                "created_at": "2026-11-15T10:00:00Z",
                "updated_at": "2026-11-15T10:00:00Z"
            }}"#
        )
    }

    #[tokio::test]
    async fn units_request_sends_bearer_and_returns_wire_units() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                200,
                r#"{"items":[{"code":"g","name":"gram","kind":"mass"}]}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "test-token", Duration::from_secs(2));
        let response = client.units().await.unwrap();
        handle.join().unwrap();

        assert_eq!(response.items[0].code, "g");
        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].method, "GET");
        assert_eq!(requests[0].target, "/api/units");
        assert_eq!(
            requests[0].header("authorization"),
            Some("Bearer test-token")
        );
        assert_eq!(requests[0].header("accept"), Some("application/json"));
        assert!(requests[0].header("cookie").is_none());
    }

    #[tokio::test]
    async fn search_uses_path_prefix_and_encodes_query_scope() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(200, r#"{"items":[]}"#)],
            Duration::ZERO,
        );
        let client = api_client(
            &format!("{base_url}/prefix/"),
            "search-token",
            Duration::from_secs(2),
        );
        let response = client
            .search_foods("banana bread & co", FoodScope::History)
            .await
            .unwrap();
        handle.join().unwrap();

        assert!(response.items.is_empty());
        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].target,
            "/prefix/api/foods/search?q=banana+bread+%26+co&scope=history"
        );
    }

    #[tokio::test]
    async fn create_log_treats_201_as_new_and_200_as_replay() {
        let body = food_log_json();
        let body: &'static str = Box::leak(body.into_boxed_str());
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(201, body), MockResponse::new(200, body)],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "write-token", Duration::from_secs(2));
        let request = write_log_request();

        let created = client.create_log(&request).await.unwrap();
        assert!(!created.replayed);
        assert_eq!(created.log.id, Uuid::parse_str(LOG_ID).unwrap());

        let replayed = client.create_log(&request).await.unwrap();
        assert!(replayed.replayed);
        handle.join().unwrap();

        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        for request in requests.iter() {
            assert_eq!(request.method, "POST");
            assert_eq!(request.target, "/api/logs");
            assert_eq!(request.header("content-type"), Some("application/json"));
            let body: Value = serde_json::from_slice(&request.body).unwrap();
            assert_eq!(body["log_date"], "2026-11-15");
            assert_eq!(body["meal_slot"], "lunch");
            assert_eq!(body["idempotency_key"], "lunch-2026-11-15-1");
            assert_eq!(body["quantity"]["amount"], "150");
            assert!(body.get("device_timezone").is_none());
            assert!(body.get("notes").is_none());
            assert!(body.get("idempotency-key").is_none());
        }
    }

    #[tokio::test]
    async fn malformed_write_success_is_uncertain_and_carries_full_request() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(201, r#"{"id":"missing-fields"}"#)],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "uncertain-token", Duration::from_secs(2));
        let error = client.create_log(&write_log_request()).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "response");
        assert_eq!(error.code, "invalid_response");
        assert_eq!(error.http_status, Some(201));
        assert!(error.uncertain);
        let request = error.request.as_ref().unwrap();
        assert_eq!(request.method, "POST");
        assert!(request.url.ends_with("/api/logs"));
        let body = request.body.as_ref().unwrap();
        assert_eq!(body["idempotency_key"], "lunch-2026-11-15-1");
        assert_eq!(body["log_date"], "2026-11-15");
        assert!(error.recovery.is_some());
        assert!(!format!("{error:?}").contains("uncertain-token"));
        assert!(
            !render_error(&error, OutputMode::JsonCompact)
                .unwrap()
                .contains("uncertain-token")
        );
        assert!(!format_error_human(&error).contains("uncertain-token"));
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn malformed_write_success_redacts_the_known_token_from_notes() {
        let token = "contrived-notes-token";
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(201, r#"{"id":"missing-fields"}"#)],
            Duration::ZERO,
        );
        let client = api_client(&base_url, token, Duration::from_secs(2));
        let mut request = write_log_request();
        request.notes = Some(format!("pasted {token} into notes"));
        let error = client.create_log(&request).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert!(error.uncertain);
        let body = error.request.as_ref().unwrap().body.as_ref().unwrap();
        assert_eq!(body["notes"], "pasted [REDACTED] into notes");
        for rendered in [
            format!("{error:?}"),
            render_error(&error, OutputMode::JsonCompact).unwrap(),
            format_error_human(&error),
        ] {
            assert!(
                !rendered.contains(token),
                "token survived in error rendering: {rendered}"
            );
        }
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn write_408_is_uncertain_with_resolved_request_and_recovery() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                408,
                r#"{"error":{"code":"request_timeout","message":"request timed out"}}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "write-408-token", Duration::from_secs(2));
        let error = client.create_log(&write_log_request()).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "server");
        assert_eq!(error.code, "request_timeout");
        assert_eq!(error.http_status, Some(408));
        assert!(error.uncertain);
        assert_eq!(error.recovery.as_deref(), Some(WRITE_RECOVERY_CREATE));
        let request = error.request.as_ref().unwrap();
        assert_eq!(request.method, "POST");
        assert!(request.url.ends_with("/api/logs"));
        assert_eq!(
            request.body.as_ref().unwrap()["idempotency_key"],
            "lunch-2026-11-15-1"
        );
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn read_408_is_a_certain_server_error() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                408,
                r#"{"error":{"code":"request_timeout","message":"request timed out"}}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "read-408-token", Duration::from_secs(2));
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "server");
        assert_eq!(error.code, "request_timeout");
        assert_eq!(error.http_status, Some(408));
        assert!(!error.uncertain);
        assert!(error.request.is_none());
        assert!(error.recovery.is_none());
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn write_server_error_is_not_retried_or_marked_uncertain() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                409,
                r#"{"error":{"code":"conflict","message":"idempotency key was already used for another request"}}"#,
            )],
            Duration::from_millis(150),
        );
        let client = api_client(&base_url, "conflict-token", Duration::from_secs(2));
        let error = client.create_log(&write_log_request()).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 5);
        assert_eq!(error.origin.label(), "server");
        assert_eq!(error.code, "conflict");
        assert_eq!(error.http_status, Some(409));
        assert!(!error.uncertain);
        assert!(error.request.is_none());
        assert_eq!(error.recovery.as_deref(), Some(CONFLICT_RECOVERY));
        assert_eq!(
            requests.lock().unwrap().len(),
            1,
            "writes must not retry automatically"
        );
    }

    #[tokio::test]
    async fn delete_accepts_only_204_and_marks_bad_success_uncertain() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(204, ""), MockResponse::new(200, "{}")],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "delete-token", Duration::from_secs(2));
        let id = Uuid::parse_str(LOG_ID).unwrap();

        client.delete_log(id).await.unwrap();
        let error = client.delete_log(id).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.code, "invalid_response");
        assert_eq!(error.http_status, Some(200));
        assert!(error.uncertain);
        let request = error.request.as_ref().unwrap();
        assert_eq!(request.method, "DELETE");
        assert!(request.url.ends_with(&format!("/api/logs/{LOG_ID}")));
        assert!(request.body.is_none());
        assert_eq!(requests.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn production_client_does_not_follow_redirects_and_sends_user_agent() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(302, "").with_header("Location", "/api/elsewhere")],
            Duration::ZERO,
        );
        let client = ApiClient::with_http(
            parse_url(&base_url),
            SecretToken::new("redirect-token").unwrap(),
            build_http_client().unwrap(),
        );
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "response");
        assert_eq!(error.code, "invalid_response");
        assert_eq!(error.http_status, Some(302));
        assert!(!error.uncertain);
        assert!(error.request.is_none());

        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].target, "/api/units");
        assert_eq!(requests[0].header("user-agent"), Some(USER_AGENT));
    }

    #[tokio::test]
    async fn write_redirect_is_uncertain_with_exact_request_and_recovery() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(303, "").with_header("Location", "/api/elsewhere")],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "write-redirect-token", Duration::from_secs(2));
        let error = client.create_log(&write_log_request()).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "response");
        assert_eq!(error.code, "invalid_response");
        assert_eq!(error.http_status, Some(303));
        assert!(error.uncertain);
        assert_eq!(error.recovery.as_deref(), Some(WRITE_RECOVERY_CREATE));
        let request = error.request.as_ref().unwrap();
        assert_eq!(request.method, "POST");
        assert!(request.url.ends_with("/api/logs"));
        assert_eq!(
            request.body.as_ref().unwrap()["idempotency_key"],
            "lunch-2026-11-15-1"
        );
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn write_5xx_is_uncertain_with_exact_request_and_recovery() {
        let responses = [500, 502, 504]
            .into_iter()
            .map(|status| {
                MockResponse::new(
                    status,
                    r#"{"error":{"code":"internal_error","message":"server failed"}}"#,
                )
            })
            .collect();
        let (base_url, requests, handle) = spawn_mock(responses, Duration::ZERO);
        let client = api_client(&base_url, "five-hundred-token", Duration::from_secs(2));

        for status in [500, 502, 504] {
            let error = client.create_log(&write_log_request()).await.unwrap_err();
            assert_eq!(error.exit_code(), 6, "status {status}");
            assert_eq!(error.origin.label(), "server", "status {status}");
            assert_eq!(error.code, "internal_error", "status {status}");
            assert_eq!(error.http_status, Some(status), "status {status}");
            assert!(error.uncertain, "status {status}");
            assert_eq!(
                error.recovery.as_deref(),
                Some(WRITE_RECOVERY_CREATE),
                "status {status}"
            );
            let request = error.request.as_ref().unwrap();
            assert_eq!(request.method, "POST");
            assert!(request.url.ends_with("/api/logs"));
            assert_eq!(
                request.body.as_ref().unwrap()["idempotency_key"],
                "lunch-2026-11-15-1"
            );
            assert!(!format_error_human(&error).contains("five-hundred-token"));
        }
        handle.join().unwrap();
        assert_eq!(requests.lock().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn delete_5xx_is_uncertain_with_exact_request_and_recovery() {
        let responses = [500, 502, 504]
            .into_iter()
            .map(|status| MockResponse::new(status, ""))
            .collect();
        let (base_url, requests, handle) = spawn_mock(responses, Duration::ZERO);
        let client = api_client(&base_url, "delete-failure-token", Duration::from_secs(2));
        let id = Uuid::parse_str(LOG_ID).unwrap();

        for status in [500, 502, 504] {
            let error = client.delete_log(id).await.unwrap_err();
            assert_eq!(error.exit_code(), 6, "status {status}");
            assert_eq!(error.origin.label(), "server", "status {status}");
            assert_eq!(error.http_status, Some(status), "status {status}");
            assert!(error.uncertain, "status {status}");
            assert_eq!(
                error.recovery.as_deref(),
                Some(WRITE_RECOVERY_DELETE),
                "status {status}"
            );
            let request = error.request.as_ref().unwrap();
            assert_eq!(request.method, "DELETE");
            assert!(request.url.ends_with(&format!("/api/logs/{LOG_ID}")));
            assert!(request.body.is_none());
        }
        handle.join().unwrap();
        assert_eq!(requests.lock().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn unauthorized_backend_errors_map_to_exit_three_without_echo() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                401,
                r#"{"error":{"code":"invalid_api_key","message":"invalid_api_key"}}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "leaked-token", Duration::from_secs(2));
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 3);
        assert_eq!(error.origin.label(), "credentials");
        assert_eq!(error.code, "invalid_api_key");
        assert_eq!(error.http_status, Some(401));
        assert_eq!(error.recovery.as_deref(), Some(AUTH_RECOVERY));
        assert!(!format!("{error:?}").contains("leaked-token"));
        assert!(!format_error_human(&error).contains("leaked-token"));
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn generic_forbidden_is_server_origin_without_credential_guidance() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                403,
                r#"{"error":{"code":"forbidden","message":"forbidden"}}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "forbidden-token", Duration::from_secs(2));
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 3);
        assert_eq!(error.origin.label(), "server");
        assert_eq!(error.code, "forbidden");
        assert_eq!(error.http_status, Some(403));
        assert!(error.recovery.is_none());
        assert!(!error.uncertain);
        assert!(error.request.is_none());
        assert!(!format_error_human(&error).contains("auth login"));
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn insufficient_scope_is_a_credentials_error() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                403,
                r#"{"error":{"code":"insufficient_scope","message":"write scope required"}}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "scope-token", Duration::from_secs(2));
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 3);
        assert_eq!(error.origin.label(), "credentials");
        assert_eq!(error.code, "insufficient_scope");
        assert_eq!(error.recovery.as_deref(), Some(AUTH_RECOVERY));
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn server_error_reflections_redact_the_known_token_and_escape_controls() {
        let (base_url, requests, handle) = spawn_mock(
            vec![MockResponse::new(
                401,
                r#"{"error":{"code":"invalid_api_key-reflect-token","message":"invalid token reflect-token\u202e"}}"#,
            )],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "reflect-token", Duration::from_secs(2));
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 3);
        assert!(!error.code.contains("reflect-token"));
        assert!(!error.message.contains("reflect-token"));
        assert!(error.code.contains("[REDACTED]"));
        assert!(error.message.contains("[REDACTED]"));

        let json = render_error(&error, OutputMode::JsonCompact).unwrap();
        assert!(!json.contains("reflect-token"));
        let human = format_error_human(&error);
        assert!(!human.contains("reflect-token"));
        assert!(human.contains("\\u{202E}"));
        assert_eq!(requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn malformed_server_error_body_uses_local_http_error_code() {
        let (base_url, _requests, handle) = spawn_mock(
            vec![MockResponse::new(500, "<html>boom</html>")],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "server-token", Duration::from_secs(2));
        let error = client.units().await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "server");
        assert_eq!(error.code, "http_error");
        assert_eq!(error.http_status, Some(500));
        assert!(!error.message.contains("html"));
        assert!(!error.uncertain);
        assert!(error.request.is_none());
    }

    #[tokio::test]
    async fn write_timeout_is_uncertain_and_includes_request() {
        let (base_url, _requests, handle) = spawn_mock(
            vec![MockResponse::new(200, "{}").with_delay(Duration::from_millis(300))],
            Duration::ZERO,
        );
        let client = api_client(&base_url, "timeout-token", Duration::from_millis(80));
        let error = client.create_log(&write_log_request()).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "transport");
        assert_eq!(error.code, "timeout");
        assert!(error.uncertain);
        assert_eq!(error.request.as_ref().unwrap().method, "POST");
        assert!(error.recovery.is_some());
    }

    #[tokio::test]
    async fn write_connect_failure_is_certain_but_includes_request() {
        let port = {
            let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            listener.local_addr().unwrap().port()
        };
        let client = api_client(
            &format!("http://127.0.0.1:{port}"),
            "connect-token",
            Duration::from_millis(500),
        );
        let error = client.create_log(&write_log_request()).await.unwrap_err();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "transport");
        assert_eq!(error.code, "network_error");
        assert!(!error.uncertain);
        assert_eq!(
            error.recovery.as_deref(),
            Some(WRITE_RECOVERY_CREATE_NOT_SENT)
        );
        let request = error.request.as_ref().unwrap();
        assert_eq!(request.method, "POST");
        assert!(request.body.is_some());
    }

    #[tokio::test]
    async fn delete_connect_failure_reports_safe_retry_when_not_sent() {
        let port = {
            let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            listener.local_addr().unwrap().port()
        };
        let client = api_client(
            &format!("http://127.0.0.1:{port}"),
            "connect-token",
            Duration::from_millis(500),
        );
        let id = Uuid::parse_str(LOG_ID).unwrap();
        let error = client.delete_log(id).await.unwrap_err();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.origin.label(), "transport");
        assert_eq!(error.code, "network_error");
        assert!(!error.uncertain);
        assert_eq!(
            error.recovery.as_deref(),
            Some(WRITE_RECOVERY_DELETE_NOT_SENT)
        );
        assert!(!error.recovery.as_deref().unwrap().contains("unknown"));
        let request = error.request.as_ref().unwrap();
        assert_eq!(request.method, "DELETE");
        assert!(request.url.ends_with(&format!("/api/logs/{LOG_ID}")));
        assert!(request.body.is_none());
    }

    #[tokio::test]
    async fn list_logs_rejects_a_different_response_date() {
        let body = r#"{"log_date":"2026-11-14","items":[]}"#;
        let (base_url, requests, handle) =
            spawn_mock(vec![MockResponse::new(200, body)], Duration::ZERO);
        let client = api_client(&base_url, "date-token", Duration::from_secs(2));
        let error = client.list_logs(date(2026, 11, 15)).await.unwrap_err();
        handle.join().unwrap();

        assert_eq!(error.exit_code(), 6);
        assert_eq!(error.code, "invalid_response");
        assert_eq!(error.http_status, Some(200));
        assert!(!error.uncertain);
        assert_eq!(
            requests.lock().unwrap()[0].target,
            "/api/logs?log_date=2026-11-15"
        );
    }
}

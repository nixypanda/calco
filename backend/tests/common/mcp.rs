use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use chrono::{DateTime, NaiveDate, SecondsFormat, Utc};
use rust_decimal::Decimal;
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use super::{assert_status, post_json, send};

pub const MCP_URI: &str = "/api/mcp";
pub const MCP_HOST: &str = "localhost";
pub const MCP_PROTOCOL_VERSION: &str = "2025-06-18";
pub const MCP_ACCEPT: &str = "application/json, text/event-stream";
pub const MCP_SESSION_HEADER: &str = "mcp-session-id";
pub const MCP_PROTOCOL_HEADER: &str = "mcp-protocol-version";

pub struct McpRequest {
    method: Method,
    uri: String,
    authorization: Option<String>,
    cookie: Option<String>,
    host: String,
    content_type: Option<String>,
    accept: Option<String>,
    protocol_version: Option<String>,
    extra_headers: Vec<(String, String)>,
    body: Body,
}

impl McpRequest {
    fn new(method: Method) -> Self {
        Self {
            method,
            uri: MCP_URI.to_owned(),
            authorization: None,
            cookie: None,
            host: MCP_HOST.to_owned(),
            content_type: None,
            accept: Some(MCP_ACCEPT.to_owned()),
            protocol_version: Some(MCP_PROTOCOL_VERSION.to_owned()),
            extra_headers: Vec::new(),
            body: Body::empty(),
        }
    }

    pub fn post(body: impl Serialize) -> Self {
        Self::post_raw(serde_json::to_vec(&body).expect("serialize MCP request"))
    }

    pub fn post_raw(body: impl Into<Body>) -> Self {
        let mut request = Self::new(Method::POST);
        request.body = body.into();
        request.content_type = Some("application/json".to_owned());
        request
    }

    pub fn get() -> Self {
        Self::new(Method::GET)
    }

    pub fn delete() -> Self {
        Self::new(Method::DELETE)
    }

    pub fn head() -> Self {
        Self::new(Method::HEAD)
    }

    pub fn token(mut self, token: &str) -> Self {
        self.authorization = Some(format!("Bearer {token}"));
        self
    }

    pub fn authorization(mut self, raw: &str) -> Self {
        self.authorization = Some(raw.to_owned());
        self
    }

    pub fn cookie(mut self, cookie: &str) -> Self {
        self.cookie = Some(cookie.to_owned());
        self
    }

    pub fn host(mut self, host: &str) -> Self {
        self.host = host.to_owned();
        self
    }

    pub fn uri(mut self, uri: &str) -> Self {
        self.uri = uri.to_owned();
        self
    }

    pub fn accept(mut self, accept: Option<&str>) -> Self {
        self.accept = accept.map(str::to_owned);
        self
    }

    pub fn content_type(mut self, content_type: Option<&str>) -> Self {
        self.content_type = content_type.map(str::to_owned);
        self
    }

    pub fn protocol_version(mut self, version: Option<&str>) -> Self {
        self.protocol_version = version.map(str::to_owned);
        self
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.extra_headers.push((name.to_owned(), value.to_owned()));
        self
    }

    pub fn build(self) -> Request<Body> {
        let mut builder = Request::builder()
            .method(self.method)
            .uri(self.uri)
            .header(header::HOST, self.host);

        if let Some(authorization) = self.authorization {
            builder = builder.header(header::AUTHORIZATION, authorization);
        }
        if let Some(cookie) = self.cookie {
            builder = builder.header(header::COOKIE, cookie);
        }
        if let Some(content_type) = self.content_type {
            builder = builder.header(header::CONTENT_TYPE, content_type);
        }
        if let Some(accept) = self.accept {
            builder = builder.header(header::ACCEPT, accept);
        }
        if let Some(protocol_version) = self.protocol_version {
            builder = builder.header(MCP_PROTOCOL_HEADER, protocol_version);
        }
        for (name, value) in self.extra_headers {
            builder = builder.header(name, value);
        }

        builder.body(self.body).expect("build MCP request")
    }
}

pub fn preflight(origin: &str, host: &str, requested_headers: &str) -> Request<Body> {
    Request::builder()
        .method(Method::OPTIONS)
        .uri(MCP_URI)
        .header(header::HOST, host)
        .header(header::ORIGIN, origin)
        .header(header::ACCESS_CONTROL_REQUEST_METHOD, "POST")
        .header(header::ACCESS_CONTROL_REQUEST_HEADERS, requested_headers)
        .body(Body::empty())
        .expect("build CORS preflight")
}

pub async fn send_mcp(router: &Router, request: McpRequest) -> (StatusCode, HeaderMap, Bytes) {
    send(router, request.build()).await
}

pub fn assert_json_response(
    status: StatusCode,
    headers: &HeaderMap,
    bytes: &Bytes,
    expected_status: StatusCode,
) -> Value {
    assert_status(status, expected_status, bytes);
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    assert!(
        content_type.starts_with("application/json"),
        "expected JSON response, got content-type {content_type:?}, body: {}",
        String::from_utf8_lossy(bytes)
    );
    serde_json::from_slice(bytes).unwrap_or_else(|error| {
        panic!(
            "failed to parse MCP JSON response: {error}\nbody: {}",
            String::from_utf8_lossy(bytes)
        )
    })
}

pub fn assert_no_session_headers(headers: &HeaderMap) {
    assert!(
        headers.get(MCP_SESSION_HEADER).is_none(),
        "stateless MCP response must not issue {MCP_SESSION_HEADER}"
    );
    assert!(
        headers.get(header::SET_COOKIE).is_none(),
        "MCP is bearer-only and must not set a session cookie"
    );
}

pub fn initialize_body(id: i64, version: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "protocolVersion": version,
            "capabilities": {},
            "clientInfo": {"name": "calco-mcp-tests", "version": "0.1.0"}
        }
    })
}

pub fn tools_list_body(id: i64) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "method": "tools/list", "params": {}})
}

pub fn tool_call_body(id: i64, name: &str, arguments: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments}
    })
}

pub fn notification_body(method: &str) -> Value {
    json!({"jsonrpc": "2.0", "method": method})
}

pub fn structured_result(body: &Value) -> Value {
    assert_eq!(body["jsonrpc"], "2.0", "not a JSON-RPC response: {body}");
    assert_eq!(
        body["result"]["isError"], false,
        "expected successful tool result, got: {body}"
    );
    let structured = body["result"]["structuredContent"]
        .as_object()
        .unwrap_or_else(|| panic!("missing structuredContent: {body}"));
    let text = body["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("missing text content: {body}"));
    let text_value: Value =
        serde_json::from_str(text).unwrap_or_else(|error| panic!("invalid text JSON: {error}"));
    assert_eq!(
        text_value,
        Value::Object(structured.clone()),
        "text content must mirror structuredContent"
    );
    Value::Object(structured.clone())
}

pub fn assert_rpc_error(body: &Value, expected_code: i64) {
    assert_eq!(body["jsonrpc"], "2.0", "not a JSON-RPC error: {body}");
    assert_eq!(
        body["error"]["code"], expected_code,
        "unexpected JSON-RPC error: {body}"
    );
    assert!(
        body["error"]["message"]
            .as_str()
            .is_some_and(|m| !m.is_empty()),
        "JSON-RPC error must have a message: {body}"
    );
}

pub fn assert_tool_error(body: &Value, expected_fragment: &str) -> String {
    assert_eq!(
        body["result"]["isError"], true,
        "expected tool error: {body}"
    );
    assert!(
        body.get("error").is_none(),
        "tool errors must not use the REST or JSON-RPC error envelope: {body}"
    );
    assert!(
        body["result"].get("structuredContent").is_none(),
        "tool errors must not carry structuredContent: {body}"
    );
    let text = body["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("missing tool error text: {body}"));
    assert!(
        text.contains(expected_fragment),
        "tool error {text:?} does not contain {expected_fragment:?}"
    );
    text.to_owned()
}

/// Sends one `tools/call` request and returns the JSON-RPC response body.
pub async fn send_tool_call(
    router: &Router,
    token: &str,
    id: i64,
    name: &str,
    arguments: Value,
) -> Value {
    let (status, headers, bytes) = send_mcp(
        router,
        McpRequest::post(tool_call_body(id, name, arguments)).token(token),
    )
    .await;
    assert_json_response(status, &headers, &bytes, StatusCode::OK)
}

/// Calls a tool and returns its structured success payload.
pub async fn tool_call_ok(
    router: &Router,
    token: &str,
    id: i64,
    name: &str,
    arguments: Value,
) -> Value {
    let body = send_tool_call(router, token, id, name, arguments).await;
    structured_result(&body)
}

/// Calls a tool, asserts the MCP tool-error contract, and returns its text.
pub async fn tool_call_err(
    router: &Router,
    token: &str,
    id: i64,
    name: &str,
    arguments: Value,
    expected_fragment: &str,
) -> String {
    let body = send_tool_call(router, token, id, name, arguments).await;
    assert_tool_error(&body, expected_fragment)
}

/// Sends `tools/list` and returns the raw response body.
///
/// `protocol_version` overrides the `MCP-Protocol-Version` header when set.
pub async fn list_tools_response(
    router: &Router,
    token: &str,
    id: i64,
    protocol_version: Option<&str>,
) -> Value {
    let mut request = McpRequest::post(tools_list_body(id)).token(token);
    if let Some(version) = protocol_version {
        request = request.protocol_version(Some(version));
    }
    let (status, headers, bytes) = send_mcp(router, request).await;
    assert_json_response(status, &headers, &bytes, StatusCode::OK)
}

pub async fn list_tools(router: &Router, token: &str, id: i64) -> Vec<Value> {
    let body = list_tools_response(router, token, id, None).await;
    body["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("missing tools array: {body}"))
        .clone()
}

pub fn sorted_tool_names(tools: &[Value]) -> Vec<String> {
    let mut names: Vec<String> = tools
        .iter()
        .map(|tool| {
            tool["name"]
                .as_str()
                .unwrap_or_else(|| panic!("missing tool name: {tool}"))
                .to_owned()
        })
        .collect();
    names.sort();
    names
}

pub fn tool_named<'a>(tools: &'a [Value], name: &str) -> &'a Value {
    tools
        .iter()
        .find(|tool| tool["name"] == name)
        .unwrap_or_else(|| panic!("missing {name} in tools/list: {tools:?}"))
}

pub fn required_names(tool: &Value) -> Vec<String> {
    let mut names: Vec<String> = tool["inputSchema"]["required"]
        .as_array()
        .unwrap_or_else(|| panic!("missing required schema: {tool}"))
        .iter()
        .map(|value| value.as_str().expect("required string").to_owned())
        .collect();
    names.sort();
    names
}

/// Sorted property names declared directly on a tool's root input schema.
pub fn tool_property_names(tool: &Value) -> Vec<String> {
    let mut names: Vec<String> = tool["inputSchema"]["properties"]
        .as_object()
        .unwrap_or_else(|| panic!("missing inputSchema properties: {tool}"))
        .keys()
        .cloned()
        .collect();
    names.sort();
    names
}

/// Collects every `properties` key anywhere in a JSON schema.
fn schema_property_names(schema: &Value, names: &mut Vec<String>) {
    match schema {
        Value::Object(object) => {
            if let Some(properties) = object.get("properties").and_then(Value::as_object) {
                names.extend(properties.keys().cloned());
            }
            for value in object.values() {
                schema_property_names(value, names);
            }
        }
        Value::Array(values) => {
            for value in values {
                schema_property_names(value, names);
            }
        }
        _ => {}
    }
}

pub fn assert_no_ownership_properties(tools: &[Value]) {
    const FORBIDDEN: [&str; 4] = ["user_id", "profile_id", "owner_id", "identity_id"];
    for tool in tools {
        let mut names = Vec::new();
        schema_property_names(&tool["inputSchema"], &mut names);
        for forbidden in FORBIDDEN {
            assert!(
                !names.iter().any(|name| name == forbidden),
                "tool {} exposed ownership argument {forbidden}: {tool}",
                tool["name"]
            );
        }
    }
}

pub fn assert_safe_tool_error_text(text: &str) {
    let lower = text.to_ascii_lowercase();
    for forbidden in [
        "postgres",
        "sqlx",
        "database",
        "food_log_nutrients",
        "food_logs",
        "syntax error",
        "stack backtrace",
        "calco_pat_",
    ] {
        assert!(
            !lower.contains(forbidden),
            "tool error leaked internals ({forbidden}): {text:?}"
        );
    }
}

pub fn nutrient_amount(nutrients: &Value, code: &str) -> String {
    nutrients
        .as_array()
        .unwrap_or_else(|| panic!("nutrients must be an array: {nutrients}"))
        .iter()
        .find(|nutrient| nutrient["code"] == code)
        .unwrap_or_else(|| panic!("{code} snapshot missing: {nutrients}"))["amount"]
        .as_str()
        .unwrap_or_else(|| panic!("{code} amount is not a string: {nutrients}"))
        .to_owned()
}

pub fn amount_value(amount: &Value) -> Decimal {
    amount
        .as_str()
        .unwrap_or_else(|| panic!("decimal amount is not a string: {amount}"))
        .parse()
        .unwrap_or_else(|error| panic!("invalid decimal amount {amount}: {error}"))
}

pub fn nutrient_amount_value(nutrients: &Value, code: &str) -> Decimal {
    let amount = nutrients
        .as_array()
        .unwrap_or_else(|| panic!("nutrients must be an array: {nutrients}"))
        .iter()
        .find(|nutrient| nutrient["code"] == code)
        .unwrap_or_else(|| panic!("{code} snapshot missing: {nutrients}"))["amount"]
        .clone();
    amount_value(&amount)
}

/// Canonicalizes decimal `amount` strings so a value produced in memory (which
/// may keep scale, for example `"7.50"`) compares with the same value read from
/// PostgreSQL (for example `"7.5"`).
pub fn normalize_decimal_amounts(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for (key, inner) in object.iter_mut() {
                if key == "amount"
                    && let Some(text) = inner.as_str()
                    && let Ok(decimal) = text.parse::<Decimal>()
                {
                    *inner = Value::String(decimal.normalize().to_string());
                    continue;
                }
                normalize_decimal_amounts(inner);
            }
        }
        Value::Array(values) => {
            for inner in values {
                normalize_decimal_amounts(inner);
            }
        }
        _ => {}
    }
}

fn round_timestamp_to_micros(text: &str) -> Option<String> {
    let parsed = DateTime::parse_from_rfc3339(text).ok()?;
    let mut seconds = parsed.timestamp();
    let nanos = parsed.timestamp_subsec_nanos();
    let mut micros = (i64::from(nanos) + 500) / 1_000;
    if micros >= 1_000_000 {
        seconds += 1;
        micros -= 1_000_000;
    }
    let normalized = DateTime::<Utc>::from_timestamp(seconds, (micros as u32) * 1_000)?;
    Some(normalized.to_rfc3339_opts(SecondsFormat::Micros, true))
}

/// Rounds `created_at`/`updated_at` timestamps to microseconds so responses
/// built in memory compare with values read back from PostgreSQL, which stores
/// timestamps at microsecond precision.
pub fn normalize_timestamps(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for (key, inner) in object.iter_mut() {
                if (key == "created_at" || key == "updated_at")
                    && let Some(text) = inner.as_str()
                {
                    if let Some(normalized) = round_timestamp_to_micros(text) {
                        *inner = Value::String(normalized);
                    }
                    continue;
                }
                normalize_timestamps(inner);
            }
        }
        Value::Array(values) => {
            for inner in values {
                normalize_timestamps(inner);
            }
        }
        _ => {}
    }
}

pub fn assert_www_authenticate(headers: &HeaderMap) {
    assert_eq!(
        headers
            .get(header::WWW_AUTHENTICATE)
            .unwrap_or_else(|| panic!("missing WWW-Authenticate: {headers:?}")),
        "Bearer"
    );
}

pub fn assert_auth_error(status: StatusCode, headers: &HeaderMap, body: &Value) {
    assert_eq!(status, StatusCode::UNAUTHORIZED, "body: {body}");
    assert_eq!(body["error"]["code"], "invalid_api_key", "body: {body}");
    assert_www_authenticate(headers);
}

pub struct TestApiKey {
    pub id: String,
    pub token: String,
}

pub async fn create_mcp_api_key(
    router: &Router,
    cookie: &str,
    name: &str,
    scope: Option<&str>,
) -> TestApiKey {
    let mut request = json!({"name": name});
    if let Some(scope) = scope {
        request["scope"] = json!(scope);
    }
    let created: Value = post_json(
        router,
        "/api/auth/api-keys",
        cookie,
        &request,
        StatusCode::CREATED,
    )
    .await;

    TestApiKey {
        id: created["id"].as_str().expect("API key id").to_owned(),
        token: created["token"].as_str().expect("API key token").to_owned(),
    }
}

pub async fn revoke_api_key(router: &Router, cookie: &str, key_id: &str) {
    let request = super::empty_request(
        Method::DELETE,
        &format!("/api/auth/api-keys/{key_id}"),
        Some(cookie),
    );
    let (status, _headers, bytes) = send(router, request).await;
    assert_status(status, StatusCode::NO_CONTENT, &bytes);
}

pub async fn last_used_at(pool: &PgPool, key_id: &str) -> Option<DateTime<Utc>> {
    sqlx::query_scalar("SELECT last_used_at FROM api_keys WHERE id = $1")
        .bind(uuid::Uuid::parse_str(key_id).expect("valid API key id"))
        .fetch_one(pool)
        .await
        .expect("read API key last_used_at")
}

pub async fn seed_product(router: &Router, cookie: &str, name: &str, energy_kcal: i64) -> String {
    let product: Value = post_json(
        router,
        "/api/foods/custom",
        cookie,
        &json!({
            "name": name,
            "brand": "MCP Brand",
            "categories": ["mcp-tests"],
            "default_quantity": 100,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": energy_kcal },
                { "code": "PROTEIN_G", "amount_per_100g": 10 },
                { "code": "CARBS_G", "amount_per_100g": 20 },
                { "code": "FAT_G", "amount_per_100g": 5 }
            ],
            "servings": [{ "unit": "serving", "grams_per_unit": 50 }]
        }),
        StatusCode::CREATED,
    )
    .await;
    product["id"].as_str().expect("product id").to_owned()
}

pub async fn seed_log(
    router: &Router,
    cookie: &str,
    product_id: &str,
    log_date: &str,
    amount: i64,
) -> String {
    let created: Value = post_json(
        router,
        "/api/logs",
        cookie,
        &json!({
            "log_date": log_date,
            "meal_slot": "breakfast",
            "item": {"type": "product", "id": product_id},
            "quantity": {"amount": amount, "unit": "g"}
        }),
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().expect("created log id").to_owned()
}

/// Creates a meal whose total and single component quantity are `amount` grams
/// of `product_id`, so the meal has exactly the product's nutrition at `amount`.
pub async fn seed_meal(
    router: &Router,
    cookie: &str,
    name: &str,
    product_id: &str,
    amount: i64,
) -> String {
    let created: Value = post_json(
        router,
        "/api/meals",
        cookie,
        &json!({
            "name": name,
            "total_quantity": {"amount": amount, "unit": "g"},
            "components": [{
                "item": {"type": "product", "id": product_id},
                "quantity": {"amount": amount, "unit": "g"}
            }]
        }),
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().expect("meal id").to_owned()
}

fn parse_uuid(value: &str) -> Uuid {
    Uuid::parse_str(value).expect("valid UUID")
}

fn parse_date(value: &str) -> NaiveDate {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").expect("valid YYYY-MM-DD date")
}

pub async fn count_logs_for_user(pool: &PgPool, profile_id: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM food_logs WHERE user_id = $1")
        .bind(parse_uuid(profile_id))
        .fetch_one(pool)
        .await
        .expect("count food logs for user")
}

pub async fn count_logs_for_user_date(pool: &PgPool, profile_id: &str, log_date: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM food_logs WHERE user_id = $1 AND log_date = $2")
        .bind(parse_uuid(profile_id))
        .bind(parse_date(log_date))
        .fetch_one(pool)
        .await
        .expect("count food logs for user and date")
}

pub async fn log_owner(pool: &PgPool, log_id: &str) -> String {
    sqlx::query_scalar("SELECT user_id::text FROM food_logs WHERE id = $1")
        .bind(parse_uuid(log_id))
        .fetch_one(pool)
        .await
        .expect("read food log owner")
}

pub async fn count_log_nutrients(pool: &PgPool, log_id: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM food_log_nutrients WHERE food_log_id = $1")
        .bind(parse_uuid(log_id))
        .fetch_one(pool)
        .await
        .expect("count food log nutrients")
}

pub async fn log_nutrient_amount(pool: &PgPool, log_id: &str, code: &str) -> Decimal {
    sqlx::query_scalar(
        r#"
        SELECT fln.amount
        FROM food_log_nutrients fln
        JOIN nutrients n ON n.id = fln.nutrient_id
        WHERE fln.food_log_id = $1 AND n.code = $2
        "#,
    )
    .bind(parse_uuid(log_id))
    .bind(code)
    .fetch_one(pool)
    .await
    .expect("read food log nutrient amount")
}

pub async fn log_item_ids(pool: &PgPool, log_id: &str) -> (Option<Uuid>, Option<Uuid>) {
    sqlx::query_as("SELECT item_product_id, item_meal_id FROM food_logs WHERE id = $1")
        .bind(parse_uuid(log_id))
        .fetch_one(pool)
        .await
        .expect("read food log item ids")
}

pub async fn profile_id(router: &Router, cookie: &str) -> String {
    let session: Value = super::get_json(router, "/api/auth/session", cookie).await;
    session["profile"]["id"]
        .as_str()
        .expect("profile id")
        .to_owned()
}

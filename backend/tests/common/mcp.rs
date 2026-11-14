use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;

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
    let text = body["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_else(|| panic!("missing tool error text: {body}"));
    assert!(
        text.contains(expected_fragment),
        "tool error {text:?} does not contain {expected_fragment:?}"
    );
    text.to_owned()
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
) {
    let _: Value = post_json(
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
}

pub async fn profile_id(router: &Router, cookie: &str) -> String {
    let session: Value = super::get_json(router, "/api/auth/session", cookie).await;
    session["profile"]["id"]
        .as_str()
        .expect("profile id")
        .to_owned()
}

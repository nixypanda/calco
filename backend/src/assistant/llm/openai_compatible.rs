//! Provider-tolerant, text-only OpenAI-compatible Chat Completions client.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderName, HeaderValue};
use reqwest::{Client, StatusCode, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_PROVIDER_RESPONSE_BYTES: usize = 1024 * 1024;
const JSON_ONLY_INSTRUCTION: &str =
    "Return only one JSON object that conforms exactly to the supplied JSON Schema.";
const GROQ_HOST: &str = "api.groq.com";

#[derive(Clone)]
pub(crate) enum Authentication {
    None,
    BearerFile(PathBuf),
    HeaderFile { name: HeaderName, path: PathBuf },
}

pub(crate) struct OpenAiCompatibleConfig {
    pub endpoint: Url,
    pub model: String,
    pub authentication: Authentication,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ChatRole {
    System,
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResponseFormat {
    JsonSchema { name: String, schema: Value },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChatRequest {
    pub messages: Vec<ChatMessage>,
    pub response_format: ResponseFormat,
    pub max_output_tokens: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TokenUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChatResponse {
    pub content: String,
    pub usage: Option<TokenUsage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ChatError {
    Unavailable,
    InvalidResponse,
    Internal,
}

#[async_trait]
pub(crate) trait ChatClient: Send + Sync {
    async fn complete(&self, request: ChatRequest) -> Result<ChatResponse, ChatError>;
}

pub(crate) struct OpenAiCompatibleClient {
    client: Client,
    endpoint: Url,
    model: String,
    authentication: ProviderAuthentication,
    groq_compatibility: bool,
    response_mode: Mutex<ResponseMode>,
}

impl std::fmt::Debug for OpenAiCompatibleClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OpenAiCompatibleClient")
            .field("endpoint", &"[REDACTED]")
            .field("model", &"[REDACTED]")
            .field("authentication", &self.authentication)
            .finish_non_exhaustive()
    }
}

#[derive(Clone)]
enum ProviderAuthentication {
    None,
    Header {
        name: HeaderName,
        value: HeaderValue,
    },
}

impl std::fmt::Debug for ProviderAuthentication {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::None => formatter.write_str("ProviderAuthentication::None"),
            Self::Header { name, .. } => formatter
                .debug_struct("ProviderAuthentication::Header")
                .field("name", name)
                .field("value", &"[REDACTED]")
                .finish(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResponseMode {
    JsonSchema,
    JsonObject,
    PromptConstrained,
}

impl OpenAiCompatibleClient {
    /// Constructs a client and reads a configured credential file exactly once.
    pub(crate) fn new(config: OpenAiCompatibleConfig) -> Result<Self, ChatError> {
        Self::with_timeouts(config, DEFAULT_CONNECT_TIMEOUT, DEFAULT_REQUEST_TIMEOUT)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    fn with_timeouts(
        config: OpenAiCompatibleConfig,
        connect_timeout: Duration,
        request_timeout: Duration,
    ) -> Result<Self, ChatError> {
        let authentication = ProviderAuthentication::from_config(config.authentication)?;
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(connect_timeout)
            .timeout(request_timeout)
            .build()
            .map_err(|_| ChatError::Internal)?;
        Ok(Self {
            client,
            groq_compatibility: config.endpoint.host_str() == Some(GROQ_HOST),
            endpoint: config.endpoint,
            model: config.model,
            authentication,
            response_mode: Mutex::new(ResponseMode::JsonSchema),
        })
    }

    async fn complete_in_mode(
        &self,
        request: &ChatRequest,
        mode: ResponseMode,
    ) -> Result<ChatResponse, CompletionFailure> {
        let request_body =
            RequestBody::from_request(&self.model, request, mode, !self.groq_compatibility)?;
        let body = if self.groq_compatibility {
            serde_json::to_value(GroqRequest {
                request: &request_body,
                reasoning_format: "hidden",
                max_tokens: request.max_output_tokens,
            })
        } else {
            serde_json::to_value(&request_body)
        }
        .map_err(|_| CompletionFailure::InvalidResponse)?;
        let mut headers = HeaderMap::new();
        headers.insert(
            reqwest::header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        self.authentication.apply(&mut headers);
        let response = self
            .client
            .post(self.endpoint.clone())
            .headers(headers)
            .json(&body)
            .send()
            .await
            .map_err(|error| {
                tracing::error!(error = %error, mode = ?mode, "provider request failed");
                CompletionFailure::Unavailable
            })?;
        let status = response.status();
        let bytes = match read_bounded_body(response).await {
            Ok(bytes) => bytes,
            Err(BodyReadFailure::TooLarge) if status.is_success() => {
                return Err(CompletionFailure::InvalidResponse);
            }
            Err(BodyReadFailure::TooLarge | BodyReadFailure::Read) => {
                return Err(CompletionFailure::Unavailable);
            }
        };
        if !status.is_success() {
            return if explicitly_rejects_response_format(status, &bytes) {
                Err(CompletionFailure::UnsupportedResponseFormat)
            } else {
                tracing::error!(status = %status, body = %String::from_utf8_lossy(&bytes), mode = ?mode, "provider request failed");
                Err(CompletionFailure::Unavailable)
            };
        }
        parse_response(&bytes).map_err(|_| {
            tracing::error!(body = %String::from_utf8_lossy(&bytes), mode = ?mode, "provider response could not be parsed");
            CompletionFailure::InvalidResponse
        })
    }

    fn response_mode(&self) -> Result<ResponseMode, ChatError> {
        self.response_mode
            .lock()
            .map(|value| *value)
            .map_err(|_| ChatError::Internal)
    }

    fn advance_mode(&self, rejected: ResponseMode) -> Result<Option<ResponseMode>, ChatError> {
        let mut current = self.response_mode.lock().map_err(|_| ChatError::Internal)?;
        if *current != rejected {
            return Ok(Some(*current));
        }
        *current = match rejected {
            ResponseMode::JsonSchema => ResponseMode::JsonObject,
            ResponseMode::JsonObject => ResponseMode::PromptConstrained,
            ResponseMode::PromptConstrained => return Ok(None),
        };
        Ok(Some(*current))
    }
}

#[async_trait]
impl ChatClient for OpenAiCompatibleClient {
    async fn complete(&self, request: ChatRequest) -> Result<ChatResponse, ChatError> {
        let mut mode = self.response_mode()?;
        loop {
            match self.complete_in_mode(&request, mode).await {
                Ok(response) => return Ok(response),
                Err(CompletionFailure::UnsupportedResponseFormat) => {
                    mode = self.advance_mode(mode)?.ok_or(ChatError::Unavailable)?;
                }
                Err(CompletionFailure::Unavailable) => return Err(ChatError::Unavailable),
                Err(CompletionFailure::InvalidResponse) => return Err(ChatError::InvalidResponse),
            }
        }
    }
}

impl ProviderAuthentication {
    fn from_config(config: Authentication) -> Result<Self, ChatError> {
        match config {
            Authentication::None => Ok(Self::None),
            Authentication::BearerFile(path) => {
                let key = read_secret_once(&path)?;
                let wire = Zeroizing::new(format!("Bearer {}", key.as_str()));
                Ok(Self::Header {
                    name: AUTHORIZATION,
                    value: sensitive_header(&wire)?,
                })
            }
            Authentication::HeaderFile { name, path } => {
                let key = read_secret_once(&path)?;
                Ok(Self::Header {
                    name,
                    value: sensitive_header(&key)?,
                })
            }
        }
    }

    fn apply(&self, headers: &mut HeaderMap) {
        if let Self::Header { name, value } = self {
            headers.insert(name, value.clone());
        }
    }
}

fn read_secret_once(path: &std::path::Path) -> Result<Zeroizing<String>, ChatError> {
    let raw = Zeroizing::new(std::fs::read_to_string(path).map_err(|_| ChatError::Internal)?);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ChatError::Internal);
    }
    Ok(Zeroizing::new(trimmed.to_owned()))
}

fn sensitive_header(secret: &str) -> Result<HeaderValue, ChatError> {
    let mut value = HeaderValue::from_str(secret).map_err(|_| ChatError::Internal)?;
    value.set_sensitive(true);
    Ok(value)
}

#[derive(Debug)]
enum CompletionFailure {
    UnsupportedResponseFormat,
    Unavailable,
    InvalidResponse,
}

#[derive(Debug)]
enum BodyReadFailure {
    TooLarge,
    Read,
}

async fn read_bounded_body(mut response: reqwest::Response) -> Result<Vec<u8>, BodyReadFailure> {
    if response
        .content_length()
        .is_some_and(|value| value > MAX_PROVIDER_RESPONSE_BYTES as u64)
    {
        return Err(BodyReadFailure::TooLarge);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| BodyReadFailure::Read)? {
        if chunk.len() > MAX_PROVIDER_RESPONSE_BYTES.saturating_sub(body.len()) {
            return Err(BodyReadFailure::TooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

#[derive(Serialize)]
struct GroqRequest<'a> {
    #[serde(flatten)]
    request: &'a RequestBody,
    reasoning_format: &'static str,
    max_tokens: u32,
}

#[derive(Debug, Deserialize, Serialize)]
struct ProviderResponse {
    choices: Vec<ProviderChoice>,
    #[serde(default)]
    usage: Option<ProviderUsage>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ProviderChoice {
    message: ProviderMessage,
}

#[derive(Debug, Deserialize, Serialize)]
struct ProviderMessage {
    content: Option<Value>,
    #[serde(default)]
    refusal: Option<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ProviderUsage {
    #[serde(default)]
    prompt_tokens: Option<u64>,
    #[serde(default)]
    completion_tokens: Option<u64>,
}

#[derive(Serialize)]
struct RequestBody {
    model: String,
    messages: Vec<RequestMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_completion_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    response_format: Option<Value>,
}

#[derive(Serialize)]
struct RequestMessage {
    role: &'static str,
    content: String,
}

impl RequestBody {
    fn from_request(
        model: &str,
        request: &ChatRequest,
        mode: ResponseMode,
        include_generic_token_limit: bool,
    ) -> Result<Self, CompletionFailure> {
        let ResponseFormat::JsonSchema { name, schema } = &request.response_format;
        let mut messages = request
            .messages
            .iter()
            .map(|message| RequestMessage {
                role: match message.role {
                    ChatRole::System => "system",
                    ChatRole::User => "user",
                    ChatRole::Assistant => "assistant",
                },
                content: message.content.clone(),
            })
            .collect::<Vec<_>>();
        if mode != ResponseMode::JsonSchema {
            let system = messages
                .iter_mut()
                .find(|message| message.role == "system")
                .ok_or(CompletionFailure::InvalidResponse)?;
            system.content = format!(
                "{}\n{}\nRequired JSON Schema:\n{}",
                system.content, JSON_ONLY_INSTRUCTION, schema
            );
        }
        let response_format = match mode {
            ResponseMode::JsonSchema => Some(json!({
                "type": "json_schema",
                "json_schema": { "name": name, "strict": true, "schema": schema }
            })),
            ResponseMode::JsonObject => Some(json!({"type": "json_object"})),
            ResponseMode::PromptConstrained => None,
        };
        Ok(Self {
            model: model.to_owned(),
            messages,
            max_completion_tokens: include_generic_token_limit.then_some(request.max_output_tokens),
            response_format,
        })
    }
}

fn parse_response(bytes: &[u8]) -> Result<ChatResponse, ()> {
    let response: ProviderResponse = serde_json::from_slice(bytes).map_err(|_| ())?;
    let message = response.choices.into_iter().next().ok_or(())?.message;
    if message.refusal.is_some() {
        return Err(());
    }
    let content = match message.content.ok_or(())? {
        Value::String(value) if !value.is_empty() => value,
        _ => return Err(()),
    };
    Ok(ChatResponse {
        content,
        usage: response.usage.map(|value| TokenUsage {
            input_tokens: value.prompt_tokens,
            output_tokens: value.completion_tokens,
        }),
    })
}

fn explicitly_rejects_response_format(status: StatusCode, body: &[u8]) -> bool {
    if status != StatusCode::BAD_REQUEST && status != StatusCode::UNPROCESSABLE_ENTITY {
        return false;
    }
    let Ok(text) = std::str::from_utf8(body) else {
        return false;
    };
    let text = text.to_ascii_lowercase();
    (text.contains("response_format")
        && ["unsupported", "not supported", "unknown", "not available"]
            .iter()
            .any(|term| text.contains(term)))
        || text.contains("json_validate_failed")
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Arc;

    use axum::extract::{OriginalUri, State};
    use axum::http::{HeaderMap as AxumHeaderMap, StatusCode as AxumStatusCode};
    use axum::routing::post;
    use axum::{Json, Router};
    use tokio::sync::Mutex as AsyncMutex;

    use super::*;

    #[derive(Clone)]
    struct MockState {
        responses: Arc<AsyncMutex<VecDeque<(AxumStatusCode, String, Duration)>>>,
        requests: Arc<AsyncMutex<Vec<(Value, AxumHeaderMap, String)>>>,
    }

    struct MockServer {
        endpoint: Url,
        state: MockState,
        task: tokio::task::JoinHandle<()>,
    }

    impl Drop for MockServer {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    async fn server(responses: Vec<(AxumStatusCode, String, Duration)>) -> MockServer {
        let state = MockState {
            responses: Arc::new(AsyncMutex::new(responses.into())),
            requests: Arc::new(AsyncMutex::new(vec![])),
        };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        async fn handler(
            State(state): State<MockState>,
            headers: AxumHeaderMap,
            uri: OriginalUri,
            Json(body): Json<Value>,
        ) -> (AxumStatusCode, String) {
            state
                .requests
                .lock()
                .await
                .push((body, headers, uri.to_string()));
            let (status, body, delay) = state.responses.lock().await.pop_front().unwrap();
            tokio::time::sleep(delay).await;
            (status, body)
        }
        let app = Router::new()
            .route("/chat", post(handler))
            .with_state(state.clone());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        MockServer {
            endpoint: format!("http://{address}/chat?x=1").parse().unwrap(),
            state,
            task,
        }
    }

    fn success() -> String {
        json!({
            "choices": [{"message": {"content": "{\"ok\":true}"}}],
            "usage": {"prompt_tokens": 7, "completion_tokens": 3},
            "service_tier": "on_demand",
            "x_groq": {"id": "ignored"}
        })
        .to_string()
    }

    fn request() -> ChatRequest {
        ChatRequest {
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: "PRIVATE PROMPT".into(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: "dal".into(),
                },
            ],
            response_format: ResponseFormat::JsonSchema {
                name: "result".into(),
                schema: json!({"type": "object"}),
            },
            max_output_tokens: 16_384,
        }
    }

    fn config(endpoint: Url, authentication: Authentication) -> OpenAiCompatibleConfig {
        OpenAiCompatibleConfig {
            endpoint,
            model: "test-model".into(),
            authentication,
        }
    }

    fn temp_key(contents: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("calco-test-key-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[tokio::test]
    async fn sends_text_messages_and_bearer_auth_to_exact_url() {
        let server = server(vec![(AxumStatusCode::OK, success(), Duration::ZERO)]).await;
        let key = temp_key("secret-for-test\n");
        let client = OpenAiCompatibleClient::new(config(
            server.endpoint.clone(),
            Authentication::BearerFile(key.clone()),
        ))
        .unwrap();
        std::fs::remove_file(key).unwrap();

        let response = client.complete(request()).await.unwrap();

        assert_eq!(response.usage.unwrap().input_tokens, Some(7));
        let requests = server.state.requests.lock().await;
        assert_eq!(requests[0].0["messages"][1]["content"], "dal");
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[0].1["authorization"], "Bearer secret-for-test");
        assert_eq!(requests[0].2, "/chat?x=1");
        assert_eq!(requests[0].0["max_completion_tokens"], 16_384);
    }

    #[tokio::test]
    async fn sends_custom_header_without_authorization() {
        let server = server(vec![(AxumStatusCode::OK, success(), Duration::ZERO)]).await;
        let key = temp_key("custom-secret\n");
        let client = OpenAiCompatibleClient::new(config(
            server.endpoint.clone(),
            Authentication::HeaderFile {
                name: "x-provider-key".parse().unwrap(),
                path: key.clone(),
            },
        ))
        .unwrap();
        std::fs::remove_file(key).unwrap();

        client.complete(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests[0].1["x-provider-key"], "custom-secret");
        assert!(requests[0].1.get("authorization").is_none());
    }

    #[tokio::test]
    async fn no_authentication_sends_no_authorization_header() {
        let server = server(vec![(AxumStatusCode::OK, success(), Duration::ZERO)]).await;
        let client =
            OpenAiCompatibleClient::new(config(server.endpoint.clone(), Authentication::None))
                .unwrap();

        client.complete(request()).await.unwrap();

        assert!(
            server.state.requests.lock().await[0]
                .1
                .get("authorization")
                .is_none()
        );
    }

    #[tokio::test]
    async fn falls_back_and_caches_supported_response_mode() {
        let unsupported = r#"{"error":{"message":"response_format is unsupported"}}"#.into();
        let server = server(vec![
            (AxumStatusCode::BAD_REQUEST, unsupported, Duration::ZERO),
            (AxumStatusCode::OK, success(), Duration::ZERO),
            (AxumStatusCode::OK, success(), Duration::ZERO),
        ])
        .await;
        let client =
            OpenAiCompatibleClient::new(config(server.endpoint.clone(), Authentication::None))
                .unwrap();

        client.complete(request()).await.unwrap();
        client.complete(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
        assert_eq!(requests[2].0["response_format"]["type"], "json_object");
        assert!(
            requests[1].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains("Required JSON Schema")
        );
    }

    #[tokio::test]
    async fn groq_validation_error_falls_back_to_json_object() {
        let server = server(vec![
            (
                AxumStatusCode::BAD_REQUEST,
                r#"{"error":{"message":"json_validate_failed"}}"#.into(),
                Duration::ZERO,
            ),
            (AxumStatusCode::OK, success(), Duration::ZERO),
        ])
        .await;
        let client =
            OpenAiCompatibleClient::new(config(server.endpoint.clone(), Authentication::None))
                .unwrap();

        client.complete(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
    }

    #[tokio::test]
    async fn falls_back_from_schema_to_json_object_to_prompt_only() {
        let unsupported = || {
            (
                AxumStatusCode::UNPROCESSABLE_ENTITY,
                r#"{"error":{"message":"response_format not available"}}"#.into(),
                Duration::ZERO,
            )
        };
        let server = server(vec![
            unsupported(),
            unsupported(),
            (AxumStatusCode::OK, success(), Duration::ZERO),
        ])
        .await;
        let client =
            OpenAiCompatibleClient::new(config(server.endpoint.clone(), Authentication::None))
                .unwrap();

        client.complete(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests.len(), 3);
        assert!(requests[2].0.get("response_format").is_none());
        assert!(
            requests[2].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains(JSON_ONLY_INSTRUCTION)
        );
    }

    #[tokio::test]
    async fn timeout_is_unavailable_and_large_success_is_invalid() {
        let delayed = server(vec![(
            AxumStatusCode::OK,
            success(),
            Duration::from_millis(50),
        )])
        .await;
        let client = OpenAiCompatibleClient::with_timeouts(
            config(delayed.endpoint.clone(), Authentication::None),
            Duration::from_millis(10),
            Duration::from_millis(10),
        )
        .unwrap();
        assert_eq!(
            client.complete(request()).await,
            Err(ChatError::Unavailable)
        );

        let large = server(vec![(
            AxumStatusCode::OK,
            "x".repeat(MAX_PROVIDER_RESPONSE_BYTES + 1),
            Duration::ZERO,
        )])
        .await;
        let client =
            OpenAiCompatibleClient::new(config(large.endpoint.clone(), Authentication::None))
                .unwrap();
        assert_eq!(
            client.complete(request()).await,
            Err(ChatError::InvalidResponse)
        );
    }

    #[test]
    fn tolerant_response_accepts_groq_extensions_and_rejects_bad_choices() {
        let parsed = parse_response(success().as_bytes()).unwrap();
        assert_eq!(parsed.content, "{\"ok\":true}");
        assert_eq!(parsed.usage.unwrap().output_tokens, Some(3));
        assert!(parse_response(br#"{"choices":[]}"#).is_err());
        assert!(
            parse_response(br#"{"choices":[{"message":{"content":null,"refusal":"no"}}]}"#)
                .is_err()
        );
    }

    #[test]
    fn response_accepts_missing_usage() {
        let parsed = parse_response(br#"{"choices":[{"message":{"content":"{}"}}]}"#).unwrap();
        assert_eq!(parsed.content, "{}");
        assert_eq!(parsed.usage, None);
    }

    #[tokio::test]
    async fn invalid_success_response_maps_to_invalid_response() {
        let server = server(vec![
            (
                AxumStatusCode::OK,
                r#"{"choices":[]}"#.into(),
                Duration::ZERO,
            ),
            (
                AxumStatusCode::OK,
                r#"{"choices":[{"message":{"content":null,"refusal":"no"}}]}"#.into(),
                Duration::ZERO,
            ),
        ])
        .await;
        let client =
            OpenAiCompatibleClient::new(config(server.endpoint.clone(), Authentication::None))
                .unwrap();

        for _ in 0..2 {
            assert_eq!(
                client.complete(request()).await,
                Err(ChatError::InvalidResponse)
            );
        }
    }

    #[test]
    fn groq_request_adds_only_provider_extensions() {
        let request = request();
        let body =
            RequestBody::from_request("test", &request, ResponseMode::JsonSchema, false).unwrap();
        let body = serde_json::to_value(GroqRequest {
            request: &body,
            reasoning_format: "hidden",
            max_tokens: request.max_output_tokens,
        })
        .unwrap();
        assert_eq!(body["reasoning_format"], "hidden");
        assert_eq!(body["max_tokens"], 16_384);
        assert!(body.get("max_completion_tokens").is_none());
    }

    #[test]
    fn credentials_and_configuration_are_redacted() {
        for secret in ["  \n", "PRIVATE\nINJECTION"] {
            let key = temp_key(secret);
            let result = OpenAiCompatibleClient::new(config(
                "http://127.0.0.1:1/private?token=query".parse().unwrap(),
                Authentication::BearerFile(key.clone()),
            ));
            std::fs::remove_file(key).unwrap();
            assert_eq!(result.unwrap_err(), ChatError::Internal);
        }

        let key = temp_key("secret-for-test");
        let client = OpenAiCompatibleClient::new(config(
            "http://127.0.0.1:1/private?token=query".parse().unwrap(),
            Authentication::BearerFile(key.clone()),
        ))
        .unwrap();
        std::fs::remove_file(key).unwrap();
        let debug = format!("{client:?}");
        assert!(!debug.contains("secret-for-test"));
        assert!(!debug.contains("query"));
        assert!(!debug.contains("test-model"));
    }
}

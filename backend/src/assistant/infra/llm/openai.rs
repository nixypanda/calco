//! Provider-tolerant OpenAI-compatible Chat Completions client.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
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
pub(crate) enum Auth {
    None,
    BearerFile(PathBuf),
    HeaderFile { name: HeaderName, path: PathBuf },
}

pub(crate) struct OpenAiConfig {
    pub endpoint: Url,
    pub model: String,
    pub auth: Auth,
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
    pub images: Vec<ChatImage>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChatImage {
    pub mime_type: &'static str,
    pub bytes: Vec<u8>,
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

pub(crate) struct OpenAiClient {
    client: Client,
    endpoint: Url,
    model: String,
    auth: ProviderAuth,
    groq_compatibility: bool,
    response_mode: Mutex<ResponseMode>,
}

impl std::fmt::Debug for OpenAiClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OpenAiClient")
            .field("endpoint", &"[REDACTED]")
            .field("model", &"[REDACTED]")
            .field("auth", &self.auth)
            .finish_non_exhaustive()
    }
}

#[derive(Clone)]
enum ProviderAuth {
    None,
    Header {
        name: HeaderName,
        value: HeaderValue,
    },
}

impl std::fmt::Debug for ProviderAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::None => formatter.write_str("ProviderAuth::None"),
            Self::Header { name, .. } => formatter
                .debug_struct("ProviderAuth::Header")
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

impl OpenAiClient {
    /// Constructs a client and reads a configured credential file exactly once.
    pub(crate) fn new(config: OpenAiConfig) -> Result<Self, ChatError> {
        Self::with_timeouts(config, DEFAULT_CONNECT_TIMEOUT, DEFAULT_REQUEST_TIMEOUT)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    fn with_timeouts(
        config: OpenAiConfig,
        connect_timeout: Duration,
        request_timeout: Duration,
    ) -> Result<Self, ChatError> {
        let auth = ProviderAuth::from_config(config.auth)?;
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
            auth,
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
        self.auth.apply(&mut headers);
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
impl ChatClient for OpenAiClient {
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

impl ProviderAuth {
    fn from_config(config: Auth) -> Result<Self, ChatError> {
        match config {
            Auth::None => Ok(Self::None),
            Auth::BearerFile(path) => {
                let key = read_secret_once(&path)?;
                let wire = Zeroizing::new(format!("Bearer {}", key.as_str()));
                Ok(Self::Header {
                    name: AUTHORIZATION,
                    value: sensitive_header(&wire)?,
                })
            }
            Auth::HeaderFile { name, path } => {
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
    content: RequestContent,
}

#[derive(Serialize)]
#[serde(untagged)]
enum RequestContent {
    Text(String),
    Parts(Vec<RequestContentPart>),
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RequestContentPart {
    Text { text: String },
    ImageUrl { image_url: ImageUrl },
}

#[derive(Serialize)]
struct ImageUrl {
    url: String,
}

impl RequestBody {
    fn from_request(
        model: &str,
        request: &ChatRequest,
        mode: ResponseMode,
        include_generic_token_limit: bool,
    ) -> Result<Self, CompletionFailure> {
        let ResponseFormat::JsonSchema { name, schema } = &request.response_format;
        let mut messages =
            request
                .messages
                .iter()
                .map(|message| RequestMessage {
                    role: match message.role {
                        ChatRole::System => "system",
                        ChatRole::User => "user",
                        ChatRole::Assistant => "assistant",
                    },
                    content: if message.images.is_empty() {
                        RequestContent::Text(message.content.clone())
                    } else {
                        let mut parts = vec![RequestContentPart::Text {
                            text: message.content.clone(),
                        }];
                        parts.extend(message.images.iter().map(|image| {
                            RequestContentPart::ImageUrl {
                                image_url: ImageUrl {
                                    url: format!(
                                        "data:{};base64,{}",
                                        image.mime_type,
                                        base64::engine::general_purpose::STANDARD
                                            .encode(&image.bytes)
                                    ),
                                },
                            }
                        }));
                        RequestContent::Parts(parts)
                    },
                })
                .collect::<Vec<_>>();
        if mode != ResponseMode::JsonSchema {
            let system = messages
                .iter_mut()
                .find(|message| message.role == "system")
                .ok_or(CompletionFailure::InvalidResponse)?;
            let RequestContent::Text(content) = &mut system.content else {
                return Err(CompletionFailure::InvalidResponse);
            };
            *content =
                format!("{content}\n{JSON_ONLY_INSTRUCTION}\nRequired JSON Schema:\n{schema}");
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
    use std::collections::{BTreeMap, VecDeque};
    use std::sync::Arc;

    use axum::extract::{OriginalUri, State};
    use axum::http::{HeaderMap as AxumHeaderMap, StatusCode as AxumStatusCode};
    use axum::routing::post;
    use axum::{Json, Router};
    use proptest::prelude::*;
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
                    images: vec![],
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: "dal".into(),
                    images: vec![],
                },
            ],
            response_format: ResponseFormat::JsonSchema {
                name: "result".into(),
                schema: json!({"type": "object"}),
            },
            max_output_tokens: 16_384,
        }
    }

    fn config(endpoint: Url, auth: Auth) -> OpenAiConfig {
        OpenAiConfig {
            endpoint,
            model: "test-model".into(),
            auth,
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
        let client = OpenAiClient::new(config(
            server.endpoint.clone(),
            Auth::BearerFile(key.clone()),
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
        let client = OpenAiClient::new(config(server.endpoint.clone(), Auth::None)).unwrap();

        client.complete(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests.len(), 3);
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
        assert!(
            !requests[0].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains(JSON_ONLY_INSTRUCTION)
        );
        assert!(
            requests[1].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains(JSON_ONLY_INSTRUCTION)
        );
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
        let client = OpenAiClient::with_timeouts(
            config(delayed.endpoint.clone(), Auth::None),
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
        let client = OpenAiClient::new(config(large.endpoint.clone(), Auth::None)).unwrap();
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

    fn generated_content() -> impl Strategy<Value = String> {
        any::<String>().prop_map(|mut content| {
            if content.is_empty() {
                content.push('x');
            }
            content
        })
    }

    fn generated_extension_value() -> impl Strategy<Value = Value> {
        prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(Value::from),
            generated_content().prop_map(Value::String),
            proptest::collection::vec(any::<i64>(), 0..4).prop_map(|values| json!(values)),
        ]
    }

    fn generated_extension_fields() -> impl Strategy<Value = BTreeMap<String, Value>> {
        proptest::collection::btree_map("[a-z][a-z0-9_]{0,11}", generated_extension_value(), 0..4)
            .prop_map(|fields| {
                fields
                    .into_iter()
                    .map(|(key, value)| (format!("x_{key}"), value))
                    .collect()
            })
    }

    #[derive(Debug, Clone)]
    enum GeneratedUsage {
        Missing,
        Null,
        Fields {
            prompt_tokens: Option<u64>,
            completion_tokens: Option<u64>,
            with_extra_fields: bool,
        },
    }

    fn generated_usage() -> impl Strategy<Value = GeneratedUsage> {
        prop_oneof![
            2 => Just(GeneratedUsage::Missing),
            1 => Just(GeneratedUsage::Null),
            7 => (
                proptest::option::of(any::<u64>()),
                proptest::option::of(any::<u64>()),
                any::<bool>(),
            )
                .prop_map(|(prompt_tokens, completion_tokens, with_extra_fields)| {
                    GeneratedUsage::Fields {
                        prompt_tokens,
                        completion_tokens,
                        with_extra_fields,
                    }
                }),
        ]
    }

    #[derive(Debug, Clone)]
    struct GeneratedValidResponse {
        content: String,
        usage: GeneratedUsage,
        extra_choices: Vec<String>,
        extension_fields: BTreeMap<String, Value>,
        message_extension: Option<Value>,
    }

    fn generated_valid_response() -> impl Strategy<Value = GeneratedValidResponse> {
        (
            generated_content(),
            generated_usage(),
            proptest::collection::vec(generated_content(), 0..3),
            generated_extension_fields(),
            proptest::option::of(generated_extension_value()),
        )
            .prop_map(
                |(content, usage, extra_choices, extension_fields, message_extension)| {
                    GeneratedValidResponse {
                        content,
                        usage,
                        extra_choices,
                        extension_fields,
                        message_extension,
                    }
                },
            )
    }

    impl GeneratedValidResponse {
        fn to_value(&self) -> Value {
            let mut message = serde_json::Map::new();
            message.insert("content".into(), Value::String(self.content.clone()));
            if let Some(extension) = &self.message_extension {
                message.insert("x_message_extension".into(), extension.clone());
            }
            let mut choices = vec![json!({"message": Value::Object(message)})];
            choices.extend(self.extra_choices.iter().map(|extra_content| {
                json!({
                    "message": {
                        "content": extra_content.clone(),
                        "x_choice_extension": true,
                    }
                })
            }));

            let mut response = serde_json::Map::new();
            response.insert("choices".into(), Value::Array(choices));
            for (key, value) in &self.extension_fields {
                response.insert(key.clone(), value.clone());
            }
            match &self.usage {
                GeneratedUsage::Missing => {}
                GeneratedUsage::Null => {
                    response.insert("usage".into(), Value::Null);
                }
                GeneratedUsage::Fields {
                    prompt_tokens,
                    completion_tokens,
                    with_extra_fields,
                } => {
                    let mut fields = serde_json::Map::new();
                    if let Some(prompt_tokens) = prompt_tokens {
                        fields.insert("prompt_tokens".into(), json!(prompt_tokens));
                    }
                    if let Some(completion_tokens) = completion_tokens {
                        fields.insert("completion_tokens".into(), json!(completion_tokens));
                    }
                    if *with_extra_fields {
                        fields.insert("total_tokens".into(), json!(123));
                        fields.insert("x_usage_extension".into(), json!("ignored"));
                    }
                    response.insert("usage".into(), Value::Object(fields));
                }
            }
            Value::Object(response)
        }

        fn expected_usage(&self) -> Option<TokenUsage> {
            match &self.usage {
                GeneratedUsage::Missing | GeneratedUsage::Null => None,
                GeneratedUsage::Fields {
                    prompt_tokens,
                    completion_tokens,
                    ..
                } => Some(TokenUsage {
                    input_tokens: *prompt_tokens,
                    output_tokens: *completion_tokens,
                }),
            }
        }
    }

    #[derive(Debug, Clone)]
    enum InvalidResponseShape {
        MissingChoices,
        NonArrayChoices(Value),
        EmptyChoices,
        MissingMessage,
        NonObjectMessage(Value),
        MissingContent,
        NullContent,
        EmptyContent,
        NonStringContent(Value),
        RefusalWithContent { content: String, refusal: Value },
        RefusalWithoutContent { refusal: Value },
        NonStringRefusalWithContent { content: String, refusal: Value },
        NonStringRefusalWithoutContent { refusal: Value },
    }

    fn generated_non_string_value() -> impl Strategy<Value = Value> {
        prop_oneof![
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(Value::from),
            proptest::collection::vec(any::<i64>(), 0..4).prop_map(|values| json!(values)),
            Just(json!({})),
        ]
    }

    fn generated_non_array_value() -> impl Strategy<Value = Value> {
        prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(Value::from),
            generated_content().prop_map(Value::String),
            proptest::collection::btree_map(
                "[a-z][a-z0-9_]{0,11}",
                generated_extension_value(),
                0..4
            )
            .prop_map(|entries| Value::Object(entries.into_iter().collect())),
        ]
    }

    fn generated_non_object_value() -> impl Strategy<Value = Value> {
        // Arrays are excluded because serde can deserialize a struct from a sequence.
        prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(Value::from),
            generated_content().prop_map(Value::String),
        ]
    }

    fn generated_invalid_response_shape() -> impl Strategy<Value = InvalidResponseShape> {
        prop_oneof![
            Just(InvalidResponseShape::MissingChoices),
            generated_non_array_value().prop_map(InvalidResponseShape::NonArrayChoices),
            Just(InvalidResponseShape::EmptyChoices),
            Just(InvalidResponseShape::MissingMessage),
            generated_non_object_value().prop_map(InvalidResponseShape::NonObjectMessage),
            Just(InvalidResponseShape::MissingContent),
            Just(InvalidResponseShape::NullContent),
            Just(InvalidResponseShape::EmptyContent),
            generated_non_string_value().prop_map(InvalidResponseShape::NonStringContent),
            (
                generated_content(),
                generated_content().prop_map(Value::String)
            )
                .prop_map(|(content, refusal)| {
                    InvalidResponseShape::RefusalWithContent { content, refusal }
                }),
            generated_content()
                .prop_map(Value::String)
                .prop_map(|refusal| InvalidResponseShape::RefusalWithoutContent { refusal }),
            (generated_content(), generated_non_string_value(),).prop_map(|(content, refusal)| {
                InvalidResponseShape::NonStringRefusalWithContent { content, refusal }
            }),
            generated_non_string_value().prop_map(|refusal| {
                InvalidResponseShape::NonStringRefusalWithoutContent { refusal }
            }),
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        #[test]
        fn parse_response_never_panics_and_parses_generated_valid_bytes(
            input in prop_oneof![
                proptest::collection::vec(any::<u8>(), 0..=8 * 1024)
                    .prop_map(|bytes| (bytes, None::<String>)),
                generated_valid_response().prop_map(|response| {
                    let bytes = serde_json::to_vec(&response.to_value()).unwrap();
                    (bytes, Some(response.content))
                }),
            ],
        ) {
            let (bytes, expected_content) = input;
            let parsed = parse_response(&bytes);
            if let Some(expected_content) = expected_content {
                let parsed = parsed.expect("generated valid response should parse");
                prop_assert_eq!(parsed.content, expected_content);
            }
        }

        #[test]
        fn generated_valid_response_preserves_content_and_usage(
            response in generated_valid_response(),
        ) {
            let expected_usage = response.expected_usage();
            let bytes = serde_json::to_vec(&response.to_value()).unwrap();
            let parsed = parse_response(&bytes).expect("generated valid response should parse");
            prop_assert_eq!(parsed.content, response.content);
            prop_assert_eq!(parsed.usage, expected_usage);
        }

        #[test]
        fn generated_invalid_response_shapes_are_rejected(
            shape in generated_invalid_response_shape(),
        ) {
            let response = match shape {
                InvalidResponseShape::MissingChoices => json!({}),
                InvalidResponseShape::NonArrayChoices(choices) => json!({"choices": choices}),
                InvalidResponseShape::EmptyChoices => json!({"choices": []}),
                InvalidResponseShape::MissingMessage => json!({"choices": [{}]}),
                InvalidResponseShape::NonObjectMessage(message) => {
                    json!({"choices": [{"message": message}]})
                }
                InvalidResponseShape::MissingContent => {
                    json!({"choices": [{"message": {}}]})
                }
                InvalidResponseShape::NullContent => {
                    json!({"choices": [{"message": {"content": null}}]})
                }
                InvalidResponseShape::EmptyContent => {
                    json!({"choices": [{"message": {"content": ""}}]})
                }
                InvalidResponseShape::NonStringContent(content) => {
                    json!({"choices": [{"message": {"content": content}}]})
                }
                InvalidResponseShape::RefusalWithContent { content, refusal } => {
                    json!({"choices": [{"message": {"content": content, "refusal": refusal}}]})
                }
                InvalidResponseShape::RefusalWithoutContent { refusal } => {
                    json!({"choices": [{"message": {"refusal": refusal}}]})
                }
                InvalidResponseShape::NonStringRefusalWithContent { content, refusal } => {
                    json!({"choices": [{"message": {"content": content, "refusal": refusal}}]})
                }
                InvalidResponseShape::NonStringRefusalWithoutContent { refusal } => {
                    json!({"choices": [{"message": {"refusal": refusal}}]})
                }
            };
            let bytes = serde_json::to_vec(&response).unwrap();
            prop_assert!(parse_response(&bytes).is_err());
        }
    }

    #[test]
    fn image_messages_use_openai_data_url_parts() {
        let mut request = request();
        request.messages[1].images.push(ChatImage {
            mime_type: "image/jpeg",
            bytes: vec![1, 2, 3],
        });

        let body =
            RequestBody::from_request("test", &request, ResponseMode::JsonSchema, true).unwrap();
        let body = serde_json::to_value(body).unwrap();

        assert_eq!(body["messages"][1]["content"][0]["type"], "text");
        assert_eq!(body["messages"][1]["content"][0]["text"], "dal");
        assert_eq!(body["messages"][1]["content"][1]["type"], "image_url");
        assert_eq!(
            body["messages"][1]["content"][1]["image_url"]["url"],
            "data:image/jpeg;base64,AQID"
        );
        assert!(body["messages"][0]["content"].is_string());
    }

    #[test]
    fn credentials_and_configuration_are_redacted() {
        for secret in ["  \n", "PRIVATE\nINJECTION"] {
            let key = temp_key(secret);
            let result = OpenAiClient::new(config(
                "http://127.0.0.1:1/private?token=query".parse().unwrap(),
                Auth::BearerFile(key.clone()),
            ));
            std::fs::remove_file(key).unwrap();
            assert_eq!(result.unwrap_err(), ChatError::Internal);
        }

        let key = temp_key("secret-for-test");
        let client = OpenAiClient::new(config(
            "http://127.0.0.1:1/private?token=query".parse().unwrap(),
            Auth::BearerFile(key.clone()),
        ))
        .unwrap();
        std::fs::remove_file(key).unwrap();
        let debug = format!("{client:?}");
        assert!(!debug.contains("secret-for-test"));
        assert!(!debug.contains("query"));
        assert!(!debug.contains("test-model"));
    }
}

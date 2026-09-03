//! Text-only OpenAI-compatible Chat Completions adapter.

use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::assistant::application::{
    FoodDraftModelPort, ModelDraftRequest, ModelDraftResponse, ModelUsage,
};
use crate::assistant::domain::{AssistantError, ConversationRole};
use crate::config::{AiAuthenticationSettings, AiEnabledSettings};

const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_PROVIDER_RESPONSE_BYTES: usize = 1024 * 1024;
const JSON_ONLY_INSTRUCTION: &str =
    "Return only one JSON object that conforms exactly to the supplied JSON Schema.";

pub struct OpenAiCompatibleFoodDraftModel {
    client: Client,
    endpoint: reqwest::Url,
    model: String,
    authentication: ProviderAuthentication,
    response_mode: Mutex<ResponseMode>,
}

impl std::fmt::Debug for OpenAiCompatibleFoodDraftModel {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OpenAiCompatibleFoodDraftModel")
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
        name: reqwest::header::HeaderName,
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

impl OpenAiCompatibleFoodDraftModel {
    /// Constructs an enabled provider. This is the only boundary that reads a
    /// configured credential file, and it reads it exactly once.
    pub fn new(settings: &AiEnabledSettings) -> Result<Self, AssistantError> {
        Self::with_timeouts(settings, DEFAULT_CONNECT_TIMEOUT, DEFAULT_REQUEST_TIMEOUT)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    fn with_timeouts(
        settings: &AiEnabledSettings,
        connect_timeout: Duration,
        request_timeout: Duration,
    ) -> Result<Self, AssistantError> {
        let authentication = ProviderAuthentication::from_settings(&settings.authentication)?;
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(connect_timeout)
            .timeout(request_timeout)
            .build()
            .map_err(|_| AssistantError::Internal)?;
        Ok(Self {
            client,
            endpoint: settings.endpoint.clone(),
            model: settings.model.as_str().to_owned(),
            authentication,
            response_mode: Mutex::new(ResponseMode::JsonSchema),
        })
    }

    async fn generate_in_mode(
        &self,
        request: &ModelDraftRequest,
        mode: ResponseMode,
    ) -> Result<ModelDraftResponse, GenerationFailure> {
        let body = RequestBody::from_request(&self.model, request, mode)?;
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
            .map_err(|_| GenerationFailure::Unavailable)?;
        let status = response.status();
        let bytes = match read_bounded_body(response).await {
            Ok(bytes) => bytes,
            Err(BodyReadFailure::TooLarge) if status.is_success() => {
                return Err(GenerationFailure::InvalidResponse);
            }
            Err(BodyReadFailure::TooLarge | BodyReadFailure::Read) => {
                return Err(GenerationFailure::Unavailable);
            }
        };
        if !status.is_success() {
            return if explicitly_rejects_response_format(status, &bytes) {
                Err(GenerationFailure::UnsupportedResponseFormat)
            } else {
                Err(GenerationFailure::Unavailable)
            };
        }
        parse_response(&bytes).map_err(|_| GenerationFailure::InvalidResponse)
    }

    fn response_mode(&self) -> Result<ResponseMode, AssistantError> {
        self.response_mode
            .lock()
            .map(|value| *value)
            .map_err(|_| AssistantError::Internal)
    }

    fn advance_mode(&self, rejected: ResponseMode) -> Result<Option<ResponseMode>, AssistantError> {
        let mut current = self
            .response_mode
            .lock()
            .map_err(|_| AssistantError::Internal)?;
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

impl ProviderAuthentication {
    fn from_settings(settings: &AiAuthenticationSettings) -> Result<Self, AssistantError> {
        match settings {
            AiAuthenticationSettings::None => Ok(Self::None),
            AiAuthenticationSettings::Bearer { api_key_file } => {
                let key = read_secret_once(api_key_file)?;
                let wire = Zeroizing::new(format!("Bearer {}", key.as_str()));
                Ok(Self::Header {
                    name: AUTHORIZATION,
                    value: sensitive_header(&wire)?,
                })
            }
            AiAuthenticationSettings::Header {
                header_name,
                api_key_file,
            } => {
                let key = read_secret_once(api_key_file)?;
                Ok(Self::Header {
                    name: header_name.clone(),
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

fn read_secret_once(path: &std::path::Path) -> Result<Zeroizing<String>, AssistantError> {
    let raw = Zeroizing::new(std::fs::read_to_string(path).map_err(|_| AssistantError::Internal)?);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(AssistantError::Internal);
    }
    Ok(Zeroizing::new(trimmed.to_owned()))
}

fn sensitive_header(secret: &str) -> Result<HeaderValue, AssistantError> {
    let mut value = HeaderValue::from_str(secret).map_err(|_| AssistantError::Internal)?;
    value.set_sensitive(true);
    Ok(value)
}

#[async_trait]
impl FoodDraftModelPort for OpenAiCompatibleFoodDraftModel {
    async fn generate(
        &self,
        request: ModelDraftRequest,
    ) -> Result<ModelDraftResponse, AssistantError> {
        let mut mode = self.response_mode()?;
        loop {
            match self.generate_in_mode(&request, mode).await {
                Ok(response) => return Ok(response),
                Err(GenerationFailure::UnsupportedResponseFormat) => {
                    mode = self
                        .advance_mode(mode)?
                        .ok_or(AssistantError::ModelUnavailable)?;
                }
                Err(GenerationFailure::Unavailable) => {
                    return Err(AssistantError::ModelUnavailable);
                }
                Err(GenerationFailure::InvalidResponse) => {
                    return Err(AssistantError::InvalidModelResponse);
                }
            }
        }
    }
}

#[derive(Debug)]
enum GenerationFailure {
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
struct RequestBody {
    model: String,
    messages: Vec<ChatMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    response_format: Option<Value>,
}

#[derive(Serialize)]
struct ChatMessage {
    role: &'static str,
    content: String,
}

impl RequestBody {
    fn from_request(
        model: &str,
        request: &ModelDraftRequest,
        mode: ResponseMode,
    ) -> Result<Self, GenerationFailure> {
        let schema: Value = serde_json::from_str(&request.response_schema)
            .map_err(|_| GenerationFailure::InvalidResponse)?;
        let system_prompt = match mode {
            ResponseMode::JsonSchema => request.system_prompt.clone(),
            ResponseMode::JsonObject | ResponseMode::PromptConstrained => format!(
                "{}\n{}\nRequired JSON Schema:\n{}",
                request.system_prompt, JSON_ONLY_INSTRUCTION, request.response_schema
            ),
        };
        let mut messages = vec![ChatMessage {
            role: "system",
            content: system_prompt,
        }];
        messages.extend(request.conversation.turns().iter().map(|turn| ChatMessage {
            role: match turn.role() {
                ConversationRole::User => "user",
                ConversationRole::Assistant => "assistant",
            },
            content: turn.text().to_owned(),
        }));
        let response_format = match mode {
            ResponseMode::JsonSchema => Some(
                json!({"type":"json_schema","json_schema":{"name":"food_draft_response","strict":true,"schema":schema}}),
            ),
            ResponseMode::JsonObject => Some(json!({"type":"json_object"})),
            ResponseMode::PromptConstrained => None,
        };
        Ok(Self {
            model: model.to_owned(),
            messages,
            response_format,
        })
    }
}

#[derive(Deserialize)]
struct ProviderResponse {
    choices: Vec<ProviderChoice>,
    #[serde(default)]
    usage: Option<ProviderUsage>,
}
#[derive(Deserialize)]
struct ProviderChoice {
    message: ProviderMessage,
}
#[derive(Deserialize)]
struct ProviderMessage {
    content: Option<Value>,
    #[serde(default)]
    refusal: Option<Value>,
}
#[derive(Deserialize)]
struct ProviderUsage {
    #[serde(default)]
    prompt_tokens: Option<u64>,
    #[serde(default)]
    completion_tokens: Option<u64>,
}

fn parse_response(bytes: &[u8]) -> Result<ModelDraftResponse, ()> {
    let response: ProviderResponse = serde_json::from_slice(bytes).map_err(|_| ())?;
    let message = response.choices.into_iter().next().ok_or(())?.message;
    if message.refusal.is_some() {
        return Err(());
    }
    let content = match message.content.ok_or(())? {
        Value::String(value) if !value.is_empty() => value,
        _ => return Err(()),
    };
    Ok(ModelDraftResponse {
        content,
        usage: response.usage.map(|value| ModelUsage {
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
    text.contains("response_format")
        && ["unsupported", "not supported", "unknown", "not available"]
            .iter()
            .any(|term| text.contains(term))
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Arc;

    use axum::extract::{OriginalUri, State};
    use axum::http::{HeaderMap as AxumHeaderMap, StatusCode as AxumStatusCode};
    use axum::routing::post;
    use axum::{Json, Router};
    use serde_json::Value;
    use tokio::sync::Mutex as AsyncMutex;

    use super::*;
    use crate::assistant::domain::{Conversation, ConversationRole, ConversationTurn};
    use crate::config::{AiAuthenticationSettings, AiEnabledSettings};

    #[derive(Clone)]
    struct MockState {
        responses: Arc<AsyncMutex<VecDeque<(AxumStatusCode, String, Duration)>>>,
        requests: Arc<AsyncMutex<Vec<(Value, AxumHeaderMap, String)>>>,
    }

    struct MockServer {
        endpoint: url::Url,
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
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        MockServer {
            endpoint: format!("http://{address}/chat?x=1").parse().unwrap(),
            state,
            task,
        }
    }

    fn success() -> String {
        r#"{"choices":[{"message":{"content":"{\"assistant_message\":\"How much?\",\"status\":\"needs_clarification\",\"draft\":null,\"warnings\":[]}"}}],"usage":{"prompt_tokens":7,"completion_tokens":3}}"#.into()
    }

    fn settings(endpoint: url::Url, authentication: AiAuthenticationSettings) -> AiEnabledSettings {
        let config = format!(
            "[ai]\nenabled=true\nendpoint=\"{endpoint}\"\nmodel=\"test-model\"\n[ai.authentication]\nkind=\"none\"\n"
        );
        let parsed: crate::config::FileConfig = toml_edit::de::from_str(&config).unwrap();
        let crate::config::AiRuntimeSettings::Enabled(mut value) = parsed.ai else {
            unreachable!()
        };
        value.authentication = authentication;
        value
    }

    fn request() -> ModelDraftRequest {
        ModelDraftRequest {
            conversation: Conversation::new(vec![
                ConversationTurn::new(ConversationRole::User, "dal").unwrap(),
            ])
            .unwrap(),
            system_prompt: "PRIVATE PROMPT".into(),
            response_schema: r#"{"type":"object"}"#.into(),
        }
    }

    fn temp_key(contents: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("calco-test-key-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[tokio::test]
    async fn sends_text_messages_and_bearer_auth_to_configured_path() {
        let server = server(vec![(AxumStatusCode::OK, success(), Duration::ZERO)]).await;
        let path = temp_key("secret-for-test\n");
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::Bearer {
                api_key_file: path.clone(),
            },
        ))
        .unwrap();
        std::fs::remove_file(path).unwrap();
        let response = model.generate(request()).await.unwrap();
        assert_eq!(response.usage.unwrap().input_tokens, Some(7));
        let requests = server.state.requests.lock().await;
        assert_eq!(requests[0].0["messages"][1]["content"], "dal");
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[0].1["authorization"], "Bearer secret-for-test");
        assert_eq!(requests[0].2, "/chat?x=1");
    }

    #[tokio::test]
    async fn sends_custom_authentication_header() {
        let server = server(vec![(AxumStatusCode::OK, success(), Duration::ZERO)]).await;
        let path = temp_key("custom-secret\n");
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::Header {
                header_name: "x-provider-key".parse().unwrap(),
                api_key_file: path.clone(),
            },
        ))
        .unwrap();
        std::fs::remove_file(path).unwrap();

        model.generate(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests[0].1["x-provider-key"], "custom-secret");
        assert!(requests[0].1.get("authorization").is_none());
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
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();
        model.generate(request()).await.unwrap();
        model.generate(request()).await.unwrap();
        let requests = server.state.requests.lock().await;
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
        assert_eq!(requests[2].0["response_format"]["type"], "json_object");
    }

    #[tokio::test]
    async fn falls_back_to_prompt_constrained_mode() {
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
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();

        model.generate(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
        assert_eq!(requests.len(), 3);
        assert!(requests[2].0.get("response_format").is_none());
        assert!(
            requests[2].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains("Return only one JSON object")
        );
    }

    #[tokio::test]
    async fn timeout_and_oversized_content_are_safely_mapped() {
        let delayed = server(vec![(
            AxumStatusCode::OK,
            success(),
            Duration::from_millis(50),
        )])
        .await;
        let model = OpenAiCompatibleFoodDraftModel::with_timeouts(
            &settings(delayed.endpoint.clone(), AiAuthenticationSettings::None),
            Duration::from_millis(10),
            Duration::from_millis(10),
        )
        .unwrap();
        assert!(matches!(
            model.generate(request()).await,
            Err(AssistantError::ModelUnavailable)
        ));

        let large = server(vec![(
            AxumStatusCode::OK,
            "x".repeat(MAX_PROVIDER_RESPONSE_BYTES + 1),
            Duration::ZERO,
        )])
        .await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            large.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();
        assert!(matches!(
            model.generate(request()).await,
            Err(AssistantError::InvalidModelResponse)
        ));
    }

    #[test]
    fn rejects_empty_and_non_header_safe_keys_without_leaking_them() {
        for secret in ["  \n", "PRIVATE\nINJECTION"] {
            let path = temp_key(secret);
            let result = OpenAiCompatibleFoodDraftModel::new(&settings(
                "http://127.0.0.1:1".parse().unwrap(),
                AiAuthenticationSettings::Bearer {
                    api_key_file: path.clone(),
                },
            ));
            std::fs::remove_file(path).unwrap();
            let error = result.unwrap_err();
            assert_eq!(error, AssistantError::Internal);
            assert!(!format!("{error:?}").contains("PRIVATE"));
        }
    }

    #[test]
    fn debug_redacts_provider_configuration_and_credentials() {
        let path = temp_key("secret-for-test");
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            "http://127.0.0.1:1/private?token=query".parse().unwrap(),
            AiAuthenticationSettings::Header {
                header_name: "x-key".parse().unwrap(),
                api_key_file: path.clone(),
            },
        ))
        .unwrap();
        std::fs::remove_file(path).unwrap();
        let debug = format!("{model:?}");
        assert!(!debug.contains("secret-for-test"));
        assert!(!debug.contains("query"));
        assert!(!debug.contains("test-model"));
    }
}

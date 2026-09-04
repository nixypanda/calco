//! Text-only OpenAI-compatible Chat Completions adapter.

use std::sync::Mutex;
use std::time::Duration;

use async_openai::Client as OpenAiClient;
use async_openai::config::Config;
use async_openai::error::OpenAIError;
use async_openai::types::chat::{
    ChatCompletionRequestAssistantMessage, ChatCompletionRequestSystemMessage,
    ChatCompletionRequestUserMessage, CreateChatCompletionRequest, CreateChatCompletionResponse,
    ResponseFormat, ResponseFormatJsonSchema,
};
use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};
use secrecy::SecretString;
use serde::Serialize;
use serde_json::Value;
use zeroize::Zeroizing;

use crate::assistant::application::{
    FoodDraftModelPort, ModelDraftRequest, ModelDraftResponse, ModelUsage,
};
use crate::assistant::domain::{AssistantError, ConversationRole};
use crate::config::{AiAuthenticationSettings, AiEnabledSettings};

const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const JSON_ONLY_INSTRUCTION: &str =
    "Return only one JSON object that conforms exactly to the supplied JSON Schema.";
const GROQ_HOST: &str = "api.groq.com";
const MAX_OUTPUT_TOKENS: u32 = 16_384;

pub struct OpenAiCompatibleFoodDraftModel {
    client: OpenAiClient<ProviderConfig>,
    model: String,
    groq_compatibility: bool,
    response_mode: Mutex<ResponseMode>,
}

impl std::fmt::Debug for OpenAiCompatibleFoodDraftModel {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OpenAiCompatibleFoodDraftModel")
            .field("endpoint", &"[REDACTED]")
            .field("model", &"[REDACTED]")
            .field("authentication", &"[REDACTED]")
            .finish_non_exhaustive()
    }
}

/// The SDK config deliberately owns the exact configured Chat Completions URL.
/// Its `url` implementation ignores the SDK's default path so endpoints with a
/// custom path or query string remain unchanged.
#[derive(Clone)]
struct ProviderConfig {
    endpoint: String,
    headers: HeaderMap,
    unused_api_key: SecretString,
}

impl Config for ProviderConfig {
    fn headers(&self) -> HeaderMap {
        self.headers.clone()
    }

    fn url(&self, _path: &str) -> String {
        self.endpoint.clone()
    }

    fn query(&self) -> Vec<(&str, &str)> {
        Vec::new()
    }

    fn api_base(&self) -> &str {
        &self.endpoint
    }

    fn api_key(&self) -> &SecretString {
        &self.unused_api_key
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
        let headers = authentication_headers(&settings.authentication)?;
        let http_client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(connect_timeout)
            .timeout(request_timeout)
            .build()
            .map_err(|_| AssistantError::Internal)?;
        let config = ProviderConfig {
            endpoint: settings.endpoint.as_str().to_owned(),
            headers,
            unused_api_key: SecretString::from(String::new()),
        };
        Ok(Self {
            client: OpenAiClient::build(http_client, config),
            model: settings.model.as_str().to_owned(),
            groq_compatibility: settings.endpoint.host_str() == Some(GROQ_HOST),
            response_mode: Mutex::new(ResponseMode::JsonSchema),
        })
    }
}

fn authentication_headers(
    settings: &AiAuthenticationSettings,
) -> Result<HeaderMap, AssistantError> {
    let mut headers = HeaderMap::new();
    match settings {
        AiAuthenticationSettings::None => {}
        AiAuthenticationSettings::Bearer { api_key_file } => {
            let key = read_secret_once(api_key_file)?;
            let wire = Zeroizing::new(format!("Bearer {}", key.as_str()));
            headers.insert(AUTHORIZATION, sensitive_header(&wire)?);
        }
        AiAuthenticationSettings::Header {
            header_name,
            api_key_file,
        } => {
            let key = read_secret_once(api_key_file)?;
            headers.insert(header_name, sensitive_header(&key)?);
        }
    }
    Ok(headers)
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
        let mut mode = *self
            .response_mode
            .lock()
            .map_err(|_| AssistantError::Internal)?;
        loop {
            let mut sdk_request = build_request(&self.model, &request, mode)
                .map_err(|_| AssistantError::InvalidModelResponse)?;
            if !self.groq_compatibility {
                sdk_request.max_completion_tokens = Some(MAX_OUTPUT_TOKENS);
            }
            // async-openai buffers the provider response internally, so the
            // former byte cap cannot be retained. The request timeout and
            // output-token bound still constrain every completion.
            let response = if self.groq_compatibility {
                // BYOT is limited to Groq's two request extensions.
                self.client
                    .chat()
                    .create_byot::<_, CreateChatCompletionResponse>(&GroqRequest {
                        request: &sdk_request,
                        reasoning_format: "hidden",
                        max_tokens: MAX_OUTPUT_TOKENS,
                    })
                    .await
            } else {
                self.client.chat().create(sdk_request).await
            };
            match response {
                Ok(response) => {
                    return parse_response(&response).map_err(|_| {
                        tracing::error!(response = ?response, mode = ?mode, "provider response was invalid");
                        AssistantError::InvalidModelResponse
                    });
                }
                Err(error) if rejects_response_format(&error) => {
                    let next = match mode {
                        ResponseMode::JsonSchema => ResponseMode::JsonObject,
                        ResponseMode::JsonObject => ResponseMode::PromptConstrained,
                        ResponseMode::PromptConstrained => {
                            return Err(AssistantError::ModelUnavailable);
                        }
                    };
                    let mut cached = self
                        .response_mode
                        .lock()
                        .map_err(|_| AssistantError::Internal)?;
                    if *cached == mode {
                        *cached = next;
                    }
                    mode = *cached;
                }
                Err(OpenAIError::JSONDeserialize(error, body)) => {
                    tracing::error!(error = %error, body = %body, mode = ?mode, "provider response could not be parsed");
                    return Err(AssistantError::InvalidModelResponse);
                }
                Err(error) => {
                    tracing::error!(error = %error, mode = ?mode, "provider request failed");
                    return Err(AssistantError::ModelUnavailable);
                }
            }
        }
    }
}

#[derive(Serialize)]
struct GroqRequest<'a> {
    #[serde(flatten)]
    request: &'a CreateChatCompletionRequest,
    reasoning_format: &'static str,
    max_tokens: u32,
}

fn build_request(
    model: &str,
    request: &ModelDraftRequest,
    mode: ResponseMode,
) -> Result<CreateChatCompletionRequest, ()> {
    let schema: Value = serde_json::from_str(&request.response_schema).map_err(|_| ())?;
    let system_prompt = match mode {
        ResponseMode::JsonSchema => request.system_prompt.clone(),
        ResponseMode::JsonObject | ResponseMode::PromptConstrained => format!(
            "{}\n{}\nRequired JSON Schema:\n{}",
            request.system_prompt, JSON_ONLY_INSTRUCTION, request.response_schema
        ),
    };
    let mut messages = vec![ChatCompletionRequestSystemMessage::from(system_prompt).into()];
    messages.extend(
        request
            .conversation
            .turns()
            .iter()
            .map(|turn| match turn.role() {
                ConversationRole::User => {
                    ChatCompletionRequestUserMessage::from(turn.text()).into()
                }
                ConversationRole::Assistant => {
                    ChatCompletionRequestAssistantMessage::from(turn.text()).into()
                }
            }),
    );
    let response_format = match mode {
        ResponseMode::JsonSchema => Some(ResponseFormat::JsonSchema {
            json_schema: ResponseFormatJsonSchema {
                description: None,
                name: "food_draft_response".to_owned(),
                schema,
                strict: Some(true),
            },
        }),
        ResponseMode::JsonObject => Some(ResponseFormat::JsonObject),
        ResponseMode::PromptConstrained => None,
    };
    Ok(CreateChatCompletionRequest {
        model: model.to_owned(),
        messages,
        response_format,
        ..Default::default()
    })
}

fn parse_response(response: &CreateChatCompletionResponse) -> Result<ModelDraftResponse, ()> {
    let message = &response.choices.first().ok_or(())?.message;
    if message.refusal.is_some() {
        return Err(());
    }
    let content = message
        .content
        .as_ref()
        .filter(|value| !value.is_empty())
        .ok_or(())?
        .clone();
    Ok(ModelDraftResponse {
        content,
        usage: response.usage.as_ref().map(|value| ModelUsage {
            input_tokens: Some(u64::from(value.prompt_tokens)),
            output_tokens: Some(u64::from(value.completion_tokens)),
        }),
    })
}

fn rejects_response_format(error: &OpenAIError) -> bool {
    let OpenAIError::ApiError(response) = error else {
        return false;
    };
    explicitly_rejects_response_format(response.status_code, &response.api_error.to_string())
}

fn explicitly_rejects_response_format(status: reqwest::StatusCode, body: &str) -> bool {
    if status != reqwest::StatusCode::BAD_REQUEST
        && status != reqwest::StatusCode::UNPROCESSABLE_ENTITY
    {
        return false;
    }
    let text = body.to_ascii_lowercase();
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
    use serde_json::{Value, json};
    use tokio::sync::Mutex as AsyncMutex;

    use super::*;
    use crate::assistant::domain::{Conversation, ConversationRole, ConversationTurn};

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
        json!({
            "id": "test-completion",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "{\"assistant_message\":\"How much?\",\"status\":\"needs_clarification\",\"draft\":null,\"warnings\":[]}"
                },
                "finish_reason": "stop"
            }],
            "created": 1,
            "model": "test-model",
            "object": "chat.completion",
            "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
        })
        .to_string()
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
    async fn sends_sdk_messages_and_bearer_auth_to_exact_configured_url() {
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
        assert!(requests[0].0.get("reasoning_format").is_none());
        assert!(requests[0].0.get("max_tokens").is_none());
        assert_eq!(requests[0].0["max_completion_tokens"], MAX_OUTPUT_TOKENS);
    }

    #[tokio::test]
    async fn sends_custom_authentication_header_without_authorization() {
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
    async fn no_authentication_sends_no_authorization_header() {
        let server = server(vec![(AxumStatusCode::OK, success(), Duration::ZERO)]).await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();

        model.generate(request()).await.unwrap();

        let requests = server.state.requests.lock().await;
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
    async fn groq_validation_error_falls_back_to_json_object() {
        let unsupported = r#"{"error":{"message":"json_validate_failed"}}"#.into();
        let server = server(vec![
            (AxumStatusCode::BAD_REQUEST, unsupported, Duration::ZERO),
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
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
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
    async fn timeout_is_safely_mapped() {
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
    }

    #[test]
    fn groq_byot_adds_only_the_provider_extensions() {
        let request = build_request("test-model", &request(), ResponseMode::JsonSchema).unwrap();
        let body = serde_json::to_value(GroqRequest {
            request: &request,
            reasoning_format: "hidden",
            max_tokens: MAX_OUTPUT_TOKENS,
        })
        .unwrap();

        assert_eq!(body["reasoning_format"], "hidden");
        assert_eq!(body["max_tokens"], MAX_OUTPUT_TOKENS);
        assert!(body.get("max_completion_tokens").is_none());
        assert_eq!(body["response_format"]["type"], "json_schema");
    }

    #[test]
    fn typed_response_rejects_no_choices_refusal_and_empty_content() {
        let no_choices = typed_response(json!([]), None);
        assert!(parse_response(&no_choices).is_err());

        let refusal = typed_response(
            json!([{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": null,
                    "refusal": "I cannot answer"
                },
                "finish_reason": "stop"
            }]),
            None,
        );
        assert!(parse_response(&refusal).is_err());

        let empty_content = typed_response(
            json!([{
                "index": 0,
                "message": {"role": "assistant", "content": ""},
                "finish_reason": "stop"
            }]),
            None,
        );
        assert!(parse_response(&empty_content).is_err());
    }

    #[tokio::test]
    async fn invalid_typed_responses_are_mapped_to_invalid_model_response() {
        let server = server(vec![
            (
                AxumStatusCode::OK,
                serde_json::to_string(&typed_response(json!([]), None)).unwrap(),
                Duration::ZERO,
            ),
            (
                AxumStatusCode::OK,
                serde_json::to_string(&typed_response(
                    json!([{
                        "index": 0,
                        "message": {"role": "assistant", "content": null, "refusal": "No"},
                        "finish_reason": "stop"
                    }]),
                    None,
                ))
                .unwrap(),
                Duration::ZERO,
            ),
            (
                AxumStatusCode::OK,
                serde_json::to_string(&typed_response(
                    json!([{
                        "index": 0,
                        "message": {"role": "assistant", "content": ""},
                        "finish_reason": "stop"
                    }]),
                    None,
                ))
                .unwrap(),
                Duration::ZERO,
            ),
        ])
        .await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();

        for _ in 0..3 {
            assert!(matches!(
                model.generate(request()).await,
                Err(AssistantError::InvalidModelResponse)
            ));
        }
    }

    #[test]
    fn typed_response_accepts_missing_usage() {
        let response = typed_response(
            json!([{
                "index": 0,
                "message": {"role": "assistant", "content": "{}"},
                "finish_reason": "stop"
            }]),
            None,
        );

        let parsed = parse_response(&response).unwrap();

        assert_eq!(parsed.content, "{}");
        assert_eq!(parsed.usage, None);
    }

    fn typed_response(choices: Value, usage: Option<Value>) -> CreateChatCompletionResponse {
        let mut wire = json!({
            "id": "test-completion",
            "choices": choices,
            "created": 1,
            "model": "test-model",
            "object": "chat.completion"
        });
        if let Some(usage) = usage {
            wire["usage"] = usage;
        }
        serde_json::from_value(wire).unwrap()
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

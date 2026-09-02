//! Text-only OpenAI Chat Completions adapter.
//!
//! This module intentionally keeps provider DTOs, endpoint details, and
//! credentials at the infrastructure boundary. Errors are deliberately coarse:
//! prompts, model responses, URLs, and credentials must not escape it.

use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::assistant::application::{
    FoodDraftModelPort, ModelDraftRequest, ModelDraftResponse, ModelUsage,
};
use crate::assistant::domain::{AssistantError, ConversationRole};
use crate::config::{AiAuthenticationSettings, AiEnabledSettings, ApiKey};

const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_PROVIDER_RESPONSE_BYTES: usize = 1024 * 1024;
const JSON_ONLY_INSTRUCTION: &str =
    "Return only one JSON object that conforms exactly to the requested food-draft schema.";

/// A direct, text-only OpenAI-compatible Chat Completions client.
///
/// The endpoint is used verbatim, including its configured path and query.
/// Redirects are disabled so authentication headers can never be forwarded to
/// a different location by this client.
pub struct OpenAiCompatibleFoodDraftModel {
    client: Client,
    endpoint: reqwest::Url,
    model: String,
    authentication: ProviderAuthentication,
    response_mode: Mutex<ResponseMode>,
}

impl std::fmt::Debug for OpenAiCompatibleFoodDraftModel {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Endpoint query parameters and model identifiers are deployment input,
        // so diagnostics omit all provider configuration as well as credentials
        // and request content.
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
    pub fn new(settings: &AiEnabledSettings) -> Result<Self, AssistantError> {
        Self::with_timeouts(settings, DEFAULT_CONNECT_TIMEOUT, DEFAULT_REQUEST_TIMEOUT)
    }

    pub fn with_timeouts(
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
            model: settings.model.clone(),
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
            .map(|mode| *mode)
            .map_err(|_| AssistantError::Internal)
    }

    fn advance_response_mode(
        &self,
        rejected: ResponseMode,
    ) -> Result<Option<ResponseMode>, AssistantError> {
        let mut mode = self
            .response_mode
            .lock()
            .map_err(|_| AssistantError::Internal)?;
        if *mode != rejected {
            return Ok(Some(*mode));
        }
        *mode = match rejected {
            ResponseMode::JsonSchema => ResponseMode::JsonObject,
            ResponseMode::JsonObject => ResponseMode::PromptConstrained,
            ResponseMode::PromptConstrained => return Ok(None),
        };
        Ok(Some(*mode))
    }
}

#[derive(Debug)]
enum BodyReadFailure {
    TooLarge,
    Read,
}

async fn read_bounded_body(mut response: reqwest::Response) -> Result<Vec<u8>, BodyReadFailure> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_PROVIDER_RESPONSE_BYTES as u64)
    {
        return Err(BodyReadFailure::TooLarge);
    }

    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(MAX_PROVIDER_RESPONSE_BYTES as u64) as usize,
    );
    while let Some(chunk) = response.chunk().await.map_err(|_| BodyReadFailure::Read)? {
        if chunk.len() > MAX_PROVIDER_RESPONSE_BYTES.saturating_sub(body.len()) {
            return Err(BodyReadFailure::TooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

impl ProviderAuthentication {
    fn from_settings(settings: &AiAuthenticationSettings) -> Result<Self, AssistantError> {
        match settings {
            AiAuthenticationSettings::None => Ok(Self::None),
            AiAuthenticationSettings::Bearer { .. } => {
                let key = settings
                    .read_api_key()
                    .map_err(|_| AssistantError::Internal)?;
                let value = bearer_header(key.ok_or(AssistantError::Internal)?)?;
                Ok(Self::Header {
                    name: AUTHORIZATION,
                    value,
                })
            }
            AiAuthenticationSettings::Header { header_name, .. } => {
                let key = settings
                    .read_api_key()
                    .map_err(|_| AssistantError::Internal)?;
                let value = secret_header(key.ok_or(AssistantError::Internal)?)?;
                Ok(Self::Header {
                    name: header_name.clone(),
                    value,
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

fn bearer_header(key: ApiKey) -> Result<HeaderValue, AssistantError> {
    let wire_value = Zeroizing::new(format!("Bearer {}", key.expose_secret()));
    let mut value =
        HeaderValue::try_from(wire_value.as_str()).map_err(|_| AssistantError::Internal)?;
    value.set_sensitive(true);
    Ok(value)
}

fn secret_header(key: ApiKey) -> Result<HeaderValue, AssistantError> {
    let mut value =
        HeaderValue::try_from(key.expose_secret()).map_err(|_| AssistantError::Internal)?;
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
                    let Some(next) = self.advance_response_mode(mode)? else {
                        return Err(AssistantError::ModelUnavailable);
                    };
                    mode = next;
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
    content: ChatContent,
}

#[derive(Serialize)]
#[serde(untagged)]
enum ChatContent {
    Text(String),
    Parts(Vec<ChatContentPart>),
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ChatContentPart {
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
        request: &ModelDraftRequest,
        mode: ResponseMode,
    ) -> Result<Self, GenerationFailure> {
        let schema: Value = serde_json::from_str(&request.response_schema)
            .map_err(|_| GenerationFailure::InvalidResponse)?;
        let system_prompt = match mode {
            ResponseMode::JsonSchema => request.system_prompt.clone(),
            ResponseMode::JsonObject | ResponseMode::PromptConstrained => format!(
                "{}\n{}\nThe required JSON Schema is:\n{}",
                request.system_prompt, JSON_ONLY_INSTRUCTION, request.response_schema
            ),
        };

        let latest_user_turn = request
            .conversation
            .turns
            .iter()
            .rposition(|turn| turn.role == ConversationRole::User);
        if !request.photos.is_empty() && latest_user_turn.is_none() {
            return Err(GenerationFailure::InvalidResponse);
        }

        let mut messages = Vec::with_capacity(request.conversation.turns.len() + 1);
        messages.push(ChatMessage {
            role: "system",
            content: ChatContent::Text(system_prompt),
        });
        messages.extend(
            request
                .conversation
                .turns
                .iter()
                .enumerate()
                .map(|(index, turn)| {
                    let content = if Some(index) == latest_user_turn && !request.photos.is_empty() {
                        let mut parts = Vec::with_capacity(request.photos.len() + 1);
                        parts.push(ChatContentPart::Text {
                            text: turn.text.clone(),
                        });
                        parts.extend(request.photos.iter().map(|photo| {
                            ChatContentPart::ImageUrl {
                                image_url: ImageUrl {
                                    url: format!(
                                        "data:{};base64,{}",
                                        photo.mime_type.as_str(),
                                        base64::engine::general_purpose::STANDARD
                                            .encode(&photo.bytes)
                                    ),
                                },
                            }
                        }));
                        ChatContent::Parts(parts)
                    } else {
                        ChatContent::Text(turn.text.clone())
                    };
                    ChatMessage {
                        role: match turn.role {
                            ConversationRole::User => "user",
                            ConversationRole::Assistant => "assistant",
                        },
                        content,
                    }
                }),
        );
        let response_format = match mode {
            ResponseMode::JsonSchema => Some(json!({
                "type": "json_schema",
                "json_schema": { "name": "food_draft_response", "strict": true, "schema": schema }
            })),
            ResponseMode::JsonObject => Some(json!({ "type": "json_object" })),
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
    let choice = response.choices.into_iter().next().ok_or(())?;
    if choice.message.refusal.is_some() {
        return Err(());
    }
    let content = match choice.message.content.ok_or(())? {
        Value::String(content) if !content.is_empty() => content,
        _ => return Err(()),
    };
    Ok(ModelDraftResponse {
        content,
        usage: response.usage.map(|usage| ModelUsage {
            input_tokens: usage.prompt_tokens,
            output_tokens: usage.completion_tokens,
        }),
    })
}

fn explicitly_rejects_response_format(status: StatusCode, body: &[u8]) -> bool {
    if !(status == StatusCode::BAD_REQUEST || status == StatusCode::UNPROCESSABLE_ENTITY) {
        return false;
    }
    // Provider text is inspected only to make a bounded compatibility decision;
    // it is never retained, logged, or included in an error.
    let Ok(text) = std::str::from_utf8(body) else {
        return false;
    };
    let text = text.to_ascii_lowercase();
    text.contains("response_format")
        && (text.contains("unsupported")
            || text.contains("not supported")
            || text.contains("unknown")
            || text.contains("not available"))
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::convert::Infallible;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use axum::body::{Body, Bytes};
    use axum::extract::{OriginalUri, State};
    use axum::http::{HeaderMap as AxumHeaderMap, Response, StatusCode as AxumStatusCode, header};
    use axum::response::IntoResponse;
    use axum::routing::post;
    use axum::{Json, Router};
    use futures_util::stream;
    use serde_json::{Value, json};
    use tokio::sync::Mutex;

    use crate::assistant::application::{
        FoodDraftModelPort, FoodPhotoMimeType, ModelDraftRequest, SanitizedFoodPhoto,
    };
    use crate::assistant::domain::{Conversation, ConversationRole, ConversationTurn};
    use crate::config::{AiAuthenticationSettings, AiEnabledSettings};

    use super::{MAX_PROVIDER_RESPONSE_BYTES, OpenAiCompatibleFoodDraftModel};

    #[derive(Clone)]
    struct MockState {
        responses: Arc<Mutex<VecDeque<(AxumStatusCode, String, Duration)>>>,
        requests: Arc<Mutex<Vec<(Value, AxumHeaderMap, String)>>>,
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

    async fn mock_server(responses: Vec<(AxumStatusCode, &str)>) -> MockServer {
        let state = MockState {
            responses: Arc::new(Mutex::new(
                responses
                    .into_iter()
                    .map(|(status, body)| (status, body.to_owned(), Duration::ZERO))
                    .collect(),
            )),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new()
            .route("/configured/path", post(handler))
            .with_state(state.clone());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        MockServer {
            endpoint: format!("http://{address}/configured/path?provider=value")
                .parse()
                .unwrap(),
            state,
            task,
        }
    }

    async fn chunked_server(
        status: AxumStatusCode,
        prefix: &'static [u8],
    ) -> (url::Url, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
        let request_count = Arc::new(AtomicUsize::new(0));
        let route_count = request_count.clone();
        let app = Router::new().route(
            "/chunked",
            post(move |Json(_): Json<Value>| {
                let route_count = route_count.clone();
                async move {
                    route_count.fetch_add(1, Ordering::Relaxed);
                    let mut first = vec![b'x'; MAX_PROVIDER_RESPONSE_BYTES];
                    first[..prefix.len()].copy_from_slice(prefix);
                    let chunks = stream::iter([
                        Ok::<Bytes, Infallible>(Bytes::from(first)),
                        Ok(Bytes::from_static(b"x")),
                    ]);
                    Response::builder()
                        .status(status)
                        .body(Body::from_stream(chunks))
                        .unwrap()
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (
            format!("http://{address}/chunked").parse().unwrap(),
            request_count,
            task,
        )
    }

    async fn handler(
        State(state): State<MockState>,
        headers: AxumHeaderMap,
        uri: OriginalUri,
        Json(body): Json<Value>,
    ) -> impl IntoResponse {
        state
            .requests
            .lock()
            .await
            .push((body, headers, uri.0.to_string()));
        let (status, response, delay) = state.responses.lock().await.pop_front().unwrap();
        tokio::time::sleep(delay).await;
        (status, response)
    }

    fn successful_response() -> &'static str {
        r#"{"choices":[{"message":{"content":"{\"status\":\"needs_clarification\"}"}}],"usage":{"prompt_tokens":7,"completion_tokens":3}}"#
    }

    fn request() -> ModelDraftRequest {
        ModelDraftRequest {
            conversation: Conversation::new(vec![
                ConversationTurn::new(ConversationRole::User, "two cups of dal").unwrap(),
                ConversationTurn::new(ConversationRole::Assistant, "which lentil?").unwrap(),
            ])
            .unwrap(),
            photos: vec![],
            system_prompt: "SYSTEM PRIVATE INSTRUCTION".into(),
            response_schema: r#"{"type":"object","additionalProperties":false}"#.into(),
        }
    }

    fn settings(endpoint: url::Url, authentication: AiAuthenticationSettings) -> AiEnabledSettings {
        AiEnabledSettings {
            endpoint,
            model: "test-model".into(),
            supports_images: false,
            authentication,
        }
    }

    #[tokio::test]
    async fn encodes_text_conversation_schema_and_usage_without_auth() {
        let server = mock_server(vec![(AxumStatusCode::OK, successful_response())]).await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();

        let response = model.generate(request()).await.unwrap();

        assert_eq!(response.content, r#"{"status":"needs_clarification"}"#);
        let usage = response.usage.unwrap();
        assert_eq!(usage.input_tokens, Some(7));
        assert_eq!(usage.output_tokens, Some(3));
        let requests = server.state.requests.lock().await;
        let (body, headers, _) = &requests[0];
        assert_eq!(body["model"], "test-model");
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["content"], "two cups of dal");
        assert_eq!(body["messages"][2]["role"], "assistant");
        assert_eq!(body["response_format"]["type"], "json_schema");
        assert!(headers.get("authorization").is_none());
        assert_eq!(requests[0].2, "/configured/path?provider=value");
    }

    #[tokio::test]
    async fn encodes_each_sanitized_photo_as_an_openai_image_url_content_part() {
        let server = mock_server(vec![(AxumStatusCode::OK, successful_response())]).await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();
        let mut multimodal = request();
        multimodal.photos = vec![
            SanitizedFoodPhoto {
                mime_type: FoodPhotoMimeType::Jpeg,
                bytes: vec![1, 2, 3],
            },
            SanitizedFoodPhoto {
                mime_type: FoodPhotoMimeType::Webp,
                bytes: vec![4, 5],
            },
        ];

        model.generate(multimodal).await.unwrap();

        let requests = server.state.requests.lock().await;
        let parts = requests[0].0["messages"][1]["content"].as_array().unwrap();
        assert_eq!(parts.len(), 3);
        assert_eq!(
            parts[0],
            json!({ "type": "text", "text": "two cups of dal" })
        );
        assert_eq!(parts[1]["image_url"]["url"], "data:image/jpeg;base64,AQID");
        assert_eq!(parts[2]["image_url"]["url"], "data:image/webp;base64,BAU=");
        assert_eq!(requests[0].0["messages"][2]["content"], "which lentil?");
    }

    #[tokio::test]
    async fn applies_bearer_and_custom_authentication_headers() {
        for (authentication, header, expected) in [
            (
                auth_file(true, None),
                "authorization",
                "Bearer secret-for-test",
            ),
            (
                auth_file(false, Some("x-provider-key")),
                "x-provider-key",
                "secret-for-test",
            ),
        ] {
            let server = mock_server(vec![(AxumStatusCode::OK, successful_response())]).await;
            let model = OpenAiCompatibleFoodDraftModel::new(&settings(
                server.endpoint.clone(),
                authentication.clone(),
            ))
            .unwrap();
            remove_auth_file(&authentication);
            model.generate(request()).await.unwrap();
            let requests = server.state.requests.lock().await;
            assert_eq!(requests[0].1.get(header).unwrap(), expected);
        }
    }

    #[tokio::test]
    async fn falls_back_only_after_explicit_unsupported_format_and_caches_result() {
        let unsupported = r#"{"error":{"message":"response_format is not supported"}}"#;
        let server = mock_server(vec![
            (AxumStatusCode::BAD_REQUEST, unsupported),
            (AxumStatusCode::UNPROCESSABLE_ENTITY, unsupported),
            (AxumStatusCode::OK, successful_response()),
            (AxumStatusCode::OK, successful_response()),
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
        assert_eq!(requests.len(), 4);
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
        assert!(
            requests[1].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains(r#""additionalProperties":false"#)
        );
        assert!(requests[2].0.get("response_format").is_none());
        assert!(
            requests[2].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains("Return only one JSON")
        );
        assert!(
            requests[2].0["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains(r#""additionalProperties":false"#)
        );
        assert!(requests[3].0.get("response_format").is_none());
    }

    #[tokio::test]
    async fn caches_json_object_when_that_fallback_succeeds() {
        let unsupported = r#"{"error":{"message":"response_format json_schema is unsupported"}}"#;
        let server = mock_server(vec![
            (AxumStatusCode::BAD_REQUEST, unsupported),
            (AxumStatusCode::OK, successful_response()),
            (AxumStatusCode::OK, successful_response()),
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
        assert_eq!(requests.len(), 3);
        assert_eq!(requests[0].0["response_format"]["type"], "json_schema");
        assert_eq!(requests[1].0["response_format"]["type"], "json_object");
        assert_eq!(requests[2].0["response_format"]["type"], "json_object");
    }

    #[tokio::test]
    async fn does_not_retry_provider_failures_or_bad_content_and_redacts_them() {
        for (status, body, expected) in [
            (
                AxumStatusCode::INTERNAL_SERVER_ERROR,
                "PRIVATE_PROVIDER_RESPONSE",
                "assistant model is unavailable",
            ),
            (
                AxumStatusCode::BAD_REQUEST,
                "ordinary invalid request",
                "assistant model is unavailable",
            ),
            (
                AxumStatusCode::OK,
                "not json",
                "assistant model returned an invalid response",
            ),
            (
                AxumStatusCode::OK,
                r#"{"choices":[]}"#,
                "assistant model returned an invalid response",
            ),
            (
                AxumStatusCode::OK,
                r#"{"choices":[{"message":{}}]}"#,
                "assistant model returned an invalid response",
            ),
            (
                AxumStatusCode::OK,
                r#"{"choices":[{"message":{"content":[]}}]}"#,
                "assistant model returned an invalid response",
            ),
            (
                AxumStatusCode::OK,
                r#"{"choices":[{"message":{"refusal":"no"}}]}"#,
                "assistant model returned an invalid response",
            ),
        ] {
            let server = mock_server(vec![(status, body)]).await;
            let model = OpenAiCompatibleFoodDraftModel::new(&settings(
                server.endpoint.clone(),
                AiAuthenticationSettings::None,
            ))
            .unwrap();
            let error = model.generate(request()).await.unwrap_err();
            assert_eq!(error.to_string(), expected);
            assert!(!format!("{error:?}").contains("PRIVATE_PROVIDER_RESPONSE"));
            assert_eq!(server.state.requests.lock().await.len(), 1);
        }
    }

    #[tokio::test]
    async fn rejects_oversized_success_with_content_length_without_retrying() {
        let oversized = "x".repeat(MAX_PROVIDER_RESPONSE_BYTES + 1);
        let server = mock_server(vec![(AxumStatusCode::OK, &oversized)]).await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            server.endpoint.clone(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();

        assert!(matches!(
            model.generate(request()).await,
            Err(crate::assistant::domain::AssistantError::InvalidModelResponse)
        ));
        assert_eq!(server.state.requests.lock().await.len(), 1);
    }

    #[tokio::test]
    async fn rejects_oversized_chunked_error_without_fallback_or_retry() {
        let (endpoint, request_count, task) = chunked_server(
            AxumStatusCode::BAD_REQUEST,
            br#"{"error":{"message":"response_format unsupported"}}"#,
        )
        .await;
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            endpoint,
            AiAuthenticationSettings::None,
        ))
        .unwrap();

        assert!(matches!(
            model.generate(request()).await,
            Err(crate::assistant::domain::AssistantError::ModelUnavailable)
        ));
        assert_eq!(request_count.load(Ordering::Relaxed), 1);
        task.abort();
    }

    #[tokio::test]
    async fn maps_timeout_and_connection_errors_without_endpoint_or_prompt() {
        let server = mock_server(vec![(AxumStatusCode::OK, successful_response())]).await;
        server.state.responses.lock().await[0].2 = Duration::from_millis(100);
        let model = OpenAiCompatibleFoodDraftModel::with_timeouts(
            &settings(server.endpoint.clone(), AiAuthenticationSettings::None),
            Duration::from_millis(50),
            Duration::from_millis(20),
        )
        .unwrap();
        let error = model.generate(request()).await.unwrap_err();
        assert_eq!(error.to_string(), "assistant model is unavailable");
        assert!(!format!("{error:?}").contains("SYSTEM PRIVATE INSTRUCTION"));

        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            "http://127.0.0.1:1/unreachable".parse().unwrap(),
            AiAuthenticationSettings::None,
        ))
        .unwrap();
        assert!(matches!(
            model.generate(request()).await,
            Err(crate::assistant::domain::AssistantError::ModelUnavailable)
        ));
    }

    #[tokio::test]
    async fn does_not_follow_redirects_that_could_forward_authentication() {
        let target_headers = Arc::new(Mutex::new(Vec::new()));
        let target_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target_address = target_listener.local_addr().unwrap();
        let target_headers_for_route = target_headers.clone();
        let target = Router::new().route(
            "/target",
            post(move |headers: AxumHeaderMap| {
                let target_headers = target_headers_for_route.clone();
                async move {
                    target_headers.lock().await.push(headers);
                    (AxumStatusCode::OK, successful_response())
                }
            }),
        );
        let target_task = tokio::spawn(async move {
            axum::serve(target_listener, target).await.unwrap();
        });

        let redirect_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let redirect_address = redirect_listener.local_addr().unwrap();
        let target_location = format!("http://{target_address}/target");
        let redirect = Router::new().route(
            "/redirect",
            post(move || {
                let target_location = target_location.clone();
                async move {
                    (
                        AxumStatusCode::TEMPORARY_REDIRECT,
                        [(header::LOCATION, target_location)],
                    )
                }
            }),
        );
        let redirect_task = tokio::spawn(async move {
            axum::serve(redirect_listener, redirect).await.unwrap();
        });
        let authentication = auth_file(true, None);
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            format!("http://{redirect_address}/redirect")
                .parse()
                .unwrap(),
            authentication.clone(),
        ))
        .unwrap();
        remove_auth_file(&authentication);

        assert!(matches!(
            model.generate(request()).await,
            Err(crate::assistant::domain::AssistantError::ModelUnavailable)
        ));
        assert!(target_headers.lock().await.is_empty());
        target_task.abort();
        redirect_task.abort();
    }

    #[test]
    fn adapter_debug_redacts_endpoint_model_and_api_key() {
        let authentication = auth_file(true, None);
        let model = OpenAiCompatibleFoodDraftModel::new(&settings(
            "http://127.0.0.1:1/provider?private=query-value"
                .parse()
                .unwrap(),
            authentication.clone(),
        ))
        .unwrap();
        remove_auth_file(&authentication);

        let debug = format!("{model:?}");
        assert!(!debug.contains("secret-for-test"));
        assert!(!debug.contains("query-value"));
        assert!(!debug.contains("test-model"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn invalid_secret_header_maps_to_a_sanitized_error() {
        let path =
            std::env::temp_dir().join(format!("calco-provider-key-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, "PRIVATE_KEY\nHEADER_INJECTION").unwrap();
        let authentication = AiAuthenticationSettings::Bearer { api_key_file: path };

        let error = OpenAiCompatibleFoodDraftModel::new(&settings(
            "http://127.0.0.1:1/provider".parse().unwrap(),
            authentication.clone(),
        ))
        .unwrap_err();
        remove_auth_file(&authentication);

        assert_eq!(error.to_string(), "assistant operation failed");
        let debug = format!("{error:?}");
        assert!(!debug.contains("PRIVATE_KEY"));
        assert!(!debug.contains("HEADER_INJECTION"));
    }

    fn auth_file(bearer: bool, header: Option<&str>) -> AiAuthenticationSettings {
        let path =
            std::env::temp_dir().join(format!("calco-provider-key-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, "secret-for-test\n").unwrap();
        match (bearer, header) {
            (true, _) => AiAuthenticationSettings::Bearer { api_key_file: path },
            (false, Some(header_name)) => AiAuthenticationSettings::Header {
                header_name: header_name.parse().unwrap(),
                api_key_file: path,
            },
            _ => unreachable!(),
        }
    }

    fn remove_auth_file(authentication: &AiAuthenticationSettings) {
        let path = match authentication {
            AiAuthenticationSettings::None => return,
            AiAuthenticationSettings::Bearer { api_key_file }
            | AiAuthenticationSettings::Header { api_key_file, .. } => api_key_file,
        };
        std::fs::remove_file(path).unwrap();
    }
}

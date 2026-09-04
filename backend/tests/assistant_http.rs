mod common;

use std::sync::Arc;

use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use calco_backend::assistant::application::{
    FoodDraftModelPort, FoodDraftPort, FoodDraftResult, FoodDraftService, ModelDraftRequest,
    ModelDraftResponse, ModelUsage,
};
use calco_backend::assistant::domain::{AssistantError, Conversation, FoodDraftTurn};
use calco_backend::assistant::infrastructure::NutritionCatalogVocabularyAdapter;
use calco_backend::assistant::module::AssistantModule;
use calco_backend::{build_app_state, build_router_from_state};
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

#[derive(Clone)]
struct FakeDraftService {
    result: Result<FoodDraftResult, AssistantError>,
}

struct FakeModel {
    response: ModelDraftResponse,
}

#[async_trait]
impl FoodDraftModelPort for FakeModel {
    async fn generate(
        &self,
        _request: ModelDraftRequest,
    ) -> Result<ModelDraftResponse, AssistantError> {
        Ok(self.response.clone())
    }
}

#[async_trait]
impl FoodDraftPort for FakeDraftService {
    async fn draft(&self, _conversation: Conversation) -> Result<FoodDraftResult, AssistantError> {
        self.result.clone()
    }
}

fn fake_assistant(result: Result<FoodDraftResult, AssistantError>) -> AssistantModule {
    AssistantModule::from_service(Arc::new(FakeDraftService { result }))
}

async fn app_with_assistant(pool: PgPool, assistant: AssistantModule) -> axum::Router {
    let mut state = build_app_state(pool, test_config()).await.unwrap();
    state.assistant = assistant;
    build_router_from_state(state)
}

async fn app_with_model_response(pool: PgPool, content: &str) -> axum::Router {
    let mut state = build_app_state(pool, test_config()).await.unwrap();
    let model = Arc::new(FakeModel {
        response: ModelDraftResponse {
            content: content.to_owned(),
            usage: None,
        },
    });
    let vocabulary = Arc::new(NutritionCatalogVocabularyAdapter::new(
        state.nutrition.catalog.services.clone(),
    ));
    state.assistant =
        AssistantModule::from_service(Arc::new(FoodDraftService::new(model, vocabulary)));
    build_router_from_state(state)
}

fn conversation() -> Value {
    json!({"turns": [{"role": "user", "text": "one bowl of dal"}]})
}

fn multipart_request(
    uri: &str,
    cookie: Option<&str>,
    fields: &[(&str, Option<&str>, &[u8])],
) -> Request<Body> {
    let boundary = "calco-assistant-test-boundary";
    let mut body = Vec::new();
    for (name, filename, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        let filename = filename
            .map(|value| format!("; filename=\"{value}\""))
            .unwrap_or_default();
        body.extend_from_slice(
            format!("Content-Disposition: form-data; name=\"{name}\"{filename}\r\n\r\n").as_bytes(),
        );
        body.extend_from_slice(value);
        body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    let mut request = Request::builder().method(Method::POST).uri(uri).header(
        header::CONTENT_TYPE,
        format!("multipart/form-data; boundary={boundary}"),
    );
    if let Some(cookie) = cookie {
        request = request.header(header::COOKIE, cookie);
    }
    request.body(Body::from(body)).unwrap()
}

fn draft_request(cookie: Option<&str>) -> Request<Body> {
    let conversation = serde_json::to_vec(&conversation()).unwrap();
    multipart_request(
        "/api/ai/custom-food/draft",
        cookie,
        &[("conversation", None, &conversation)],
    )
}

#[sqlx::test]
async fn routes_require_user_auth_and_expose_text_only_status(pool: PgPool) {
    let router = app_with_assistant(
        pool,
        fake_assistant(Ok(FoodDraftResult {
            turn: FoodDraftTurn::clarification("How many grams?").unwrap(),
            usage: Some(ModelUsage {
                input_tokens: Some(8),
                output_tokens: Some(3),
            }),
        })),
    )
    .await;

    let request = empty_request(Method::GET, "/api/ai/food-assistant/status", None);
    let (status, _, _) = send(&router, request).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (admin, user) = bootstrap_and_user(&router).await;
    let request = empty_request(Method::GET, "/api/ai/food-assistant/status", Some(&admin));
    let (status, _, _) = send(&router, request).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let status: Value = get_json(&router, "/api/ai/food-assistant/status", &user).await;
    assert_eq!(status, json!({"enabled": true, "supports_images": false}));

    let (status, _, bytes) = send(&router, draft_request(Some(&user))).await;
    assert_eq!(status, StatusCode::OK);
    let response: Value = parse_json(&bytes);
    assert_eq!(response["status"], "needs_clarification");
    assert_eq!(response["assistant_message"], "How many grams?");

    let foods: Value = get_json(&router, "/api/foods/custom", &user).await;
    assert_eq!(foods["items"], json!([]));
}

#[sqlx::test]
async fn disabled_malformed_and_provider_failures_are_safe(pool: PgPool) {
    let disabled = app_with_assistant(pool.clone(), AssistantModule::disabled()).await;
    let (_, user) = bootstrap_and_user(&disabled).await;
    let status: Value = get_json(&disabled, "/api/ai/food-assistant/status", &user).await;
    assert_eq!(status, json!({"enabled": false, "supports_images": false}));
    let request = draft_request(Some(&user));
    let (status, _, bytes) = send(&disabled, request).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        parse_json::<Value>(&bytes)["error"]["code"],
        "assistant_disabled"
    );

    let failing =
        app_with_assistant(pool, fake_assistant(Err(AssistantError::ModelUnavailable))).await;
    let bad_conversation = serde_json::to_vec(&json!({
        "turns": [{"role": "user", "text": "dal", "image": "not-allowed"}]
    }))
    .unwrap();
    let request = multipart_request(
        "/api/ai/custom-food/draft",
        Some(&user),
        &[("conversation", None, &bad_conversation)],
    );
    let (status, _, bytes) = send(&failing, request).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        parse_json::<Value>(&bytes)["error"]["code"],
        "invalid_request"
    );

    let request = draft_request(Some(&user));
    let (status, _, bytes) = send(&failing, request).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("provider_unavailable"));
    assert!(!text.contains("endpoint"));
    assert!(!text.contains("model"));
}

#[sqlx::test]
async fn multipart_limits_and_text_only_boundary_are_enforced(pool: PgPool) {
    let router = app_with_assistant(
        pool,
        fake_assistant(Ok(FoodDraftResult {
            turn: FoodDraftTurn::clarification("How much?").unwrap(),
            usage: None,
        })),
    )
    .await;
    let (_, user) = bootstrap_and_user(&router).await;

    let oversized = vec![b'x'; 96 * 1024 + 1];
    let request = multipart_request(
        "/api/ai/custom-food/draft",
        Some(&user),
        &[("conversation", None, &oversized)],
    );
    let (status, _, bytes) = send(&router, request).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(
        parse_json::<Value>(&bytes)["error"]["code"],
        "payload_too_large"
    );

    let valid = serde_json::to_vec(&conversation()).unwrap();
    for fields in [
        vec![("photos", Some("food.jpg"), b"photo".as_slice())],
        vec![("unknown", None, valid.as_slice())],
    ] {
        let request = multipart_request("/api/ai/custom-food/draft", Some(&user), &fields);
        let (status, _, bytes) = send(&router, request).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(
            parse_json::<Value>(&bytes)["error"]["code"],
            "invalid_request"
        );
    }
}

#[sqlx::test]
async fn model_draft_uses_real_catalog_vocabulary_and_is_submittable(pool: PgPool) {
    let response = r#"{
        "assistant_message":"Review this estimate.",
        "status":"draft_ready",
        "draft":{
            "name":"Dal",
            "brand":null,
            "categories":["lentils"],
            "serving_size_g":240,
            "default_quantity":1,
            "default_unit":"g",
            "nutrients":[
                {"code":"ENERGY_KCAL","amount_per_100g":120},
                {"code":"PROTEIN_G","amount_per_100g":7},
                {"code":"CARBS_G","amount_per_100g":20},
                {"code":"FAT_G","amount_per_100g":2}
            ],
            "servings":[{"label":"one cup","quantity":1,"unit":"cup","grams":240}]
        },
        "warnings":["Estimated values"]
    }"#;
    let router = app_with_model_response(pool, response).await;
    let (_, user) = bootstrap_and_user(&router).await;

    let (status, _, bytes) = send(&router, draft_request(Some(&user))).await;
    assert_eq!(status, StatusCode::OK);
    let assistant_response: Value = parse_json(&bytes);
    assert_eq!(assistant_response["status"], "draft_ready");
    assert_eq!(assistant_response["draft"]["default_unit"], "g");
    assert_eq!(assistant_response["draft"]["servings"][0]["unit"], "cup");

    let created: Value = post_json(
        &router,
        "/api/foods/custom",
        &user,
        &assistant_response["draft"],
        StatusCode::CREATED,
    )
    .await;
    let id = created["id"]
        .as_str()
        .expect("custom-food creation returns its persisted id");
    let detail_uri = format!("/api/foods/{id}");
    let persisted: Value = get_json(&router, &detail_uri, &user).await;
    assert_eq!(persisted["id"], id);
    assert_eq!(persisted["name"], "Dal");
    assert_eq!(persisted["default_unit"], "g");
    assert_eq!(persisted["servings"][0]["unit"], "cup");
}

#[sqlx::test]
async fn per_user_rate_limit_returns_retry_after(pool: PgPool) {
    let router = app_with_assistant(
        pool,
        fake_assistant(Ok(FoodDraftResult {
            turn: FoodDraftTurn::clarification("How much?").unwrap(),
            usage: None,
        })),
    )
    .await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let malformed_user = create_user_session(&router, &admin, "malformed", "testpassword").await;

    for _ in 0..10 {
        let request = draft_request(Some(&user));
        let (status, _, _) = send(&router, request).await;
        assert_eq!(status, StatusCode::OK);
    }
    let request = draft_request(Some(&user));
    let (status, headers, bytes) = send(&router, request).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert!(headers.contains_key(header::RETRY_AFTER));
    assert_eq!(parse_json::<Value>(&bytes)["error"]["code"], "rate_limited");

    let non_json = Request::builder()
        .method(Method::POST)
        .uri("/api/ai/custom-food/draft")
        .header(header::COOKIE, malformed_user)
        .header(header::CONTENT_TYPE, "text/plain")
        .body(Body::from("not json"))
        .unwrap();
    let (status, _, _) = send(&router, non_json).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

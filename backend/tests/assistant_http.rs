mod common;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use calco_backend::assistant::application::{FoodDraftPort, FoodDraftRequest};
use calco_backend::assistant::domain::{
    AssistantError, DraftNutrient, DraftStatus, FoodDraft, FoodDraftTurn,
};
use calco_backend::assistant::module::AssistantModule;
use calco_backend::config::{AiAuthenticationSettings, AiEnabledSettings, AiRuntimeSettings};
use calco_backend::{build_app_state, build_router_with_state};
use common::*;
use rust_decimal::Decimal;
use serde_json::{Value, json};
use sqlx::PgPool;

struct ScriptedFoodDraftPort {
    responses: Mutex<VecDeque<Result<FoodDraftTurn, AssistantError>>>,
}

impl ScriptedFoodDraftPort {
    fn new(responses: impl IntoIterator<Item = Result<FoodDraftTurn, AssistantError>>) -> Self {
        Self {
            responses: Mutex::new(responses.into_iter().collect()),
        }
    }
}

#[async_trait]
impl FoodDraftPort for ScriptedFoodDraftPort {
    async fn draft(&self, _request: FoodDraftRequest) -> Result<FoodDraftTurn, AssistantError> {
        self.responses
            .lock()
            .expect("scripted-port mutex poisoned")
            .pop_front()
            .expect("unexpected food-draft request")
    }
}

fn multipart_request(cookie: Option<&str>, fields: &[(&str, String)]) -> Request<Body> {
    const BOUNDARY: &str = "calco-assistant-test-boundary";
    let mut body = String::new();
    for (name, value) in fields {
        body.push_str(&format!(
            "--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
        ));
    }
    body.push_str(&format!("--{BOUNDARY}--\r\n"));

    let mut builder = Request::builder()
        .method(Method::POST)
        .uri("/api/ai/custom-food/draft")
        .header(
            header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={BOUNDARY}"),
        );
    if let Some(cookie) = cookie {
        builder = builder.header(header::COOKIE, cookie);
    }
    builder
        .body(Body::from(body))
        .expect("build multipart request")
}

fn conversation() -> String {
    json!({
        "turns": [{ "role": "user", "text": "one bowl of dal rice" }]
    })
    .to_string()
}

fn ready_turn() -> FoodDraftTurn {
    let draft = FoodDraft::new(
        "Dal rice",
        None,
        vec!["rice dishes".into()],
        Some(Decimal::from(300)),
        Some(Decimal::ONE),
        Some("serving".into()),
        vec![
            DraftNutrient::new("ENERGY_KCAL", Decimal::from(150)).unwrap(),
            DraftNutrient::new("PROTEIN_G", Decimal::from(5)).unwrap(),
            DraftNutrient::new("CARBS_G", Decimal::from(25)).unwrap(),
            DraftNutrient::new("FAT_G", Decimal::from(3)).unwrap(),
        ],
        vec![],
    )
    .unwrap();
    FoodDraftTurn::new(
        "Here is an estimated draft.",
        DraftStatus::DraftReady,
        Some(draft),
        vec!["Review the estimate before creating the food.".into()],
    )
    .unwrap()
}

async fn app_with_port(pool: PgPool, port: Arc<dyn FoodDraftPort>) -> Router {
    let config = test_config();
    let mut state = build_app_state(pool, config.clone())
        .await
        .expect("build test app state");
    state.assistant = AssistantModule::enabled_with_port(port);
    build_router_with_state(state, &config.environment)
}

fn assert_error(body: &[u8], code: &str) {
    let value: Value = serde_json::from_slice(body).expect("error response is JSON");
    assert_eq!(value["error"]["code"], code, "body: {value}");
}

#[sqlx::test]
async fn assistant_http_is_authenticated_text_only_and_never_creates_products(pool: PgPool) {
    let disabled_router = app(pool.clone()).await;

    let (status, _, body) = send(
        &disabled_router,
        empty_request(Method::GET, "/api/ai/food-assistant/status", None),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_error(&body, "unauthorized");

    let (status, _, body) = send(
        &disabled_router,
        multipart_request(None, &[("conversation", conversation())]),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_error(&body, "unauthorized");

    let (_admin, user) = bootstrap_and_user(&disabled_router).await;
    let (status, _, body) = send(
        &disabled_router,
        empty_request(Method::GET, "/api/ai/food-assistant/status", Some(&user)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let status_body: Value = parse_json(&body);
    assert_eq!(
        status_body,
        json!({ "enabled": false, "supports_images": false })
    );

    let (status, _, body) = send(
        &disabled_router,
        multipart_request(Some(&user), &[("conversation", conversation())]),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_error(&body, "assistant_disabled");

    for fields in [
        vec![],
        vec![("conversation", "{".to_owned())],
        vec![("unexpected", conversation())],
        vec![("photos", "not-an-image".to_owned())],
    ] {
        let (status, _, body) =
            send(&disabled_router, multipart_request(Some(&user), &fields)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "body: {body:?}");
        assert_error(&body, "validation");
    }

    let too_large = "x".repeat(320 * 1024 + 1);
    let (status, _, body) = send(
        &disabled_router,
        multipart_request(Some(&user), &[("conversation", too_large)]),
    )
    .await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "body: {body:?}");
    assert_error(&body, "payload_too_large");

    let scripted_port: Arc<dyn FoodDraftPort> = Arc::new(ScriptedFoodDraftPort::new([
        Ok(ready_turn()),
        Err(AssistantError::ModelUnavailable),
        Err(AssistantError::InvalidModelResponse),
        Err(AssistantError::Internal),
    ]));
    let enabled_router = app_with_port(pool.clone(), scripted_port).await;

    let (status, _, body) = send(
        &enabled_router,
        empty_request(Method::GET, "/api/ai/food-assistant/status", Some(&user)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        parse_json::<Value>(&body),
        json!({ "enabled": true, "supports_images": false })
    );

    let products_before: i64 = sqlx::query_scalar("SELECT count(*) FROM products")
        .fetch_one(&pool)
        .await
        .unwrap();
    let (status, _, body) = send(
        &enabled_router,
        multipart_request(Some(&user), &[("conversation", conversation())]),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "body: {body:?}");
    let draft: Value = parse_json(&body);
    assert_eq!(draft["status"], "draft_ready");
    assert_eq!(draft["draft"]["name"], "Dal rice");
    assert_eq!(draft["draft"]["nutrients"][0]["code"], "ENERGY_KCAL");
    let products_after: i64 = sqlx::query_scalar("SELECT count(*) FROM products")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(products_after, products_before);

    for (expected_status, expected_code) in [
        (StatusCode::SERVICE_UNAVAILABLE, "model_unavailable"),
        (StatusCode::BAD_GATEWAY, "invalid_model_response"),
        (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
    ] {
        let (status, _, body) = send(
            &enabled_router,
            multipart_request(Some(&user), &[("conversation", conversation())]),
        )
        .await;
        assert_eq!(status, expected_status, "body: {body:?}");
        assert_error(&body, expected_code);
    }
}

#[sqlx::test]
async fn configured_image_capability_is_not_advertised_before_slice_nine(pool: PgPool) {
    let mut config = test_config();
    config.ai = AiRuntimeSettings::Enabled(AiEnabledSettings {
        endpoint: "http://127.0.0.1:9/v1/chat/completions".parse().unwrap(),
        model: "configured-vision-model".into(),
        supports_images: true,
        authentication: AiAuthenticationSettings::None,
    });

    let state = build_app_state(pool, config).await.unwrap();
    assert!(state.assistant.status.enabled);
    assert!(!state.assistant.status.supports_images);
}

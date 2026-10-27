use std::io::Cursor;
use std::sync::{Arc, Mutex};

use crate::common::*;
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use calco_backend::assistant::app::{
    AssistantError, FoodDraftAcceptancePort, FoodDraftModel, FoodDraftModelRequest,
    FoodDraftResult, FoodDraftService, FoodVocabulary, FoodVocabularyPort, ModelUsage,
};
use calco_backend::assistant::composition::AssistantComponents;
use calco_backend::assistant::domain::{
    DraftNutrient, DraftServing, FoodDraft, FoodDraftBuilder, FoodDraftTurn,
};
use calco_backend::assistant::infra::{CatalogVocabularyAdapter, SafeImageSanitizer};
use calco_backend::{build_app_state, build_router_from_state};
use serde_json::{Value, json};
use sqlx::PgPool;

struct FakeModel {
    result: Result<FoodDraftResult, AssistantError>,
    observed_vocabulary: Option<Arc<Mutex<Option<FoodVocabulary>>>>,
}

struct FakeVocabulary;

#[async_trait]
impl FoodDraftModel for FakeModel {
    async fn generate(
        &self,
        _request: &FoodDraftModelRequest,
        vocabulary: &FoodVocabulary,
    ) -> Result<FoodDraftResult, AssistantError> {
        if let Some(observed) = &self.observed_vocabulary {
            *observed.lock().unwrap() = Some(vocabulary.clone());
        }
        self.result.clone()
    }
}

fn fake_assistant_with_images(
    result: Result<FoodDraftResult, AssistantError>,
) -> AssistantComponents {
    AssistantComponents::from_food_draft_service(Arc::new(FoodDraftService::new(
        Arc::new(FakeModel {
            result,
            observed_vocabulary: None,
        }),
        Arc::new(FakeVocabulary),
        Arc::new(FakeVocabulary),
        Some(Arc::new(SafeImageSanitizer::new())),
    )))
}

#[async_trait]
impl FoodVocabularyPort for FakeVocabulary {
    async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError> {
        Ok(FoodVocabulary::default())
    }
}

#[async_trait]
impl FoodDraftAcceptancePort for FakeVocabulary {
    async fn validate_draft(&self, _draft: &FoodDraft) -> Result<(), AssistantError> {
        Ok(())
    }
}

fn fake_assistant(result: Result<FoodDraftResult, AssistantError>) -> AssistantComponents {
    AssistantComponents::from_food_draft_service(Arc::new(FoodDraftService::new(
        Arc::new(FakeModel {
            result,
            observed_vocabulary: None,
        }),
        Arc::new(FakeVocabulary),
        Arc::new(FakeVocabulary),
        None,
    )))
}

async fn app_with_assistant(pool: PgPool, assistant: AssistantComponents) -> axum::Router {
    let mut state = build_app_state(pool, test_config()).await.unwrap();
    state.assistant = assistant;
    build_router_from_state(state)
}

async fn app_with_model_result_and_real_vocabulary(
    pool: PgPool,
    result: FoodDraftResult,
) -> (axum::Router, Arc<Mutex<Option<FoodVocabulary>>>) {
    let mut state = build_app_state(pool, test_config()).await.unwrap();
    let observed_vocabulary = Arc::new(Mutex::new(None));
    let model = Arc::new(FakeModel {
        result: Ok(result),
        observed_vocabulary: Some(observed_vocabulary.clone()),
    });
    let vocabulary = Arc::new(CatalogVocabularyAdapter::new(
        state.nutrition.catalog.services.clone(),
    ));
    state.assistant = AssistantComponents::from_food_draft_service(Arc::new(
        FoodDraftService::new(model, vocabulary.clone(), vocabulary, None),
    ));
    (build_router_from_state(state), observed_vocabulary)
}

fn conversation() -> Value {
    json!({"turns": [{"role": "user", "text": "one bowl of dal"}]})
}

fn multipart_request(
    uri: &str,
    cookie: Option<&str>,
    fields: &[(&str, Option<(&str, &str)>, &[u8])],
) -> Request<Body> {
    let boundary = "calco-assistant-test-boundary";
    let mut body = Vec::new();
    for (name, file, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        let filename = file
            .map(|(filename, _)| format!("; filename=\"{filename}\""))
            .unwrap_or_default();
        body.extend_from_slice(
            format!("Content-Disposition: form-data; name=\"{name}\"{filename}\r\n").as_bytes(),
        );
        if let Some((_, mime_type)) = file {
            body.extend_from_slice(format!("Content-Type: {mime_type}\r\n").as_bytes());
        }
        body.extend_from_slice(b"\r\n");
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
    let disabled = app_with_assistant(pool.clone(), AssistantComponents::disabled()).await;
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
        "invalid_conversation"
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
        "conversation_too_large"
    );

    let valid = serde_json::to_vec(&conversation()).unwrap();
    for (fields, expected_code) in [
        (
            vec![(
                "photos",
                Some(("food.jpg", "image/jpeg")),
                b"photo".as_slice(),
            )],
            "photos_not_supported",
        ),
        (
            vec![("unknown", None, valid.as_slice())],
            "unexpected_field",
        ),
    ] {
        let request = multipart_request("/api/ai/custom-food/draft", Some(&user), &fields);
        let (status, _, bytes) = send(&router, request).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(parse_json::<Value>(&bytes)["error"]["code"], expected_code);
    }
}

#[sqlx::test]
async fn valid_photo_is_sanitized_and_reaches_the_model(pool: PgPool) {
    struct ImageObservingModel(Arc<Mutex<Vec<(usize, &'static str)>>>);

    #[async_trait]
    impl FoodDraftModel for ImageObservingModel {
        async fn generate(
            &self,
            request: &FoodDraftModelRequest,
            _vocabulary: &FoodVocabulary,
        ) -> Result<FoodDraftResult, AssistantError> {
            *self.0.lock().unwrap() = request
                .turns
                .iter()
                .flat_map(|turn| &turn.photos)
                .map(|photo| (photo.bytes.len(), photo.mime_type.as_str()))
                .collect();
            Ok(FoodDraftResult {
                turn: FoodDraftTurn::clarification("How large was the serving?").unwrap(),
                usage: None,
            })
        }
    }

    let observed = Arc::new(Mutex::new(vec![]));
    let service = Arc::new(FoodDraftService::new(
        Arc::new(ImageObservingModel(observed.clone())),
        Arc::new(FakeVocabulary),
        Arc::new(FakeVocabulary),
        Some(Arc::new(SafeImageSanitizer::new())),
    ));
    let router =
        app_with_assistant(pool, AssistantComponents::from_food_draft_service(service)).await;
    let (_, user) = bootstrap_and_user(&router).await;
    let status: Value = get_json(&router, "/api/ai/food-assistant/status", &user).await;
    assert_eq!(status, json!({"enabled": true, "supports_images": true}));
    let conversation = serde_json::to_vec(&conversation()).unwrap();
    let image = image::ImageBuffer::from_pixel(2, 3, image::Rgba([20, 30, 40, 255]));
    let mut png = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let png = png.into_inner();
    let request = multipart_request(
        "/api/ai/custom-food/draft",
        Some(&user),
        &[
            ("conversation", None, &conversation),
            ("photos", Some(("food.png", "image/png")), &png),
        ],
    );
    let (status, _, bytes) = send(&router, request).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "body: {}",
        String::from_utf8_lossy(&bytes)
    );
    let observed = observed.lock().unwrap();
    assert_eq!(observed.len(), 1);
    assert_eq!(observed[0].1, "image/png");
    assert!(observed[0].0 > 0);
}

#[sqlx::test]
async fn image_transport_rejects_invalid_and_excess_photos(pool: PgPool) {
    let router = app_with_assistant(
        pool,
        fake_assistant_with_images(Ok(FoodDraftResult {
            turn: FoodDraftTurn::clarification("How much?").unwrap(),
            usage: None,
        })),
    )
    .await;
    let (_, user) = bootstrap_and_user(&router).await;
    let conversation = serde_json::to_vec(&conversation()).unwrap();
    let fake_png = b"not a png".as_slice();
    let image = image::ImageBuffer::from_pixel(2, 3, image::Rgba([20, 30, 40, 255]));
    let mut valid_png = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image)
        .write_to(&mut valid_png, image::ImageFormat::Png)
        .unwrap();
    let valid_png = valid_png.into_inner();

    let invalid = multipart_request(
        "/api/ai/custom-food/draft",
        Some(&user),
        &[
            ("conversation", None, &conversation),
            ("photos", Some(("food.png", "image/png")), fake_png),
        ],
    );
    let (status, _, bytes) = send(&router, invalid).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let response: Value = parse_json(&bytes);
    assert_eq!(response["error"]["code"], "photo_invalid");
    assert_eq!(
        response["error"]["message"],
        "a photo could not be read; choose a valid JPEG, PNG, or WebP image"
    );

    let photo = (
        "photos",
        Some(("food.png", "image/png")),
        valid_png.as_slice(),
    );
    let too_many = multipart_request(
        "/api/ai/custom-food/draft",
        Some(&user),
        &[
            ("conversation", None, &conversation),
            photo,
            photo,
            photo,
            photo,
            photo,
        ],
    );
    let (status, _, bytes) = send(&router, too_many).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        parse_json::<Value>(&bytes)["error"]["code"],
        "too_many_photos"
    );
}

#[sqlx::test]
async fn real_catalog_vocabulary_reaches_model_and_trusted_draft_is_submittable(pool: PgPool) {
    let nutrient = |code: &str, amount: i64| {
        DraftNutrient::new(code.into(), rust_decimal::Decimal::new(amount, 0)).unwrap()
    };
    let draft = FoodDraftBuilder::new("Dal")
        .categories(["lentils"])
        .default_quantity(rust_decimal::Decimal::ONE, "g")
        .nutrients([
            nutrient("ENERGY_KCAL", 120),
            nutrient("PROTEIN_G", 7),
            nutrient("CARBS_G", 20),
            nutrient("FAT_G", 2),
        ])
        .servings([DraftServing::new("cup".into(), rust_decimal::Decimal::new(240, 0)).unwrap()])
        .build()
        .unwrap();
    let (router, observed_vocabulary) = app_with_model_result_and_real_vocabulary(
        pool,
        FoodDraftResult {
            turn: FoodDraftTurn::ready(
                "Review this estimate.",
                draft,
                vec!["Estimated values".into()],
            )
            .unwrap(),
            usage: None,
        },
    )
    .await;
    let (_, user) = bootstrap_and_user(&router).await;

    let (status, _, bytes) = send(&router, draft_request(Some(&user))).await;
    assert_eq!(status, StatusCode::OK);
    let assistant_response: Value = parse_json(&bytes);
    assert_eq!(assistant_response["status"], "draft_ready");
    assert_eq!(assistant_response["draft"]["default_unit"], "g");
    assert_eq!(assistant_response["draft"]["servings"][0]["unit"], "cup");

    let vocabulary = observed_vocabulary.lock().unwrap().take().unwrap();
    assert!(
        vocabulary
            .nutrients
            .iter()
            .any(|value| value.code == "ENERGY_KCAL")
    );
    assert!(
        vocabulary
            .default_units
            .iter()
            .any(|value| value.code == "g")
    );
    assert!(
        vocabulary
            .serving_units
            .iter()
            .any(|value| value.code == "cup")
    );
    for required in ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"] {
        assert!(
            vocabulary
                .required_nutrient_codes
                .iter()
                .any(|code| code == required)
        );
    }

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

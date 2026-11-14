use std::sync::Mutex;

use axum::Router;
use axum::http::{StatusCode, header};
use calco_backend::config::{AppConfig, ConfigError};
use chrono::{Duration, NaiveDate};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::mcp::*;
use crate::common::*;

static ENV_LOCK: Mutex<()> = Mutex::new(());

async fn summary_energy(router: Router, token: String, date: &'static str) -> String {
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            90,
            "get_daily_summary",
            json!({"from_date": date, "to_date": date}),
        ))
        .token(&token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let result = structured_result(&body);
    result["days"][0]["energy_kcal"]
        .as_str()
        .unwrap_or_else(|| panic!("missing summary energy: {result}"))
        .to_owned()
}

fn required_names(tool: &Value) -> Vec<String> {
    let mut names: Vec<String> = tool["inputSchema"]["required"]
        .as_array()
        .unwrap_or_else(|| panic!("missing required schema: {tool}"))
        .iter()
        .map(|value| value.as_str().expect("required string").to_owned())
        .collect();
    names.sort();
    names
}

fn tool_named<'a>(tools: &'a [Value], name: &str) -> &'a Value {
    tools
        .iter()
        .find(|tool| tool["name"] == name)
        .unwrap_or_else(|| panic!("missing {name} in tools/list: {tools:?}"))
}

#[sqlx::test]
async fn initialize_and_tools_list_are_stateless(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP initialize", Some("read")).await;

    for (requested, negotiated) in [("2025-06-18", "2025-06-18"), ("2026-07-28", "2025-11-25")] {
        let (status, headers, bytes) = send_mcp(
            &router,
            McpRequest::post(initialize_body(1, requested))
                .protocol_version(Some(requested))
                .token(&key.token),
        )
        .await;
        let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);

        assert_no_session_headers(&headers);
        assert_eq!(body["result"]["protocolVersion"], negotiated);
        assert_eq!(body["result"]["serverInfo"]["name"], "calco");
        assert_eq!(
            body["result"]["serverInfo"]["version"],
            env!("CARGO_PKG_VERSION")
        );
        assert!(body["result"]["capabilities"]["tools"].is_object());
        assert!(body["result"]["capabilities"].get("resources").is_none());
        assert!(body["result"]["capabilities"].get("prompts").is_none());
    }

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tools_list_body(2)).token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_no_session_headers(&headers);

    let tools = body["result"]["tools"].as_array().expect("tools array");
    let names: Vec<&str> = tools
        .iter()
        .map(|tool| tool["name"].as_str().expect("tool name"))
        .collect();
    assert_eq!(names, vec!["get_daily_summary", "get_food", "search_foods"]);

    for tool in tools {
        assert_eq!(
            tool["annotations"]["readOnlyHint"], true,
            "tool is not marked read-only: {tool}"
        );
        assert!(
            tool["description"]
                .as_str()
                .is_some_and(|text| !text.is_empty()),
            "tool description missing: {tool}"
        );
    }

    assert_eq!(required_names(tool_named(tools, "search_foods")), ["query"]);
    assert_eq!(required_names(tool_named(tools, "get_food")), ["food_id"]);
    assert_eq!(
        required_names(tool_named(tools, "get_daily_summary")),
        ["from_date", "to_date"]
    );

    let search_foods = tool_named(tools, "search_foods");
    assert_eq!(
        search_foods["inputSchema"]["properties"]["query"]["maxLength"],
        256
    );
    let search_schema = search_foods["inputSchema"].to_string();
    for scope in ["all", "custom", "history"] {
        assert!(
            search_schema.contains(&format!("\"{scope}\"")),
            "search scope schema missing {scope}: {search_schema}"
        );
    }
}

#[sqlx::test]
async fn direct_tools_list_and_tools_call_work_without_initialize(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP direct", Some("read")).await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tools_list_body(10)).token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(body["result"]["tools"].as_array().unwrap().len(), 3);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            11,
            "search_foods",
            json!({"query": "nothing matches this", "scope": "all"}),
        ))
        .token(&key.token)
        .header(MCP_SESSION_HEADER, "bogus-session"),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_no_session_headers(&headers);
    let result = structured_result(&body);
    assert_eq!(result["items"], json!([]));

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            12,
            "get_daily_summary",
            json!({"from_date": "2026-08-01", "to_date": "2026-08-02"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let result = structured_result(&body);
    assert_eq!(result["days"], json!([]));
}

#[sqlx::test]
async fn stateless_methods_and_bogus_session_headers(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP methods", Some("read")).await;

    for request in [
        McpRequest::get()
            .token(&key.token)
            .accept(Some("text/event-stream")),
        McpRequest::delete().token(&key.token),
        McpRequest::head().token(&key.token),
    ] {
        let (status, headers, bytes) = send_mcp(&router, request).await;
        assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED, "body: {bytes:?}");
        assert_eq!(headers.get(header::ALLOW).unwrap(), "POST");
        assert_ne!(
            headers
                .get(header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok()),
            Some("text/event-stream")
        );
    }

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(initialize_body(20, "2025-06-18"))
            .token(&key.token)
            .header(MCP_SESSION_HEADER, "bogus-session"),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_no_session_headers(&headers);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tools_list_body(21))
            .token(&key.token)
            .header(MCP_SESSION_HEADER, "bogus-session"),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_no_session_headers(&headers);
}

#[sqlx::test]
async fn auth_is_required_on_every_mcp_request(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP auth", Some("read")).await;
    let revoked = create_mcp_api_key(&router, &user, "MCP revoked", Some("read")).await;

    let unauthenticated = [
        McpRequest::post(initialize_body(30, "2025-06-18")),
        McpRequest::post(tools_list_body(31)),
        McpRequest::post(tool_call_body(
            32,
            "get_daily_summary",
            json!({"from_date": "2026-08-01", "to_date": "2026-08-01"}),
        )),
        McpRequest::post(notification_body("notifications/initialized")),
        McpRequest::get(),
        McpRequest::delete(),
        McpRequest::head(),
    ];

    for request in unauthenticated {
        let (status, headers, bytes) = send_mcp(&router, request).await;
        let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
        assert_auth_error(status, &headers, &body);
    }

    for request in [
        McpRequest::post(initialize_body(33, "2025-06-18")).cookie(&user),
        McpRequest::post(initialize_body(34, "2025-06-18")).cookie(&admin),
        McpRequest::post(initialize_body(35, "2025-06-18"))
            .cookie(&user)
            .authorization("Bearer garbage"),
        McpRequest::post(initialize_body(36, "2025-06-18")).authorization("Basic abc"),
        McpRequest::post(initialize_body(37, "2025-06-18")).authorization("Bearer"),
        McpRequest::post(initialize_body(38, "2025-06-18")).authorization("Bearer two words"),
    ] {
        let (status, headers, bytes) = send_mcp(&router, request).await;
        let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
        assert_auth_error(status, &headers, &body);
    }

    let duplicate_auth = format!("Bearer {}", key.token);
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(initialize_body(381, "2025-06-18"))
            .header("authorization", &duplicate_auth)
            .header("authorization", &duplicate_auth),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tools_list_body(39)).token(&revoked.token),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    revoke_api_key(&router, &user, &revoked.id).await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tools_list_body(40)).token(&revoked.token),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);

    for uri in ["/api/mcp/", "/api/mcp/not-a-route"] {
        let (status, headers, bytes) = send_mcp(&router, McpRequest::get().uri(uri)).await;
        assert!(
            matches!(status, StatusCode::UNAUTHORIZED | StatusCode::NOT_FOUND),
            "unauthenticated MCP subpath {uri} returned {status}: {bytes:?}"
        );
        if status == StatusCode::UNAUTHORIZED {
            assert_www_authenticate(&headers);
        }
        let body = String::from_utf8_lossy(&bytes);
        assert!(
            !body.contains("structuredContent") && !body.contains("\"isError\""),
            "MCP subpath {uri} reached tool dispatch without auth: {body}"
        );
    }

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(notification_body("notifications/initialized")).token(&key.token),
    )
    .await;
    assert_status(status, StatusCode::ACCEPTED, &bytes);
    assert_no_session_headers(&headers);

    let write_key = create_mcp_api_key(&router, &user, "MCP write", Some("read_write")).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(initialize_body(41, "2025-06-18")).token(&write_key.token),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_no_session_headers(&headers);
}

#[sqlx::test]
async fn two_user_summary_isolation_sequential_and_concurrent(pool: PgPool) {
    let router = app(pool).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "mcp-user-b", "testpassword").await;

    let product_a = seed_product(&router, &user_a, "MCPAlphaOnly Food", 111).await;
    let product_b = seed_product(&router, &user_b, "MCPBetaOnly Food", 222).await;
    seed_log(&router, &user_a, &product_a, "2026-07-01", 100).await;
    seed_log(&router, &user_b, &product_b, "2026-07-01", 100).await;

    let key_a = create_mcp_api_key(&router, &user_a, "MCP isolation A", Some("read")).await;
    let key_b = create_mcp_api_key(&router, &user_b, "MCP isolation B", Some("read")).await;

    assert_eq!(
        summary_energy(router.clone(), key_a.token.clone(), "2026-07-01").await,
        "111"
    );
    assert_eq!(
        summary_energy(router.clone(), key_b.token.clone(), "2026-07-01").await,
        "222"
    );

    for _ in 0..3 {
        assert_eq!(
            summary_energy(router.clone(), key_a.token.clone(), "2026-07-01").await,
            "111"
        );
        assert_eq!(
            summary_energy(router.clone(), key_b.token.clone(), "2026-07-01").await,
            "222"
        );
    }

    let profile_b = profile_id(&router, &user_b).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            50,
            "get_daily_summary",
            json!({
                "from_date": "2026-07-01",
                "to_date": "2026-07-01",
                "user_id": profile_b,
                "profile_id": profile_b,
                "owner_id": profile_b
            }),
        ))
        .token(&key_a.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(
        structured_result(&body)["days"][0]["energy_kcal"],
        "111",
        "extra arguments changed the caller identity"
    );

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            51,
            "get_daily_summary",
            json!({"from_date": "2026-07-01", "to_date": "2026-07-01"}),
        ))
        .token(&key_a.token)
        .cookie(&user_b),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(
        structured_result(&body)["days"][0]["energy_kcal"],
        "111",
        "bearer key must win over a foreign browser session"
    );

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            52,
            "search_foods",
            json!({"query": "MCPAlphaOnly", "scope": "history"}),
        ))
        .token(&key_b.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let foreign_items = structured_result(&body)["items"]
        .as_array()
        .unwrap()
        .clone();
    assert!(
        !foreign_items.iter().any(|item| item["id"] == product_a),
        "history search leaked another user's history: {foreign_items:?}"
    );

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            53,
            "search_foods",
            json!({"query": "MCPAlphaOnly", "scope": "history"}),
        ))
        .token(&key_a.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let items = structured_result(&body)["items"]
        .as_array()
        .unwrap()
        .clone();
    assert!(
        items.iter().any(|item| item["id"] == product_a),
        "owner history search did not return the logged product: {items:?}"
    );

    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..4 {
        let router = router.clone();
        let token = key_a.token.clone();
        tasks.spawn(async move { summary_energy(router, token, "2026-07-01").await });
    }
    for _ in 0..4 {
        let router = router.clone();
        let token = key_b.token.clone();
        tasks.spawn(async move { summary_energy(router, token, "2026-07-01").await });
    }

    let mut a_results = 0;
    let mut b_results = 0;
    while let Some(result) = tasks.join_next().await {
        match result.expect("concurrent summary task") {
            value if value == "111" => a_results += 1,
            value if value == "222" => b_results += 1,
            other => panic!("unexpected concurrent summary owner/result: {other}"),
        }
    }
    assert_eq!((a_results, b_results), (4, 4));
}

#[sqlx::test]
async fn search_get_food_and_summary_match_rest(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "MCPParity Food", 321).await;
    seed_log(&router, &user, &product_id, "2026-09-10", 100).await;
    let key = create_mcp_api_key(&router, &user, "MCP parity", Some("read")).await;

    let rest_search: Value = get_json(&router, "/api/foods/search?q=MCPParity", &user).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            60,
            "search_foods",
            json!({"query": "MCPParity"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(structured_result(&body)["items"], rest_search["items"]);

    let rest_detail: Value = get_json(&router, &format!("/api/foods/{product_id}"), &user).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            61,
            "get_food",
            json!({"food_id": product_id}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(structured_result(&body), rest_detail);

    let rest_summary: Value = get_json(
        &router,
        "/api/logs/summary?from_date=2026-09-10&to_date=2026-09-10",
        &user,
    )
    .await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            62,
            "get_daily_summary",
            json!({"from_date": "2026-09-10", "to_date": "2026-09-10"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(structured_result(&body), rest_summary);

    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{product_id}"),
        &user,
        &json!({
            "name": "MCPParity Food",
            "brand": "MCP Brand",
            "categories": ["mcp-tests"],
            "default_quantity": 100,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": 999 },
                { "code": "PROTEIN_G", "amount_per_100g": 10 },
                { "code": "CARBS_G", "amount_per_100g": 20 },
                { "code": "FAT_G", "amount_per_100g": 5 }
            ],
            "servings": [{ "unit": "serving", "grams_per_unit": 50 }]
        }),
        StatusCode::OK,
    )
    .await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            63,
            "get_food",
            json!({"food_id": product_id}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(
        structured_result(&body)["nutrition_summary"]["per_100g"]["energy_kcal"],
        "999"
    );

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            64,
            "get_daily_summary",
            json!({"from_date": "2026-09-10", "to_date": "2026-09-10"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(
        structured_result(&body),
        rest_summary,
        "catalog edits must not rewrite historical log snapshots"
    );
}

#[sqlx::test]
async fn summary_only_returns_logged_days_and_rejects_367_day_difference(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "MCP Range Food", 100).await;
    for date in ["2025-01-01", "2025-01-03", "2025-01-05"] {
        seed_log(&router, &user, &product_id, date, 100).await;
    }
    let key = create_mcp_api_key(&router, &user, "MCP range", Some("read")).await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            70,
            "get_daily_summary",
            json!({"from_date": "2025-01-01", "to_date": "2025-01-05"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let result = structured_result(&body);
    let dates: Vec<&str> = result["days"]
        .as_array()
        .unwrap()
        .iter()
        .map(|day| day["date"].as_str().unwrap())
        .collect();
    assert_eq!(dates, vec!["2025-01-01", "2025-01-03", "2025-01-05"]);

    let rest: Value = get_json(
        &router,
        "/api/logs/summary?from_date=2025-01-01&to_date=2025-01-05",
        &user,
    )
    .await;
    assert_eq!(result, rest);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            71,
            "get_daily_summary",
            json!({"from_date": "2025-01-01", "to_date": "2026-01-02"}),
        ))
        .token(&key.token),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            72,
            "get_daily_summary",
            json!({"from_date": "2025-01-01", "to_date": "2026-01-03"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_tool_error(&body, "date range cannot exceed 366 days");
}

#[sqlx::test]
async fn summary_output_can_cover_367_inclusive_days(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let user_id = profile_id(&router, &user).await;
    let key = create_mcp_api_key(&router, &user, "MCP bulk range", Some("read")).await;

    let start = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
    let dates: Vec<NaiveDate> = (0..367)
        .map(|offset| start + Duration::days(offset))
        .collect();
    let ids: Vec<Uuid> = (0..367).map(|_| Uuid::new_v4()).collect();
    sqlx::query(
        r#"
        INSERT INTO food_logs (id, user_id, log_date, meal_slot, item_name, quantity, unit)
        SELECT id, $1, log_date, NULL, 'Bulk MCP Summary', 1, 'g'
        FROM UNNEST($2::uuid[], $3::date[]) AS rows(id, log_date)
        "#,
    )
    .bind(Uuid::parse_str(&user_id).unwrap())
    .bind(&ids)
    .bind(&dates)
    .execute(&pool)
    .await
    .expect("seed 367 summary days");

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            80,
            "get_daily_summary",
            json!({"from_date": "2025-01-01", "to_date": "2026-01-02"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let result = structured_result(&body);
    let days = result["days"].as_array().expect("summary days");
    assert_eq!(days.len(), 367);
    assert_eq!(days.first().unwrap()["date"], "2025-01-01");
    assert_eq!(days.last().unwrap()["date"], "2026-01-02");
    assert!(
        days.windows(2)
            .all(|pair| pair[0]["date"].as_str() < pair[1]["date"].as_str()),
        "summary days must be ascending"
    );
}

#[sqlx::test]
async fn host_origin_and_cors_are_enforced(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP transport security", Some("read")).await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(initialize_body(90, "2025-06-18")).token(&key.token),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);

    let (status, _headers, bytes) = send_mcp(
        &router,
        McpRequest::post(initialize_body(91, "2025-06-18"))
            .token(&key.token)
            .host("evil.example"),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "body: {bytes:?}");
    assert!(String::from_utf8_lossy(&bytes).contains("Host header is not allowed"));

    let custom = app_with_config(
        pool.clone(),
        test_config_with_mcp(&["https://app.example"], &["mcp.example.test"]),
    )
    .await;

    let (status, headers, bytes) = send_mcp(
        &custom,
        McpRequest::post(initialize_body(92, "2025-06-18"))
            .token(&key.token)
            .host("mcp.example.test"),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);

    let (status, _headers, bytes) = send_mcp(
        &custom,
        McpRequest::post(initialize_body(93, "2025-06-18"))
            .token(&key.token)
            .host("localhost"),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "body: {bytes:?}");

    let (status, headers, bytes) = send_mcp(
        &custom,
        McpRequest::post(initialize_body(94, "2025-06-18"))
            .token(&key.token)
            .host("mcp.example.test")
            .header(header::ORIGIN.as_str(), "https://app.example"),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(
        headers.get(header::ACCESS_CONTROL_ALLOW_ORIGIN).unwrap(),
        "https://app.example"
    );

    for origin in ["https://evil.example", "null", "not a uri"] {
        let (status, _headers, bytes) = send_mcp(
            &custom,
            McpRequest::post(initialize_body(95, "2025-06-18"))
                .token(&key.token)
                .host("mcp.example.test")
                .header(header::ORIGIN.as_str(), origin),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "origin {origin}: {bytes:?}");
        assert!(String::from_utf8_lossy(&bytes).contains("Origin"));
    }

    let preflight_key = create_mcp_api_key(&router, &user, "MCP preflight", Some("read")).await;
    assert!(last_used_at(&pool, &preflight_key.id).await.is_none());
    let requested_headers = "authorization,content-type,mcp-protocol-version,mcp-method,mcp-name";
    let (status, headers, _bytes) = send(
        &custom,
        preflight("https://app.example", "mcp.example.test", requested_headers),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        headers.get(header::ACCESS_CONTROL_ALLOW_ORIGIN).unwrap(),
        "https://app.example"
    );
    assert_eq!(
        headers
            .get(header::ACCESS_CONTROL_ALLOW_CREDENTIALS)
            .unwrap(),
        "true"
    );
    let allowed_headers = headers
        .get(header::ACCESS_CONTROL_ALLOW_HEADERS)
        .unwrap()
        .to_str()
        .unwrap()
        .to_ascii_lowercase();
    for name in [
        "authorization",
        "content-type",
        "mcp-protocol-version",
        "mcp-method",
        "mcp-name",
    ] {
        assert!(
            allowed_headers.contains(name),
            "missing {name}: {allowed_headers}"
        );
    }
    assert!(
        headers
            .get(header::ACCESS_CONTROL_ALLOW_METHODS)
            .unwrap()
            .to_str()
            .unwrap()
            .contains("POST")
    );
    assert!(last_used_at(&pool, &preflight_key.id).await.is_none());

    let (status, headers, _bytes) = send(
        &custom,
        preflight(
            "https://evil.example",
            "mcp.example.test",
            requested_headers,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers.get(header::ACCESS_CONTROL_ALLOW_ORIGIN).is_none());
}

#[test]
fn startup_config_rejects_unsafe_mcp_hosts() {
    assert_eq!(
        with_mcp_hosts(None).unwrap().server.mcp_allowed_hosts,
        ["localhost", "127.0.0.1", "[::1]"]
    );

    for value in [
        "",
        "*",
        "https://evil.example",
        "bad host",
        "host/path",
        "localhost,localhost",
    ] {
        assert_eq!(
            with_mcp_hosts(Some(value)).err(),
            Some(ConfigError::InvalidMcpAllowedHosts),
            "accepted unsafe MCP_ALLOWED_HOSTS={value:?}"
        );
    }

    assert_eq!(
        with_mcp_hosts(Some("mcp.example.test, mcp.example.test:8443, [::1]:8443"))
            .unwrap()
            .server
            .mcp_allowed_hosts,
        ["mcp.example.test", "mcp.example.test:8443", "[::1]:8443"]
    );
}

#[sqlx::test]
async fn cors_origins_are_normalized_at_startup(pool: PgPool) {
    let config = with_cors_origins(Some(
        "https://CALCO.example.com:443/, http://localhost:1234",
    ))
    .expect("valid CORS origins");

    let origins: Vec<String> = config
        .server
        .cors_allowed_origins
        .iter()
        .map(|origin| origin.to_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        origins,
        ["https://calco.example.com", "http://localhost:1234"]
    );

    let router = app_with_config(pool, config).await;
    for origin in ["https://calco.example.com", "http://localhost:1234"] {
        let (status, headers, _bytes) = send(
            &router,
            preflight(
                origin,
                "localhost",
                "authorization,content-type,mcp-protocol-version,mcp-method,mcp-name",
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            headers.get(header::ACCESS_CONTROL_ALLOW_ORIGIN).unwrap(),
            origin
        );
    }
}

#[test]
fn startup_config_rejects_unsafe_cors_origins() {
    for value in [
        "*",
        "null",
        "https://user:pass@example.com",
        "https://example.com/path",
        "https://example.com?x=1",
        "https://example.com#fragment",
        "ftp://example.com",
        "https://example.com:0",
        "not a url",
    ] {
        assert_eq!(
            with_cors_origins(Some(value)).err(),
            Some(ConfigError::InvalidCorsAllowedOrigins),
            "accepted unsafe CORS_ALLOWED_ORIGINS={value:?}"
        );
    }
}

fn with_mcp_hosts(value: Option<&str>) -> Result<AppConfig, ConfigError> {
    with_startup_config(None, value)
}

fn with_cors_origins(value: Option<&str>) -> Result<AppConfig, ConfigError> {
    with_startup_config(value, None)
}

fn with_startup_config(
    cors_origins: Option<&str>,
    mcp_hosts: Option<&str>,
) -> Result<AppConfig, ConfigError> {
    let _guard = ENV_LOCK.lock().expect("environment lock");
    let old_cors = std::env::var_os("CORS_ALLOWED_ORIGINS");
    let old_mcp_hosts = std::env::var_os("MCP_ALLOWED_HOSTS");
    let old_config_file = std::env::var_os("CALCO_CONFIG_FILE");

    // SAFETY: the test binary only mutates these variables while holding
    // ENV_LOCK, and no production code reads them during an integration test.
    // DATABASE_URL is intentionally left alone: sqlx::test validates that it
    // does not change at runtime.
    unsafe {
        std::env::remove_var("CALCO_CONFIG_FILE");
        match cors_origins {
            Some(value) => std::env::set_var("CORS_ALLOWED_ORIGINS", value),
            None => std::env::remove_var("CORS_ALLOWED_ORIGINS"),
        }
        match mcp_hosts {
            Some(value) => std::env::set_var("MCP_ALLOWED_HOSTS", value),
            None => std::env::remove_var("MCP_ALLOWED_HOSTS"),
        }
    }

    let result = AppConfig::from_env();

    unsafe {
        match old_cors {
            Some(value) => std::env::set_var("CORS_ALLOWED_ORIGINS", value),
            None => std::env::remove_var("CORS_ALLOWED_ORIGINS"),
        }
        match old_mcp_hosts {
            Some(value) => std::env::set_var("MCP_ALLOWED_HOSTS", value),
            None => std::env::remove_var("MCP_ALLOWED_HOSTS"),
        }
        match old_config_file {
            Some(value) => std::env::set_var("CALCO_CONFIG_FILE", value),
            None => std::env::remove_var("CALCO_CONFIG_FILE"),
        }
    }

    result
}

#[sqlx::test]
async fn transport_accept_content_type_and_body_limit(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP transport", Some("read")).await;

    for request in [
        McpRequest::post(initialize_body(100, "2025-06-18"))
            .token(&key.token)
            .accept(None),
        McpRequest::post(initialize_body(101, "2025-06-18"))
            .token(&key.token)
            .accept(Some("application/json")),
    ] {
        let (status, _headers, bytes) = send_mcp(&router, request).await;
        assert_eq!(status, StatusCode::NOT_ACCEPTABLE, "body: {bytes:?}");
        assert!(String::from_utf8_lossy(&bytes).contains("Not Acceptable"));
    }

    for request in [
        McpRequest::post(initialize_body(102, "2025-06-18"))
            .token(&key.token)
            .content_type(Some("text/plain")),
        McpRequest::post(initialize_body(103, "2025-06-18"))
            .token(&key.token)
            .content_type(None),
    ] {
        let (status, _headers, bytes) = send_mcp(&router, request).await;
        assert_eq!(
            status,
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "body: {bytes:?}"
        );
        assert!(String::from_utf8_lossy(&bytes).contains("Unsupported Media Type"));
    }

    let oversized = json!({
        "jsonrpc": "2.0",
        "id": 104,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "1"},
            "padding": "x".repeat(70 * 1024)
        }
    });
    let (status, _headers, bytes) =
        send_mcp(&router, McpRequest::post(oversized).token(&key.token)).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "body: {bytes:?}");
    assert!(String::from_utf8_lossy(&bytes).contains("Payload Too Large"));
}

#[sqlx::test]
async fn search_query_length_is_bounded(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP query length", Some("read")).await;

    let allowed = "q".repeat(256);
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            115,
            "search_foods",
            json!({"query": allowed}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let result = structured_result(&body);
    assert_eq!(result["items"], json!([]));

    let rejected = "q".repeat(257);
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            116,
            "search_foods",
            json!({"query": rejected}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let text = assert_tool_error(&body, "256");
    assert!(text.contains("query must be at most 256 characters"));
    assert!(!text.contains("internal service error"));
    assert!(!text.contains("database"));
}

#[sqlx::test]
async fn mcp_errors_and_tool_failures(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product_id = seed_product(&router, &user, "MCP Error Food", 120).await;
    seed_log(&router, &user, &product_id, "2026-10-01", 100).await;
    let key = create_mcp_api_key(&router, &user, "MCP errors", Some("read")).await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post_raw("not valid json".to_owned()).token(&key.token),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNSUPPORTED_MEDIA_TYPE,
        "rmcp 3.10 documents a 415 transport rejection for non-JSON bodies: {bytes:?}"
    );
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    let malformed_body = String::from_utf8_lossy(&bytes);
    assert!(
        !malformed_body.contains("structuredContent") && !malformed_body.contains("\"isError\""),
        "malformed JSON reached tool dispatch: {malformed_body}"
    );
    if content_type.starts_with("application/json") {
        let body: Value = serde_json::from_slice(&bytes).expect("JSON malformed request error");
        assert_eq!(body["jsonrpc"], "2.0");
        assert_eq!(body["error"]["code"], -32700);
    } else {
        assert!(
            malformed_body.contains("deserialize") || malformed_body.contains("Bad Request"),
            "unexpected malformed-json body: {malformed_body}"
        );
    }

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(json!({"jsonrpc":"2.0","id":110,"method":"no/such","params":{}}))
            .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_rpc_error(&body, -32601);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(111, "no_such_tool", json!({}))).token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_rpc_error(&body, -32602);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            112,
            "search_foods",
            json!({"query": "anything", "scope": "private"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_tool_error(&body, "failed to deserialize parameters");

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            113,
            "get_daily_summary",
            json!({"from_date": "not-a-date", "to_date": "2026-10-01"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_tool_error(&body, "from_date must be a YYYY-MM-DD date");

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            114,
            "get_daily_summary",
            json!({"from_date": "2026-10-02", "to_date": "2026-10-01"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_tool_error(&body, "from_date must be on or before to_date");

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            115,
            "get_food",
            json!({"food_id": Uuid::new_v4().to_string()}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_tool_error(&body, "food not found");

    sqlx::query("ALTER TABLE food_log_nutrients RENAME TO food_log_nutrients_mcp_broken")
        .execute(&pool)
        .await
        .expect("break summary dependency");
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            116,
            "get_daily_summary",
            json!({"from_date": "2026-10-01", "to_date": "2026-10-01"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let text = assert_tool_error(&body, "internal service error");
    assert!(!text.contains("food_log_nutrients"));
    assert!(!text.contains("postgres"));
}

/// The tool description promises strict `YYYY-MM-DD`, so non-padded dates must
/// be rejected before the lenient chrono parse.
#[sqlx::test]
async fn non_padded_dates_are_rejected(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP strict dates", Some("read")).await;

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            1131,
            "get_daily_summary",
            json!({"from_date": "2026-1-1", "to_date": "2026-10-01"}),
        ))
        .token(&key.token),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_tool_error(&body, "from_date must be a YYYY-MM-DD date");
}

#[sqlx::test]
async fn last_used_at_updates_on_success_but_not_failed_auth(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP last used", Some("read")).await;

    assert!(last_used_at(&pool, &key.id).await.is_none());

    let (status, _headers, _bytes) = send(
        &router,
        preflight("https://evil.example", "localhost", "authorization"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        last_used_at(&pool, &key.id).await.is_none(),
        "CORS preflight must not authenticate or touch last_used_at"
    );

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            120,
            "search_foods",
            json!({"query": "last-used-success"}),
        ))
        .token(&key.token),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let touched = last_used_at(&pool, &key.id)
        .await
        .expect("successful MCP call must update last_used_at");

    revoke_api_key(&router, &user, &key.id).await;
    let sentinel = "calco_pat_sentinel_should_not_leak";
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tools_list_body(121)).token(sentinel),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert!(!String::from_utf8_lossy(&bytes).contains(sentinel));
    assert_eq!(
        last_used_at(&pool, &key.id).await,
        Some(touched),
        "failed authentication changed last_used_at"
    );
}

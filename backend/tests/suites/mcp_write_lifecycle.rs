use std::collections::BTreeSet;

use axum::Router;
use axum::http::{StatusCode, header};
use chrono::DateTime;
use rust_decimal::Decimal;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::mcp::*;
use crate::common::*;

fn create_args(product_id: &str, log_date: &str) -> Value {
    json!({
        "log_date": log_date,
        "meal_slot": "lunch",
        "device_timezone": "Asia/Kolkata",
        "item": {"type": "product", "id": product_id},
        "quantity": {"amount": 150, "unit": "g"},
        "notes": "MCP roundtrip"
    })
}

async fn create_rest_log(
    router: &Router,
    cookie: &str,
    product_id: &str,
    log_date: &str,
    meal_slot: &str,
    amount: i64,
) -> (String, Value) {
    let created: Value = post_json(
        router,
        "/api/logs",
        cookie,
        &json!({
            "log_date": log_date,
            "meal_slot": meal_slot,
            "item": {"type": "product", "id": product_id},
            "quantity": {"amount": amount, "unit": "g"}
        }),
        StatusCode::CREATED,
    )
    .await;
    let id = created["id"].as_str().expect("created log id").to_owned();
    (id, created)
}

fn assert_timestamp(value: &Value) {
    let text = value
        .as_str()
        .unwrap_or_else(|| panic!("timestamp is not a string: {value}"));
    DateTime::parse_from_rfc3339(text).unwrap_or_else(|error| {
        panic!("invalid RFC 3339 timestamp {text:?}: {error}");
    });
}

fn object_keys(value: &Value) -> Vec<String> {
    let mut keys: Vec<String> = value
        .as_object()
        .unwrap_or_else(|| panic!("expected object: {value}"))
        .keys()
        .cloned()
        .collect();
    keys.sort();
    keys
}

// ─── T1 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn read_write_key_create_list_summary_and_delete_roundtrip(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Roundtrip Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP write", Some("read_write")).await;
    let read = create_mcp_api_key(&router, &user, "MCP read", Some("read")).await;
    let profile = profile_id(&router, &user).await;

    let empty = tool_call_ok(
        &router,
        &read.token,
        1,
        "list_logs",
        json!({"log_date": "2026-11-01"}),
    )
    .await;
    assert_eq!(empty, json!({"log_date": "2026-11-01", "items": []}));

    let created = tool_call_ok(
        &router,
        &write.token,
        2,
        "create_log",
        create_args(&product, "2026-11-01"),
    )
    .await;
    let log_id = created["id"].as_str().expect("created log id").to_owned();
    Uuid::parse_str(&log_id).expect("created log id is a UUID");
    assert_eq!(created["log_date"], "2026-11-01");
    assert_eq!(created["meal_slot"], "lunch");
    assert_eq!(created["device_timezone"], "Asia/Kolkata");
    assert_eq!(created["notes"], "MCP roundtrip");
    assert_eq!(
        created["item"],
        json!({
            "type": "product",
            "id": product,
            "name": "MCP Roundtrip Food",
            "brand": "MCP Brand"
        })
    );
    assert_eq!(created["quantity"], json!({"amount": "150", "unit": "g"}));
    assert_eq!(created["nutrients"].as_array().expect("nutrients").len(), 4);
    assert_eq!(nutrient_amount(&created["nutrients"], "ENERGY_KCAL"), "150");
    assert_eq!(nutrient_amount(&created["nutrients"], "PROTEIN_G"), "15");
    assert_eq!(nutrient_amount(&created["nutrients"], "CARBS_G"), "30");
    assert_eq!(
        nutrient_amount_value(&created["nutrients"], "FAT_G"),
        Decimal::new(75, 1),
        "fat should be 7.5: {}",
        created["nutrients"][3]
    );
    assert_timestamp(&created["created_at"]);
    assert_timestamp(&created["updated_at"]);
    assert!(created.get("idempotency_key").is_none());

    let listed = tool_call_ok(
        &router,
        &read.token,
        3,
        "list_logs",
        json!({"log_date": "2026-11-01"}),
    )
    .await;
    let rest_list: Value = get_json(&router, "/api/logs?log_date=2026-11-01", &user).await;
    assert_eq!(listed, rest_list, "list_logs must match REST exactly");
    assert_eq!(listed["items"].as_array().expect("items").len(), 1);
    assert_eq!(listed["items"][0]["id"], log_id);

    let mut created_normalized = created.clone();
    normalize_timestamps(&mut created_normalized);
    normalize_decimal_amounts(&mut created_normalized);
    let mut listed_normalized = listed["items"][0].clone();
    normalize_timestamps(&mut listed_normalized);
    normalize_decimal_amounts(&mut listed_normalized);
    assert_eq!(
        created_normalized, listed_normalized,
        "list_logs must return the log create_log reported"
    );

    let summary = tool_call_ok(
        &router,
        &read.token,
        4,
        "get_daily_summary",
        json!({"from_date": "2026-11-01", "to_date": "2026-11-01"}),
    )
    .await;
    let rest_summary: Value = get_json(
        &router,
        "/api/logs/summary?from_date=2026-11-01&to_date=2026-11-01",
        &user,
    )
    .await;
    assert_eq!(summary, rest_summary, "summary must match REST exactly");
    assert_eq!(summary["days"][0]["energy_kcal"], "150");
    assert_eq!(summary["days"][0]["protein_g"], "15");
    assert_eq!(summary["days"][0]["carbs_g"], "30");
    assert_eq!(summary["days"][0]["fat_g"], "7.5");

    let deleted = tool_call_ok(
        &router,
        &write.token,
        5,
        "delete_log",
        json!({"log_id": log_id}),
    )
    .await;
    assert_eq!(deleted, json!({"deleted": true}));

    let after = tool_call_ok(
        &router,
        &read.token,
        6,
        "list_logs",
        json!({"log_date": "2026-11-01"}),
    )
    .await;
    assert_eq!(after, json!({"log_date": "2026-11-01", "items": []}));
    let summary_after = tool_call_ok(
        &router,
        &read.token,
        7,
        "get_daily_summary",
        json!({"from_date": "2026-11-01", "to_date": "2026-11-01"}),
    )
    .await;
    assert_eq!(summary_after, json!({"days": []}));
    let (status, _body) = get_status(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let text = tool_call_err(
        &router,
        &write.token,
        8,
        "delete_log",
        json!({"log_id": log_id}),
        "not found",
    )
    .await;
    assert_safe_tool_error_text(&text);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 0);
}

// ─── T2 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn read_key_cannot_create_or_delete_logs(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Read Scope Food", 100).await;
    let read = create_mcp_api_key(&router, &user, "MCP read", Some("read")).await;
    let write = create_mcp_api_key(&router, &user, "MCP write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let body = send_tool_call(
        &router,
        &read.token,
        1,
        "create_log",
        create_args(&product, "2026-11-02"),
    )
    .await;
    let text = assert_tool_error(&body, "read_write");
    assert_eq!(text, "read_write API key scope required");
    assert_safe_tool_error_text(&text);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 0);
    let empty = tool_call_ok(
        &router,
        &read.token,
        2,
        "list_logs",
        json!({"log_date": "2026-11-02"}),
    )
    .await;
    assert_eq!(empty["items"], json!([]));

    let mut probe = create_args(&product, "2026-11-02");
    probe["idempotency_key"] = json!("probe-key");
    let created = tool_call_ok(&router, &write.token, 3, "create_log", probe.clone()).await;
    let log_id = created["id"].as_str().expect("created log id").to_owned();
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let text = tool_call_err(&router, &read.token, 4, "create_log", probe, "read_write").await;
    assert_eq!(text, "read_write API key scope required");
    assert_safe_tool_error_text(&text);
    assert!(
        !text.contains(&log_id),
        "scope failure leaked the existing log id: {text}"
    );
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let text = tool_call_err(
        &router,
        &read.token,
        5,
        "delete_log",
        json!({"log_id": log_id}),
        "read_write",
    )
    .await;
    assert_eq!(text, "read_write API key scope required");
    assert_safe_tool_error_text(&text);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);
}

// ─── T3 ────────────────────────────────────────────────────────────────

fn assert_read_key_tools(tools: &[Value]) {
    assert_eq!(
        sorted_tool_names(tools),
        ["get_daily_summary", "get_food", "list_logs", "search_foods"]
    );
    let mut unique = sorted_tool_names(tools);
    unique.dedup();
    assert_eq!(unique.len(), tools.len(), "tool names are not unique");

    let list_logs = tool_named(tools, "list_logs");
    assert_eq!(required_names(list_logs), ["log_date"]);
    assert_eq!(list_logs["annotations"]["readOnlyHint"], true);
    assert!(
        list_logs["description"]
            .as_str()
            .is_some_and(|description| !description.is_empty()),
        "list_logs description missing: {list_logs}"
    );

    assert_eq!(required_names(tool_named(tools, "search_foods")), ["query"]);
    assert_eq!(required_names(tool_named(tools, "get_food")), ["food_id"]);
    assert_eq!(
        required_names(tool_named(tools, "get_daily_summary")),
        ["from_date", "to_date"]
    );

    for tool in tools {
        assert_eq!(
            tool["inputSchema"]["type"], "object",
            "inputSchema root must be an object: {tool}"
        );
        assert_ne!(
            tool["annotations"]["destructiveHint"], true,
            "read tool has a destructive hint: {tool}"
        );
    }
    assert_no_ownership_properties(tools);
}

#[sqlx::test]
async fn tools_list_for_read_key_hides_write_tools(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP read list", Some("read")).await;

    let direct = list_tools(&router, &key.token, 1).await;
    assert_read_key_tools(&direct);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(initialize_body(2, "2025-06-18")).token(&key.token),
    )
    .await;
    let _ = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let after_initialize = list_tools(&router, &key.token, 3).await;
    assert_read_key_tools(&after_initialize);

    let names = sorted_tool_names(&direct);
    assert!(!names.iter().any(|name| name == "create_log"));
    assert!(!names.iter().any(|name| name == "delete_log"));

    // SEP-2549 cache hints exist for 2026-07-28 requests and must be private
    // because the tool list depends on the caller.
    let cache_request = json!({
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/list",
        "params": {
            "_meta": {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": {}
            }
        }
    });
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(cache_request)
            .token(&key.token)
            .protocol_version(Some("2026-07-28"))
            .header("mcp-method", "tools/list"),
    )
    .await;
    let cache_body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    assert_eq!(cache_body["result"]["ttlMs"], 0, "cache_body: {cache_body}");
    assert_eq!(
        cache_body["result"]["cacheScope"], "private",
        "cache_body: {cache_body}"
    );
    let cache_tools = cache_body["result"]["tools"]
        .as_array()
        .expect("cached tools");
    assert_read_key_tools(cache_tools);
}

// ─── T4 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn tools_list_for_read_write_key_exposes_write_tool_schemas(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let key = create_mcp_api_key(&router, &user, "MCP write list", Some("read_write")).await;

    let tools = list_tools(&router, &key.token, 1).await;
    assert_eq!(
        sorted_tool_names(&tools),
        [
            "create_log",
            "delete_log",
            "get_daily_summary",
            "get_food",
            "list_logs",
            "search_foods"
        ]
    );

    let create = tool_named(&tools, "create_log");
    assert_eq!(required_names(create), ["item", "log_date", "quantity"]);
    assert_eq!(
        tool_property_names(create),
        [
            "device_timezone",
            "idempotency_key",
            "item",
            "log_date",
            "meal_slot",
            "notes",
            "quantity"
        ]
    );
    assert_eq!(
        create["inputSchema"]["properties"]["idempotency_key"]["maxLength"],
        128
    );
    assert_eq!(
        create["inputSchema"]["$defs"]["MealSlotParam"]["enum"],
        json!(["breakfast", "lunch", "dinner", "snack", "late_night_snack"])
    );
    let item_types: Vec<&str> = create["inputSchema"]["$defs"]["LogItemParam"]["oneOf"]
        .as_array()
        .expect("LogItemParam alternatives")
        .iter()
        .map(|alternative| {
            alternative["properties"]["type"]["const"]
                .as_str()
                .expect("item type constant")
        })
        .collect();
    assert_eq!(item_types, ["product", "meal"]);
    let quantity_properties = create["inputSchema"]["$defs"]["LogQuantityParam"]["properties"]
        .as_object()
        .expect("quantity properties");
    assert!(quantity_properties.contains_key("amount"));
    assert!(quantity_properties.contains_key("unit"));
    assert_eq!(create["annotations"]["readOnlyHint"], false);
    assert_eq!(create["annotations"]["destructiveHint"], false);
    let create_description = create["description"].as_str().expect("description");
    assert!(create_description.contains("log"));
    assert!(create_description.contains("idempotency"));

    let delete = tool_named(&tools, "delete_log");
    assert_eq!(tool_property_names(delete), ["log_id"]);
    assert_eq!(required_names(delete), ["log_id"]);
    assert_eq!(delete["annotations"]["readOnlyHint"], false);
    assert_eq!(delete["annotations"]["destructiveHint"], true);
    let delete_description = delete["description"]
        .as_str()
        .expect("description")
        .to_ascii_lowercase();
    assert!(
        delete_description.contains("delete") || delete_description.contains("remove"),
        "delete description must explain deletion: {delete_description}"
    );
    assert!(
        delete_description.contains("cannot be undone")
            || delete_description.contains("irreversible"),
        "delete description must warn the action is permanent: {delete_description}"
    );

    let list = tool_named(&tools, "list_logs");
    assert_eq!(tool_property_names(list), ["log_date"]);
    assert_eq!(required_names(list), ["log_date"]);
    assert_eq!(list["annotations"]["readOnlyHint"], true);

    assert_no_ownership_properties(&tools);
}

// ─── T5 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_and_list_never_honor_foreign_ownership_arguments(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "mcp-write-user-b", "testpassword").await;
    let product_a = seed_product(&router, &user_a, "MCP Owner A Food", 100).await;
    let product_b = seed_product(&router, &user_b, "MCP Owner B Food", 200).await;
    let log_a = seed_log(&router, &user_a, &product_a, "2026-11-05", 100).await;
    let log_b = seed_log(&router, &user_b, &product_b, "2026-11-05", 100).await;
    let profile_a = profile_id(&router, &user_a).await;
    let profile_b = profile_id(&router, &user_b).await;
    let write_a = create_mcp_api_key(&router, &user_a, "MCP A write", Some("read_write")).await;

    let body = send_tool_call(
        &router,
        &write_a.token,
        1,
        "list_logs",
        json!({
            "log_date": "2026-11-05",
            "user_id": profile_b,
            "profile_id": profile_b,
            "owner_id": profile_b
        }),
    )
    .await;
    if body["result"]["isError"] == true {
        let text = assert_tool_error(&body, "");
        assert_safe_tool_error_text(&text);
    } else {
        let result = structured_result(&body);
        let ids: Vec<&str> = result["items"]
            .as_array()
            .expect("items")
            .iter()
            .map(|item| item["id"].as_str().expect("log id"))
            .collect();
        assert_eq!(ids, [log_a.as_str()], "foreign ownership changed list_logs");
        assert!(!ids.contains(&log_b.as_str()));
    }

    let b_count_before = count_logs_for_user(&pool, &profile_b).await;
    let body = send_tool_call(
        &router,
        &write_a.token,
        2,
        "create_log",
        json!({
            "log_date": "2026-11-05",
            "meal_slot": "lunch",
            "item": {"type": "product", "id": product_a},
            "quantity": {"amount": 100, "unit": "g"},
            "user_id": profile_b,
            "profile_id": profile_b,
            "owner_id": profile_b
        }),
    )
    .await;
    if body["result"]["isError"] == true {
        let text = assert_tool_error(&body, "");
        assert_safe_tool_error_text(&text);
    } else {
        let result = structured_result(&body);
        let created_id = result["id"].as_str().expect("created log id");
        assert_eq!(
            log_owner(&pool, created_id).await,
            profile_a,
            "create_log honored a foreign owner argument"
        );
    }
    assert_eq!(
        count_logs_for_user(&pool, &profile_b).await,
        b_count_before,
        "foreign ownership arguments changed the other user's rows"
    );
    assert_eq!(count_logs_for_user(&pool, &profile_b).await, 1);
}

// ─── T6 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn delete_log_of_another_user_is_not_found_and_preserves_the_row(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "mcp-delete-user-b", "testpassword").await;
    let product_a = seed_product(&router, &user_a, "MCP Delete A Food", 100).await;
    let product_b = seed_product(&router, &user_b, "MCP Delete B Food", 200).await;
    let _log_a = seed_log(&router, &user_a, &product_a, "2026-11-05", 100).await;
    let log_b = seed_log(&router, &user_b, &product_b, "2026-11-05", 100).await;
    let profile_b = profile_id(&router, &user_b).await;
    let write_a = create_mcp_api_key(&router, &user_a, "MCP A write", Some("read_write")).await;

    let text = tool_call_err(
        &router,
        &write_a.token,
        1,
        "delete_log",
        json!({"log_id": log_b}),
        "not found",
    )
    .await;
    assert_safe_tool_error_text(&text);
    let unknown_text = tool_call_err(
        &router,
        &write_a.token,
        2,
        "delete_log",
        json!({"log_id": Uuid::new_v4().to_string()}),
        "not found",
    )
    .await;
    assert_eq!(
        unknown_text, text,
        "unknown UUID must use the same safe error"
    );
    assert_eq!(count_logs_for_user(&pool, &profile_b).await, 1);
    let fetched: Value = get_json(&router, &format!("/api/logs/{log_b}"), &user_b).await;
    assert_eq!(fetched["id"], log_b);

    let list_a = tool_call_ok(
        &router,
        &write_a.token,
        3,
        "list_logs",
        json!({"log_date": "2026-11-05"}),
    )
    .await;
    let ids: Vec<&str> = list_a["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["id"].as_str().expect("log id"))
        .collect();
    assert!(!ids.contains(&log_b.as_str()));
}

// ─── T7 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_invalid_arguments_are_tool_errors_and_write_nothing(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Invalid Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP invalid write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let mut missing_log_date = create_args(&product, "2026-11-03");
    missing_log_date.as_object_mut().unwrap().remove("log_date");
    let mut missing_item = create_args(&product, "2026-11-03");
    missing_item.as_object_mut().unwrap().remove("item");
    let mut missing_quantity = create_args(&product, "2026-11-03");
    missing_quantity.as_object_mut().unwrap().remove("quantity");

    let cases: Vec<(Value, &str)> = vec![
        (missing_log_date, "failed to deserialize parameters"),
        (missing_item, "failed to deserialize parameters"),
        (missing_quantity, "failed to deserialize parameters"),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": "not-a-uuid"},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "failed to deserialize parameters",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product"},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "failed to deserialize parameters",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "recipe", "id": product},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "failed to deserialize parameters",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "meal_slot": "brunch",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "failed to deserialize parameters",
        ),
        (
            json!({
                "log_date": "2026-02-30",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "YYYY-MM-DD",
        ),
        (
            json!({
                "log_date": "2026-1-1",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "YYYY-MM-DD",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 0, "unit": "g"}
            }),
            "quantity amount must be positive",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": -1, "unit": "g"}
            }),
            "quantity amount must be positive",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 100, "unit": "cup"}
            }),
            "cannot convert",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": Uuid::new_v4().to_string()},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "not found",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "meal", "id": Uuid::new_v4().to_string()},
                "quantity": {"amount": 100, "unit": "g"}
            }),
            "not found",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": "lots", "unit": "g"}
            }),
            "failed to deserialize parameters",
        ),
        (
            json!({
                "log_date": "2026-11-03",
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 100}
            }),
            "failed to deserialize parameters",
        ),
    ];

    for (index, (arguments, expected)) in cases.into_iter().enumerate() {
        let id = 100 + index as i64;
        let text = {
            let before = count_logs_for_user(&pool, &profile).await;
            let text =
                tool_call_err(&router, &write.token, id, "create_log", arguments, expected).await;
            assert_safe_tool_error_text(&text);
            assert_eq!(count_logs_for_user(&pool, &profile).await, before);
            text
        };
        if expected == "YYYY-MM-DD" {
            assert!(text.contains("log_date"), "unexpected date error: {text}");
        }
        if expected == "cannot convert" {
            assert!(
                text.contains("cup"),
                "conversion error lost the unit: {text}"
            );
        }
    }

    assert_eq!(count_logs_for_user(&pool, &profile).await, 0);
}

/// T7 internal-failure branch. `#[sqlx::test]` gives this test its own
/// database, so renaming a table cannot affect the developer database.
#[sqlx::test]
async fn create_log_internal_failure_is_safe_and_writes_nothing(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Internal Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP internal write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    sqlx::query("ALTER TABLE food_log_nutrients RENAME TO food_log_nutrients_mcp_write_broken")
        .execute(&pool)
        .await
        .expect("rename food_log_nutrients");

    let body = send_tool_call(
        &router,
        &write.token,
        1,
        "create_log",
        create_args(&product, "2026-11-03"),
    )
    .await;

    sqlx::query("ALTER TABLE food_log_nutrients_mcp_write_broken RENAME TO food_log_nutrients")
        .execute(&pool)
        .await
        .expect("restore food_log_nutrients");

    let text = assert_tool_error(&body, "internal service error");
    assert_safe_tool_error_text(&text);
    assert!(!text.contains("food_log_nutrients"));
    assert_eq!(count_logs_for_user(&pool, &profile).await, 0);
}

// ─── T8 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn list_logs_and_delete_log_invalid_arguments_are_tool_errors(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Invalid List Food", 100).await;
    let log_id = seed_log(&router, &user, &product, "2026-11-09", 100).await;
    let read = create_mcp_api_key(&router, &user, "MCP list read", Some("read")).await;
    let write = create_mcp_api_key(&router, &user, "MCP list write", Some("read_write")).await;

    let text = tool_call_err(
        &router,
        &read.token,
        1,
        "list_logs",
        json!({"log_date": "not-a-date"}),
        "log_date",
    )
    .await;
    assert_safe_tool_error_text(&text);
    let text = tool_call_err(
        &router,
        &read.token,
        2,
        "list_logs",
        json!({}),
        "failed to deserialize parameters",
    )
    .await;
    assert_safe_tool_error_text(&text);

    for (id, arguments) in [(3, json!({"log_id": "not-a-uuid"})), (4, json!({}))] {
        let text = tool_call_err(
            &router,
            &write.token,
            id,
            "delete_log",
            arguments,
            "failed to deserialize parameters",
        )
        .await;
        assert_safe_tool_error_text(&text);
    }

    let text = tool_call_err(
        &router,
        &write.token,
        5,
        "delete_log",
        json!({"log_id": Uuid::new_v4().to_string()}),
        "not found",
    )
    .await;
    assert_safe_tool_error_text(&text);

    let fetched: Value = get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(fetched["id"], log_id);
    assert_eq!(
        count_logs_for_user_date(&pool, &profile_id(&router, &user).await, "2026-11-09").await,
        1
    );
}

// ─── T9 ────────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_snapshots_nutrients_and_item_name_against_catalog_edits(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Snapshot Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP snapshot write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let mut arguments = create_args(&product, "2026-11-10");
    arguments["quantity"] = json!({"amount": 150, "unit": "g"});
    arguments["idempotency_key"] = json!("snapshot-key");
    let created = tool_call_ok(&router, &write.token, 1, "create_log", arguments.clone()).await;
    let log_id = created["id"].as_str().expect("created log id").to_owned();
    let mut original = created.clone();
    normalize_timestamps(&mut original);
    assert_eq!(original["item"]["name"], "MCP Snapshot Food");
    assert_eq!(original["item"]["brand"], "MCP Brand");
    assert_eq!(
        nutrient_amount(&original["nutrients"], "ENERGY_KCAL"),
        "150"
    );

    let _: Value = put_json(
        &router,
        &format!("/api/foods/custom/{product}"),
        &user,
        &json!({
            "name": "MCP Snapshot Food Renamed",
            "brand": "New Brand",
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

    let catalog: Value = tool_call_ok(
        &router,
        &write.token,
        2,
        "get_food",
        json!({"food_id": product}),
    )
    .await;
    assert_eq!(catalog["name"], "MCP Snapshot Food Renamed");
    assert_eq!(
        catalog["nutrition_summary"]["per_100g"]["energy_kcal"],
        "999"
    );

    let listed = tool_call_ok(
        &router,
        &write.token,
        3,
        "list_logs",
        json!({"log_date": "2026-11-10"}),
    )
    .await;
    let listed_log = &listed["items"][0];
    assert_eq!(listed_log["item"]["name"], "MCP Snapshot Food");
    assert_eq!(listed_log["item"]["brand"], "MCP Brand");
    assert_eq!(
        nutrient_amount(&listed_log["nutrients"], "ENERGY_KCAL"),
        "150"
    );
    let mut listed_normalized = listed_log.clone();
    normalize_timestamps(&mut listed_normalized);
    normalize_decimal_amounts(&mut listed_normalized);
    let mut original_normalized = created.clone();
    normalize_timestamps(&mut original_normalized);
    normalize_decimal_amounts(&mut original_normalized);
    assert_eq!(
        listed_normalized["created_at"], original_normalized["created_at"],
        "catalog edits must not change log timestamps"
    );
    assert_eq!(
        listed_normalized["updated_at"], original_normalized["updated_at"],
        "catalog edits must not change log timestamps"
    );

    let rest_log: Value = get_json(&router, &format!("/api/logs/{log_id}"), &user).await;
    assert_eq!(rest_log["item"]["name"], "MCP Snapshot Food");
    assert_eq!(
        nutrient_amount(&rest_log["nutrients"], "ENERGY_KCAL"),
        "150"
    );

    let summary = tool_call_ok(
        &router,
        &write.token,
        4,
        "get_daily_summary",
        json!({"from_date": "2026-11-10", "to_date": "2026-11-10"}),
    )
    .await;
    assert_eq!(summary["days"][0]["energy_kcal"], "150");
    assert_eq!(
        log_nutrient_amount(&pool, &log_id, "ENERGY_KCAL").await,
        Decimal::from(150)
    );

    let retried = tool_call_ok(&router, &write.token, 5, "create_log", arguments).await;
    assert_eq!(retried["id"], log_id);
    assert_eq!(retried["item"]["name"], "MCP Snapshot Food");
    assert_eq!(nutrient_amount(&retried["nutrients"], "ENERGY_KCAL"), "150");
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);
}

// ─── T10 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_accepts_meal_items_and_keeps_the_meal_snapshot(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Meal Component", 250).await;
    let meal = seed_meal(&router, &user, "MCP Meal", &product, 60).await;
    let write = create_mcp_api_key(&router, &user, "MCP meal write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let created = tool_call_ok(
        &router,
        &write.token,
        1,
        "create_log",
        json!({
            "log_date": "2026-11-06",
            "item": {"type": "meal", "id": meal},
            "quantity": {"amount": 60, "unit": "g"}
        }),
    )
    .await;
    let log_id = created["id"].as_str().expect("created log id").to_owned();
    assert_eq!(
        created["item"],
        json!({"type": "meal", "id": meal, "name": "MCP Meal"})
    );
    assert_eq!(
        nutrient_amount_value(&created["nutrients"], "ENERGY_KCAL"),
        Decimal::from(150)
    );

    let (item_product_id, item_meal_id) = log_item_ids(&pool, &log_id).await;
    assert!(item_product_id.is_none(), "meal log stored a product id");
    assert_eq!(item_meal_id, Some(Uuid::parse_str(&meal).unwrap()));

    let updated: Value = put_json(
        &router,
        &format!("/api/meals/{meal}"),
        &user,
        &json!({
            "name": "MCP Meal Renamed",
            "total_quantity": {"amount": 60, "unit": "g"},
            "components": [{
                "item": {"type": "product", "id": product},
                "quantity": {"amount": 60, "unit": "g"}
            }]
        }),
        StatusCode::OK,
    )
    .await;
    assert_eq!(updated["name"], "MCP Meal Renamed");

    let listed = tool_call_ok(
        &router,
        &write.token,
        2,
        "list_logs",
        json!({"log_date": "2026-11-06"}),
    )
    .await;
    assert_eq!(listed["items"][0]["item"]["name"], "MCP Meal");

    let deleted = tool_call_ok(
        &router,
        &write.token,
        3,
        "delete_log",
        json!({"log_id": log_id}),
    )
    .await;
    assert_eq!(deleted, json!({"deleted": true}));
    let after = tool_call_ok(
        &router,
        &write.token,
        4,
        "list_logs",
        json!({"log_date": "2026-11-06"}),
    )
    .await;
    assert_eq!(after, json!({"log_date": "2026-11-06", "items": []}));
    let summary_after = tool_call_ok(
        &router,
        &write.token,
        5,
        "get_daily_summary",
        json!({"from_date": "2026-11-06", "to_date": "2026-11-06"}),
    )
    .await;
    assert_eq!(summary_after, json!({"days": []}));
    assert_eq!(count_logs_for_user(&pool, &profile).await, 0);
}

// ─── T11 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_idempotency_same_key_returns_existing_log(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Retry Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP retry write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let args = |key: Value, amount: i64| {
        json!({
            "log_date": "2026-11-04",
            "item": {"type": "product", "id": product},
            "quantity": {"amount": amount, "unit": "g"},
            "idempotency_key": key
        })
    };

    let first = tool_call_ok(
        &router,
        &write.token,
        1,
        "create_log",
        args(json!("retry-key-1"), 100),
    )
    .await;
    let id1 = first["id"].as_str().expect("id1").to_owned();

    let retried = tool_call_ok(
        &router,
        &write.token,
        2,
        "create_log",
        args(json!("retry-key-1"), 100),
    )
    .await;
    assert_eq!(retried["id"], id1);
    let mut first_normalized = first.clone();
    normalize_timestamps(&mut first_normalized);
    normalize_decimal_amounts(&mut first_normalized);
    let mut retried_normalized = retried.clone();
    normalize_timestamps(&mut retried_normalized);
    normalize_decimal_amounts(&mut retried_normalized);
    assert_eq!(first_normalized, retried_normalized);

    let second = tool_call_ok(
        &router,
        &write.token,
        3,
        "create_log",
        args(json!("retry-key-2"), 100),
    )
    .await;
    let id2 = second["id"].as_str().expect("id2").to_owned();
    assert_ne!(id2, id1);

    let changed_payload = tool_call_ok(
        &router,
        &write.token,
        4,
        "create_log",
        args(json!("retry-key-1"), 200),
    )
    .await;
    assert_eq!(changed_payload["id"], id1);
    assert_eq!(changed_payload["quantity"]["amount"], "100");

    let absent_key = tool_call_ok(
        &router,
        &write.token,
        5,
        "create_log",
        json!({
            "log_date": "2026-11-04",
            "item": {"type": "product", "id": product},
            "quantity": {"amount": 100, "unit": "g"}
        }),
    )
    .await;
    let id3 = absent_key["id"].as_str().expect("id3").to_owned();

    let null_key = tool_call_ok(
        &router,
        &write.token,
        6,
        "create_log",
        args(Value::Null, 100),
    )
    .await;
    let id4 = null_key["id"].as_str().expect("id4").to_owned();

    let ids: BTreeSet<&str> = [id1.as_str(), id2.as_str(), id3.as_str(), id4.as_str()]
        .into_iter()
        .collect();
    assert_eq!(ids.len(), 4, "idempotent creates returned duplicate ids");
    assert_eq!(count_logs_for_user(&pool, &profile).await, 4);
    assert_eq!(count_log_nutrients(&pool, &id1).await, 4);

    let summary = tool_call_ok(
        &router,
        &write.token,
        7,
        "get_daily_summary",
        json!({"from_date": "2026-11-04", "to_date": "2026-11-04"}),
    )
    .await;
    assert_eq!(summary["days"][0]["energy_kcal"], "400");

    let listed = tool_call_ok(
        &router,
        &write.token,
        8,
        "list_logs",
        json!({"log_date": "2026-11-04"}),
    )
    .await;
    assert_eq!(listed["items"].as_array().expect("items").len(), 4);
    for response in [
        &first,
        &retried,
        &second,
        &changed_payload,
        &absent_key,
        &null_key,
    ] {
        assert!(
            !response.to_string().contains("idempotency_key"),
            "log response exposed idempotency_key: {response}"
        );
    }
}

// ─── T12 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_idempotency_is_per_user(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "mcp-idem-user-b", "testpassword").await;
    let product_a = seed_product(&router, &user_a, "MCP Idem A Food", 100).await;
    let product_b = seed_product(&router, &user_b, "MCP Idem B Food", 200).await;
    let write_a = create_mcp_api_key(&router, &user_a, "MCP A idem", Some("read_write")).await;
    let write_b = create_mcp_api_key(&router, &user_b, "MCP B idem", Some("read_write")).await;
    let profile_a = profile_id(&router, &user_a).await;
    let profile_b = profile_id(&router, &user_b).await;

    let args = |product: &str| {
        json!({
            "log_date": "2026-11-11",
            "item": {"type": "product", "id": product},
            "quantity": {"amount": 100, "unit": "g"},
            "idempotency_key": "shared-key"
        })
    };

    let a_first = tool_call_ok(&router, &write_a.token, 1, "create_log", args(&product_a)).await;
    let id_a = a_first["id"].as_str().expect("A id").to_owned();
    assert_eq!(nutrient_amount(&a_first["nutrients"], "ENERGY_KCAL"), "100");

    let b_first = tool_call_ok(&router, &write_b.token, 2, "create_log", args(&product_b)).await;
    let id_b = b_first["id"].as_str().expect("B id").to_owned();
    assert_ne!(id_a, id_b);
    assert_eq!(nutrient_amount(&b_first["nutrients"], "ENERGY_KCAL"), "200");

    let a_retry = tool_call_ok(&router, &write_a.token, 3, "create_log", args(&product_a)).await;
    let b_retry = tool_call_ok(&router, &write_b.token, 4, "create_log", args(&product_b)).await;
    assert_eq!(a_retry["id"], id_a);
    assert_eq!(b_retry["id"], id_b);

    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 1);
    assert_eq!(count_logs_for_user(&pool, &profile_b).await, 1);

    let a_list = tool_call_ok(
        &router,
        &write_a.token,
        5,
        "list_logs",
        json!({"log_date": "2026-11-11"}),
    )
    .await;
    assert_eq!(a_list["items"].as_array().expect("A items").len(), 1);
    assert_eq!(a_list["items"][0]["id"], id_a);
    assert_eq!(
        nutrient_amount(&a_list["items"][0]["nutrients"], "ENERGY_KCAL"),
        "100"
    );

    let b_list = tool_call_ok(
        &router,
        &write_b.token,
        6,
        "list_logs",
        json!({"log_date": "2026-11-11"}),
    )
    .await;
    assert_eq!(b_list["items"].as_array().expect("B items").len(), 1);
    assert_eq!(b_list["items"][0]["id"], id_b);
    assert_eq!(
        nutrient_amount(&b_list["items"][0]["nutrients"], "ENERGY_KCAL"),
        "200"
    );

    let a_summary = tool_call_ok(
        &router,
        &write_a.token,
        7,
        "get_daily_summary",
        json!({"from_date": "2026-11-11", "to_date": "2026-11-11"}),
    )
    .await;
    assert_eq!(a_summary["days"][0]["energy_kcal"], "100");
    let b_summary = tool_call_ok(
        &router,
        &write_b.token,
        8,
        "get_daily_summary",
        json!({"from_date": "2026-11-11", "to_date": "2026-11-11"}),
    )
    .await;
    assert_eq!(b_summary["days"][0]["energy_kcal"], "200");
}

// ─── T13 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_idempotency_is_durable_across_new_router(pool: PgPool) {
    let router_one = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router_one).await;
    let product = seed_product(&router_one, &user, "MCP Durable Food", 100).await;
    let write = create_mcp_api_key(&router_one, &user, "MCP durable", Some("read_write")).await;
    let profile = profile_id(&router_one, &user).await;

    let args = |key: &str| {
        json!({
            "log_date": "2026-11-12",
            "item": {"type": "product", "id": product},
            "quantity": {"amount": 100, "unit": "g"},
            "idempotency_key": key
        })
    };

    let first = tool_call_ok(
        &router_one,
        &write.token,
        1,
        "create_log",
        args("durable-key"),
    )
    .await;
    let first_id = first["id"].as_str().expect("first id").to_owned();
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let router_two = app(pool.clone()).await;
    let retried = tool_call_ok(
        &router_two,
        &write.token,
        2,
        "create_log",
        args("durable-key"),
    )
    .await;
    assert_eq!(retried["id"], first_id);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let second = tool_call_ok(
        &router_two,
        &write.token,
        3,
        "create_log",
        args("durable-key-2"),
    )
    .await;
    let second_id = second["id"].as_str().expect("second id").to_owned();
    assert_ne!(second_id, first_id);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 2);
}

// ─── T14 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_concurrent_duplicates_produce_one_row(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Concurrent Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP concurrent", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let arguments = json!({
        "log_date": "2026-11-13",
        "item": {"type": "product", "id": product},
        "quantity": {"amount": 150, "unit": "g"},
        "idempotency_key": "concurrent-key"
    });

    let mut tasks = tokio::task::JoinSet::new();
    for index in 0..6 {
        let router = router.clone();
        let token = write.token.clone();
        let arguments = arguments.clone();
        tasks.spawn(async move {
            tool_call_ok(&router, &token, 100 + index, "create_log", arguments).await
        });
    }

    let mut ids = BTreeSet::new();
    while let Some(result) = tasks.join_next().await {
        let result = result.expect("concurrent create task");
        ids.insert(
            result["id"]
                .as_str()
                .expect("concurrent created log id")
                .to_owned(),
        );
    }
    assert_eq!(ids.len(), 1, "concurrent retries produced different logs");
    let log_id = ids.into_iter().next().expect("one log id");

    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);
    assert_eq!(count_log_nutrients(&pool, &log_id).await, 4);

    let summary = tool_call_ok(
        &router,
        &write.token,
        200,
        "get_daily_summary",
        json!({"from_date": "2026-11-13", "to_date": "2026-11-13"}),
    )
    .await;
    assert_eq!(
        summary["days"][0]["energy_kcal"], "150",
        "concurrent duplicate was counted twice"
    );
}

// ─── T15 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn create_log_rejects_invalid_and_oversized_idempotency_keys(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Idempotency Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP key limits", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;

    let tools = list_tools(&router, &write.token, 1).await;
    let create = tool_named(&tools, "create_log");
    assert_eq!(
        create["inputSchema"]["properties"]["idempotency_key"]["maxLength"],
        128
    );

    let key_128 = "k".repeat(128);
    let args = |key: Value| {
        json!({
            "log_date": "2026-11-14",
            "item": {"type": "product", "id": product},
            "quantity": {"amount": 100, "unit": "g"},
            "idempotency_key": key
        })
    };

    let created = tool_call_ok(&router, &write.token, 2, "create_log", args(json!(key_128))).await;
    let log_id = created["id"].as_str().expect("created log id").to_owned();
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let retried = tool_call_ok(&router, &write.token, 3, "create_log", args(json!(key_128))).await;
    assert_eq!(retried["id"], log_id);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let key_129 = "k".repeat(129);
    let text = tool_call_err(
        &router,
        &write.token,
        4,
        "create_log",
        args(json!(key_129)),
        "idempotency_key",
    )
    .await;
    assert_safe_tool_error_text(&text);
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let text = tool_call_err(
        &router,
        &write.token,
        5,
        "create_log",
        args(json!("   ")),
        "idempotency_key",
    )
    .await;
    assert_safe_tool_error_text(&text);
    assert!(text.contains("blank"), "unexpected blank-key error: {text}");
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let text = tool_call_err(
        &router,
        &write.token,
        6,
        "create_log",
        args(json!("bad\u{0}key")),
        "idempotency_key",
    )
    .await;
    assert_safe_tool_error_text(&text);
    assert!(
        text.contains("control"),
        "unexpected control-character error: {text}"
    );
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);
}

// ─── T16 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn cookie_only_and_revoked_keys_are_rejected_for_write_tools(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (admin, user_a) = bootstrap_and_user(&router).await;
    let user_b = create_user_session(&router, &admin, "mcp-auth-user-b", "testpassword").await;
    let product = seed_product(&router, &user_a, "MCP Auth Food", 100).await;
    let profile_a = profile_id(&router, &user_a).await;
    let profile_b = profile_id(&router, &user_b).await;

    let send_cookie_create = |id: i64| {
        let router = router.clone();
        let user = user_a.clone();
        let arguments = create_args(&product, "2026-11-07");
        async move {
            let (status, headers, bytes) = send_mcp(
                &router,
                McpRequest::post(tool_call_body(id, "create_log", arguments)).cookie(&user),
            )
            .await;
            let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
            assert_auth_error(status, &headers, &body);
        }
    };
    send_cookie_create(1).await;
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 0);

    let seeded = seed_log(&router, &user_a, &product, "2026-11-07", 100).await;
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 1);
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(2, "delete_log", json!({"log_id": seeded})))
            .cookie(&user_a),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 1);
    let fetched: Value = get_json(&router, &format!("/api/logs/{seeded}"), &user_a).await;
    assert_eq!(fetched["id"], seeded);

    let revocable = create_mcp_api_key(&router, &user_a, "MCP revocable", Some("read_write")).await;
    let created = tool_call_ok(
        &router,
        &revocable.token,
        3,
        "create_log",
        create_args(&product, "2026-11-07"),
    )
    .await;
    let created_id = created["id"].as_str().expect("created log id").to_owned();
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 2);

    revoke_api_key(&router, &user_a, &revocable.id).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            4,
            "delete_log",
            json!({"log_id": created_id}),
        ))
        .token(&revocable.token),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 2);

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            5,
            "create_log",
            create_args(&product, "2026-11-07"),
        ))
        .token(&revocable.token),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 2);

    let write = create_mcp_api_key(
        &router,
        &user_a,
        "MCP write with B cookie",
        Some("read_write"),
    )
    .await;
    let b_before = count_logs_for_user(&pool, &profile_b).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            6,
            "create_log",
            create_args(&product, "2026-11-07"),
        ))
        .token(&write.token)
        .cookie(&user_b),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let created = structured_result(&body);
    let created_id = created["id"].as_str().expect("created log id").to_owned();
    assert_eq!(log_owner(&pool, &created_id).await, profile_a);
    assert_eq!(
        count_logs_for_user(&pool, &profile_b).await,
        b_before,
        "a foreign browser cookie changed the write owner"
    );

    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            7,
            "create_log",
            create_args(&product, "2026-11-07"),
        ))
        .authorization("Basic abc")
        .cookie(&user_a),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 3);

    let duplicate =
        create_mcp_api_key(&router, &user_a, "MCP duplicate auth", Some("read_write")).await;
    let raw = format!("Bearer {}", duplicate.token);
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            8,
            "create_log",
            create_args(&product, "2026-11-07"),
        ))
        .header("authorization", &raw)
        .header("authorization", &raw),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert_eq!(count_logs_for_user(&pool, &profile_a).await, 3);
}

// ─── T17 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn last_used_at_updates_for_successful_writes_and_not_failed_auth(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Last Used Food", 100).await;

    let used_key = create_mcp_api_key(&router, &user, "MCP used write", Some("read_write")).await;
    assert!(last_used_at(&pool, &used_key.id).await.is_none());
    let _ = tool_call_ok(
        &router,
        &used_key.token,
        1,
        "create_log",
        create_args(&product, "2026-11-08"),
    )
    .await;
    let touched = last_used_at(&pool, &used_key.id)
        .await
        .expect("successful write must update last_used_at");

    let unused_revoked =
        create_mcp_api_key(&router, &user, "MCP unused revoked", Some("read_write")).await;
    assert!(last_used_at(&pool, &unused_revoked.id).await.is_none());
    revoke_api_key(&router, &user, &unused_revoked.id).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            2,
            "create_log",
            create_args(&product, "2026-11-08"),
        ))
        .token(&unused_revoked.token),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert!(
        last_used_at(&pool, &unused_revoked.id).await.is_none(),
        "failed authentication touched last_used_at"
    );

    revoke_api_key(&router, &user, &used_key.id).await;
    let (status, headers, bytes) = send_mcp(
        &router,
        McpRequest::post(tool_call_body(
            3,
            "create_log",
            create_args(&product, "2026-11-08"),
        ))
        .token(&used_key.token),
    )
    .await;
    let body: Value = serde_json::from_slice(&bytes).expect("auth error JSON");
    assert_auth_error(status, &headers, &body);
    assert_eq!(
        last_used_at(&pool, &used_key.id).await,
        Some(touched),
        "failed authentication changed last_used_at"
    );

    let delete_key =
        create_mcp_api_key(&router, &user, "MCP delete write", Some("read_write")).await;
    assert!(last_used_at(&pool, &delete_key.id).await.is_none());
    let seeded = seed_log(&router, &user, &product, "2026-11-08", 100).await;
    let deleted = tool_call_ok(
        &router,
        &delete_key.token,
        4,
        "delete_log",
        json!({"log_id": seeded}),
    )
    .await;
    assert_eq!(deleted, json!({"deleted": true}));
    assert!(
        last_used_at(&pool, &delete_key.id).await.is_some(),
        "successful delete must update last_used_at"
    );
}

// ─── T18 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn mcp_writes_preserve_host_origin_and_cors(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP CORS Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP cors write", Some("read_write")).await;
    let profile = profile_id(&router, &user).await;
    let custom = app_with_config(
        pool.clone(),
        test_config_with_mcp(&["https://app.example"], &["mcp.example.test"]),
    )
    .await;

    let (status, headers, bytes) = send_mcp(
        &custom,
        McpRequest::post(tool_call_body(
            1,
            "create_log",
            create_args(&product, "2026-11-15"),
        ))
        .token(&write.token)
        .host("mcp.example.test")
        .header(header::ORIGIN.as_str(), "https://app.example"),
    )
    .await;
    let body = assert_json_response(status, &headers, &bytes, StatusCode::OK);
    let result = structured_result(&body);
    assert!(result["id"].is_string());
    assert_no_session_headers(&headers);
    assert_eq!(
        headers.get(header::ACCESS_CONTROL_ALLOW_ORIGIN).unwrap(),
        "https://app.example"
    );
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let (status, _headers, bytes) = send_mcp(
        &custom,
        McpRequest::post(tool_call_body(
            2,
            "create_log",
            create_args(&product, "2026-11-15"),
        ))
        .token(&write.token)
        .host("evil.example"),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "body: {bytes:?}");
    let body_text = String::from_utf8_lossy(&bytes);
    assert!(body_text.contains("Host header is not allowed"));
    assert!(!body_text.contains("structuredContent"));
    assert!(!body_text.contains("\"isError\""));
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let (status, _headers, bytes) = send_mcp(
        &custom,
        McpRequest::post(tool_call_body(
            3,
            "create_log",
            create_args(&product, "2026-11-15"),
        ))
        .token(&write.token)
        .host("mcp.example.test")
        .header(header::ORIGIN.as_str(), "https://evil.example"),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "body: {bytes:?}");
    assert!(String::from_utf8_lossy(&bytes).contains("Origin"));
    assert_eq!(count_logs_for_user(&pool, &profile).await, 1);

    let preflight_key =
        create_mcp_api_key(&router, &user, "MCP write preflight", Some("read_write")).await;
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

// ─── T19 ───────────────────────────────────────────────────────────────

#[sqlx::test]
async fn rest_and_mcp_share_response_shape_and_list_order(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let product = seed_product(&router, &user, "MCP Parity Food", 100).await;
    let write = create_mcp_api_key(&router, &user, "MCP parity write", Some("read_write")).await;

    let lunch = tool_call_ok(
        &router,
        &write.token,
        1,
        "create_log",
        json!({
            "log_date": "2026-11-10",
            "meal_slot": "lunch",
            "device_timezone": "Asia/Kolkata",
            "item": {"type": "product", "id": product},
            "quantity": {"amount": 150, "unit": "g"},
            "notes": "MCP lunch"
        }),
    )
    .await;
    let lunch_id = lunch["id"].as_str().expect("lunch id").to_owned();
    assert_eq!(
        object_keys(&lunch),
        [
            "created_at",
            "device_timezone",
            "id",
            "item",
            "log_date",
            "meal_slot",
            "notes",
            "nutrients",
            "quantity",
            "updated_at"
        ]
    );
    assert!(lunch.get("idempotency_key").is_none());

    let rest_lunch: Value = get_json(&router, &format!("/api/logs/{lunch_id}"), &user).await;
    let mut lunch_normalized = lunch.clone();
    normalize_timestamps(&mut lunch_normalized);
    normalize_decimal_amounts(&mut lunch_normalized);
    let mut rest_lunch_normalized = rest_lunch.clone();
    normalize_timestamps(&mut rest_lunch_normalized);
    normalize_decimal_amounts(&mut rest_lunch_normalized);
    assert_eq!(
        lunch_normalized, rest_lunch_normalized,
        "create_log response must match GET /api/logs/<id> apart from timestamp precision"
    );

    let (dinner_id, dinner) =
        create_rest_log(&router, &user, &product, "2026-11-10", "dinner", 50).await;
    let (breakfast_id, _breakfast) =
        create_rest_log(&router, &user, &product, "2026-11-10", "breakfast", 100).await;
    let (snack_id, _snack) =
        create_rest_log(&router, &user, &product, "2026-11-10", "snack", 25).await;

    let listed = tool_call_ok(
        &router,
        &write.token,
        2,
        "list_logs",
        json!({"log_date": "2026-11-10"}),
    )
    .await;
    let rest_list: Value = get_json(&router, "/api/logs?log_date=2026-11-10", &user).await;
    assert_eq!(listed, rest_list, "MCP and REST lists must match exactly");
    assert_eq!(object_keys(&listed), ["items", "log_date"]);
    let slots: Vec<&str> = listed["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["meal_slot"].as_str().expect("meal slot"))
        .collect();
    assert_eq!(slots, ["breakfast", "lunch", "dinner", "snack"]);
    let ids: Vec<&str> = listed["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["id"].as_str().expect("log id"))
        .collect();
    assert_eq!(
        ids,
        [
            breakfast_id.as_str(),
            lunch_id.as_str(),
            dinner_id.as_str(),
            snack_id.as_str()
        ]
    );

    let summary = tool_call_ok(
        &router,
        &write.token,
        3,
        "get_daily_summary",
        json!({"from_date": "2026-11-10", "to_date": "2026-11-10"}),
    )
    .await;
    let rest_summary: Value = get_json(
        &router,
        "/api/logs/summary?from_date=2026-11-10&to_date=2026-11-10",
        &user,
    )
    .await;
    assert_eq!(summary, rest_summary, "MCP and REST summaries must match");
    assert_eq!(summary["days"][0]["energy_kcal"], "325");
    assert_eq!(object_keys(&summary), ["days"]);

    let deleted = tool_call_ok(
        &router,
        &write.token,
        4,
        "delete_log",
        json!({"log_id": lunch_id}),
    )
    .await;
    assert_eq!(deleted, json!({"deleted": true}));

    let after = tool_call_ok(
        &router,
        &write.token,
        5,
        "list_logs",
        json!({"log_date": "2026-11-10"}),
    )
    .await;
    let rest_after: Value = get_json(&router, "/api/logs?log_date=2026-11-10", &user).await;
    assert_eq!(after, rest_after);
    let after_ids: Vec<&str> = after["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["id"].as_str().expect("log id"))
        .collect();
    assert_eq!(
        after_ids,
        [breakfast_id.as_str(), dinner_id.as_str(), snack_id.as_str()]
    );

    let summary_after = tool_call_ok(
        &router,
        &write.token,
        6,
        "get_daily_summary",
        json!({"from_date": "2026-11-10", "to_date": "2026-11-10"}),
    )
    .await;
    let rest_summary_after: Value = get_json(
        &router,
        "/api/logs/summary?from_date=2026-11-10&to_date=2026-11-10",
        &user,
    )
    .await;
    assert_eq!(summary_after, rest_summary_after);
    assert_eq!(summary_after["days"][0]["energy_kcal"], "175");
    let (status, _body) = get_status(&router, &format!("/api/logs/{lunch_id}"), &user).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    assert!(dinner.get("deleted").is_none());
    assert!(dinner.get("idempotency_key").is_none());
}

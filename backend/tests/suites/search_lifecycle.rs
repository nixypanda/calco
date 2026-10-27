use crate::common::*;
use axum::http::StatusCode;
use chrono::{TimeZone, Utc};
use serde_json::{Value, json};
use sqlx::PgPool;

async fn create_custom_product(
    router: &axum::Router,
    user: &str,
    name: &str,
    brand: &str,
    categories: &[&str],
) -> String {
    let payload = json!({
        "name": name,
        "brand": brand,
        "categories": categories,
        "default_quantity": 1,
        "default_unit": "g",
        "nutrients": [
            { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
            { "code": "PROTEIN_G", "amount_per_100g": 1 },
            { "code": "CARBS_G", "amount_per_100g": 10 },
            { "code": "FAT_G", "amount_per_100g": 1 }
        ],
        "servings": [
            { "unit": "serving", "grams_per_unit": 100 }
        ]
    });
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        user,
        &payload,
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().expect("id missing").to_string()
}

async fn insert_external_product(
    pool: &PgPool,
    source_id: &str,
    name: &str,
    brand: Option<&str>,
    barcode: Option<&str>,
    categories: &[&str],
) -> String {
    let categories: Vec<String> = categories
        .iter()
        .map(|value| (*value).to_string())
        .collect();
    let id: uuid::Uuid = sqlx::query_scalar(
        r#"
        INSERT INTO products (source, source_id, visibility, name, brand, barcode, categories)
        VALUES ('OFF', $1, 'global', $2, $3, $4, $5)
        RETURNING id
        "#,
    )
    .bind(source_id)
    .bind(name)
    .bind(brand)
    .bind(barcode)
    .bind(categories)
    .fetch_one(pool)
    .await
    .expect("insert external product");
    id.to_string()
}

async fn log_product(router: &axum::Router, user: &str, product_id: &str, log_date: &str) {
    let payload = json!({
        "log_date": log_date,
        "meal_slot": "breakfast",
        "item": { "type": "product", "id": product_id },
        "quantity": { "amount": 100, "unit": "g" }
    });
    let _: Value = post_json(router, "/api/logs", user, &payload, StatusCode::CREATED).await;
}

async fn search_items(router: &axum::Router, user: &str, query: &str, scope: &str) -> Vec<Value> {
    let params = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("q", query)
        .append_pair("scope", scope)
        .finish();
    let response: Value = get_json(router, &format!("/api/foods/search?{params}"), user).await;
    response["items"].as_array().expect("items missing").clone()
}

async fn search_ids(router: &axum::Router, user: &str, query: &str, scope: &str) -> Vec<String> {
    search_items(router, user, query, scope)
        .await
        .iter()
        .map(|item| item["id"].as_str().expect("id missing").to_string())
        .collect()
}

async fn category_suggestions(
    router: &axum::Router,
    user: &str,
    query: Option<&str>,
) -> Vec<(String, i64)> {
    category_suggestions_with_limit(router, user, query, 10).await
}

async fn category_suggestions_with_limit(
    router: &axum::Router,
    user: &str,
    query: Option<&str>,
    limit: i64,
) -> Vec<(String, i64)> {
    let mut params = url::form_urlencoded::Serializer::new(String::new());
    if let Some(query) = query {
        params.append_pair("q", query);
    }
    params.append_pair("limit", &limit.to_string());
    let response: Value = get_json(
        router,
        &format!("/api/foods/categories?{}", params.finish()),
        user,
    )
    .await;
    response["items"]
        .as_array()
        .expect("items missing")
        .iter()
        .map(|item| {
            (
                item["value"].as_str().expect("value missing").to_string(),
                item["count"].as_i64().expect("count missing"),
            )
        })
        .collect()
}

fn assert_ids_unordered(mut actual: Vec<String>, mut expected: Vec<String>) {
    actual.sort();
    expected.sort();
    assert_eq!(actual, expected);
}

#[sqlx::test]
async fn catalog_search_orders_by_match_tier(pool: PgPool) {
    // Insert in reverse tier order on purpose: insertion order must not affect
    // ranking, and hydration must restore the ranker's order.
    let fuzzy_typo =
        insert_external_product(&pool, "tier-fuzzy-typo", "tier-tokeen", None, None, &[]).await;
    let brand_substring = insert_external_product(
        &pool,
        "tier-brand-substring",
        "Zzz brand substring",
        Some("zzz tier-token brand"),
        None,
        &[],
    )
    .await;
    let brand_prefix = insert_external_product(
        &pool,
        "tier-brand-prefix",
        "Zzz brand prefix",
        Some("tier-token brand"),
        None,
        &[],
    )
    .await;
    let name_substring = insert_external_product(
        &pool,
        "tier-name-substring",
        "zzz tier-token name substring",
        None,
        None,
        &[],
    )
    .await;
    let name_prefix = insert_external_product(
        &pool,
        "tier-name-prefix",
        "tier-token name prefix",
        None,
        None,
        &[],
    )
    .await;
    let barcode_prefix = insert_external_product(
        &pool,
        "tier-barcode-prefix",
        "Zzz prefix barcode",
        None,
        Some("tier-token-2"),
        &[],
    )
    .await;
    let barcode_exact = insert_external_product(
        &pool,
        "tier-barcode-exact",
        "Zzz exact barcode",
        None,
        Some("tier-token"),
        &[],
    )
    .await;
    let unrelated =
        insert_external_product(&pool, "tier-unrelated", "Unrelated Food", None, None, &[]).await;

    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let ids = search_ids(&router, &user, "tier-token", "all").await;

    assert_eq!(
        ids,
        vec![
            barcode_exact,
            barcode_prefix,
            name_prefix,
            name_substring,
            brand_prefix,
            brand_substring,
            fuzzy_typo,
        ]
    );
    assert!(
        !ids.contains(&unrelated),
        "unrelated product must not match"
    );
}

#[sqlx::test]
async fn catalog_search_hydrates_brand_barcode_source_and_categories(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let external = insert_external_product(
        &pool,
        "hydration-external",
        "Hydration External",
        Some("Hydration Brand"),
        Some("hydration-barcode"),
        &["hydration category"],
    )
    .await;
    let custom = create_custom_product(
        &router,
        &user,
        "Hydration Custom",
        "Hydration Custom Brand",
        &["hydration custom"],
    )
    .await;

    let items = search_items(&router, &user, "hydration", "all").await;
    let external_item = items
        .iter()
        .find(|item| item["id"] == external)
        .expect("external item missing");
    assert_eq!(external_item["source"], "OFF");
    assert_eq!(external_item["source_id"], "hydration-external");
    assert_eq!(external_item["barcode"], "hydration-barcode");
    assert_eq!(external_item["brand"], "Hydration Brand");
    assert_eq!(external_item["categories"], json!(["hydration category"]));

    let custom_item = items
        .iter()
        .find(|item| item["id"] == custom)
        .expect("custom item missing");
    assert_eq!(custom_item["source"], "USER");
    assert!(custom_item["barcode"].is_null());
    assert_eq!(custom_item["brand"], "Hydration Custom Brand");
    assert_eq!(custom_item["categories"], json!(["hydration custom"]));
}

#[sqlx::test]
async fn catalog_search_applies_include_and_exclude_category_filters(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let oats = create_custom_product(
        &router,
        &user,
        "Filter Oats",
        "Filter Lab",
        &["breakfast", "grain"],
    )
    .await;
    let yogurt = create_custom_product(
        &router,
        &user,
        "Filter Yogurt",
        "Filter Lab",
        &["breakfast", "dairy"],
    )
    .await;
    let chips =
        create_custom_product(&router, &user, "Filter Chips", "Filter Lab", &["snack"]).await;

    let breakfast = search_ids(&router, &user, "filter category:breakfast", "all").await;
    assert_ids_unordered(breakfast, vec![oats.clone(), yogurt.clone()]);

    let without_dairy = search_ids(&router, &user, "filter -category:dairy", "all").await;
    assert_ids_unordered(without_dairy, vec![oats.clone(), chips.clone()]);

    let breakfast_without_grain = search_ids(
        &router,
        &user,
        "filter category:breakfast -category:grain",
        "all",
    )
    .await;
    assert_eq!(breakfast_without_grain, vec![yogurt.clone()]);

    let custom_breakfast = search_ids(&router, &user, "filter category:breakfast", "custom").await;
    assert_ids_unordered(custom_breakfast, vec![oats.clone(), yogurt.clone()]);

    log_product(&router, &user, &oats, "2026-06-01").await;
    log_product(&router, &user, &yogurt, "2026-06-02").await;
    log_product(&router, &user, &chips, "2026-06-03").await;

    let history_breakfast =
        search_ids(&router, &user, "filter category:breakfast", "history").await;
    assert_ids_unordered(history_breakfast, vec![oats, yogurt]);
}

#[sqlx::test]
async fn catalog_search_matches_typos(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let granola =
        create_custom_product(&router, &user, "Granola", "Typo Lab", &["breakfast"]).await;

    let ids = search_ids(&router, &user, "granila", "all").await;

    assert!(
        ids.contains(&granola),
        "expected typo query to return {granola}; got {ids:?}"
    );
}

#[sqlx::test]
async fn catalog_search_treats_percent_and_underscore_literally(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let percent = create_custom_product(&router, &user, "100% Juice", "Literal Lab", &[]).await;
    let underscore = create_custom_product(&router, &user, "foo_bar", "Literal Lab", &[]).await;
    let plain = create_custom_product(&router, &user, "Plain Juice", "Literal Lab", &[]).await;

    let percent_ids = search_ids(&router, &user, "%", "all").await;
    assert_eq!(percent_ids, vec![percent]);
    assert!(!percent_ids.contains(&plain));

    let underscore_ids = search_ids(&router, &user, "_", "all").await;
    assert_eq!(underscore_ids, vec![underscore]);
    assert!(!underscore_ids.contains(&plain));
}

#[sqlx::test]
async fn catalog_search_empty_query_puts_barcoded_products_first(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    // Create the non-barcoded product first so expected order differs from
    // insertion order.
    let alpha = create_custom_product(&router, &user, "Alpha", "Empty Query Lab", &[]).await;
    let zebra = insert_external_product(
        &pool,
        "empty-query-barcoded",
        "Zebra",
        None,
        Some("12345"),
        &[],
    )
    .await;

    let ids = search_ids(&router, &user, "", "all").await;

    assert_eq!(ids, vec![zebra, alpha]);
}

#[sqlx::test]
async fn catalog_search_limits_results_to_fifty_after_ranking(pool: PgPool) {
    for index in 0..55 {
        insert_external_product(
            &pool,
            &format!("limit-token-{index:02}"),
            &format!("Zzz Limit Token {index:02}"),
            None,
            None,
            &[],
        )
        .await;
    }
    // These exact-name matches are inserted last, so a pre-ranking SQL LIMIT
    // would drop them from the first 50 physical rows.
    let mut best = Vec::new();
    for index in 0..5 {
        best.push(
            insert_external_product(
                &pool,
                &format!("limit-token-best-{index:02}"),
                "Limit Token",
                None,
                None,
                &[],
            )
            .await,
        );
    }

    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    let ids = search_ids(&router, &user, "limit token", "all").await;

    assert_eq!(ids.len(), 50, "expected the search limit of 50");
    for id in best {
        assert!(
            ids.contains(&id),
            "exact-name match inserted last must survive ranking; got {ids:?}"
        );
    }
}

#[sqlx::test]
async fn catalog_search_skips_products_with_blank_stored_names(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let valid = create_custom_product(
        &router,
        &user,
        "Valid Searchable Food",
        "Resilient Lab",
        &[],
    )
    .await;
    let invalid = insert_external_product(&pool, "blank-stored-name", "", None, None, &[]).await;

    let ids = search_ids(&router, &user, "valid", "all").await;
    assert_eq!(ids, vec![valid.clone()]);

    let empty_query = search_ids(&router, &user, "", "all").await;
    assert!(empty_query.contains(&valid));
    assert!(
        !empty_query.contains(&invalid),
        "malformed stored row must be skipped, not abort or match the search"
    );
}

#[sqlx::test]
async fn catalog_search_scopes_filter_catalog_and_history_by_source_and_user(pool: PgPool) {
    let router = app(pool.clone()).await;
    let admin = bootstrap_admin(&router).await;
    let user_a = create_user_session(&router, &admin, "scope_a", "testpassword").await;
    let user_b = create_user_session(&router, &admin, "scope_b", "testpassword").await;

    let external =
        insert_external_product(&pool, "scope-external", "Scope External", None, None, &[]).await;
    let custom_a =
        create_custom_product(&router, &user_a, "Scope Custom A", "Scope Lab", &["scope"]).await;
    let custom_b =
        create_custom_product(&router, &user_b, "Scope Custom B", "Scope Lab", &["scope"]).await;

    let all = search_ids(&router, &user_a, "scope", "all").await;
    assert_ids_unordered(
        all,
        vec![external.clone(), custom_a.clone(), custom_b.clone()],
    );

    let custom = search_ids(&router, &user_a, "scope", "custom").await;
    assert_ids_unordered(custom, vec![custom_a.clone(), custom_b.clone()]);

    log_product(&router, &user_b, &custom_b, "2026-06-01").await;
    let history_a = search_ids(&router, &user_a, "scope", "history").await;
    assert!(
        !history_a.contains(&custom_b),
        "user A history must not include user B's log; got {history_a:?}"
    );

    log_product(&router, &user_a, &custom_a, "2026-06-02").await;
    let history_a = search_ids(&router, &user_a, "scope", "history").await;
    assert_eq!(history_a, vec![custom_a]);
    assert!(!history_a.contains(&custom_b));
}

#[sqlx::test]
async fn history_search_matches_category_text(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let dairy =
        create_custom_product(&router, &user, "Neutral One", "Neutral Lab", &["dairy"]).await;
    let snacks =
        create_custom_product(&router, &user, "Neutral Two", "Neutral Lab", &["snacks"]).await;
    for scope in ["all", "custom"] {
        let ids = search_ids(&router, &user, "dairy", scope).await;
        assert!(
            !ids.contains(&dairy),
            "category text must only match in History, not {scope}; got {ids:?}"
        );
    }

    log_product(&router, &user, &dairy, "2026-06-01").await;
    log_product(&router, &user, &snacks, "2026-06-02").await;

    let ids = search_ids(&router, &user, "dairy", "history").await;

    assert_eq!(ids, vec![dairy]);
    assert!(!ids.contains(&snacks));
}

#[sqlx::test]
async fn history_search_uses_same_day_creation_time_before_relevance(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let strong_match =
        create_custom_product(&router, &user, "Greek Yogurt", "Neutral Lab", &["snacks"]).await;
    let weak_match =
        create_custom_product(&router, &user, "Neutral Snack", "Neutral Lab", &["yogurt"]).await;

    log_product(&router, &user, &strong_match, "2026-06-01").await;
    log_product(&router, &user, &weak_match, "2026-06-01").await;

    let older = Utc.with_ymd_and_hms(2026, 6, 1, 8, 0, 0).unwrap();
    let newer = Utc.with_ymd_and_hms(2026, 6, 1, 20, 0, 0).unwrap();
    sqlx::query("UPDATE food_logs SET created_at = $1 WHERE item_product_id = $2")
        .bind(older)
        .bind(uuid::Uuid::parse_str(&strong_match).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("UPDATE food_logs SET created_at = $1 WHERE item_product_id = $2")
        .bind(newer)
        .bind(uuid::Uuid::parse_str(&weak_match).unwrap())
        .execute(&pool)
        .await
        .unwrap();

    let ids = search_ids(&router, &user, "yogurt", "history").await;

    assert_eq!(
        ids,
        vec![weak_match, strong_match],
        "same-day History ordering must use MAX(created_at) before relevance"
    );
}

#[sqlx::test]
async fn deleted_products_disappear_from_search_and_category_counts(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let category = "deletion-unicorn";
    let id = create_custom_product(
        &router,
        &user,
        "Deletion Probe",
        "Deletion Lab",
        &[category],
    )
    .await;

    let all = search_ids(&router, &user, "deletion", "all").await;
    assert!(all.contains(&id));
    let custom = search_ids(&router, &user, "deletion", "custom").await;
    assert!(custom.contains(&id));

    log_product(&router, &user, &id, "2026-06-01").await;
    let history = search_ids(&router, &user, "deletion", "history").await;
    assert!(history.contains(&id));

    let suggestions = category_suggestions(&router, &user, Some(category)).await;
    assert!(
        suggestions.iter().any(|(value, _)| value == category),
        "expected the category before deletion; got {suggestions:?}"
    );

    delete_no_content(&router, &format!("/api/foods/custom/{id}"), &user).await;

    for scope in ["all", "custom", "history"] {
        let ids = search_ids(&router, &user, "deletion", scope).await;
        assert!(
            !ids.contains(&id),
            "deleted product must not appear in {scope}; got {ids:?}"
        );
    }
    let suggestions = category_suggestions(&router, &user, Some(category)).await;
    assert!(
        !suggestions.iter().any(|(value, _)| value == category),
        "deleted category must not be suggested; got {suggestions:?}"
    );
}

#[sqlx::test]
async fn category_suggestions_rank_prefix_substring_fuzzy_and_count(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    for name in ["Dairy Product One", "Dairy Product Two"] {
        create_custom_product(&router, &user, name, "Category Lab", &["dairy products"]).await;
    }
    create_custom_product(&router, &user, "Plain Dairy", "Category Lab", &["dairy"]).await;
    create_custom_product(&router, &user, "Non Dairy", "Category Lab", &["non-dairy"]).await;
    create_custom_product(&router, &user, "Dairy Typo", "Category Lab", &["daiiry"]).await;
    create_custom_product(
        &router,
        &user,
        "Zeppelin Food",
        "Category Lab",
        &["zeppelin"],
    )
    .await;

    let suggestions = category_suggestions(&router, &user, Some("dairy")).await;

    assert_eq!(
        suggestions,
        vec![
            ("dairy products".to_string(), 2),
            ("dairy".to_string(), 1),
            ("non-dairy".to_string(), 1),
            ("daiiry".to_string(), 1),
        ]
    );
    assert!(
        !suggestions.iter().any(|(value, _)| value == "zeppelin"),
        "unrelated category must not be suggested"
    );

    let limited = category_suggestions_with_limit(&router, &user, Some("dairy"), 1).await;
    assert_eq!(limited, vec![("dairy products".to_string(), 2)]);

    create_custom_product(
        &router,
        &user,
        "Veggie Probe",
        "Category Lab",
        &["other-vegetables"],
    )
    .await;
    let boundary = category_suggestions(&router, &user, Some("vegtable")).await;
    assert_eq!(boundary, vec![("other-vegetables".to_string(), 1)]);
}

#[sqlx::test]
async fn category_suggestions_http_limit_contract(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    for category in ["alpha", "beta", "gamma"] {
        create_custom_product(&router, &user, category, "Limit Lab", &[category]).await;
    }

    assert_eq!(
        category_suggestions_with_limit(&router, &user, None, 0)
            .await
            .len(),
        1
    );
    assert_eq!(
        category_suggestions_with_limit(&router, &user, None, -1)
            .await
            .len(),
        1
    );
    assert_eq!(
        category_suggestions_with_limit(&router, &user, None, 100)
            .await
            .len(),
        3
    );
}

#[sqlx::test]
async fn category_suggestions_empty_query_orders_by_count_then_name(pool: PgPool) {
    let router = app(pool).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    create_custom_product(&router, &user, "Apple One", "Count Lab", &["apples"]).await;
    create_custom_product(&router, &user, "Apple Two", "Count Lab", &["apples"]).await;
    create_custom_product(&router, &user, "Zebra Snack", "Count Lab", &["zebras"]).await;
    create_custom_product(&router, &user, "Snack Mix", "Count Lab", &["snacks"]).await;

    let suggestions = category_suggestions(&router, &user, None).await;

    assert_eq!(
        suggestions,
        vec![
            ("apples".to_string(), 2),
            ("snacks".to_string(), 1),
            ("zebras".to_string(), 1),
        ]
    );
}

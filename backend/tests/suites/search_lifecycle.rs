use crate::common::*;
use axum::http::StatusCode;
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

    let custom_without_dairy = search_ids(&router, &user, "filter -category:dairy", "custom").await;
    assert_ids_unordered(custom_without_dairy, vec![oats.clone(), chips.clone()]);

    let custom_breakfast_without_grain = search_ids(
        &router,
        &user,
        "filter category:breakfast -category:grain",
        "custom",
    )
    .await;
    assert_eq!(custom_breakfast_without_grain, vec![yogurt.clone()]);

    log_product(&router, &user, &oats, "2026-06-01").await;
    log_product(&router, &user, &yogurt, "2026-06-02").await;
    log_product(&router, &user, &chips, "2026-06-03").await;

    let history_breakfast =
        search_ids(&router, &user, "filter category:breakfast", "history").await;
    assert_ids_unordered(history_breakfast, vec![oats.clone(), yogurt.clone()]);

    let history_without_dairy =
        search_ids(&router, &user, "filter -category:dairy", "history").await;
    assert_ids_unordered(history_without_dairy, vec![oats, chips]);

    let history_breakfast_without_grain = search_ids(
        &router,
        &user,
        "filter category:breakfast -category:grain",
        "history",
    )
    .await;
    assert_eq!(history_breakfast_without_grain, vec![yogurt]);
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
async fn category_counts_ignore_space_only_product_names(pool: PgPool) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;

    create_custom_product(
        &router,
        &user,
        "Blank Name Control",
        "Blank Lab",
        &["blank-name-visible"],
    )
    .await;
    insert_external_product(
        &pool,
        "blank-name-hidden",
        "   ",
        None,
        None,
        &["blank-name-hidden"],
    )
    .await;

    let suggestions = category_suggestions(&router, &user, Some("blank-name")).await;

    assert!(
        suggestions
            .iter()
            .any(|(value, _)| value == "blank-name-visible"),
        "visible category should still be suggested; got {suggestions:?}"
    );
    assert!(
        !suggestions
            .iter()
            .any(|(value, _)| value == "blank-name-hidden"),
        "space-only product name must be excluded from counts; got {suggestions:?}"
    );
}

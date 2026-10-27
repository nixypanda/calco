use std::collections::HashSet;

use chrono::{DateTime, TimeZone, Utc};
use rust_decimal::Decimal;
use sea_query::PostgresQueryBuilder;
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::nutrition::catalog::domain::*;

use super::PgProductRepo;
use super::statements::nutrient_ids_by_code_statement;

fn timestamp(day: u32, hour: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 6, day, hour, 0, 0).unwrap()
}

fn custom_origin(user_id: Uuid) -> ProductOrigin {
    ProductOrigin::Custom { user_id }
}

fn serving(unit: &str, grams_per_unit: i64) -> ProductServing {
    ProductServing {
        unit: UnitCode(unit.to_owned()),
        grams_per_unit: Decimal::from(grams_per_unit),
    }
}

#[allow(clippy::too_many_arguments)]
fn product_fixture(
    id: Uuid,
    origin: ProductOrigin,
    name: &str,
    brand: Option<&str>,
    categories: &[&str],
    default_quantity: Option<i64>,
    default_unit: Option<&str>,
    nutrients: Vec<ProductNutrient>,
    servings: Vec<ProductServing>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
) -> Product {
    Product {
        id: ProductId(id),
        origin,
        visibility: ProductVisibility::Global,
        name: ProductName::new(name).expect("valid product name"),
        brand: brand.map(|brand| Brand(brand.to_owned())),
        categories: categories
            .iter()
            .map(|category| Category((*category).to_owned()))
            .collect(),
        default_quantity: default_quantity.map(Decimal::from),
        default_unit: default_unit.map(|unit| UnitCode(unit.to_owned())),
        nutrients,
        servings,
        created_at,
        updated_at,
    }
}

async fn seed_identity_and_profile(pool: &PgPool, label: &str) -> Uuid {
    let identity_id = Uuid::new_v4();
    let user_id = Uuid::new_v4();

    sqlx::query(
        r#"
        INSERT INTO identities (
            id, username, password_hash, role, status, created_at, updated_at,
            session_security_stamp
        )
        VALUES ($1, $2, 'test-password-hash', 'user', 'active', now(), now(), $3)
        "#,
    )
    .bind(identity_id)
    .bind(format!("{label}-{identity_id}"))
    .bind(Uuid::new_v4())
    .execute(pool)
    .await
    .expect("seed identity");

    sqlx::query(
        r#"
        INSERT INTO user_profiles (id, identity_id, display_name, created_at, updated_at)
        VALUES ($1, $2, $3, now(), now())
        "#,
    )
    .bind(user_id)
    .bind(identity_id)
    .bind(label)
    .execute(pool)
    .await
    .expect("seed user profile");

    user_id
}

async fn seed_product(pool: &PgPool, product: &Product) {
    sqlx::query(
        r#"
        INSERT INTO products (
            id, source, source_id, user_id, visibility, barcode, name, brand, categories,
            default_quantity, default_unit, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        "#,
    )
    .bind(product.id.0)
    .bind(product.origin.source_code())
    .bind(product.origin.source_id())
    .bind(product.origin.owner_id())
    .bind(product.visibility.as_str())
    .bind(product.origin.barcode().map(|barcode| barcode.0.as_str()))
    .bind(product.name.as_str())
    .bind(product.brand.as_ref().map(|brand| brand.0.as_str()))
    .bind(
        product
            .categories
            .iter()
            .map(|category| category.0.clone())
            .collect::<Vec<_>>(),
    )
    .bind(product.default_quantity)
    .bind(product.default_unit.as_ref().map(|unit| unit.0.as_str()))
    .bind(product.created_at)
    .bind(product.updated_at)
    .execute(pool)
    .await
    .expect("seed product");

    for nutrient in &product.nutrients {
        let inserted = sqlx::query(
            r#"
            INSERT INTO product_nutrients (
                product_id, nutrient_id, amount_per_100g, source, confidence
            )
            SELECT $1, id, $3, $4, $5
            FROM nutrients
            WHERE code = $2
            "#,
        )
        .bind(product.id.0)
        .bind(&nutrient.nutrient_code.0)
        .bind(nutrient.amount_per_100g.value())
        .bind(nutrient.source.as_deref())
        .bind(
            nutrient
                .confidence
                .as_ref()
                .map(|confidence| confidence.as_str()),
        )
        .execute(pool)
        .await
        .expect("seed product nutrient");
        assert_eq!(
            inserted.rows_affected(),
            1,
            "seed nutrient code must exist: {}",
            nutrient.nutrient_code.0
        );
    }

    for (position, serving) in product.servings.iter().enumerate() {
        sqlx::query(
            r#"
            INSERT INTO product_servings (product_id, unit, grams_per_unit, position)
            VALUES ($1, $2, $3, $4)
            "#,
        )
        .bind(product.id.0)
        .bind(serving.unit.0.as_str())
        .bind(serving.grams_per_unit)
        .bind(position as i32)
        .execute(pool)
        .await
        .expect("seed product serving");
    }
}

async fn insert_serving_row(
    pool: &PgPool,
    product_id: Uuid,
    serving: &ProductServing,
    position: i32,
) {
    sqlx::query(
        r#"
        INSERT INTO product_servings (product_id, unit, grams_per_unit, position)
        VALUES ($1, $2, $3, $4)
        "#,
    )
    .bind(product_id)
    .bind(serving.unit.0.as_str())
    .bind(serving.grams_per_unit)
    .bind(position)
    .execute(pool)
    .await
    .expect("insert product serving row");
}

#[sqlx::test]
async fn nutrient_id_lookup_resolves_multiple_codes(pool: PgPool) {
    let codes = vec![
        "ENERGY_KCAL".to_owned(),
        "PROTEIN_G".to_owned(),
        "FAT_G".to_owned(),
    ];
    let (sql, values) = nutrient_ids_by_code_statement(&codes).build_sqlx(PostgresQueryBuilder);

    let rows: Vec<(String, Uuid)> =
        sqlx::query_as_with::<_, (String, Uuid), _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_all(&pool)
            .await
            .expect("resolve nutrient ids");
    let resolved: HashSet<String> = rows.into_iter().map(|(code, _)| code).collect();
    assert_eq!(
        resolved.len(),
        codes.len(),
        "nutrient lookup must resolve every requested code"
    );
    for code in &codes {
        assert!(
            resolved.contains(code),
            "nutrient lookup must resolve {code}"
        );
    }
}

#[sqlx::test]
async fn serving_loads_return_position_order_without_normalizing(pool: PgPool) {
    let user_id = seed_identity_and_profile(&pool, "catalog-serving-order").await;
    let created_at = timestamp(2, 8);
    let product = product_fixture(
        Uuid::new_v4(),
        custom_origin(user_id),
        "Reversed serving product",
        None,
        &["serving-order"],
        None,
        None,
        vec![],
        vec![],
        created_at,
        created_at,
    );
    seed_product(&pool, &product).await;

    // Insert position 1 first so a query without ORDER BY returns the
    // physical insertion order and fails the position-order assertion.
    insert_serving_row(&pool, product.id.0, &serving("cup", 240), 1).await;
    insert_serving_row(&pool, product.id.0, &serving("slice", 30), 0).await;

    let expected_servings = vec![serving("slice", 30), serving("cup", 240)];
    let repository = PgProductRepo::new(pool.clone());

    let found = repository
        .find_by_id(product.id)
        .await
        .expect("find product by id")
        .expect("product exists");
    assert_eq!(
        found.servings, expected_servings,
        "find_by_id must return servings in position order without normalization"
    );

    let custom_foods = repository
        .list_custom_foods()
        .await
        .expect("list custom foods");
    assert_eq!(custom_foods.len(), 1, "one custom product is seeded");
    assert_eq!(
        custom_foods[0].servings, expected_servings,
        "list_custom_foods must return servings in position order without normalization"
    );
}

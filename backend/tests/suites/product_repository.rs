use std::collections::HashMap;

use calco_backend::nutrition::catalog::domain::{
    Nutrient, NutrientCatalog, NutrientCode, NutritionError, Product, ProductNutrientInput,
    ProductRepository, ProductServingInput, Source, UnitCode,
};
use calco_backend::nutrition::catalog::infrastructure::PostgresProductRepository;
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

fn nutrient_catalog() -> NutrientCatalog {
    [
        Nutrient {
            code: NutrientCode("ENERGY_KCAL".into()),
            name: "Energy".into(),
            unit: UnitCode("kcal".into()),
            category: "macro".into(),
        },
        Nutrient {
            code: NutrientCode("PROTEIN_G".into()),
            name: "Protein".into(),
            unit: UnitCode("g".into()),
            category: "macro".into(),
        },
    ]
    .into_iter()
    .collect()
}

fn external_product(
    source_id: &str,
    barcode: Option<&str>,
    name: &str,
    nutrients: &[(&str, i64)],
    servings: &[(&str, i64)],
) -> Product {
    Product::new_external(
        Source::Off,
        source_id.into(),
        barcode.map(str::to_owned),
        name.into(),
        Some("Test brand".into()),
        vec!["test".into()],
        None,
        None,
        nutrients
            .iter()
            .map(|(code, amount)| ProductNutrientInput {
                code: (*code).into(),
                amount_per_100g: Decimal::from(*amount),
                source: Some("OFF".into()),
                confidence: Some("derived".into()),
            })
            .collect(),
        servings
            .iter()
            .map(|(unit, grams)| ProductServingInput {
                unit: (*unit).into(),
                grams_per_unit: Decimal::from(*grams),
            })
            .collect(),
        &nutrient_catalog(),
    )
    .expect("external product should be valid")
}

#[sqlx::test]
async fn external_upsert_is_state_idempotent_and_accepts_missing_barcode(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());
    let product = external_product(
        "state-idempotent",
        None,
        "State idempotent food",
        &[("ENERGY_KCAL", 100), ("PROTEIN_G", 10)],
        &[("cup", 240), ("slice", 30)],
    );

    let first = repository
        .upsert_external_many(std::slice::from_ref(&product))
        .await
        .unwrap();
    assert_eq!(first.created, 1);
    assert_eq!(first.updated, 0);
    assert_eq!(first.nutrients_written, 2);
    assert_eq!(first.servings_written, 2);

    let parent_before: (Uuid, Option<String>, chrono::DateTime<chrono::Utc>, chrono::DateTime<chrono::Utc>) =
        sqlx::query_as(
            "SELECT id, barcode, created_at, updated_at FROM products WHERE source = 'OFF' AND source_id = $1",
        )
        .bind("state-idempotent")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(parent_before.0, product.id.0);
    assert_eq!(parent_before.1, None);

    let nutrient_timestamps_before: Vec<(String, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        r#"SELECT nutrient.code, product_nutrient.updated_at
           FROM product_nutrients AS product_nutrient
           JOIN nutrients AS nutrient ON nutrient.id = product_nutrient.nutrient_id
           WHERE product_nutrient.product_id = $1
           ORDER BY nutrient.code"#,
    )
    .bind(parent_before.0)
    .fetch_all(&pool)
    .await
    .unwrap();
    let servings_before: Vec<(Uuid, String, i32)> = sqlx::query_as(
        "SELECT id, unit, position FROM product_servings WHERE product_id = $1 ORDER BY position",
    )
    .bind(parent_before.0)
    .fetch_all(&pool)
    .await
    .unwrap();

    let retry = repository
        .upsert_external_many(std::slice::from_ref(&product))
        .await
        .unwrap();
    assert_eq!(retry.created, 0);
    assert_eq!(retry.updated, 0);
    assert_eq!(retry.nutrients_written, 0);
    assert_eq!(retry.servings_written, 0);

    let parent_after: (Uuid, Option<String>, chrono::DateTime<chrono::Utc>, chrono::DateTime<chrono::Utc>) =
        sqlx::query_as(
            "SELECT id, barcode, created_at, updated_at FROM products WHERE source = 'OFF' AND source_id = $1",
        )
        .bind("state-idempotent")
        .fetch_one(&pool)
        .await
        .unwrap();
    let nutrient_timestamps_after: Vec<(String, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        r#"SELECT nutrient.code, product_nutrient.updated_at
           FROM product_nutrients AS product_nutrient
           JOIN nutrients AS nutrient ON nutrient.id = product_nutrient.nutrient_id
           WHERE product_nutrient.product_id = $1
           ORDER BY nutrient.code"#,
    )
    .bind(parent_before.0)
    .fetch_all(&pool)
    .await
    .unwrap();
    let servings_after: Vec<(Uuid, String, i32)> = sqlx::query_as(
        "SELECT id, unit, position FROM product_servings WHERE product_id = $1 ORDER BY position",
    )
    .bind(parent_before.0)
    .fetch_all(&pool)
    .await
    .unwrap();

    assert_eq!(parent_after, parent_before);
    assert_eq!(nutrient_timestamps_after, nutrient_timestamps_before);
    assert_eq!(servings_after, servings_before);
}

#[sqlx::test]
async fn external_upsert_replaces_children_and_preserves_ids_during_position_swaps(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());
    let original = external_product(
        "authoritative-children",
        Some("123456"),
        "Original food",
        &[("ENERGY_KCAL", 100), ("PROTEIN_G", 10)],
        &[("cup", 240), ("slice", 30)],
    );
    repository
        .upsert_external_many(std::slice::from_ref(&original))
        .await
        .unwrap();

    let original_parent_id: Uuid =
        sqlx::query_scalar("SELECT id FROM products WHERE source = 'OFF' AND source_id = $1")
            .bind("authoritative-children")
            .fetch_one(&pool)
            .await
            .unwrap();
    let serving_ids_before: HashMap<String, Uuid> = sqlx::query_as::<_, (String, Uuid)>(
        "SELECT unit, id FROM product_servings WHERE product_id = $1",
    )
    .bind(original_parent_id)
    .fetch_all(&pool)
    .await
    .unwrap()
    .into_iter()
    .collect();

    let replacement = external_product(
        "authoritative-children",
        Some("654321"),
        "Updated food",
        &[("ENERGY_KCAL", 120)],
        &[("slice", 30), ("cup", 250)],
    );
    let changed = repository
        .upsert_external_many(std::slice::from_ref(&replacement))
        .await
        .unwrap();

    assert_eq!(changed.created, 0);
    assert_eq!(changed.updated, 1);
    assert_eq!(changed.nutrients_written, 2); // one update and one authoritative delete
    assert_eq!(changed.servings_written, 2); // both rows changed position

    let parent_after: (Uuid, String, Option<String>) = sqlx::query_as(
        "SELECT id, name, barcode FROM products WHERE source = 'OFF' AND source_id = $1",
    )
    .bind("authoritative-children")
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(parent_after.0, original_parent_id);
    assert_eq!(parent_after.1, "Updated food");
    assert_eq!(parent_after.2.as_deref(), Some("654321"));

    let nutrients: Vec<(String, Decimal)> = sqlx::query_as(
        r#"SELECT nutrient.code, product_nutrient.amount_per_100g
           FROM product_nutrients AS product_nutrient
           JOIN nutrients AS nutrient ON nutrient.id = product_nutrient.nutrient_id
           WHERE product_nutrient.product_id = $1"#,
    )
    .bind(original_parent_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(nutrients, vec![("ENERGY_KCAL".into(), Decimal::from(120))]);

    let servings_after: Vec<(Uuid, String, Decimal, i32)> = sqlx::query_as(
        "SELECT id, unit, grams_per_unit, position FROM product_servings WHERE product_id = $1 ORDER BY position",
    )
    .bind(original_parent_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(servings_after[0].1, "slice");
    assert_eq!(servings_after[0].2, Decimal::from(30));
    assert_eq!(servings_after[0].3, 0);
    assert_eq!(servings_after[1].1, "cup");
    assert_eq!(servings_after[1].2, Decimal::from(250));
    assert_eq!(servings_after[1].3, 1);
    for (id, unit, _, _) in &servings_after {
        assert_eq!(serving_ids_before.get(unit), Some(id));
    }

    let empty_children = external_product(
        "authoritative-children",
        Some("654321"),
        "Updated food",
        &[],
        &[],
    );
    let cleared = repository
        .upsert_external_many(std::slice::from_ref(&empty_children))
        .await
        .unwrap();
    assert_eq!(cleared.updated, 0);
    assert_eq!(cleared.nutrients_written, 1);
    assert_eq!(cleared.servings_written, 2);
    let remaining_children: (i64, i64) = sqlx::query_as(
        r#"SELECT
               (SELECT COUNT(*) FROM product_nutrients WHERE product_id = $1),
               (SELECT COUNT(*) FROM product_servings WHERE product_id = $1)"#,
    )
    .bind(original_parent_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(remaining_children, (0, 0));
}

#[sqlx::test]
async fn external_upsert_validates_batch_and_rolls_back_all_parent_writes(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());

    let first = external_product("duplicate-key", None, "First", &[], &[]);
    let second = external_product("duplicate-key", None, "Second", &[], &[]);
    let duplicate = repository.upsert_external_many(&[first, second]).await;
    assert!(matches!(duplicate, Err(NutritionError::Validation(_))));

    let mut valid = external_product("rolled-back-first", None, "Valid", &[], &[]);
    let mut primary_key_collision =
        external_product("rolled-back-second", None, "Collision", &[], &[]);
    primary_key_collision.id = valid.id;
    let failed = repository
        .upsert_external_many(&[valid.clone(), primary_key_collision])
        .await;
    assert!(matches!(failed, Err(NutritionError::Database(_))));

    let parent_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM products WHERE source = 'OFF' AND source_id = ANY($1)",
    )
    .bind(vec![
        "duplicate-key",
        "rolled-back-first",
        "rolled-back-second",
    ])
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(parent_count, 0);

    valid.nutrients = vec![];
    let mut unknown = external_product("unknown-nutrient", None, "Unknown", &[], &[]);
    unknown
        .nutrients
        .push(calco_backend::nutrition::catalog::domain::ProductNutrient {
            nutrient_code: NutrientCode("DOES_NOT_EXIST".into()),
            amount_per_100g: calco_backend::nutrition::catalog::domain::AmountPer100g::new(
                Decimal::ONE,
            )
            .unwrap(),
            unit: UnitCode("g".into()),
            source: None,
            confidence: None,
        });
    let unknown_result = repository.upsert_external_many(&[valid, unknown]).await;
    assert!(matches!(unknown_result, Err(NutritionError::Validation(_))));
    let parent_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM products WHERE source = 'OFF' AND source_id = ANY($1)",
    )
    .bind(vec!["rolled-back-first", "unknown-nutrient"])
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(parent_count, 0);
}

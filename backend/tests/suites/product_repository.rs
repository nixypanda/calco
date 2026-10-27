use calco_backend::nutrition::catalog::domain::{
    ExternalProductBatch, ExternalProductBuilder, ExternalSource, Nutrient, NutrientCatalog,
    NutrientCode, NutritionError, Product, ProductNutrientInput, ProductRepository,
    ProductServingInput, UnitCode,
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
        ExternalSource::Off,
        ExternalProductBuilder::new(source_id, name)
            .barcode(barcode.map(str::to_owned))
            .brand(Some("Test brand".into()))
            .categories(vec!["test".into()])
            .nutrients(
                nutrients
                    .iter()
                    .map(|(code, amount)| ProductNutrientInput {
                        code: (*code).into(),
                        amount_per_100g: Decimal::from(*amount),
                        source: Some("OFF".into()),
                        confidence: Some("derived".into()),
                    })
                    .collect(),
            )
            .servings(
                servings
                    .iter()
                    .map(|(unit, grams)| ProductServingInput {
                        unit: (*unit).into(),
                        grams_per_unit: Decimal::from(*grams),
                    })
                    .collect(),
            ),
        &nutrient_catalog(),
    )
    .expect("external product should be valid")
}

fn external_batch(products: Vec<Product>) -> ExternalProductBatch {
    ExternalProductBatch::new(products).expect("external product batch should be valid")
}

#[sqlx::test]
async fn external_upsert_applies_each_authoritative_payload_and_accepts_missing_barcode(
    pool: PgPool,
) {
    let repository = PostgresProductRepository::new(pool.clone());
    let product = external_product(
        "authoritative-replacement",
        None,
        "State idempotent food",
        &[("ENERGY_KCAL", 100), ("PROTEIN_G", 10)],
        &[("cup", 240), ("slice", 30)],
    );

    let first_batch = external_batch(vec![product.clone()]);
    let first = repository.upsert_external_many(&first_batch).await.unwrap();
    assert_eq!(first.created, 1);
    assert_eq!(first.updated, 0);
    assert_eq!(first.nutrients_written, 2);
    assert_eq!(first.servings_written, 2);

    let parent_before: (Uuid, Option<String>) =
        sqlx::query_as("SELECT id, barcode FROM products WHERE source = 'OFF' AND source_id = $1")
            .bind("authoritative-replacement")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(parent_before.0, product.id.0);
    assert_eq!(parent_before.1, None);

    let replacement = external_product(
        "authoritative-replacement",
        Some("replacement-barcode"),
        "Replacement food",
        &[],
        &[],
    );
    let replacement_batch = external_batch(vec![replacement]);
    let replaced = repository
        .upsert_external_many(&replacement_batch)
        .await
        .unwrap();
    assert_eq!(replaced.created, 0);
    assert_eq!(replaced.updated, 1);
    assert_eq!(replaced.nutrients_written, 0);
    assert_eq!(replaced.servings_written, 0);

    let parent_after: (Uuid, String, Option<String>) = sqlx::query_as(
        "SELECT id, name, barcode FROM products WHERE source = 'OFF' AND source_id = $1",
    )
    .bind("authoritative-replacement")
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(parent_after.0, parent_before.0);
    assert_eq!(parent_after.1, "Replacement food");
    assert_eq!(parent_after.2.as_deref(), Some("replacement-barcode"));
    let remaining_children: (i64, i64) = sqlx::query_as(
        r#"SELECT
               (SELECT COUNT(*) FROM product_nutrients WHERE product_id = $1),
               (SELECT COUNT(*) FROM product_servings WHERE product_id = $1)"#,
    )
    .bind(parent_before.0)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(remaining_children, (0, 0));
}

#[sqlx::test]
async fn external_upsert_replaces_children_in_incoming_order(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());
    let original = external_product(
        "authoritative-children",
        Some("123456"),
        "Original food",
        &[("ENERGY_KCAL", 100), ("PROTEIN_G", 10)],
        &[("cup", 240), ("slice", 30)],
    );
    let original_batch = external_batch(vec![original]);
    repository
        .upsert_external_many(&original_batch)
        .await
        .unwrap();

    let original_parent_id: Uuid =
        sqlx::query_scalar("SELECT id FROM products WHERE source = 'OFF' AND source_id = $1")
            .bind("authoritative-children")
            .fetch_one(&pool)
            .await
            .unwrap();
    let replacement = external_product(
        "authoritative-children",
        Some("654321"),
        "Updated food",
        &[("ENERGY_KCAL", 120)],
        &[("slice", 30), ("cup", 250)],
    );
    let replacement_batch = external_batch(vec![replacement]);
    let changed = repository
        .upsert_external_many(&replacement_batch)
        .await
        .unwrap();

    assert_eq!(changed.created, 0);
    assert_eq!(changed.updated, 1);
    assert_eq!(changed.nutrients_written, 1);
    assert_eq!(changed.servings_written, 2);

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
    let empty_children = external_product(
        "authoritative-children",
        Some("654321"),
        "Updated food",
        &[],
        &[],
    );
    let empty_batch = external_batch(vec![empty_children]);
    let cleared = repository.upsert_external_many(&empty_batch).await.unwrap();
    assert_eq!(cleared.updated, 0);
    assert_eq!(cleared.nutrients_written, 0);
    assert_eq!(cleared.servings_written, 0);
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
async fn external_upsert_rolls_back_all_parent_writes_on_persistence_errors(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());

    let mut valid = external_product("rolled-back-first", None, "Valid", &[], &[]);
    let mut primary_key_collision =
        external_product("rolled-back-second", None, "Collision", &[], &[]);
    primary_key_collision.id = valid.id;
    let colliding_batch = external_batch(vec![valid.clone(), primary_key_collision]);
    let failed = repository.upsert_external_many(&colliding_batch).await;
    assert!(matches!(failed, Err(NutritionError::Database(_))));

    let parent_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM products WHERE source = 'OFF' AND source_id = ANY($1)",
    )
    .bind(vec!["rolled-back-first", "rolled-back-second"])
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
    let unknown_batch = external_batch(vec![valid, unknown]);
    let unknown_result = repository.upsert_external_many(&unknown_batch).await;
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

#[sqlx::test]
async fn external_upsert_table_locks_block_writers_but_allow_reads(pool: PgPool) {
    for (index, table) in ["products", "product_nutrients", "product_servings"]
        .into_iter()
        .enumerate()
    {
        let mut blocker = pool.begin().await.unwrap();
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "LOCK TABLE {table} IN ROW EXCLUSIVE MODE"
        )))
        .execute(&mut *blocker)
        .await
        .unwrap();

        let repository = PostgresProductRepository::new(pool.clone());
        let product =
            external_product(&format!("blocked-by-{table}"), None, "Lock probe", &[], &[]);
        let batch = external_batch(vec![product]);
        let write = tokio::spawn(async move { repository.upsert_external_many(&batch).await });

        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(
            !write.is_finished(),
            "upsert should wait for a writer lock held on {table}"
        );

        let read = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM products").fetch_one(&pool),
        )
        .await
        .expect("ordinary reads should not be blocked by the chosen table lock")
        .unwrap();
        assert!(read >= index as i64);

        blocker.rollback().await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), write)
            .await
            .expect("upsert should continue once the competing writer releases its lock")
            .unwrap()
            .unwrap();
    }
}

#[sqlx::test]
async fn concurrent_same_payload_upserts_serialize_complete_aggregate(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());
    let product = external_product(
        "concurrent-same-payload",
        None,
        "Concurrent replay",
        &[("ENERGY_KCAL", 100)],
        &[("cup", 200)],
    );
    let first_batch = external_batch(vec![product.clone()]);
    let second_batch = external_batch(vec![product]);

    let (first, second) = tokio::join!(
        repository.upsert_external_many(&first_batch),
        repository.upsert_external_many(&second_batch),
    );
    let first = first.unwrap();
    let second = second.unwrap();

    assert_eq!(first.created + second.created, 1);
    assert_eq!(first.updated + second.updated, 0);
    assert_eq!(first.nutrients_written, 1);
    assert_eq!(first.servings_written, 1);
    assert_eq!(second.nutrients_written, 1);
    assert_eq!(second.servings_written, 1);
    let product_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM products WHERE source = 'OFF' AND source_id = 'concurrent-same-payload'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(product_count, 1);
}

#[sqlx::test]
async fn concurrent_overlapping_upserts_leave_one_complete_aggregate(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());
    let original = external_product(
        "concurrent-overlap",
        None,
        "Original",
        &[("ENERGY_KCAL", 100)],
        &[("cup", 200)],
    );
    let original_batch = external_batch(vec![original]);
    repository
        .upsert_external_many(&original_batch)
        .await
        .unwrap();

    let version_a = external_product(
        "concurrent-overlap",
        None,
        "Version A",
        &[("ENERGY_KCAL", 110)],
        &[("cup", 210)],
    );
    let version_b = external_product(
        "concurrent-overlap",
        None,
        "Version B",
        &[("ENERGY_KCAL", 120), ("PROTEIN_G", 12)],
        &[("slice", 30)],
    );
    let batch_a = external_batch(vec![version_a]);
    let batch_b = external_batch(vec![version_b]);

    let (result_a, result_b) = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        tokio::join!(
            repository.upsert_external_many(&batch_a),
            repository.upsert_external_many(&batch_b),
        )
    })
    .await
    .expect("overlapping upserts must not deadlock");
    result_a.unwrap();
    result_b.unwrap();

    let product_id: Uuid = sqlx::query_scalar(
        "SELECT id FROM products WHERE source = 'OFF' AND source_id = 'concurrent-overlap'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let name: String = sqlx::query_scalar("SELECT name FROM products WHERE id = $1")
        .bind(product_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    let nutrients: Vec<(String, Decimal)> = sqlx::query_as(
        r#"SELECT nutrient.code, product_nutrient.amount_per_100g
           FROM product_nutrients AS product_nutrient
           JOIN nutrients AS nutrient ON nutrient.id = product_nutrient.nutrient_id
           WHERE product_nutrient.product_id = $1
           ORDER BY nutrient.code"#,
    )
    .bind(product_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    let servings: Vec<(String, Decimal)> = sqlx::query_as(
        "SELECT unit, grams_per_unit FROM product_servings WHERE product_id = $1 ORDER BY position",
    )
    .bind(product_id)
    .fetch_all(&pool)
    .await
    .unwrap();

    match name.as_str() {
        "Version A" => {
            assert_eq!(nutrients, vec![("ENERGY_KCAL".into(), Decimal::from(110))]);
            assert_eq!(servings, vec![("cup".into(), Decimal::from(210))]);
        }
        "Version B" => {
            assert_eq!(
                nutrients,
                vec![
                    ("ENERGY_KCAL".into(), Decimal::from(120)),
                    ("PROTEIN_G".into(), Decimal::from(12)),
                ]
            );
            assert_eq!(servings, vec![("slice".into(), Decimal::from(30))]);
        }
        other => panic!("unexpected final product version: {other}"),
    }
}

#[sqlx::test]
async fn external_upsert_handles_more_than_one_chunk(pool: PgPool) {
    let repository = PostgresProductRepository::new(pool.clone());
    let source_ids: Vec<String> = (0..=1_000)
        .map(|index| format!("chunk-{index:04}"))
        .collect();

    let first_batch = external_batch(
        source_ids
            .iter()
            .map(|source_id| external_product(source_id, None, "Chunk product", &[], &[]))
            .collect(),
    );
    let first = repository
        .upsert_external_many(&first_batch)
        .await
        .expect("first chunked upsert");
    assert_eq!(first.created, 1_001);
    assert_eq!(first.updated, 0);

    let stored_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM products WHERE source = 'OFF' AND source_id = ANY($1)",
    )
    .bind(&source_ids)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(stored_count, 1_001, "every product must be persisted");

    let replacement_batch = external_batch(
        source_ids
            .iter()
            .enumerate()
            .map(|(index, source_id)| {
                let name = if index == 0 {
                    "Renamed first chunk product"
                } else if index == source_ids.len() - 1 {
                    "Renamed last chunk product"
                } else {
                    "Chunk product"
                };
                external_product(source_id, None, name, &[], &[])
            })
            .collect(),
    );
    let replacement = repository
        .upsert_external_many(&replacement_batch)
        .await
        .expect("second chunked upsert");
    assert_eq!(replacement.created, 0);
    assert_eq!(replacement.updated, 2);

    let first_name: String =
        sqlx::query_scalar("SELECT name FROM products WHERE source = 'OFF' AND source_id = $1")
            .bind(&source_ids[0])
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(first_name, "Renamed first chunk product");

    let last_name: String =
        sqlx::query_scalar("SELECT name FROM products WHERE source = 'OFF' AND source_id = $1")
            .bind(source_ids.last().unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(last_name, "Renamed last chunk product");
}

use crate::common::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;
use sqlx::migrate::Migrator;
use std::path::{Path, PathBuf};
use uuid::Uuid;

static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

const MEAL_CONSTRAINTS: [&str; 5] = [
    "meals_total_quantity_paired_check",
    "meals_total_quantity_positive_check",
    "meals_total_quantity_unit_nonblank_check",
    "meal_components_quantity_positive_check",
    "meal_components_unit_nonblank_check",
];

/// Every code point in Rust's Unicode `White_Space` set, which `str::trim`
/// removes. Keep this in sync with the explicit PostgreSQL `btrim` set.
const RUST_WHITESPACE: [char; 25] = [
    '\u{0009}', '\u{000a}', '\u{000b}', '\u{000c}', '\u{000d}', '\u{0020}', '\u{0085}', '\u{00a0}',
    '\u{1680}', '\u{2000}', '\u{2001}', '\u{2002}', '\u{2003}', '\u{2004}', '\u{2005}', '\u{2006}',
    '\u{2007}', '\u{2008}', '\u{2009}', '\u{200a}', '\u{2028}', '\u{2029}', '\u{202f}', '\u{205f}',
    '\u{3000}',
];

fn copy_migrations_before_meal_constraints() -> PathBuf {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    let destination =
        std::env::temp_dir().join(format!("calco-meal-migrations-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&destination).unwrap();
    for entry in std::fs::read_dir(&source).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_str().unwrap();
        if name.ends_with("_meal_quantity_constraints.sql") {
            continue;
        }
        std::fs::copy(&path, destination.join(name)).unwrap();
    }
    destination
}

async fn migrate_to_legacy(pool: &PgPool) -> PathBuf {
    let legacy_migrations = copy_migrations_before_meal_constraints();
    Migrator::new(legacy_migrations.as_path())
        .await
        .unwrap()
        .run(pool)
        .await
        .unwrap();
    legacy_migrations
}

async fn bootstrap_user_and_profile(pool: &PgPool) -> (axum::Router, String, Uuid) {
    let router = app(pool.clone()).await;
    let (_admin, user) = bootstrap_and_user(&router).await;
    let profile_id: Uuid =
        sqlx::query_scalar("SELECT id FROM user_profiles WHERE display_name = 'tester'")
            .fetch_one(pool)
            .await
            .unwrap();
    (router, user, profile_id)
}

async fn seed_product(router: &axum::Router, user: &str, name: &str) -> String {
    let created: Value = post_json(
        router,
        "/api/foods/custom",
        user,
        &json!({
            "name": name,
            "categories": ["migration"],
            "default_quantity": 1,
            "default_unit": "g",
            "nutrients": [
                { "code": "ENERGY_KCAL", "amount_per_100g": 100 },
                { "code": "PROTEIN_G", "amount_per_100g": 5 },
                { "code": "CARBS_G", "amount_per_100g": 10 },
                { "code": "FAT_G", "amount_per_100g": 2 }
            ],
            "servings": []
        }),
        StatusCode::CREATED,
    )
    .await;
    created["id"].as_str().unwrap().to_string()
}

async fn expect_meal_migration_rejected(pool: &PgPool, row_ids: &[Uuid]) -> String {
    let error = MIGRATOR
        .run(pool)
        .await
        .expect_err("structurally invalid legacy rows must abort the meal migration");
    let message = error.to_string();
    assert!(
        message.contains("cannot add meal structural constraints"),
        "unexpected migration error: {message}"
    );
    for row_id in row_ids {
        assert!(
            message.contains(&row_id.to_string()),
            "migration error must list affected row {row_id}: {message}"
        );
    }

    let applied: i64 =
        sqlx::query_scalar("SELECT count(*) FROM _sqlx_migrations WHERE version = 20261121000000")
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(applied, 0, "the rejected migration must not be recorded");

    let constraints: i64 =
        sqlx::query_scalar("SELECT count(*) FROM pg_constraint WHERE conname = ANY($1::text[])")
            .bind(MEAL_CONSTRAINTS)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(
        constraints, 0,
        "the rejected migration must not mutate the schema"
    );

    message
}

#[sqlx::test(migrations = false)]
async fn upgrade_aborts_on_half_paired_legacy_total(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (_router, _user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let meal_id = Uuid::new_v4();

    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Half Paired', 100, NULL)",
    )
    .bind(meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();

    expect_meal_migration_rejected(&pool, &[meal_id]).await;

    let row: (Option<String>, Option<String>) = sqlx::query_as(
        "SELECT total_quantity_amount::text, total_quantity_unit FROM meals WHERE id = $1",
    )
    .bind(meal_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row, (Some("100".to_string()), None));

    std::fs::remove_dir_all(legacy_migrations).ok();
}

#[sqlx::test(migrations = false)]
async fn upgrade_aborts_on_structurally_invalid_meal_quantities(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (router, user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let product_id =
        Uuid::parse_str(&seed_product(&router, &user, "Legacy Invalid Total Food").await).unwrap();
    let meal_id = Uuid::new_v4();

    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Invalid Total', 0, ' ')",
    )
    .bind(meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
         VALUES ($1, $2, $3, 100, 'g')",
    )
    .bind(Uuid::new_v4())
    .bind(meal_id)
    .bind(product_id)
    .execute(&pool)
    .await
    .unwrap();

    expect_meal_migration_rejected(&pool, &[meal_id]).await;

    let row: (Option<String>, Option<String>) = sqlx::query_as(
        "SELECT total_quantity_amount::text, total_quantity_unit FROM meals WHERE id = $1",
    )
    .bind(meal_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row, (Some("0".to_string()), Some(" ".to_string())));

    std::fs::remove_dir_all(legacy_migrations).ok();
}

#[sqlx::test(migrations = false)]
async fn upgrade_aborts_on_structurally_invalid_component_quantities(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (router, user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let product_id =
        Uuid::parse_str(&seed_product(&router, &user, "Legacy Invalid Component Food").await)
            .unwrap();
    let meal_id = Uuid::new_v4();
    let component_id = Uuid::new_v4();

    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Invalid Component', 100, 'g')",
    )
    .bind(meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
         VALUES ($1, $2, $3, 0, ' ')",
    )
    .bind(component_id)
    .bind(meal_id)
    .bind(product_id)
    .execute(&pool)
    .await
    .unwrap();

    expect_meal_migration_rejected(&pool, &[component_id]).await;

    let row: (String, String) =
        sqlx::query_as("SELECT quantity::text, unit FROM meal_components WHERE id = $1")
            .bind(component_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(row, ("0".to_string(), " ".to_string()));

    std::fs::remove_dir_all(legacy_migrations).ok();
}

#[sqlx::test(migrations = false)]
async fn upgrade_aborts_on_meal_without_components(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (_router, _user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let meal_id = Uuid::new_v4();

    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Empty Meal', 100, 'g')",
    )
    .bind(meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();

    expect_meal_migration_rejected(&pool, &[meal_id]).await;

    let components: i64 =
        sqlx::query_scalar("SELECT count(*) FROM meal_components WHERE meal_id = $1")
            .bind(meal_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(components, 0);

    std::fs::remove_dir_all(legacy_migrations).ok();
}

#[sqlx::test]
async fn fresh_constraints_reject_every_rust_whitespace_unit(pool: PgPool) {
    let (router, user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let product_id =
        Uuid::parse_str(&seed_product(&router, &user, "Unicode Whitespace Food").await).unwrap();
    let valid_meal_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Valid Meal', 100, 'g')",
    )
    .bind(valid_meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
         VALUES ($1, $2, $3, 100, 'g')",
    )
    .bind(Uuid::new_v4())
    .bind(valid_meal_id)
    .bind(product_id)
    .execute(&pool)
    .await
    .unwrap();

    for whitespace in RUST_WHITESPACE {
        let unit = whitespace.to_string();
        let invalid_total = sqlx::query(
            "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
             VALUES ($1, $2, $3, 100, $4)",
        )
        .bind(Uuid::new_v4())
        .bind(profile_id)
        .bind(format!("whitespace-total-{:x}", whitespace as u32))
        .bind(&unit)
        .execute(&pool)
        .await;
        assert!(
            invalid_total.is_err(),
            "total unit {whitespace:?} must be rejected"
        );

        let invalid_component = sqlx::query(
            "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
             VALUES ($1, $2, $3, 1, $4)",
        )
        .bind(Uuid::new_v4())
        .bind(valid_meal_id)
        .bind(product_id)
        .bind(&unit)
        .execute(&pool)
        .await;
        assert!(
            invalid_component.is_err(),
            "component unit {whitespace:?} must be rejected"
        );
    }
}

#[sqlx::test(migrations = false)]
async fn upgrade_aborts_on_unicode_whitespace_total_units(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (router, user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let product_id =
        Uuid::parse_str(&seed_product(&router, &user, "Legacy Whitespace Total Food").await)
            .unwrap();
    let whitespace_units = ['\u{0009}', '\u{000a}', '\u{00a0}'];
    let mut meal_ids = Vec::new();

    for whitespace in whitespace_units {
        let meal_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
             VALUES ($1, $2, $3, 100, $4)",
        )
        .bind(meal_id)
        .bind(profile_id)
        .bind(format!("whitespace-total-{:x}", whitespace as u32))
        .bind(whitespace.to_string())
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
             VALUES ($1, $2, $3, 100, 'g')",
        )
        .bind(Uuid::new_v4())
        .bind(meal_id)
        .bind(product_id)
        .execute(&pool)
        .await
        .unwrap();
        meal_ids.push(meal_id);
    }

    expect_meal_migration_rejected(&pool, &meal_ids).await;

    for (meal_id, whitespace) in meal_ids.iter().zip(whitespace_units) {
        let unit: String =
            sqlx::query_scalar("SELECT total_quantity_unit FROM meals WHERE id = $1")
                .bind(meal_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(unit, whitespace.to_string());
    }

    std::fs::remove_dir_all(legacy_migrations).ok();
}

#[sqlx::test(migrations = false)]
async fn upgrade_aborts_on_unicode_whitespace_component_units(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (router, user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let product_id =
        Uuid::parse_str(&seed_product(&router, &user, "Legacy Whitespace Component Food").await)
            .unwrap();
    let meal_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Whitespace Components', 100, 'g')",
    )
    .bind(meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();

    let whitespace_units = ['\u{0009}', '\u{000a}', '\u{00a0}'];
    let mut component_ids = Vec::new();
    for whitespace in whitespace_units {
        let component_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
             VALUES ($1, $2, $3, 1, $4)",
        )
        .bind(component_id)
        .bind(meal_id)
        .bind(product_id)
        .bind(whitespace.to_string())
        .execute(&pool)
        .await
        .unwrap();
        component_ids.push(component_id);
    }

    expect_meal_migration_rejected(&pool, &component_ids).await;

    for (component_id, whitespace) in component_ids.iter().zip(whitespace_units) {
        let unit: String = sqlx::query_scalar("SELECT unit FROM meal_components WHERE id = $1")
            .bind(component_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(unit, whitespace.to_string());
    }

    std::fs::remove_dir_all(legacy_migrations).ok();
}

#[sqlx::test]
async fn fresh_migration_validates_every_meal_quantity_constraint(pool: PgPool) {
    for constraint in MEAL_CONSTRAINTS {
        let validated: bool =
            sqlx::query_scalar("SELECT convalidated FROM pg_constraint WHERE conname = $1")
                .bind(constraint)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(
            validated,
            "{constraint} should be validated on a fresh schema"
        );
    }
}

#[sqlx::test(migrations = false)]
async fn valid_legacy_upgrade_preserves_dynamic_degradation(pool: PgPool) {
    let legacy_migrations = migrate_to_legacy(&pool).await;
    let (router, user, profile_id) = bootstrap_user_and_profile(&pool).await;
    let product_id =
        Uuid::parse_str(&seed_product(&router, &user, "Legacy Valid Food").await).unwrap();

    let nonmass_meal_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Legacy Cup Total', 1, 'cup')",
    )
    .bind(nonmass_meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
         VALUES ($1, $2, $3, 100, 'g')",
    )
    .bind(Uuid::new_v4())
    .bind(nonmass_meal_id)
    .bind(product_id)
    .execute(&pool)
    .await
    .unwrap();

    let unconvertible_component_meal_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'Legacy Serving Component', 100, 'g')",
    )
    .bind(unconvertible_component_meal_id)
    .bind(profile_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
         VALUES ($1, $2, $3, 1, 'cup')",
    )
    .bind(Uuid::new_v4())
    .bind(unconvertible_component_meal_id)
    .bind(product_id)
    .execute(&pool)
    .await
    .unwrap();

    MIGRATOR.run(&pool).await.unwrap();
    let upgraded_router = app(pool.clone()).await;

    for constraint in MEAL_CONSTRAINTS {
        let validated: bool =
            sqlx::query_scalar("SELECT convalidated FROM pg_constraint WHERE conname = $1")
                .bind(constraint)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(validated, "{constraint} should be validated after upgrade");
    }

    let new_invalid_component = sqlx::query(
        "INSERT INTO meal_components (id, meal_id, component_product_id, quantity, unit) \
         VALUES ($1, $2, $3, 1, ' ')",
    )
    .bind(Uuid::new_v4())
    .bind(nonmass_meal_id)
    .bind(product_id)
    .execute(&pool)
    .await;
    assert!(
        new_invalid_component.is_err(),
        "new blank units must be rejected after the upgrade"
    );

    let new_invalid_total = sqlx::query(
        "INSERT INTO meals (id, user_id, name, total_quantity_amount, total_quantity_unit) \
         VALUES ($1, $2, 'New Negative Total', -1, 'g')",
    )
    .bind(Uuid::new_v4())
    .bind(profile_id)
    .execute(&pool)
    .await;
    assert!(
        new_invalid_total.is_err(),
        "new negative totals must be rejected after the upgrade"
    );

    let list: Value = get_json(&upgraded_router, "/api/meals", &user).await;
    let items = list["items"].as_array().unwrap();

    let nonmass_meal = items
        .iter()
        .find(|meal| meal["id"] == nonmass_meal_id.to_string())
        .expect("legacy non-mass-total meal missing from list");
    assert_eq!(
        nonmass_meal["nutrition"]["status"],
        "total_quantity_unavailable"
    );
    assert_eq!(
        nonmass_meal["nutrition"]["reason"],
        "quantity_not_convertible"
    );
    assert_eq!(nonmass_meal["nutrition"]["total_quantity"]["unit"], "cup");
    assert_eq!(nonmass_meal["components"][0]["availability"], "available");

    let serving_meal = items
        .iter()
        .find(|meal| meal["id"] == unconvertible_component_meal_id.to_string())
        .expect("legacy serving-component meal missing from list");
    assert_eq!(serving_meal["nutrition"]["status"], "unavailable");
    assert_eq!(
        serving_meal["nutrition"]["unavailable_components"][0]["reason"],
        "quantity_not_convertible"
    );
    assert_eq!(serving_meal["components"][0]["availability"], "unavailable");
    assert_eq!(serving_meal["components"][0]["quantity"]["unit"], "cup");

    std::fs::remove_dir_all(legacy_migrations).ok();
}

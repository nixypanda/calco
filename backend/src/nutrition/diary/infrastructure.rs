use async_trait::async_trait;
use sea_query::{
    Expr, ExprTrait, Iden, InsertStatement, OnConflict, PostgresQueryBuilder, Query,
    SelectStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::PgPool;
use std::str::FromStr;
use uuid::Uuid;

use crate::nutrition::diary::domain::{
    DiaryPreferences as DomainDiaryPreferences, DiaryPreferencesRepository, EnabledMealSlots,
};
use crate::nutrition::error::NutritionError;
use crate::nutrition::food_log::domain::MealSlot;

#[derive(Iden)]
enum DiaryPreferences {
    Table,
    UserId,
    EnabledMealSlots,
    UpdatedAt,
}

#[derive(Clone)]
pub struct PostgresDiaryPreferencesRepository {
    pool: PgPool,
}

impl PostgresDiaryPreferencesRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn find_by_user_id_statement(user_id: Uuid) -> SelectStatement {
    Query::select()
        .columns([DiaryPreferences::UserId, DiaryPreferences::EnabledMealSlots])
        .from(DiaryPreferences::Table)
        .and_where(Expr::col(DiaryPreferences::UserId).eq(user_id))
        .to_owned()
}

fn canonical_slots(preferences: &DomainDiaryPreferences) -> Vec<String> {
    preferences
        .enabled_meal_slots
        .canonical()
        .into_iter()
        .map(|slot| slot.as_str().to_owned())
        .collect()
}

fn save_statement(preferences: &DomainDiaryPreferences) -> InsertStatement {
    let slots = canonical_slots(preferences);
    Query::insert()
        .into_table(DiaryPreferences::Table)
        .columns([DiaryPreferences::UserId, DiaryPreferences::EnabledMealSlots])
        .values_panic([preferences.user_id.into(), slots.into()])
        .on_conflict(
            OnConflict::column(DiaryPreferences::UserId)
                .update_column(DiaryPreferences::EnabledMealSlots)
                .value(DiaryPreferences::UpdatedAt, Expr::current_timestamp())
                .to_owned(),
        )
        .to_owned()
}

#[async_trait]
impl DiaryPreferencesRepository for PostgresDiaryPreferencesRepository {
    async fn find_by_user_id(
        &self,
        user_id: Uuid,
    ) -> Result<Option<DomainDiaryPreferences>, NutritionError> {
        let (sql, values) = find_by_user_id_statement(user_id).build_sqlx(PostgresQueryBuilder);
        let row = sqlx::query_as_with::<_, DiaryPreferencesRow, _>(
            sqlx::AssertSqlSafe(sql.as_str()),
            values,
        )
        .fetch_optional(&self.pool)
        .await?;

        row.map(row_to_domain).transpose()
    }

    async fn save(&self, preferences: &DomainDiaryPreferences) -> Result<(), NutritionError> {
        let (sql, values) = save_statement(preferences).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

fn row_to_domain(row: DiaryPreferencesRow) -> Result<DomainDiaryPreferences, NutritionError> {
    let slots = row
        .enabled_meal_slots
        .iter()
        .map(|slot| MealSlot::from_str(slot).map_err(NutritionError::Internal))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(DomainDiaryPreferences::new(
        row.user_id,
        EnabledMealSlots::new(slots)?,
    ))
}

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
struct DiaryPreferencesRow {
    user_id: Uuid,
    enabled_meal_slots: Vec<String>,
}

#[cfg(test)]
async fn legacy_find_by_user_id(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<DiaryPreferencesRow>, sqlx::Error> {
    sqlx::query_as::<_, DiaryPreferencesRow>(
        "SELECT user_id, enabled_meal_slots FROM diary_preferences WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_save(
    pool: &PgPool,
    preferences: &DomainDiaryPreferences,
) -> Result<(), sqlx::Error> {
    let slots = preferences
        .enabled_meal_slots
        .canonical()
        .into_iter()
        .map(|slot| slot.as_str().to_owned())
        .collect::<Vec<_>>();
    sqlx::query(
        r#"
        INSERT INTO diary_preferences (user_id, enabled_meal_slots)
        VALUES ($1, $2)
        ON CONFLICT (user_id) DO UPDATE
        SET enabled_meal_slots = EXCLUDED.enabled_meal_slots,
            updated_at = NOW()
        "#,
    )
    .bind(preferences.user_id)
    .bind(slots)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Utc};

    fn timestamp(year: i32, month: u32, day: u32) -> DateTime<Utc> {
        chrono::NaiveDate::from_ymd_opt(year, month, day)
            .unwrap()
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_utc()
    }

    fn assert_recent(timestamp: DateTime<Utc>, label: &str) {
        let age = Utc::now().signed_duration_since(timestamp);
        assert!(
            age.num_seconds().abs() < 300,
            "{label} updated_at should be current, got {timestamp}"
        );
    }

    fn canonical_strings(slots: &EnabledMealSlots) -> Vec<String> {
        slots
            .canonical()
            .into_iter()
            .map(|slot| slot.as_str().to_owned())
            .collect()
    }

    fn normalize_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn save_statement_uses_current_timestamp_without_extra_bind() {
        let preferences = DomainDiaryPreferences::new(
            Uuid::nil(),
            EnabledMealSlots::new([MealSlot::Breakfast]).expect("valid slots"),
        );
        let (sql, values) = save_statement(&preferences).build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql.contains(r#""updated_at" = CURRENT_TIMESTAMP"#),
            "save must set updated_at from the current timestamp: {sql}"
        );
        assert!(
            !sql.contains(r#""excluded"."updated_at""#),
            "save must not bind EXCLUDED.updated_at: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            2,
            "save must bind exactly user_id and enabled_meal_slots: {sql}"
        );
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

    async fn fetch_diary_row(pool: &PgPool, user_id: Uuid) -> DiaryPreferencesRow {
        sqlx::query_as::<_, DiaryPreferencesRow>(
            "SELECT user_id, enabled_meal_slots FROM diary_preferences WHERE user_id = $1",
        )
        .bind(user_id)
        .fetch_one(pool)
        .await
        .expect("fetch diary preferences")
    }

    async fn fetch_updated_at(pool: &PgPool, user_id: Uuid) -> DateTime<Utc> {
        sqlx::query_scalar("SELECT updated_at FROM diary_preferences WHERE user_id = $1")
            .bind(user_id)
            .fetch_one(pool)
            .await
            .expect("fetch diary preferences updated_at")
    }

    async fn fetch_created_at(pool: &PgPool, user_id: Uuid) -> DateTime<Utc> {
        sqlx::query_scalar("SELECT created_at FROM diary_preferences WHERE user_id = $1")
            .bind(user_id)
            .fetch_one(pool)
            .await
            .expect("fetch diary preferences created_at")
    }

    async fn sea_find_by_user_id(pool: &PgPool, user_id: Uuid) -> Option<DiaryPreferencesRow> {
        let (sql, values) = find_by_user_id_statement(user_id).build_sqlx(PostgresQueryBuilder);
        sqlx::query_as_with::<_, DiaryPreferencesRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_optional(pool)
            .await
            .expect("sea-query find_by_user_id")
    }

    #[sqlx::test]
    async fn find_by_user_id_matches_legacy(pool: PgPool) {
        let user_with_preferences =
            seed_identity_and_profile(&pool, "diary-find-with-preferences").await;
        let user_without_preferences =
            seed_identity_and_profile(&pool, "diary-find-without-preferences").await;

        let seeded_slots = vec![
            "dinner".to_owned(),
            "breakfast".to_owned(),
            "late_night_snack".to_owned(),
        ];

        sqlx::query("INSERT INTO diary_preferences (user_id, enabled_meal_slots) VALUES ($1, $2)")
            .bind(user_with_preferences)
            .bind(&seeded_slots)
            .execute(&pool)
            .await
            .expect("seed diary preferences");

        let repository = PostgresDiaryPreferencesRepository::new(pool.clone());

        let legacy_row = legacy_find_by_user_id(&pool, user_with_preferences)
            .await
            .expect("legacy find_by_user_id");
        let sea_row = sea_find_by_user_id(&pool, user_with_preferences).await;

        assert_eq!(sea_row, legacy_row);
        let repository_row = repository
            .find_by_user_id(user_with_preferences)
            .await
            .expect("repository find_by_user_id");
        let legacy_domain = legacy_row
            .map(row_to_domain)
            .transpose()
            .expect("legacy row conversion");
        assert_eq!(repository_row, legacy_domain);

        let row = sea_row.expect("expected a diary preferences row");
        assert_eq!(row.user_id, user_with_preferences);
        assert_eq!(row.enabled_meal_slots, seeded_slots);
        assert_eq!(row.enabled_meal_slots.len(), 3);

        let legacy_none = legacy_find_by_user_id(&pool, user_without_preferences)
            .await
            .expect("legacy find missing by_user_id");
        let sea_none = sea_find_by_user_id(&pool, user_without_preferences).await;

        assert_eq!(sea_none, legacy_none);
        let repository_none = repository
            .find_by_user_id(user_without_preferences)
            .await
            .expect("repository find missing by_user_id");
        let legacy_none_domain = legacy_none
            .map(row_to_domain)
            .transpose()
            .expect("legacy missing row conversion");
        assert_eq!(repository_none, legacy_none_domain);
        assert!(sea_none.is_none());
        assert!(repository_none.is_none());
    }

    #[sqlx::test]
    async fn save_matches_legacy_for_insert_and_update(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "diary-save-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "diary-save-sea").await;
        let repository = PostgresDiaryPreferencesRepository::new(pool.clone());

        let initial_enabled = EnabledMealSlots::new([
            MealSlot::LateNightSnack,
            MealSlot::Breakfast,
            MealSlot::Dinner,
        ])
        .expect("valid initial slots");
        let initial_canonical = canonical_strings(&initial_enabled);
        assert_eq!(
            initial_canonical,
            vec!["breakfast", "dinner", "late_night_snack"]
        );

        let legacy_preferences =
            DomainDiaryPreferences::new(legacy_user_id, initial_enabled.clone());
        let sea_preferences = DomainDiaryPreferences::new(sea_user_id, initial_enabled);

        legacy_save(&pool, &legacy_preferences)
            .await
            .expect("legacy save insert");
        repository
            .save(&sea_preferences)
            .await
            .expect("repository save insert");

        let legacy_row = fetch_diary_row(&pool, legacy_user_id).await;
        let sea_row = fetch_diary_row(&pool, sea_user_id).await;
        let legacy_created_at = fetch_created_at(&pool, legacy_user_id).await;
        let sea_created_at = fetch_created_at(&pool, sea_user_id).await;

        assert_eq!(legacy_row.user_id, legacy_user_id);
        assert_eq!(sea_row.user_id, sea_user_id);
        assert_eq!(sea_row.enabled_meal_slots, legacy_row.enabled_meal_slots);
        assert_eq!(&sea_row.enabled_meal_slots, &initial_canonical);
        assert_recent(
            fetch_updated_at(&pool, legacy_user_id).await,
            "legacy insert",
        );
        assert_recent(
            fetch_updated_at(&pool, sea_user_id).await,
            "sea-query insert",
        );

        let stale_updated_at = timestamp(2000, 1, 1);
        sqlx::query("UPDATE diary_preferences SET updated_at = $1 WHERE user_id = ANY($2)")
            .bind(stale_updated_at)
            .bind(vec![legacy_user_id, sea_user_id])
            .execute(&pool)
            .await
            .expect("backdate diary updated_at");

        let updated_enabled = EnabledMealSlots::new([
            MealSlot::Snack,
            MealSlot::LateNightSnack,
            MealSlot::Breakfast,
            MealSlot::Lunch,
        ])
        .expect("valid updated slots");
        let updated_canonical = canonical_strings(&updated_enabled);
        assert_eq!(
            updated_canonical,
            vec!["breakfast", "lunch", "snack", "late_night_snack"]
        );
        assert_ne!(&updated_canonical, &initial_canonical);

        let legacy_updated_preferences =
            DomainDiaryPreferences::new(legacy_user_id, updated_enabled.clone());
        let sea_updated_preferences = DomainDiaryPreferences::new(sea_user_id, updated_enabled);

        legacy_save(&pool, &legacy_updated_preferences)
            .await
            .expect("legacy save update");
        repository
            .save(&sea_updated_preferences)
            .await
            .expect("repository save update");

        let legacy_updated_row = fetch_diary_row(&pool, legacy_user_id).await;
        let sea_updated_row = fetch_diary_row(&pool, sea_user_id).await;

        assert_eq!(legacy_updated_row.user_id, legacy_user_id);
        assert_eq!(sea_updated_row.user_id, sea_user_id);
        assert_eq!(
            sea_updated_row.enabled_meal_slots,
            legacy_updated_row.enabled_meal_slots
        );
        assert_eq!(&sea_updated_row.enabled_meal_slots, &updated_canonical);
        assert_eq!(&legacy_updated_row.enabled_meal_slots, &updated_canonical);
        assert_eq!(
            fetch_created_at(&pool, legacy_user_id).await,
            legacy_created_at,
            "legacy save must not overwrite created_at on conflict"
        );
        assert_eq!(
            fetch_created_at(&pool, sea_user_id).await,
            sea_created_at,
            "repository save must not overwrite created_at on conflict"
        );
        let legacy_updated_at = fetch_updated_at(&pool, legacy_user_id).await;
        let sea_updated_at = fetch_updated_at(&pool, sea_user_id).await;
        assert!(legacy_updated_at > stale_updated_at);
        assert!(sea_updated_at > stale_updated_at);
        assert_recent(legacy_updated_at, "legacy update");
        assert_recent(sea_updated_at, "sea-query update");
    }
}

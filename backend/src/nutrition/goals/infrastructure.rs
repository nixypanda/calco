use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use sea_query::{
    Expr, ExprTrait, Iden, InsertStatement, OnConflict, Order, PostgresQueryBuilder, Query,
    SelectStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::nutrition::goals::domain::{GoalTarget, GoalTargetRepository, GoalTargets};

#[derive(Iden)]
enum GoalTargetVersions {
    Table,
    Id,
    UserId,
    EffectiveFrom,
    CalorieTarget,
    ProteinTargetG,
    CarbsTargetG,
    FatTargetG,
    CreatedAt,
    UpdatedAt,
}

#[derive(Clone)]
pub struct PostgresGoalTargetRepository {
    pool: PgPool,
}

impl PostgresGoalTargetRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn find_effective_for_date_statement(user_id: Uuid, requested_date: NaiveDate) -> SelectStatement {
    Query::select()
        .columns([
            GoalTargetVersions::Id,
            GoalTargetVersions::UserId,
            GoalTargetVersions::EffectiveFrom,
            GoalTargetVersions::CalorieTarget,
            GoalTargetVersions::ProteinTargetG,
            GoalTargetVersions::CarbsTargetG,
            GoalTargetVersions::FatTargetG,
            GoalTargetVersions::CreatedAt,
            GoalTargetVersions::UpdatedAt,
        ])
        .from(GoalTargetVersions::Table)
        .and_where(Expr::col(GoalTargetVersions::UserId).eq(user_id))
        .and_where(Expr::col(GoalTargetVersions::EffectiveFrom).lte(requested_date))
        .order_by(GoalTargetVersions::EffectiveFrom, Order::Desc)
        .limit(1)
        .to_owned()
}

fn upsert_statement(goal_target: &GoalTarget) -> InsertStatement {
    Query::insert()
        .into_table(GoalTargetVersions::Table)
        .columns([
            GoalTargetVersions::Id,
            GoalTargetVersions::UserId,
            GoalTargetVersions::EffectiveFrom,
            GoalTargetVersions::CalorieTarget,
            GoalTargetVersions::ProteinTargetG,
            GoalTargetVersions::CarbsTargetG,
            GoalTargetVersions::FatTargetG,
            GoalTargetVersions::CreatedAt,
            GoalTargetVersions::UpdatedAt,
        ])
        .values_panic([
            goal_target.id.into(),
            goal_target.user_id.into(),
            goal_target.effective_from.into(),
            goal_target.targets.calorie_target.into(),
            goal_target.targets.protein_target_g.into(),
            goal_target.targets.carbs_target_g.into(),
            goal_target.targets.fat_target_g.into(),
            goal_target.created_at.into(),
            goal_target.updated_at.into(),
        ])
        .on_conflict(
            OnConflict::columns([
                GoalTargetVersions::UserId,
                GoalTargetVersions::EffectiveFrom,
            ])
            .update_columns([
                GoalTargetVersions::CalorieTarget,
                GoalTargetVersions::ProteinTargetG,
                GoalTargetVersions::CarbsTargetG,
                GoalTargetVersions::FatTargetG,
                GoalTargetVersions::UpdatedAt,
            ])
            .to_owned(),
        )
        .to_owned()
}

#[async_trait]
impl GoalTargetRepository for PostgresGoalTargetRepository {
    async fn find_effective_for_date(
        &self,
        user_id: Uuid,
        requested_date: NaiveDate,
    ) -> Result<Option<GoalTarget>, crate::nutrition::error::NutritionError> {
        let (sql, values) = find_effective_for_date_statement(user_id, requested_date)
            .build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, GoalTargetRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        row.map(goal_target_row_to_domain).transpose()
    }

    async fn upsert(
        &self,
        goal_target: &GoalTarget,
    ) -> Result<(), crate::nutrition::error::NutritionError> {
        let (sql, values) = upsert_statement(goal_target).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

fn goal_target_row_to_domain(
    row: GoalTargetRow,
) -> Result<GoalTarget, crate::nutrition::error::NutritionError> {
    Ok(GoalTarget {
        id: row.id,
        user_id: row.user_id,
        effective_from: row.effective_from,
        targets: GoalTargets::new(
            row.calorie_target,
            row.protein_target_g,
            row.carbs_target_g,
            row.fat_target_g,
        )?,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

#[derive(Debug, PartialEq, Eq, sqlx::FromRow)]
struct GoalTargetRow {
    id: Uuid,
    user_id: Uuid,
    effective_from: NaiveDate,
    calorie_target: Decimal,
    protein_target_g: Decimal,
    carbs_target_g: Decimal,
    fat_target_g: Decimal,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[cfg(test)]
async fn legacy_find_effective_for_date(
    pool: &PgPool,
    user_id: Uuid,
    requested_date: NaiveDate,
) -> Result<Option<GoalTargetRow>, sqlx::Error> {
    sqlx::query_as::<_, GoalTargetRow>(
        r#"
        SELECT id, user_id, effective_from, calorie_target, protein_target_g, carbs_target_g, fat_target_g,
               created_at, updated_at
        FROM goal_target_versions
        WHERE user_id = $1 AND effective_from <= $2
        ORDER BY effective_from DESC
        LIMIT 1
        "#,
    )
    .bind(user_id)
    .bind(requested_date)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_upsert(pool: &PgPool, goal_target: &GoalTarget) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO goal_target_versions (
            id, user_id, effective_from, calorie_target, protein_target_g, carbs_target_g, fat_target_g,
            created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (user_id, effective_from) DO UPDATE SET
            calorie_target = EXCLUDED.calorie_target,
            protein_target_g = EXCLUDED.protein_target_g,
            carbs_target_g = EXCLUDED.carbs_target_g,
            fat_target_g = EXCLUDED.fat_target_g,
            updated_at = EXCLUDED.updated_at
        "#,
    )
    .bind(goal_target.id)
    .bind(goal_target.user_id)
    .bind(goal_target.effective_from)
    .bind(goal_target.targets.calorie_target)
    .bind(goal_target.targets.protein_target_g)
    .bind(goal_target.targets.carbs_target_g)
    .bind(goal_target.targets.fat_target_g)
    .bind(goal_target.created_at)
    .bind(goal_target.updated_at)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    fn timestamp(day: NaiveDate, hour: u32) -> DateTime<Utc> {
        day.and_hms_opt(hour, 0, 0).unwrap().and_utc()
    }

    fn targets(calorie_target: i64, protein: i64, carbs: i64, fat: i64) -> GoalTargets {
        GoalTargets {
            calorie_target: Decimal::from(calorie_target),
            protein_target_g: Decimal::from(protein),
            carbs_target_g: Decimal::from(carbs),
            fat_target_g: Decimal::from(fat),
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

    async fn seed_goal_version(
        pool: &PgPool,
        id: Uuid,
        user_id: Uuid,
        effective_from: NaiveDate,
        targets: GoalTargets,
        created_at: DateTime<Utc>,
        updated_at: DateTime<Utc>,
    ) -> Uuid {
        sqlx::query(
            r#"
            INSERT INTO goal_target_versions (
                id, user_id, effective_from, calorie_target, protein_target_g, carbs_target_g, fat_target_g,
                created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            "#,
        )
        .bind(id)
        .bind(user_id)
        .bind(effective_from)
        .bind(targets.calorie_target)
        .bind(targets.protein_target_g)
        .bind(targets.carbs_target_g)
        .bind(targets.fat_target_g)
        .bind(created_at)
        .bind(updated_at)
        .execute(pool)
        .await
        .expect("seed goal target version");

        id
    }

    async fn fetch_goal_row(
        pool: &PgPool,
        user_id: Uuid,
        effective_from: NaiveDate,
    ) -> GoalTargetRow {
        sqlx::query_as::<_, GoalTargetRow>(
            r#"
            SELECT id, user_id, effective_from, calorie_target, protein_target_g, carbs_target_g,
                   fat_target_g, created_at, updated_at
            FROM goal_target_versions
            WHERE user_id = $1 AND effective_from = $2
            "#,
        )
        .bind(user_id)
        .bind(effective_from)
        .fetch_one(pool)
        .await
        .expect("fetch goal target version")
    }

    async fn sea_find_effective_for_date(
        pool: &PgPool,
        user_id: Uuid,
        requested_date: NaiveDate,
    ) -> Option<GoalTargetRow> {
        let (sql, values) = find_effective_for_date_statement(user_id, requested_date)
            .build_sqlx(PostgresQueryBuilder);
        sqlx::query_as_with::<_, GoalTargetRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_optional(pool)
            .await
            .expect("sea-query find_effective_for_date")
    }

    fn normalize_sql(sql: &str) -> String {
        sql.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn find_effective_for_date_statement_has_limit() {
        let (sql, values) = find_effective_for_date_statement(Uuid::nil(), date(2026, 1, 1))
            .build_sqlx(PostgresQueryBuilder);
        let sql = normalize_sql(&sql);

        assert!(
            sql.contains(" LIMIT "),
            "find_effective_for_date must limit to one row: {sql}"
        );
        assert_eq!(
            values.0.iter().count(),
            3,
            "expected user_id, requested_date, and limit binds: {sql}"
        );
        assert_eq!(
            values.0.iter().nth(2),
            Some(&sea_query::Value::BigUnsigned(Some(1))),
            "find_effective_for_date must bind a limit of one row: {sql}"
        );
    }

    #[sqlx::test]
    async fn find_effective_for_date_matches_legacy(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "goals-find-equivalence").await;
        let other_user_id = seed_identity_and_profile(&pool, "goals-find-other").await;

        let first_id = seed_goal_version(
            &pool,
            Uuid::new_v4(),
            user_id,
            date(2026, 1, 1),
            targets(1650, 100, 200, 50),
            timestamp(date(2026, 1, 1), 8),
            timestamp(date(2026, 1, 1), 8),
        )
        .await;
        let second_id = seed_goal_version(
            &pool,
            Uuid::new_v4(),
            user_id,
            date(2026, 4, 1),
            targets(1855, 120, 220, 55),
            timestamp(date(2026, 4, 1), 8),
            timestamp(date(2026, 4, 1), 8),
        )
        .await;
        let third_id = seed_goal_version(
            &pool,
            Uuid::new_v4(),
            user_id,
            date(2026, 8, 1),
            targets(1980, 130, 230, 60),
            timestamp(date(2026, 8, 1), 8),
            timestamp(date(2026, 8, 1), 8),
        )
        .await;
        seed_goal_version(
            &pool,
            Uuid::new_v4(),
            other_user_id,
            date(2026, 12, 1),
            targets(2300, 175, 250, 60),
            timestamp(date(2026, 12, 1), 8),
            timestamp(date(2026, 12, 1), 8),
        )
        .await;

        let cases = [
            (date(2025, 12, 31), None),
            (date(2026, 1, 1), Some(first_id)),
            (date(2026, 2, 15), Some(first_id)),
            (date(2026, 4, 1), Some(second_id)),
            (date(2026, 6, 15), Some(second_id)),
            (date(2026, 8, 1), Some(third_id)),
            (date(2027, 1, 1), Some(third_id)),
        ];

        let repository = PostgresGoalTargetRepository::new(pool.clone());

        for (requested_date, expected_id) in cases {
            let legacy_row = legacy_find_effective_for_date(&pool, user_id, requested_date)
                .await
                .unwrap_or_else(|error| {
                    panic!("legacy query failed for {requested_date}: {error}")
                });
            let sea_row = sea_find_effective_for_date(&pool, user_id, requested_date).await;

            assert_eq!(
                sea_row, legacy_row,
                "sea-query diverged from legacy for {requested_date}"
            );
            assert_eq!(
                sea_row.as_ref().map(|row| row.id),
                expected_id,
                "unexpected goal version selected for {requested_date}"
            );

            let repository_row = repository
                .find_effective_for_date(user_id, requested_date)
                .await
                .unwrap_or_else(|error| {
                    panic!("repository query failed for {requested_date}: {error}")
                });
            let legacy_domain = legacy_row
                .map(goal_target_row_to_domain)
                .transpose()
                .unwrap_or_else(|error| {
                    panic!("legacy row conversion failed for {requested_date}: {error}")
                });
            assert_eq!(
                repository_row, legacy_domain,
                "repository diverged from legacy for {requested_date}"
            );

            if let Some(row) = sea_row {
                assert_eq!(row.user_id, user_id);
                assert!(
                    row.effective_from <= requested_date,
                    "selected a goal version effective after the requested date"
                );
            }
        }
    }

    #[sqlx::test]
    async fn upsert_matches_legacy_for_conflict_and_insert(pool: PgPool) {
        let legacy_user_id = seed_identity_and_profile(&pool, "goals-upsert-legacy").await;
        let sea_user_id = seed_identity_and_profile(&pool, "goals-upsert-sea").await;
        let repository = PostgresGoalTargetRepository::new(pool.clone());

        let conflict_date = date(2026, 1, 1);
        let old_targets = targets(1596, 100, 200, 44);
        let new_targets = targets(2100, 150, 240, 60);
        let seeded_created_at = timestamp(date(2025, 12, 1), 8);
        let seeded_updated_at = timestamp(date(2025, 12, 2), 9);

        let legacy_existing_id = seed_goal_version(
            &pool,
            Uuid::new_v4(),
            legacy_user_id,
            conflict_date,
            old_targets.clone(),
            seeded_created_at,
            seeded_updated_at,
        )
        .await;
        let sea_existing_id = seed_goal_version(
            &pool,
            Uuid::new_v4(),
            sea_user_id,
            conflict_date,
            old_targets.clone(),
            seeded_created_at,
            seeded_updated_at,
        )
        .await;

        let legacy_update = GoalTarget {
            id: Uuid::new_v4(),
            user_id: legacy_user_id,
            effective_from: conflict_date,
            targets: new_targets.clone(),
            created_at: timestamp(date(2026, 3, 1), 10),
            updated_at: timestamp(date(2026, 3, 1), 11),
        };
        let sea_update = GoalTarget {
            id: Uuid::new_v4(),
            user_id: sea_user_id,
            effective_from: conflict_date,
            targets: new_targets.clone(),
            created_at: legacy_update.created_at,
            updated_at: legacy_update.updated_at,
        };

        legacy_upsert(&pool, &legacy_update)
            .await
            .expect("legacy upsert conflict");
        repository
            .upsert(&sea_update)
            .await
            .expect("repository upsert conflict");

        let legacy_row = fetch_goal_row(&pool, legacy_user_id, conflict_date).await;
        let sea_row = fetch_goal_row(&pool, sea_user_id, conflict_date).await;

        assert_eq!(legacy_row.id, legacy_existing_id);
        assert_eq!(sea_row.id, sea_existing_id);
        assert_eq!(sea_row.effective_from, legacy_row.effective_from);
        assert_eq!(sea_row.created_at, legacy_row.created_at);
        assert_eq!(sea_row.updated_at, legacy_row.updated_at);
        assert_eq!(sea_row.calorie_target, legacy_row.calorie_target);
        assert_eq!(sea_row.protein_target_g, legacy_row.protein_target_g);
        assert_eq!(sea_row.carbs_target_g, legacy_row.carbs_target_g);
        assert_eq!(sea_row.fat_target_g, legacy_row.fat_target_g);

        assert_eq!(
            legacy_row.created_at, seeded_created_at,
            "legacy upsert must not overwrite created_at on conflict"
        );
        assert_eq!(
            sea_row.created_at, seeded_created_at,
            "sea-query upsert must not overwrite created_at on conflict"
        );
        assert_ne!(
            legacy_update.created_at, seeded_created_at,
            "the test must use a distinguishable inserted created_at"
        );
        assert_eq!(legacy_row.updated_at, legacy_update.updated_at);
        assert_eq!(sea_row.updated_at, sea_update.updated_at);
        assert_eq!(sea_row.calorie_target, new_targets.calorie_target);
        assert_eq!(sea_row.protein_target_g, new_targets.protein_target_g);
        assert_eq!(sea_row.carbs_target_g, new_targets.carbs_target_g);
        assert_eq!(sea_row.fat_target_g, new_targets.fat_target_g);

        let insert_date = date(2026, 6, 1);
        let insert_targets = targets(1850, 125, 225, 50);
        let legacy_insert = GoalTarget {
            id: Uuid::new_v4(),
            user_id: legacy_user_id,
            effective_from: insert_date,
            targets: insert_targets.clone(),
            created_at: timestamp(date(2026, 5, 1), 7),
            updated_at: timestamp(date(2026, 5, 1), 8),
        };
        let sea_insert = GoalTarget {
            id: Uuid::new_v4(),
            user_id: sea_user_id,
            effective_from: insert_date,
            targets: insert_targets.clone(),
            created_at: legacy_insert.created_at,
            updated_at: legacy_insert.updated_at,
        };

        legacy_upsert(&pool, &legacy_insert)
            .await
            .expect("legacy upsert insert");
        repository
            .upsert(&sea_insert)
            .await
            .expect("repository upsert insert");

        let legacy_insert_row = fetch_goal_row(&pool, legacy_user_id, insert_date).await;
        let sea_insert_row = fetch_goal_row(&pool, sea_user_id, insert_date).await;

        assert_eq!(legacy_insert_row.id, legacy_insert.id);
        assert_eq!(sea_insert_row.id, sea_insert.id);
        assert_eq!(
            sea_insert_row.effective_from,
            legacy_insert_row.effective_from
        );
        assert_eq!(sea_insert_row.created_at, legacy_insert_row.created_at);
        assert_eq!(sea_insert_row.updated_at, legacy_insert_row.updated_at);
        assert_eq!(
            sea_insert_row.calorie_target,
            legacy_insert_row.calorie_target
        );
        assert_eq!(
            sea_insert_row.protein_target_g,
            legacy_insert_row.protein_target_g
        );
        assert_eq!(
            sea_insert_row.carbs_target_g,
            legacy_insert_row.carbs_target_g
        );
        assert_eq!(sea_insert_row.fat_target_g, legacy_insert_row.fat_target_g);

        assert_eq!(legacy_insert_row.created_at, legacy_insert.created_at);
        assert_eq!(sea_insert_row.created_at, sea_insert.created_at);
        assert_eq!(legacy_insert_row.updated_at, legacy_insert.updated_at);
        assert_eq!(sea_insert_row.updated_at, sea_insert.updated_at);
        assert_eq!(sea_insert_row.calorie_target, insert_targets.calorie_target);
        assert_eq!(
            sea_insert_row.protein_target_g,
            insert_targets.protein_target_g
        );
        assert_eq!(sea_insert_row.carbs_target_g, insert_targets.carbs_target_g);
        assert_eq!(sea_insert_row.fat_target_g, insert_targets.fat_target_g);
    }
}

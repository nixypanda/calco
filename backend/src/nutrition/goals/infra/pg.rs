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

use crate::nutrition::goals::domain::{GoalTarget, GoalTargetRepo, GoalTargets};

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
pub struct PgGoalTargetRepo {
    pool: PgPool,
}

impl PgGoalTargetRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn goal_target_find_effective_for_date_statement(
    user_id: Uuid,
    requested_date: NaiveDate,
) -> SelectStatement {
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

fn goal_target_upsert_statement(goal_target: &GoalTarget) -> InsertStatement {
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
impl GoalTargetRepo for PgGoalTargetRepo {
    async fn find_effective_for_date(
        &self,
        user_id: Uuid,
        requested_date: NaiveDate,
    ) -> Result<Option<GoalTarget>, crate::nutrition::error::NutritionError> {
        let (sql, values) = goal_target_find_effective_for_date_statement(user_id, requested_date)
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
        let (sql, values) =
            goal_target_upsert_statement(goal_target).build_sqlx(PostgresQueryBuilder);
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

#[derive(sqlx::FromRow)]
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
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    fn timestamp(day: NaiveDate, hour: u32) -> DateTime<Utc> {
        day.and_hms_opt(hour, 0, 0).unwrap().and_utc()
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

    #[sqlx::test]
    async fn finds_latest_effective_goal_on_or_before_date(pool: PgPool) {
        let user_id = seed_identity_and_profile(&pool, "goals-effective-date").await;
        let other_user_id = seed_identity_and_profile(&pool, "goals-effective-date-other").await;
        let repository = PgGoalTargetRepo::new(pool.clone());

        let february = GoalTarget::create(
            user_id,
            date(2026, 2, 1),
            GoalTargets::new(
                Decimal::from(2290),
                Decimal::from(160),
                Decimal::from(255),
                Decimal::from(70),
            )
            .expect("valid goal targets"),
            timestamp(date(2026, 2, 1), 8),
        );
        let other_user_goal = GoalTarget::create(
            other_user_id,
            date(2026, 1, 15),
            GoalTargets::new(
                Decimal::from(1560),
                Decimal::from(120),
                Decimal::from(180),
                Decimal::from(40),
            )
            .expect("valid other-user goal targets"),
            timestamp(date(2026, 1, 15), 8),
        );
        let january = GoalTarget::create(
            user_id,
            date(2026, 1, 1),
            GoalTargets::defaults(),
            timestamp(date(2026, 3, 1), 8),
        );

        // Insertion order (January before February) and created_at order
        // (January later than February) both contradict effective-date order.
        repository
            .upsert(&january)
            .await
            .expect("upsert january goal");
        repository
            .upsert(&february)
            .await
            .expect("upsert february goal");
        repository
            .upsert(&other_user_goal)
            .await
            .expect("upsert other-user goal");

        let before_first = repository
            .find_effective_for_date(user_id, date(2025, 12, 31))
            .await
            .expect("find goal before first effective date");
        assert!(before_first.is_none());

        let on_january_effective_date = repository
            .find_effective_for_date(user_id, date(2026, 1, 1))
            .await
            .expect("find january goal on its effective date")
            .expect("january goal is effective on its own effective date");
        assert_eq!(on_january_effective_date.effective_from, date(2026, 1, 1));
        assert_eq!(
            on_january_effective_date.targets.calorie_target,
            Decimal::from(2100)
        );

        let on_february_effective_date = repository
            .find_effective_for_date(user_id, date(2026, 2, 1))
            .await
            .expect("find february goal on its effective date")
            .expect("february goal is effective on its own effective date");
        assert_eq!(on_february_effective_date.effective_from, date(2026, 2, 1));
        assert_eq!(
            on_february_effective_date.targets.calorie_target,
            Decimal::from(2290)
        );
        assert_eq!(
            on_february_effective_date.targets.protein_target_g,
            Decimal::from(160)
        );
        assert_eq!(
            on_february_effective_date.targets.carbs_target_g,
            Decimal::from(255)
        );
        assert_eq!(
            on_february_effective_date.targets.fat_target_g,
            Decimal::from(70)
        );

        let after_january = repository
            .find_effective_for_date(user_id, date(2026, 2, 15))
            .await
            .expect("find february goal after its effective date")
            .expect("february goal is effective after its effective date");
        assert_eq!(after_january.effective_from, date(2026, 2, 1));
        assert_eq!(after_january.targets.calorie_target, Decimal::from(2290));

        let between = repository
            .find_effective_for_date(user_id, date(2026, 1, 15))
            .await
            .expect("find january goal between effective dates")
            .expect("january goal is effective between effective dates");
        assert_eq!(
            between.effective_from,
            date(2026, 1, 1),
            "another user's goal must not be selected"
        );
        assert_eq!(between.targets.calorie_target, Decimal::from(2100));
    }
}

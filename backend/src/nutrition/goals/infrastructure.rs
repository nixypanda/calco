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
}

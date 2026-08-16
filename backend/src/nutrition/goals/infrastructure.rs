use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use sqlx::postgres::PgPool;
use uuid::Uuid;

use crate::nutrition::goals::domain::{GoalTarget, GoalTargetRepository, GoalTargets};

#[derive(Clone)]
pub struct PostgresGoalTargetRepository {
    pool: PgPool,
}

impl PostgresGoalTargetRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl GoalTargetRepository for PostgresGoalTargetRepository {
    async fn find_effective_for_date(
        &self,
        user_id: Uuid,
        requested_date: NaiveDate,
    ) -> Result<Option<GoalTarget>, crate::nutrition::error::NutritionError> {
        let row = sqlx::query_as::<_, GoalTargetRow>(
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
        .fetch_optional(&self.pool)
        .await?;

        row.map(goal_target_row_to_domain).transpose()
    }

    async fn find_by_user_id_and_effective_from(
        &self,
        user_id: Uuid,
        effective_from: NaiveDate,
    ) -> Result<Option<GoalTarget>, crate::nutrition::error::NutritionError> {
        let row = sqlx::query_as::<_, GoalTargetRow>(
            r#"
            SELECT id, user_id, effective_from, calorie_target, protein_target_g, carbs_target_g, fat_target_g,
                   created_at, updated_at
            FROM goal_target_versions
            WHERE user_id = $1 AND effective_from = $2
            "#,
        )
        .bind(user_id)
        .bind(effective_from)
        .fetch_optional(&self.pool)
        .await?;

        row.map(goal_target_row_to_domain).transpose()
    }

    async fn create(
        &self,
        goal_target: &GoalTarget,
    ) -> Result<(), crate::nutrition::error::NutritionError> {
        sqlx::query(
            r#"
            INSERT INTO goal_target_versions (
                id, user_id, effective_from, calorie_target, protein_target_g, carbs_target_g, fat_target_g,
                created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
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
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn update(
        &self,
        goal_target: &GoalTarget,
    ) -> Result<(), crate::nutrition::error::NutritionError> {
        sqlx::query(
            r#"
            UPDATE goal_target_versions
            SET calorie_target = $2,
                protein_target_g = $3,
                carbs_target_g = $4,
                fat_target_g = $5,
                updated_at = $6
            WHERE id = $1
            "#,
        )
        .bind(goal_target.id)
        .bind(goal_target.targets.calorie_target)
        .bind(goal_target.targets.protein_target_g)
        .bind(goal_target.targets.carbs_target_g)
        .bind(goal_target.targets.fat_target_g)
        .bind(goal_target.updated_at)
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

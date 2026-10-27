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

#[derive(sqlx::FromRow)]
struct DiaryPreferencesRow {
    user_id: Uuid,
    enabled_meal_slots: Vec<String>,
}

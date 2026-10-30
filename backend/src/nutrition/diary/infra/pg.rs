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
    DiaryPrefs as DomainDiaryPrefs, DiaryPrefsRepo, EnabledMealSlots,
};
use crate::nutrition::error::NutritionError;
use crate::nutrition::food_log::domain::MealSlot;

#[derive(Iden)]
#[iden = "diary_preferences"]
enum DiaryPrefs {
    Table,
    UserId,
    EnabledMealSlots,
    UpdatedAt,
}

#[derive(Clone)]
pub struct PgDiaryPrefsRepo {
    pool: PgPool,
}

impl PgDiaryPrefsRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn diary_prefs_find_by_user_id_statement(user_id: Uuid) -> SelectStatement {
    Query::select()
        .columns([DiaryPrefs::UserId, DiaryPrefs::EnabledMealSlots])
        .from(DiaryPrefs::Table)
        .and_where(Expr::col(DiaryPrefs::UserId).eq(user_id))
        .to_owned()
}

fn canonical_slots(prefs: &DomainDiaryPrefs) -> Vec<String> {
    prefs
        .enabled_meal_slots
        .canonical()
        .into_iter()
        .map(|slot| slot.as_str().to_owned())
        .collect()
}

fn diary_prefs_upsert_statement(prefs: &DomainDiaryPrefs) -> InsertStatement {
    let slots = canonical_slots(prefs);
    Query::insert()
        .into_table(DiaryPrefs::Table)
        .columns([DiaryPrefs::UserId, DiaryPrefs::EnabledMealSlots])
        .values_panic([prefs.user_id.into(), slots.into()])
        .on_conflict(
            OnConflict::column(DiaryPrefs::UserId)
                .update_column(DiaryPrefs::EnabledMealSlots)
                .value(DiaryPrefs::UpdatedAt, Expr::current_timestamp())
                .to_owned(),
        )
        .to_owned()
}

#[async_trait]
impl DiaryPrefsRepo for PgDiaryPrefsRepo {
    async fn find_by_user_id(
        &self,
        user_id: Uuid,
    ) -> Result<Option<DomainDiaryPrefs>, NutritionError> {
        let (sql, values) =
            diary_prefs_find_by_user_id_statement(user_id).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, DiaryPrefsRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        row.map(row_to_domain).transpose()
    }

    async fn upsert(&self, prefs: &DomainDiaryPrefs) -> Result<(), NutritionError> {
        let (sql, values) = diary_prefs_upsert_statement(prefs).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

fn row_to_domain(row: DiaryPrefsRow) -> Result<DomainDiaryPrefs, NutritionError> {
    let slots = row
        .enabled_meal_slots
        .iter()
        .map(|slot| MealSlot::from_str(slot).map_err(NutritionError::Internal))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(DomainDiaryPrefs::new(
        row.user_id,
        EnabledMealSlots::new(slots)?,
    ))
}

#[derive(sqlx::FromRow)]
struct DiaryPrefsRow {
    user_id: Uuid,
    enabled_meal_slots: Vec<String>,
}

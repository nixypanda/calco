use async_trait::async_trait;
use sea_query::{Expr, ExprTrait, Order, PostgresQueryBuilder, Query, SelectStatement};
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;

use crate::nutrition::catalog::domain::{
    Nutrient, NutrientCode, NutrientRepository, NutritionError, UnitCode,
};

use super::iden::Nutrients;

// ─── Nutrient Repository ───────────────────────────────────────

fn list_nutrients_statement() -> SelectStatement {
    Query::select()
        .columns([
            Nutrients::Code,
            Nutrients::Name,
            Nutrients::Unit,
            Nutrients::Category,
        ])
        .from(Nutrients::Table)
        .order_by(Nutrients::Code, Order::Asc)
        .to_owned()
}

fn find_nutrient_statement(code: &str) -> SelectStatement {
    Query::select()
        .columns([
            Nutrients::Code,
            Nutrients::Name,
            Nutrients::Unit,
            Nutrients::Category,
        ])
        .from(Nutrients::Table)
        .and_where(Expr::col(Nutrients::Code).eq(code))
        .to_owned()
}

#[derive(Clone)]
pub struct PostgresNutrientRepository {
    pool: PgPool,
}

impl PostgresNutrientRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl NutrientRepository for PostgresNutrientRepository {
    async fn list_all(&self) -> Result<Vec<Nutrient>, NutritionError> {
        let (sql, values) = list_nutrients_statement().build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, NutrientRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        Ok(rows.into_iter().map(nutrient_row_to_nutrient).collect())
    }

    async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, NutritionError> {
        let (sql, values) = find_nutrient_statement(code).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, NutrientRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        Ok(row.map(nutrient_row_to_nutrient))
    }
}

#[derive(sqlx::FromRow)]
struct NutrientRow {
    code: String,
    name: String,
    unit: String,
    category: String,
}

fn nutrient_row_to_nutrient(row: NutrientRow) -> Nutrient {
    Nutrient {
        code: NutrientCode(row.code),
        name: row.name,
        unit: UnitCode(row.unit),
        category: row.category,
    }
}

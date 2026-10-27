use async_trait::async_trait;
use rust_decimal::Decimal;
use sea_query::{Expr, ExprTrait, Iden, Order, PostgresQueryBuilder, Query, SelectStatement};
use sea_query_sqlx::SqlxBinder;
use sqlx::postgres::PgPool;

use crate::nutrition::catalog::domain::{NutritionError, UnitCode, UnitRepo};

#[derive(Iden)]
enum Units {
    Table,
    Code,
    Name,
    Kind,
    CanonicalGrams,
}

// ─── Unit Repo ───────────────────────────────────────────

fn list_units_statement() -> SelectStatement {
    Query::select()
        .columns([Units::Code, Units::Name, Units::Kind])
        .from(Units::Table)
        .order_by(Units::Code, Order::Asc)
        .to_owned()
}

fn list_mass_factors_statement() -> SelectStatement {
    Query::select()
        .columns([Units::Code, Units::CanonicalGrams])
        .from(Units::Table)
        .and_where(Expr::col(Units::CanonicalGrams).is_not_null())
        .to_owned()
}

#[derive(Clone)]
pub struct PgUnitRepo {
    pool: PgPool,
}

impl PgUnitRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl UnitRepo for PgUnitRepo {
    async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
        let (sql, values) = list_units_statement().build_sqlx(PostgresQueryBuilder);
        let rows = sqlx::query_as_with::<_, UnitRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_all(&self.pool)
            .await?;

        Ok(rows
            .into_iter()
            .map(|r| (UnitCode(r.code), r.name, r.kind))
            .collect())
    }

    async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, NutritionError> {
        let (sql, values) = list_mass_factors_statement().build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, MassFactorRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        Ok(rows
            .into_iter()
            .map(|r| (r.code, r.canonical_grams))
            .collect())
    }
}

#[derive(sqlx::FromRow)]
struct UnitRow {
    code: String,
    name: String,
    kind: String,
}

#[derive(sqlx::FromRow)]
struct MassFactorRow {
    code: String,
    canonical_grams: Decimal,
}

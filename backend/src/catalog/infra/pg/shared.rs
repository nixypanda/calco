use sea_query::{Expr, ExprTrait, Iden, InsertStatement, PostgresQueryBuilder, Query};
use sea_query_sqlx::SqlxBinder;

use std::collections::HashMap;
use uuid::Uuid;

use crate::catalog::error::CatalogError;

/// Iden for the shared `nutrients` catalog table.
#[derive(Iden)]
enum Nutrients {
    Table,
    Id,
    Code,
}

/// Resolve a list of nutrient codes (one entry per snapshot, duplicates
/// allowed) to their database ids, validating that every code exists.
///
/// Returns a map from code to nutrient id. The `entity` label is used in the
/// validation error message (e.g. `"food log snapshot"` / `"product"`).
pub async fn resolve_nutrient_ids(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    codes: &[String],
    entity: &str,
) -> Result<HashMap<String, Uuid>, CatalogError> {
    if codes.is_empty() {
        return Ok(HashMap::new());
    }

    // Unique codes for the lookup query.
    let mut unique_codes: Vec<String> = codes.to_vec();
    unique_codes.sort();
    unique_codes.dedup();

    let (sql, values) = Query::select()
        .columns([Nutrients::Code, Nutrients::Id])
        .from(Nutrients::Table)
        .and_where(Expr::col(Nutrients::Code).is_in(unique_codes.to_vec()))
        .to_owned()
        .build_sqlx(PostgresQueryBuilder);
    let rows: Vec<(String, Uuid)> =
        sqlx::query_as_with::<_, (String, Uuid), _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_all(&mut **tx)
            .await?;
    let nutrient_ids: HashMap<String, Uuid> = rows.into_iter().collect();

    // Validate that every snapshot's code resolved.
    let resolved_count = codes
        .iter()
        .filter(|c| nutrient_ids.contains_key(c.as_str()))
        .count();
    if resolved_count != codes.len() {
        return Err(CatalogError::Validation(format!(
            "unknown nutrient code in {} (expected {} rows, inserted {})",
            entity,
            codes.len(),
            resolved_count
        )));
    }

    Ok(nutrient_ids)
}

/// Execute a multi-row insert in bounded chunks, returning the total number
/// of rows affected.
///
/// `total` is the number of logical rows. `build(start, end)` produces the
/// `InsertStatement` for the slice `[start..end]` (it may capture the data
/// and resolved id map by reference). `chunk_size` caps rows per statement.
pub async fn insert_chunked<F>(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    total: usize,
    chunk_size: usize,
    mut build: F,
) -> Result<usize, CatalogError>
where
    F: FnMut(usize, usize) -> InsertStatement,
{
    if total == 0 {
        return Ok(0);
    }

    let mut written: usize = 0;
    let mut start = 0;
    while start < total {
        let end = (start + chunk_size).min(total);
        let statement = build(start, end);
        let (sql, values) = statement.build_sqlx(PostgresQueryBuilder);
        let result = sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&mut **tx)
            .await?;
        written += result.rows_affected() as usize;
        start = end;
    }
    Ok(written)
}

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sea_query::extension::postgres::PgExpr;
use sea_query::{
    Expr, ExprTrait, Iden, InsertStatement, PostgresQueryBuilder, Query, SelectStatement,
    UpdateStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Iden)]
enum Identities {
    Table,
    Id,
    Username,
    PasswordHash,
    Role,
    Status,
    SessionSecurityStamp,
    CreatedAt,
    UpdatedAt,
}

#[derive(Clone)]
pub struct PgIdentityRepo {
    pool: PgPool,
}
impl PgIdentityRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn identity_columns() -> [Identities; 8] {
    [
        Identities::Id,
        Identities::Username,
        Identities::PasswordHash,
        Identities::Role,
        Identities::Status,
        Identities::SessionSecurityStamp,
        Identities::CreatedAt,
        Identities::UpdatedAt,
    ]
}

fn find_by_username_statement(username: &str) -> SelectStatement {
    Query::select()
        .columns(identity_columns())
        .from(Identities::Table)
        .and_where(Expr::col(Identities::Username).eq(username))
        .to_owned()
}

fn find_by_id_statement(id: IdentityId) -> SelectStatement {
    Query::select()
        .columns(identity_columns())
        .from(Identities::Table)
        .and_where(Expr::col(Identities::Id).eq(id.0))
        .to_owned()
}

fn find_by_ids_statement(ids: &[Uuid]) -> SelectStatement {
    Query::select()
        .columns(identity_columns())
        .from(Identities::Table)
        .and_where(Expr::col(Identities::Id).eq_any(ids.to_vec()))
        .to_owned()
}

fn create_statement(identity: &Identity) -> InsertStatement {
    Query::insert()
        .into_table(Identities::Table)
        .columns(identity_columns())
        .values_panic([
            identity.id.0.into(),
            identity.username.as_str().into(),
            identity.password_hash.0.as_str().into(),
            identity.role.as_str().into(),
            identity.status.as_str().into(),
            identity.session_security_stamp.0.into(),
            identity.created_at.into(),
            identity.updated_at.into(),
        ])
        .to_owned()
}

fn update_statement(identity: &Identity) -> UpdateStatement {
    Query::update()
        .table(Identities::Table)
        .values([
            (
                Identities::PasswordHash,
                identity.password_hash.0.as_str().into(),
            ),
            (Identities::Status, identity.status.as_str().into()),
            (
                Identities::SessionSecurityStamp,
                identity.session_security_stamp.0.into(),
            ),
            (Identities::UpdatedAt, identity.updated_at.into()),
        ])
        .and_where(Expr::col(Identities::Id).eq(identity.id.0))
        .to_owned()
}

fn exists_admin_statement() -> SelectStatement {
    Query::select()
        .expr(Expr::exists(
            Query::select()
                .expr(Expr::val(1))
                .from(Identities::Table)
                .and_where(Expr::col(Identities::Role).eq(IdentityRole::Admin.as_str()))
                .to_owned(),
        ))
        .to_owned()
}

#[async_trait]
impl IdentityRepo for PgIdentityRepo {
    async fn find_by_username(&self, username: &str) -> Result<Option<Identity>, AuthError> {
        let (sql, values) = find_by_username_statement(username).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, IdentityRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        row.map(identity_row_to_identity).transpose()
    }

    async fn find_by_id(&self, id: IdentityId) -> Result<Option<Identity>, AuthError> {
        let (sql, values) = find_by_id_statement(id).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, IdentityRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        row.map(identity_row_to_identity).transpose()
    }

    async fn find_by_ids(&self, ids: &[IdentityId]) -> Result<Vec<Identity>, AuthError> {
        let ids: Vec<Uuid> = ids.iter().map(|id| id.0).collect();
        let (sql, values) = find_by_ids_statement(&ids).build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, IdentityRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        rows.into_iter().map(identity_row_to_identity).collect()
    }

    async fn create(&self, identity: &Identity) -> Result<(), AuthError> {
        let (sql, values) = create_statement(identity).build_sqlx(PostgresQueryBuilder);
        let result = sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await;

        match result {
            Ok(_) => Ok(()),
            Err(e) => Err(map_identity_insert_error(e)),
        }
    }

    async fn update(&self, identity: &Identity) -> Result<(), AuthError> {
        let (sql, values) = update_statement(identity).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;

        Ok(())
    }

    async fn exists_admin(&self) -> Result<bool, AuthError> {
        let (sql, values) = exists_admin_statement().build_sqlx(PostgresQueryBuilder);
        let row: (bool,) =
            sqlx::query_as_with::<_, (bool,), _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_one(&self.pool)
                .await?;

        Ok(row.0)
    }
}

fn map_identity_insert_error(err: sqlx::Error) -> AuthError {
    if let sqlx::Error::Database(db_err) = &err
        && db_err.is_unique_violation()
    {
        let constraint = db_err.constraint().unwrap_or("");
        if constraint.contains("username") {
            return AuthError::UsernameTaken;
        }
        if constraint.contains("admin") {
            return AuthError::AdminAlreadyExists;
        }
    }
    AuthError::Database(err)
}

#[derive(sqlx::FromRow)]
struct IdentityRow {
    id: Uuid,
    username: String,
    password_hash: String,
    role: String,
    status: String,
    session_security_stamp: Uuid,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

fn identity_row_to_identity(row: IdentityRow) -> Result<Identity, AuthError> {
    Ok(Identity {
        id: IdentityId(row.id),
        username: Username::new(&row.username)?,
        password_hash: PasswordHash(row.password_hash),
        role: row.role.parse::<IdentityRole>()?,
        status: row.status.parse::<IdentityStatus>()?,
        session_security_stamp: SessionSecurityStamp(row.session_security_stamp),
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sea_query::{
    Condition, Expr, ExprTrait, Iden, InsertStatement, PostgresQueryBuilder, Query,
    SelectStatement, UpdateStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Iden)]
enum Sessions {
    Table,
    Id,
    IdentityId,
    IdentitySecurityStamp,
    SessionTokenHash,
    CreatedAt,
    LastSeenAt,
    ExpiresAt,
    RevokedAt,
}

#[derive(Clone)]
pub struct PgSessionRepo {
    pool: PgPool,
}
impl PgSessionRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn session_columns() -> [Sessions; 8] {
    [
        Sessions::Id,
        Sessions::IdentityId,
        Sessions::IdentitySecurityStamp,
        Sessions::SessionTokenHash,
        Sessions::CreatedAt,
        Sessions::LastSeenAt,
        Sessions::ExpiresAt,
        Sessions::RevokedAt,
    ]
}

fn create_statement(session: &Session) -> InsertStatement {
    Query::insert()
        .into_table(Sessions::Table)
        .columns(session_columns())
        .values_panic([
            session.id.into(),
            session.identity_id.0.into(),
            session.identity_security_stamp.0.into(),
            session.session_token_hash.0.as_str().into(),
            session.created_at.into(),
            session.last_seen_at.into(),
            session.expires_at.into(),
            session.revoked_at.into(),
        ])
        .to_owned()
}

fn find_by_token_hash_statement(token_hash: &str) -> SelectStatement {
    Query::select()
        .columns(session_columns())
        .from(Sessions::Table)
        .and_where(Expr::col(Sessions::SessionTokenHash).eq(token_hash))
        .to_owned()
}

fn update_statement(session: &Session) -> UpdateStatement {
    Query::update()
        .table(Sessions::Table)
        .values([
            (Sessions::IdentityId, session.identity_id.0.into()),
            (
                Sessions::IdentitySecurityStamp,
                session.identity_security_stamp.0.into(),
            ),
            (
                Sessions::SessionTokenHash,
                session.session_token_hash.0.as_str().into(),
            ),
            (Sessions::CreatedAt, session.created_at.into()),
            (Sessions::LastSeenAt, session.last_seen_at.into()),
            (Sessions::ExpiresAt, session.expires_at.into()),
            (Sessions::RevokedAt, session.revoked_at.into()),
        ])
        .and_where(Expr::col(Sessions::Id).eq(session.id))
        .and_where(
            Condition::any()
                .add(Expr::col(Sessions::RevokedAt).is_null())
                .add(Expr::val(session.revoked_at).is_not_null())
                .into(),
        )
        .to_owned()
}

#[async_trait]
impl SessionRepo for PgSessionRepo {
    async fn create(&self, session: &Session) -> Result<(), AuthError> {
        let (sql, values) = create_statement(session).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;

        Ok(())
    }

    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<Session>, AuthError> {
        let (sql, values) =
            find_by_token_hash_statement(token_hash).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, SessionRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        Ok(row.map(session_row_to_session))
    }

    async fn update(&self, session: &Session) -> Result<(), AuthError> {
        let (sql, values) = update_statement(session).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;

        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct SessionRow {
    id: Uuid,
    identity_id: Uuid,
    identity_security_stamp: Uuid,
    session_token_hash: String,
    created_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    revoked_at: Option<DateTime<Utc>>,
}

fn session_row_to_session(row: SessionRow) -> Session {
    Session {
        id: row.id,
        identity_id: IdentityId(row.identity_id),
        identity_security_stamp: SessionSecurityStamp(row.identity_security_stamp),
        session_token_hash: SessionTokenHash(row.session_token_hash),
        created_at: row.created_at,
        last_seen_at: row.last_seen_at,
        expires_at: row.expires_at,
        revoked_at: row.revoked_at,
    }
}

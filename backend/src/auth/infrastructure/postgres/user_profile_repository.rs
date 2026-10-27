use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sea_query::{
    Expr, ExprTrait, Iden, InsertStatement, Order, PostgresQueryBuilder, Query, SelectStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Iden)]
enum UserProfiles {
    Table,
    Id,
    IdentityId,
    DisplayName,
    CreatedAt,
    UpdatedAt,
}

#[derive(Clone)]
pub struct PostgresUserProfileRepository {
    pool: PgPool,
}
impl PostgresUserProfileRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn profile_columns() -> [UserProfiles; 5] {
    [
        UserProfiles::Id,
        UserProfiles::IdentityId,
        UserProfiles::DisplayName,
        UserProfiles::CreatedAt,
        UserProfiles::UpdatedAt,
    ]
}

fn find_by_identity_id_statement(identity_id: IdentityId) -> SelectStatement {
    Query::select()
        .columns(profile_columns())
        .from(UserProfiles::Table)
        .and_where(Expr::col(UserProfiles::IdentityId).eq(identity_id.0))
        .to_owned()
}

fn find_by_id_statement(id: Uuid) -> SelectStatement {
    Query::select()
        .columns(profile_columns())
        .from(UserProfiles::Table)
        .and_where(Expr::col(UserProfiles::Id).eq(id))
        .to_owned()
}

fn create_statement(profile: &UserProfile) -> InsertStatement {
    Query::insert()
        .into_table(UserProfiles::Table)
        .columns(profile_columns())
        .values_panic([
            profile.id.into(),
            profile.identity_id.0.into(),
            profile.display_name.as_str().into(),
            profile.created_at.into(),
            profile.updated_at.into(),
        ])
        .to_owned()
}

fn list_all_statement() -> SelectStatement {
    Query::select()
        .columns(profile_columns())
        .from(UserProfiles::Table)
        .order_by(UserProfiles::CreatedAt, Order::Desc)
        .to_owned()
}

#[async_trait]
impl UserProfileRepository for PostgresUserProfileRepository {
    async fn find_by_identity_id(
        &self,
        identity_id: IdentityId,
    ) -> Result<Option<UserProfile>, AuthError> {
        let (sql, values) =
            find_by_identity_id_statement(identity_id).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, ProfileRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        Ok(row.map(profile_row_to_user_profile))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<UserProfile>, AuthError> {
        let (sql, values) = find_by_id_statement(id).build_sqlx(PostgresQueryBuilder);
        let row =
            sqlx::query_as_with::<_, ProfileRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_optional(&self.pool)
                .await?;

        Ok(row.map(profile_row_to_user_profile))
    }

    async fn create(&self, profile: &UserProfile) -> Result<(), AuthError> {
        let (sql, values) = create_statement(profile).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;

        Ok(())
    }

    async fn list_all(&self) -> Result<Vec<UserProfile>, AuthError> {
        let (sql, values) = list_all_statement().build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, ProfileRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        Ok(rows.into_iter().map(profile_row_to_user_profile).collect())
    }
}

#[derive(sqlx::FromRow)]
struct ProfileRow {
    id: Uuid,
    identity_id: Uuid,
    display_name: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

fn profile_row_to_user_profile(row: ProfileRow) -> UserProfile {
    UserProfile {
        id: row.id,
        identity_id: IdentityId(row.identity_id),
        display_name: row.display_name,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

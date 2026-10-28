use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sea_query::{
    Condition, Expr, ExprTrait, Iden, InsertStatement, Order, PostgresQueryBuilder, Query,
    SelectStatement, UpdateStatement,
};
use sea_query_sqlx::SqlxBinder;
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::domain::*;

#[derive(Iden)]
enum ApiKeys {
    Table,
    Id,
    IdentityId,
    IdentitySecurityStamp,
    Name,
    TokenHash,
    TokenHint,
    Scope,
    CreatedAt,
    LastUsedAt,
    ExpiresAt,
    RevokedAt,
}

#[derive(Clone)]
pub struct PgApiKeyRepo {
    pool: PgPool,
}

impl PgApiKeyRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

fn api_key_columns() -> [ApiKeys; 11] {
    [
        ApiKeys::Id,
        ApiKeys::IdentityId,
        ApiKeys::IdentitySecurityStamp,
        ApiKeys::Name,
        ApiKeys::TokenHash,
        ApiKeys::TokenHint,
        ApiKeys::Scope,
        ApiKeys::CreatedAt,
        ApiKeys::LastUsedAt,
        ApiKeys::ExpiresAt,
        ApiKeys::RevokedAt,
    ]
}

fn create_statement(key: &ApiKey) -> InsertStatement {
    Query::insert()
        .into_table(ApiKeys::Table)
        .columns(api_key_columns())
        .values_panic([
            key.id.0.into(),
            key.identity_id.0.into(),
            key.identity_security_stamp.0.into(),
            key.name.as_str().into(),
            key.token_hash.0.as_str().into(),
            key.token_hint.as_str().into(),
            key.scope.as_str().into(),
            key.created_at.into(),
            key.last_used_at.into(),
            key.expires_at.into(),
            key.revoked_at.into(),
        ])
        .to_owned()
}

fn find_by_token_hash_statement(token_hash: &str) -> SelectStatement {
    Query::select()
        .columns(api_key_columns())
        .from(ApiKeys::Table)
        .and_where(Expr::col(ApiKeys::TokenHash).eq(token_hash))
        .to_owned()
}

fn find_by_id_statement(id: ApiKeyId) -> SelectStatement {
    Query::select()
        .columns(api_key_columns())
        .from(ApiKeys::Table)
        .and_where(Expr::col(ApiKeys::Id).eq(id.0))
        .to_owned()
}

fn find_by_id_and_identity_id_statement(id: ApiKeyId, identity_id: IdentityId) -> SelectStatement {
    Query::select()
        .columns(api_key_columns())
        .from(ApiKeys::Table)
        .and_where(Expr::col(ApiKeys::Id).eq(id.0))
        .and_where(Expr::col(ApiKeys::IdentityId).eq(identity_id.0))
        .to_owned()
}

fn list_by_identity_id_statement(identity_id: IdentityId) -> SelectStatement {
    Query::select()
        .columns(api_key_columns())
        .from(ApiKeys::Table)
        .and_where(Expr::col(ApiKeys::IdentityId).eq(identity_id.0))
        .order_by(ApiKeys::CreatedAt, Order::Desc)
        .to_owned()
}

fn update_statement(key: &ApiKey) -> UpdateStatement {
    Query::update()
        .table(ApiKeys::Table)
        .values([
            (ApiKeys::IdentityId, key.identity_id.0.into()),
            (
                ApiKeys::IdentitySecurityStamp,
                key.identity_security_stamp.0.into(),
            ),
            (ApiKeys::Name, key.name.as_str().into()),
            (ApiKeys::TokenHash, key.token_hash.0.as_str().into()),
            (ApiKeys::TokenHint, key.token_hint.as_str().into()),
            (ApiKeys::Scope, key.scope.as_str().into()),
            (ApiKeys::CreatedAt, key.created_at.into()),
            (ApiKeys::LastUsedAt, key.last_used_at.into()),
            (ApiKeys::ExpiresAt, key.expires_at.into()),
            (ApiKeys::RevokedAt, key.revoked_at.into()),
        ])
        .and_where(Expr::col(ApiKeys::Id).eq(key.id.0))
        .and_where(Expr::col(ApiKeys::IdentityId).eq(key.identity_id.0))
        .and_where(
            Condition::any()
                .add(Expr::col(ApiKeys::RevokedAt).is_null())
                .add(Expr::val(key.revoked_at).is_not_null())
                .into(),
        )
        .to_owned()
}

#[async_trait]
impl ApiKeyRepo for PgApiKeyRepo {
    async fn create(&self, key: &ApiKey) -> Result<(), AuthError> {
        let (sql, values) = create_statement(key).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;

        Ok(())
    }

    async fn find_by_token_hash(&self, token_hash: &str) -> Result<Option<ApiKey>, AuthError> {
        let (sql, values) =
            find_by_token_hash_statement(token_hash).build_sqlx(PostgresQueryBuilder);
        let row = sqlx::query_as_with::<_, ApiKeyRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_optional(&self.pool)
            .await?;

        row.map(api_key_row_to_api_key).transpose()
    }

    async fn find_by_id(&self, id: ApiKeyId) -> Result<Option<ApiKey>, AuthError> {
        let (sql, values) = find_by_id_statement(id).build_sqlx(PostgresQueryBuilder);
        let row = sqlx::query_as_with::<_, ApiKeyRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_optional(&self.pool)
            .await?;

        row.map(api_key_row_to_api_key).transpose()
    }

    async fn find_by_id_and_identity_id(
        &self,
        id: ApiKeyId,
        identity_id: IdentityId,
    ) -> Result<Option<ApiKey>, AuthError> {
        let (sql, values) =
            find_by_id_and_identity_id_statement(id, identity_id).build_sqlx(PostgresQueryBuilder);
        let row = sqlx::query_as_with::<_, ApiKeyRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .fetch_optional(&self.pool)
            .await?;

        row.map(api_key_row_to_api_key).transpose()
    }

    async fn list_by_identity_id(&self, id: IdentityId) -> Result<Vec<ApiKey>, AuthError> {
        let (sql, values) = list_by_identity_id_statement(id).build_sqlx(PostgresQueryBuilder);
        let rows =
            sqlx::query_as_with::<_, ApiKeyRow, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
                .fetch_all(&self.pool)
                .await?;

        rows.into_iter().map(api_key_row_to_api_key).collect()
    }

    async fn update(&self, key: &ApiKey) -> Result<(), AuthError> {
        let (sql, values) = update_statement(key).build_sqlx(PostgresQueryBuilder);
        sqlx::query_with::<_, _>(sqlx::AssertSqlSafe(sql.as_str()), values)
            .execute(&self.pool)
            .await?;

        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct ApiKeyRow {
    id: Uuid,
    identity_id: Uuid,
    identity_security_stamp: Uuid,
    name: String,
    token_hash: String,
    token_hint: String,
    scope: String,
    created_at: DateTime<Utc>,
    last_used_at: Option<DateTime<Utc>>,
    expires_at: Option<DateTime<Utc>>,
    revoked_at: Option<DateTime<Utc>>,
}

fn api_key_row_to_api_key(row: ApiKeyRow) -> Result<ApiKey, AuthError> {
    Ok(ApiKey {
        id: ApiKeyId(row.id),
        identity_id: IdentityId(row.identity_id),
        identity_security_stamp: SessionSecurityStamp(row.identity_security_stamp),
        name: ApiKeyName::new(&row.name)?,
        token_hash: ApiKeyTokenHash(row.token_hash),
        token_hint: row.token_hint,
        scope: row.scope.parse()?,
        created_at: row.created_at,
        last_used_at: row.last_used_at,
        expires_at: row.expires_at,
        revoked_at: row.revoked_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::infra::pg::{PgIdentityRepo, PgUserProfileRepo};

    #[sqlx::test]
    async fn stale_record_used_does_not_unrevoke_an_api_key(pool: PgPool) {
        // Microsecond-aligned so the Postgres timestamptz round trip is exact.
        let now = DateTime::from_timestamp(1_780_000_000, 0).unwrap();
        let identity = Identity::new_user(
            Username::new("api-key-race").unwrap(),
            PasswordHash("hash".into()),
            now,
        );
        PgIdentityRepo::new(pool.clone())
            .create(&identity)
            .await
            .unwrap();
        PgUserProfileRepo::new(pool.clone())
            .create(&UserProfile::new(identity.id, "API Key Race", now))
            .await
            .unwrap();

        let (_, key) = create_api_key(
            &identity,
            ApiKeyName::new("Race").unwrap(),
            ApiKeyScope::Read,
            None,
            now,
        )
        .unwrap();
        let repo = PgApiKeyRepo::new(pool);
        repo.create(&key).await.unwrap();

        let stale = repo.find_by_id(key.id).await.unwrap().expect("api key");
        assert!(stale.revoked_at.is_none());

        let mut wrong_owner = stale.clone();
        wrong_owner.identity_id = IdentityId::new();
        repo.update(&wrong_owner.record_used(now)).await.unwrap();
        let untouched = repo.find_by_id(key.id).await.unwrap().unwrap();
        assert!(untouched.revoked_at.is_none());
        assert!(untouched.last_used_at.is_none());

        let used = stale.record_used(now);
        repo.update(&used).await.unwrap();
        let refreshed = repo.find_by_id(key.id).await.unwrap().unwrap();
        assert_eq!(
            refreshed.last_used_at,
            Some(now),
            "live key authentication must persist last_used_at"
        );

        let revoked_at = Utc::now();
        repo.update(&refreshed.revoke(revoked_at)).await.unwrap();
        let revoked = repo.find_by_id(key.id).await.unwrap().unwrap();
        let revoked_at = revoked.revoked_at.expect("key should be revoked");
        assert_eq!(revoked.last_used_at, Some(now));

        repo.update(&stale.record_used(now + chrono::Duration::seconds(1)))
            .await
            .unwrap();

        let stored = repo.find_by_id(key.id).await.unwrap().unwrap();
        assert_eq!(stored.revoked_at, Some(revoked_at));
        assert_eq!(stored.last_used_at, Some(now));
    }
}

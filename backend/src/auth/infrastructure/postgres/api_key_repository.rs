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
pub struct PostgresApiKeyRepository {
    pool: PgPool,
}

impl PostgresApiKeyRepository {
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
impl ApiKeyRepository for PostgresApiKeyRepository {
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

#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
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
async fn legacy_create(pool: &PgPool, key: &ApiKey) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO api_keys (id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
    )
    .bind(key.id.0)
    .bind(key.identity_id.0)
    .bind(key.identity_security_stamp.0)
    .bind(key.name.as_str())
    .bind(&key.token_hash.0)
    .bind(&key.token_hint)
    .bind(key.scope.as_str())
    .bind(key.created_at)
    .bind(key.last_used_at)
    .bind(key.expires_at)
    .bind(key.revoked_at)
    .execute(pool)
    .await?;

    Ok(())
}

#[cfg(test)]
async fn legacy_find_by_token_hash(
    pool: &PgPool,
    token_hash: &str,
) -> Result<Option<ApiKeyRow>, sqlx::Error> {
    sqlx::query_as::<_, ApiKeyRow>(
        "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
         FROM api_keys WHERE token_hash = $1",
    )
    .bind(token_hash)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_find_by_id(pool: &PgPool, id: ApiKeyId) -> Result<Option<ApiKeyRow>, sqlx::Error> {
    sqlx::query_as::<_, ApiKeyRow>(
        "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
         FROM api_keys WHERE id = $1",
    )
    .bind(id.0)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_find_by_id_and_identity_id(
    pool: &PgPool,
    id: ApiKeyId,
    identity_id: IdentityId,
) -> Result<Option<ApiKeyRow>, sqlx::Error> {
    sqlx::query_as::<_, ApiKeyRow>(
        "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
         FROM api_keys WHERE id = $1 AND identity_id = $2",
    )
    .bind(id.0)
    .bind(identity_id.0)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_list_by_identity_id(
    pool: &PgPool,
    id: IdentityId,
) -> Result<Vec<ApiKeyRow>, sqlx::Error> {
    sqlx::query_as::<_, ApiKeyRow>(
        "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, scope, created_at, last_used_at, expires_at, revoked_at \
         FROM api_keys WHERE identity_id = $1 ORDER BY created_at DESC",
    )
    .bind(id.0)
    .fetch_all(pool)
    .await
}

#[cfg(test)]
async fn legacy_update(pool: &PgPool, key: &ApiKey) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE api_keys SET identity_id = $1, identity_security_stamp = $2, name = $3, token_hash = $4, token_hint = $5, scope = $6, created_at = $7, last_used_at = $8, expires_at = $9, revoked_at = $10 WHERE id = $11 AND identity_id = $12 AND (revoked_at IS NULL OR $10 IS NOT NULL)",
    )
    .bind(key.identity_id.0)
    .bind(key.identity_security_stamp.0)
    .bind(key.name.as_str())
    .bind(&key.token_hash.0)
    .bind(&key.token_hint)
    .bind(key.scope.as_str())
    .bind(key.created_at)
    .bind(key.last_used_at)
    .bind(key.expires_at)
    .bind(key.revoked_at)
    .bind(key.id.0)
    .bind(key.identity_id.0)
    .execute(pool)
    .await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timestamp(seconds: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(seconds, 0).expect("valid timestamp")
    }

    fn api_key_fixture(
        id: Uuid,
        identity_id: Uuid,
        stamp: Uuid,
        name: &str,
        token_hash: &str,
        created_at: i64,
    ) -> ApiKey {
        ApiKey {
            id: ApiKeyId(id),
            identity_id: IdentityId(identity_id),
            identity_security_stamp: SessionSecurityStamp(stamp),
            name: ApiKeyName::new(name).expect("valid api key name"),
            token_hash: ApiKeyTokenHash(token_hash.to_owned()),
            token_hint: "calco_pat_test_hint".to_owned(),
            scope: ApiKeyScope::Read,
            created_at: timestamp(created_at),
            last_used_at: None,
            expires_at: Some(timestamp(created_at + 1_000)),
            revoked_at: None,
        }
    }

    fn api_key_as_row(key: &ApiKey) -> ApiKeyRow {
        ApiKeyRow {
            id: key.id.0,
            identity_id: key.identity_id.0,
            identity_security_stamp: key.identity_security_stamp.0,
            name: key.name.as_str().to_owned(),
            token_hash: key.token_hash.0.clone(),
            token_hint: key.token_hint.clone(),
            scope: key.scope.as_str().to_owned(),
            created_at: key.created_at,
            last_used_at: key.last_used_at,
            expires_at: key.expires_at,
            revoked_at: key.revoked_at,
        }
    }

    async fn seed_identity(pool: &PgPool, label: &str) -> Uuid {
        let id = Uuid::new_v4();
        sqlx::query(
            r#"
            INSERT INTO identities (
                id, username, password_hash, role, status, created_at, updated_at,
                session_security_stamp
            )
            VALUES ($1, $2, 'test-password-hash', 'user', 'active', now(), now(), $3)
            "#,
        )
        .bind(id)
        .bind(format!("{label}-{id}"))
        .bind(Uuid::new_v4())
        .execute(pool)
        .await
        .expect("seed identity");

        id
    }

    async fn fetch_api_key_row(pool: &PgPool, id: ApiKeyId) -> ApiKeyRow {
        sqlx::query_as::<_, ApiKeyRow>(
            "SELECT id, identity_id, identity_security_stamp, name, token_hash, token_hint, \
             scope, created_at, last_used_at, expires_at, revoked_at FROM api_keys WHERE id = $1",
        )
        .bind(id.0)
        .fetch_one(pool)
        .await
        .expect("fetch api key")
    }

    fn assert_rows_equivalent_except_key(
        left: &ApiKeyRow,
        right: &ApiKeyRow,
        ignore_id: bool,
        ignore_token_hash: bool,
    ) {
        if !ignore_id {
            assert_eq!(left.id, right.id);
        }
        assert_eq!(left.identity_id, right.identity_id);
        assert_eq!(left.identity_security_stamp, right.identity_security_stamp);
        assert_eq!(left.name, right.name);
        if !ignore_token_hash {
            assert_eq!(left.token_hash, right.token_hash);
        }
        assert_eq!(left.token_hint, right.token_hint);
        assert_eq!(left.scope, right.scope);
        assert_eq!(left.created_at, right.created_at);
        assert_eq!(left.last_used_at, right.last_used_at);
        assert_eq!(left.expires_at, right.expires_at);
        assert_eq!(left.revoked_at, right.revoked_at);
    }

    #[sqlx::test]
    async fn create_and_read_queries_match_legacy(pool: PgPool) {
        let identity_id = seed_identity(&pool, "api-key-read-owner").await;
        let other_identity_id = seed_identity(&pool, "api-key-read-other").await;
        let repository = PostgresApiKeyRepository::new(pool.clone());
        let stamp = Uuid::new_v4();

        let legacy_key = api_key_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "created key",
            "legacy-create-token-hash",
            1_800_000_000,
        );
        let sea_key = api_key_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "created key",
            "sea-create-token-hash",
            1_800_000_000,
        );

        legacy_create(&pool, &legacy_key)
            .await
            .expect("legacy create api key");
        repository
            .create(&sea_key)
            .await
            .expect("repository create api key");

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM api_keys")
            .fetch_one(&pool)
            .await
            .expect("count api keys");
        assert_eq!(count, 2, "both api keys must be inserted");

        let legacy_row = fetch_api_key_row(&pool, legacy_key.id).await;
        let sea_row = fetch_api_key_row(&pool, sea_key.id).await;

        assert_eq!(legacy_row, api_key_as_row(&legacy_key));
        assert_eq!(sea_row, api_key_as_row(&sea_key));
        assert_rows_equivalent_except_key(&legacy_row, &sea_row, true, true);

        let legacy_by_token = legacy_find_by_token_hash(&pool, &sea_key.token_hash.0)
            .await
            .expect("legacy find_by_token_hash")
            .expect("legacy must find the sea-created key");
        let sea_by_token = repository
            .find_by_token_hash(&sea_key.token_hash.0)
            .await
            .expect("repository find_by_token_hash")
            .expect("repository must find the sea-created key");

        assert_eq!(legacy_by_token, sea_row);
        assert_eq!(api_key_as_row(&sea_by_token), legacy_by_token);
        assert_eq!(sea_by_token.id, sea_key.id);
        assert_eq!(sea_by_token.identity_id, sea_key.identity_id);

        let missing_token = "api-key-token-hash-that-does-not-exist";
        assert_eq!(
            legacy_find_by_token_hash(&pool, missing_token)
                .await
                .expect("legacy find missing token"),
            None
        );
        assert!(
            repository
                .find_by_token_hash(missing_token)
                .await
                .expect("repository find missing token")
                .is_none()
        );

        assert_eq!(
            legacy_find_by_id(&pool, sea_key.id)
                .await
                .expect("legacy find_by_id"),
            Some(sea_row.clone())
        );
        assert_eq!(
            api_key_as_row(
                &repository
                    .find_by_id(sea_key.id)
                    .await
                    .expect("repository find_by_id")
                    .expect("repository must find the key by id")
            ),
            sea_row
        );
        assert_eq!(
            legacy_find_by_id(&pool, ApiKeyId(Uuid::new_v4()))
                .await
                .expect("legacy find missing id"),
            None
        );
        assert!(
            repository
                .find_by_id(ApiKeyId(Uuid::new_v4()))
                .await
                .expect("repository find missing id")
                .is_none()
        );

        assert_eq!(
            legacy_find_by_id_and_identity_id(&pool, sea_key.id, IdentityId(identity_id))
                .await
                .expect("legacy find_by_id_and_identity_id match"),
            Some(sea_row.clone())
        );
        assert_eq!(
            api_key_as_row(
                &repository
                    .find_by_id_and_identity_id(sea_key.id, IdentityId(identity_id))
                    .await
                    .expect("repository find_by_id_and_identity_id match")
                    .expect("repository must find the key for the matching identity")
            ),
            sea_row
        );
        let other_key = api_key_fixture(
            Uuid::new_v4(),
            other_identity_id,
            stamp,
            "other owner key",
            "other-owner-token-hash",
            1_800_000_200,
        );
        repository
            .create(&other_key)
            .await
            .expect("create other-owner api key");
        assert_eq!(
            fetch_api_key_row(&pool, other_key.id).await,
            api_key_as_row(&other_key),
            "other-owner fixture key must exist before the mismatch check"
        );

        assert_eq!(
            legacy_find_by_id_and_identity_id(&pool, sea_key.id, IdentityId(other_identity_id))
                .await
                .expect("legacy find_by_id_and_identity_id mismatch"),
            None
        );
        assert!(
            repository
                .find_by_id_and_identity_id(sea_key.id, IdentityId(other_identity_id))
                .await
                .expect("repository find_by_id_and_identity_id mismatch")
                .is_none(),
            "owner mismatch must still require the id predicate"
        );
    }

    #[sqlx::test]
    async fn list_by_identity_id_matches_legacy_ordering(pool: PgPool) {
        let identity_id = seed_identity(&pool, "api-key-list-owner").await;
        let other_identity_id = seed_identity(&pool, "api-key-list-other").await;
        let repository = PostgresApiKeyRepository::new(pool.clone());
        let stamp = Uuid::new_v4();

        let mut oldest = api_key_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "oldest key",
            "list-token-oldest",
            1_800_000_000,
        );
        oldest.expires_at = Some(timestamp(1_800_002_000));
        let middle = api_key_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "middle key",
            "list-token-middle",
            1_800_000_100,
        );
        let newest = api_key_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "newest key",
            "list-token-newest",
            1_800_000_200,
        );
        assert!(
            oldest.expires_at > newest.expires_at,
            "fixture must invert expires_at relative to created_at"
        );
        let other = api_key_fixture(
            Uuid::new_v4(),
            other_identity_id,
            stamp,
            "other owner key",
            "list-token-other",
            1_800_000_300,
        );

        for key in [&oldest, &middle, &newest, &other] {
            legacy_create(&pool, key)
                .await
                .expect("seed api key for list");
        }

        let legacy_rows = legacy_list_by_identity_id(&pool, IdentityId(identity_id))
            .await
            .expect("legacy list_by_identity_id");
        let sea_rows = repository
            .list_by_identity_id(IdentityId(identity_id))
            .await
            .expect("repository list_by_identity_id");
        let sea_rows: Vec<ApiKeyRow> = sea_rows.iter().map(api_key_as_row).collect();

        assert_eq!(legacy_rows.len(), 3, "must list exactly the owner's keys");
        assert_eq!(sea_rows, legacy_rows);
        assert_eq!(
            sea_rows.iter().map(|row| row.id).collect::<Vec<_>>(),
            vec![newest.id.0, middle.id.0, oldest.id.0],
            "keys must be ordered by created_at descending"
        );
        assert!(
            sea_rows.iter().all(|row| row.identity_id == identity_id),
            "must not list another identity's keys"
        );

        let missing_identity = seed_identity(&pool, "api-key-list-empty").await;
        assert_eq!(
            legacy_list_by_identity_id(&pool, IdentityId(missing_identity))
                .await
                .expect("legacy list empty"),
            Vec::new()
        );
        assert!(
            repository
                .list_by_identity_id(IdentityId(missing_identity))
                .await
                .expect("repository list empty")
                .is_empty()
        );
    }

    #[sqlx::test]
    async fn update_matches_legacy_including_revocation_and_owner_guards(pool: PgPool) {
        let first_identity = seed_identity(&pool, "api-key-update-first").await;
        let second_identity = seed_identity(&pool, "api-key-update-second").await;
        let repository = PostgresApiKeyRepository::new(pool.clone());

        let mut legacy_key = api_key_fixture(
            Uuid::new_v4(),
            first_identity,
            Uuid::new_v4(),
            "update key",
            "legacy-update-token",
            1_800_000_000,
        );
        let mut sea_key = api_key_fixture(
            Uuid::new_v4(),
            first_identity,
            legacy_key.identity_security_stamp.0,
            "update key",
            "sea-update-token",
            1_800_000_000,
        );

        legacy_create(&pool, &legacy_key)
            .await
            .expect("legacy create update key");
        repository
            .create(&sea_key)
            .await
            .expect("repository create update key");

        let revoked_at = timestamp(1_800_000_500);
        let updated_stamp = Uuid::new_v4();
        for (key, name, token_hash) in [
            (&mut legacy_key, "revoked key", "legacy-revoked-token"),
            (&mut sea_key, "revoked key", "sea-revoked-token"),
        ] {
            key.identity_security_stamp = SessionSecurityStamp(updated_stamp);
            key.name = ApiKeyName::new(name).expect("valid updated name");
            key.token_hash = ApiKeyTokenHash(token_hash.to_owned());
            key.token_hint = "updated hint".to_owned();
            key.scope = ApiKeyScope::ReadWrite;
            key.created_at = timestamp(1_800_000_100);
            key.last_used_at = Some(timestamp(1_800_000_200));
            key.expires_at = Some(timestamp(1_800_000_400));
            key.revoked_at = Some(revoked_at);
        }

        legacy_update(&pool, &legacy_key)
            .await
            .expect("legacy revoke api key");
        repository
            .update(&sea_key)
            .await
            .expect("repository revoke api key");

        let legacy_revoked = fetch_api_key_row(&pool, legacy_key.id).await;
        let sea_revoked = fetch_api_key_row(&pool, sea_key.id).await;

        assert_rows_equivalent_except_key(&legacy_revoked, &sea_revoked, true, true);
        for row in [&legacy_revoked, &sea_revoked] {
            assert_eq!(row.identity_id, first_identity);
            assert_eq!(row.identity_security_stamp, updated_stamp);
            assert_eq!(row.scope, "read_write");
            assert_eq!(row.created_at, timestamp(1_800_000_100));
            assert_eq!(row.last_used_at, Some(timestamp(1_800_000_200)));
            assert_eq!(row.expires_at, Some(timestamp(1_800_000_400)));
            assert_eq!(row.revoked_at, Some(revoked_at));
        }
        assert_eq!(legacy_revoked.token_hash, "legacy-revoked-token");
        assert_eq!(sea_revoked.token_hash, "sea-revoked-token");

        legacy_key.revoked_at = None;
        legacy_key.last_used_at = Some(timestamp(1_800_000_600));
        legacy_key.name = ApiKeyName::new("noop key").expect("valid noop name");
        legacy_key.token_hash = ApiKeyTokenHash("legacy-noop-token".to_owned());
        sea_key.revoked_at = None;
        sea_key.last_used_at = Some(timestamp(1_800_000_600));
        sea_key.name = ApiKeyName::new("noop key").expect("valid noop name");
        sea_key.token_hash = ApiKeyTokenHash("sea-noop-token".to_owned());

        legacy_update(&pool, &legacy_key)
            .await
            .expect("legacy no-op update");
        repository
            .update(&sea_key)
            .await
            .expect("repository no-op update");

        let legacy_after_noop = fetch_api_key_row(&pool, legacy_key.id).await;
        let sea_after_noop = fetch_api_key_row(&pool, sea_key.id).await;

        assert_eq!(
            legacy_after_noop, legacy_revoked,
            "legacy guard must keep an already-revoked key unchanged"
        );
        assert_eq!(
            sea_after_noop, sea_revoked,
            "repository guard must keep an already-revoked key unchanged"
        );

        let re_revoked_at = timestamp(1_800_000_700);
        legacy_key.revoked_at = Some(re_revoked_at);
        legacy_key.last_used_at = Some(timestamp(1_800_000_800));
        legacy_key.name = ApiKeyName::new("rerevoked key").expect("valid name");
        legacy_key.token_hash = ApiKeyTokenHash("legacy-rerevoked-token".to_owned());
        sea_key.revoked_at = Some(re_revoked_at);
        sea_key.last_used_at = Some(timestamp(1_800_000_800));
        sea_key.name = ApiKeyName::new("rerevoked key").expect("valid name");
        sea_key.token_hash = ApiKeyTokenHash("sea-rerevoked-token".to_owned());

        legacy_update(&pool, &legacy_key)
            .await
            .expect("legacy re-revoke api key");
        repository
            .update(&sea_key)
            .await
            .expect("repository re-revoke api key");

        let legacy_after_rerevoke = fetch_api_key_row(&pool, legacy_key.id).await;
        let sea_after_rerevoke = fetch_api_key_row(&pool, sea_key.id).await;

        assert_rows_equivalent_except_key(&legacy_after_rerevoke, &sea_after_rerevoke, true, true);
        for row in [&legacy_after_rerevoke, &sea_after_rerevoke] {
            assert_eq!(row.revoked_at, Some(re_revoked_at));
            assert_eq!(row.last_used_at, Some(timestamp(1_800_000_800)));
        }
        assert_eq!(legacy_after_rerevoke.token_hash, "legacy-rerevoked-token");
        assert_eq!(sea_after_rerevoke.token_hash, "sea-rerevoked-token");

        let mismatched_owner = IdentityId(second_identity);
        legacy_key.identity_id = mismatched_owner;
        legacy_key.name = ApiKeyName::new("blocked owner key").expect("valid name");
        legacy_key.revoked_at = Some(timestamp(1_800_000_900));
        sea_key.identity_id = mismatched_owner;
        sea_key.name = ApiKeyName::new("blocked owner key").expect("valid name");
        sea_key.revoked_at = Some(timestamp(1_800_000_900));

        legacy_update(&pool, &legacy_key)
            .await
            .expect("legacy owner-mismatch update");
        repository
            .update(&sea_key)
            .await
            .expect("repository owner-mismatch update");

        assert_eq!(
            fetch_api_key_row(&pool, legacy_key.id).await,
            legacy_after_rerevoke,
            "legacy update must not change a key whose owner does not match"
        );
        assert_eq!(
            fetch_api_key_row(&pool, sea_key.id).await,
            sea_after_rerevoke,
            "repository update must not change a key whose owner does not match"
        );
    }
}

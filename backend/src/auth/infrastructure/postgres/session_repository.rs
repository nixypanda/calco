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
pub struct PostgresSessionRepository {
    pool: PgPool,
}
impl PostgresSessionRepository {
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
impl SessionRepository for PostgresSessionRepository {
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

#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
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

#[cfg(test)]
async fn legacy_create(pool: &PgPool, session: &Session) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO sessions (id, identity_id, identity_security_stamp, session_token_hash, created_at, last_seen_at, expires_at, revoked_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(session.id)
    .bind(session.identity_id.0)
    .bind(session.identity_security_stamp.0)
    .bind(&session.session_token_hash.0)
    .bind(session.created_at)
    .bind(session.last_seen_at)
    .bind(session.expires_at)
    .bind(session.revoked_at)
    .execute(pool)
    .await?;

    Ok(())
}

#[cfg(test)]
async fn legacy_find_by_token_hash(
    pool: &PgPool,
    token_hash: &str,
) -> Result<Option<SessionRow>, sqlx::Error> {
    sqlx::query_as::<_, SessionRow>(
        "SELECT id, identity_id, identity_security_stamp, session_token_hash, created_at, last_seen_at, expires_at, revoked_at \
         FROM sessions WHERE session_token_hash = $1",
    )
    .bind(token_hash)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_update(pool: &PgPool, session: &Session) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE sessions SET identity_id = $1, identity_security_stamp = $2, session_token_hash = $3, created_at = $4, \
         last_seen_at = $5, expires_at = $6, revoked_at = $7 WHERE id = $8 AND (revoked_at IS NULL OR $7 IS NOT NULL)",
    )
    .bind(session.identity_id.0)
    .bind(session.identity_security_stamp.0)
    .bind(&session.session_token_hash.0)
    .bind(session.created_at)
    .bind(session.last_seen_at)
    .bind(session.expires_at)
    .bind(session.revoked_at)
    .bind(session.id)
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

    fn session_fixture(
        id: Uuid,
        identity_id: Uuid,
        stamp: Uuid,
        token_hash: &str,
        base: i64,
    ) -> Session {
        Session {
            id,
            identity_id: IdentityId(identity_id),
            identity_security_stamp: SessionSecurityStamp(stamp),
            session_token_hash: SessionTokenHash(token_hash.to_owned()),
            created_at: timestamp(base),
            last_seen_at: timestamp(base + 10),
            expires_at: timestamp(base + 100),
            revoked_at: None,
        }
    }

    fn session_as_row(session: &Session) -> SessionRow {
        SessionRow {
            id: session.id,
            identity_id: session.identity_id.0,
            identity_security_stamp: session.identity_security_stamp.0,
            session_token_hash: session.session_token_hash.0.clone(),
            created_at: session.created_at,
            last_seen_at: session.last_seen_at,
            expires_at: session.expires_at,
            revoked_at: session.revoked_at,
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

    async fn fetch_session_row(pool: &PgPool, id: Uuid) -> SessionRow {
        sqlx::query_as::<_, SessionRow>(
            "SELECT id, identity_id, identity_security_stamp, session_token_hash, created_at, \
             last_seen_at, expires_at, revoked_at FROM sessions WHERE id = $1",
        )
        .bind(id)
        .fetch_one(pool)
        .await
        .expect("fetch session")
    }

    fn assert_rows_equivalent_except_id(left: &SessionRow, right: &SessionRow) {
        assert_eq!(left.identity_id, right.identity_id);
        assert_eq!(left.identity_security_stamp, right.identity_security_stamp);
        assert_eq!(left.created_at, right.created_at);
        assert_eq!(left.last_seen_at, right.last_seen_at);
        assert_eq!(left.expires_at, right.expires_at);
        assert_eq!(left.revoked_at, right.revoked_at);
    }

    #[sqlx::test]
    async fn create_and_find_by_token_hash_match_legacy(pool: PgPool) {
        let identity_id = seed_identity(&pool, "session-create").await;
        let repository = PostgresSessionRepository::new(pool.clone());
        let stamp = Uuid::new_v4();

        let legacy_session = session_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "legacy-session-token-hash",
            1_800_000_000,
        );
        let sea_session = session_fixture(
            Uuid::new_v4(),
            identity_id,
            stamp,
            "sea-session-token-hash",
            1_800_000_000,
        );

        legacy_create(&pool, &legacy_session)
            .await
            .expect("legacy create session");
        repository
            .create(&sea_session)
            .await
            .expect("repository create session");

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sessions")
            .fetch_one(&pool)
            .await
            .expect("count sessions");
        assert_eq!(count, 2, "both sessions must be inserted");

        let legacy_row = fetch_session_row(&pool, legacy_session.id).await;
        let sea_row = fetch_session_row(&pool, sea_session.id).await;

        assert_eq!(legacy_row, session_as_row(&legacy_session));
        assert_eq!(sea_row, session_as_row(&sea_session));
        assert_rows_equivalent_except_id(&legacy_row, &sea_row);
        assert_eq!(sea_row.session_token_hash, sea_session.session_token_hash.0);

        let legacy_found = legacy_find_by_token_hash(&pool, &sea_session.session_token_hash.0)
            .await
            .expect("legacy find_by_token_hash")
            .expect("legacy must find the sea-created session");
        let sea_found = repository
            .find_by_token_hash(&sea_session.session_token_hash.0)
            .await
            .expect("repository find_by_token_hash")
            .expect("repository must find the sea-created session");

        assert_eq!(legacy_found, sea_row);
        assert_eq!(session_as_row(&sea_found), legacy_found);
        assert_eq!(sea_found.id, sea_session.id);
        assert_eq!(sea_found.identity_id, sea_session.identity_id);

        let missing = "session-token-hash-that-does-not-exist";
        assert_eq!(
            legacy_find_by_token_hash(&pool, missing)
                .await
                .expect("legacy find missing session"),
            None
        );
        assert!(
            repository
                .find_by_token_hash(missing)
                .await
                .expect("repository find missing session")
                .is_none()
        );
    }

    #[sqlx::test]
    async fn update_matches_legacy_including_revocation_guard(pool: PgPool) {
        let first_identity = seed_identity(&pool, "session-update-first").await;
        let second_identity = seed_identity(&pool, "session-update-second").await;
        let repository = PostgresSessionRepository::new(pool.clone());

        let mut legacy_session = session_fixture(
            Uuid::new_v4(),
            first_identity,
            Uuid::new_v4(),
            "legacy-session-update-token",
            1_800_000_000,
        );
        let mut sea_session = session_fixture(
            Uuid::new_v4(),
            first_identity,
            legacy_session.identity_security_stamp.0,
            "sea-session-update-token",
            1_800_000_000,
        );

        legacy_create(&pool, &legacy_session)
            .await
            .expect("legacy create update session");
        repository
            .create(&sea_session)
            .await
            .expect("repository create update session");

        let revoked_at = timestamp(1_800_000_500);
        let updated_stamp = Uuid::new_v4();
        for (session, token_hash) in [
            (&mut legacy_session, "legacy-session-revoked-token"),
            (&mut sea_session, "sea-session-revoked-token"),
        ] {
            session.identity_id = IdentityId(second_identity);
            session.identity_security_stamp = SessionSecurityStamp(updated_stamp);
            session.session_token_hash = SessionTokenHash(token_hash.to_owned());
            session.created_at = timestamp(1_800_000_100);
            session.last_seen_at = timestamp(1_800_000_200);
            session.expires_at = timestamp(1_800_000_400);
            session.revoked_at = Some(revoked_at);
        }

        legacy_update(&pool, &legacy_session)
            .await
            .expect("legacy revoke session");
        repository
            .update(&sea_session)
            .await
            .expect("repository revoke session");

        let legacy_revoked = fetch_session_row(&pool, legacy_session.id).await;
        let sea_revoked = fetch_session_row(&pool, sea_session.id).await;

        assert_rows_equivalent_except_id(&legacy_revoked, &sea_revoked);
        for row in [&legacy_revoked, &sea_revoked] {
            assert_eq!(row.identity_id, second_identity);
            assert_eq!(row.identity_security_stamp, updated_stamp);
            assert_eq!(row.created_at, timestamp(1_800_000_100));
            assert_eq!(row.last_seen_at, timestamp(1_800_000_200));
            assert_eq!(row.expires_at, timestamp(1_800_000_400));
            assert_eq!(row.revoked_at, Some(revoked_at));
        }
        assert_eq!(
            legacy_revoked.session_token_hash,
            "legacy-session-revoked-token"
        );
        assert_eq!(sea_revoked.session_token_hash, "sea-session-revoked-token");

        legacy_session.revoked_at = None;
        legacy_session.last_seen_at = timestamp(1_800_000_600);
        legacy_session.session_token_hash =
            SessionTokenHash("legacy-session-noop-token".to_owned());
        sea_session.revoked_at = None;
        sea_session.last_seen_at = timestamp(1_800_000_600);
        sea_session.session_token_hash = SessionTokenHash("sea-session-noop-token".to_owned());

        legacy_update(&pool, &legacy_session)
            .await
            .expect("legacy no-op update");
        repository
            .update(&sea_session)
            .await
            .expect("repository no-op update");

        let legacy_after_noop = fetch_session_row(&pool, legacy_session.id).await;
        let sea_after_noop = fetch_session_row(&pool, sea_session.id).await;

        assert_eq!(
            legacy_after_noop, legacy_revoked,
            "legacy guard must keep an already-revoked session unchanged"
        );
        assert_eq!(
            sea_after_noop, sea_revoked,
            "repository guard must keep an already-revoked session unchanged"
        );

        let re_revoked_at = timestamp(1_800_000_700);
        legacy_session.revoked_at = Some(re_revoked_at);
        legacy_session.last_seen_at = timestamp(1_800_000_800);
        legacy_session.session_token_hash =
            SessionTokenHash("legacy-session-rerevoked-token".to_owned());
        sea_session.revoked_at = Some(re_revoked_at);
        sea_session.last_seen_at = timestamp(1_800_000_800);
        sea_session.session_token_hash = SessionTokenHash("sea-session-rerevoked-token".to_owned());

        legacy_update(&pool, &legacy_session)
            .await
            .expect("legacy re-revoke session");
        repository
            .update(&sea_session)
            .await
            .expect("repository re-revoke session");

        let legacy_after_rerevoke = fetch_session_row(&pool, legacy_session.id).await;
        let sea_after_rerevoke = fetch_session_row(&pool, sea_session.id).await;

        assert_rows_equivalent_except_id(&legacy_after_rerevoke, &sea_after_rerevoke);
        for row in [&legacy_after_rerevoke, &sea_after_rerevoke] {
            assert_eq!(row.revoked_at, Some(re_revoked_at));
            assert_eq!(row.last_seen_at, timestamp(1_800_000_800));
        }
        assert_eq!(
            legacy_after_rerevoke.session_token_hash,
            "legacy-session-rerevoked-token"
        );
        assert_eq!(
            sea_after_rerevoke.session_token_hash,
            "sea-session-rerevoked-token"
        );
    }
}

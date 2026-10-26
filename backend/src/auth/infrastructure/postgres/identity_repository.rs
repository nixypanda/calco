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
pub struct PostgresIdentityRepository {
    pool: PgPool,
}
impl PostgresIdentityRepository {
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
impl IdentityRepository for PostgresIdentityRepository {
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

#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
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

#[cfg(test)]
async fn legacy_find_by_username(
    pool: &PgPool,
    username: &str,
) -> Result<Option<IdentityRow>, sqlx::Error> {
    sqlx::query_as::<_, IdentityRow>(
        "SELECT id, username, password_hash, role, status, session_security_stamp, created_at, updated_at \
         FROM identities WHERE username = $1",
    )
    .bind(username)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_find_by_id(
    pool: &PgPool,
    id: IdentityId,
) -> Result<Option<IdentityRow>, sqlx::Error> {
    sqlx::query_as::<_, IdentityRow>(
        "SELECT id, username, password_hash, role, status, session_security_stamp, created_at, updated_at \
         FROM identities WHERE id = $1",
    )
    .bind(id.0)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_find_by_ids(
    pool: &PgPool,
    ids: &[IdentityId],
) -> Result<Vec<IdentityRow>, sqlx::Error> {
    let ids: Vec<Uuid> = ids.iter().map(|id| id.0).collect();
    sqlx::query_as::<_, IdentityRow>(
        "SELECT id, username, password_hash, role, status, session_security_stamp, created_at, updated_at \
         FROM identities WHERE id = ANY($1)",
    )
    .bind(ids)
    .fetch_all(pool)
    .await
}

#[cfg(test)]
async fn legacy_create(pool: &PgPool, identity: &Identity) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO identities (id, username, password_hash, role, status, session_security_stamp, created_at, updated_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(identity.id.0)
    .bind(identity.username.as_str())
    .bind(&identity.password_hash.0)
    .bind(identity.role.as_str())
    .bind(identity.status.as_str())
    .bind(identity.session_security_stamp.0)
    .bind(identity.created_at)
    .bind(identity.updated_at)
    .execute(pool)
    .await?;

    Ok(())
}

#[cfg(test)]
async fn legacy_update(pool: &PgPool, identity: &Identity) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE identities SET password_hash = $1, status = $2, session_security_stamp = $3, updated_at = $4 \
         WHERE id = $5",
    )
    .bind(&identity.password_hash.0)
    .bind(identity.status.as_str())
    .bind(identity.session_security_stamp.0)
    .bind(identity.updated_at)
    .bind(identity.id.0)
    .execute(pool)
    .await?;

    Ok(())
}

#[cfg(test)]
async fn legacy_exists_admin(pool: &PgPool) -> Result<(bool,), sqlx::Error> {
    sqlx::query_as("SELECT EXISTS(SELECT 1 FROM identities WHERE role = 'admin')")
        .fetch_one(pool)
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timestamp(seconds: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(seconds, 0).expect("valid timestamp")
    }

    fn identity_fixture(
        id: Uuid,
        username: &str,
        role: IdentityRole,
        status: IdentityStatus,
        password_hash: &str,
        stamp: Uuid,
        created_at: i64,
        updated_at: i64,
    ) -> Identity {
        Identity {
            id: IdentityId(id),
            username: Username::new(username).expect("valid username"),
            password_hash: PasswordHash(password_hash.to_owned()),
            role,
            status,
            session_security_stamp: SessionSecurityStamp(stamp),
            created_at: timestamp(created_at),
            updated_at: timestamp(updated_at),
        }
    }

    fn identity_as_row(identity: &Identity) -> IdentityRow {
        IdentityRow {
            id: identity.id.0,
            username: identity.username.as_str().to_owned(),
            password_hash: identity.password_hash.0.clone(),
            role: identity.role.as_str().to_owned(),
            status: identity.status.as_str().to_owned(),
            session_security_stamp: identity.session_security_stamp.0,
            created_at: identity.created_at,
            updated_at: identity.updated_at,
        }
    }

    async fn fetch_identity_row(pool: &PgPool, id: IdentityId) -> IdentityRow {
        sqlx::query_as::<_, IdentityRow>(
            "SELECT id, username, password_hash, role, status, session_security_stamp, \
             created_at, updated_at FROM identities WHERE id = $1",
        )
        .bind(id.0)
        .fetch_one(pool)
        .await
        .expect("fetch identity")
    }

    fn sort_rows(rows: &mut [IdentityRow]) {
        rows.sort_by_key(|row| row.id);
    }

    #[sqlx::test]
    async fn find_queries_match_legacy(pool: PgPool) {
        let repository = PostgresIdentityRepository::new(pool.clone());
        let alpha = identity_fixture(
            Uuid::new_v4(),
            "alpha-find-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "alpha-password-hash",
            Uuid::new_v4(),
            1_800_000_000,
            1_800_000_100,
        );
        let beta = identity_fixture(
            Uuid::new_v4(),
            "beta-find-user",
            IdentityRole::User,
            IdentityStatus::Disabled,
            "beta-password-hash",
            Uuid::new_v4(),
            1_800_000_200,
            1_800_000_300,
        );
        let gamma = identity_fixture(
            Uuid::new_v4(),
            "gamma-find-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "gamma-password-hash",
            Uuid::new_v4(),
            1_800_000_400,
            1_800_000_500,
        );

        for identity in [&alpha, &beta, &gamma] {
            legacy_create(&pool, identity)
                .await
                .expect("seed identity for find test");
        }

        let by_username = repository
            .find_by_username(alpha.username.as_str())
            .await
            .expect("repository find_by_username")
            .expect("repository must find alpha");
        let legacy_by_username = legacy_find_by_username(&pool, alpha.username.as_str())
            .await
            .expect("legacy find_by_username")
            .expect("legacy must find alpha");
        assert_eq!(identity_as_row(&by_username), legacy_by_username);
        assert_eq!(legacy_by_username, identity_as_row(&alpha));

        assert!(
            repository
                .find_by_username("missing-find-user")
                .await
                .expect("repository find missing username")
                .is_none()
        );
        assert_eq!(
            legacy_find_by_username(&pool, "missing-find-user")
                .await
                .expect("legacy find missing username"),
            None
        );

        let by_id = repository
            .find_by_id(beta.id)
            .await
            .expect("repository find_by_id")
            .expect("repository must find beta");
        let legacy_by_id = legacy_find_by_id(&pool, beta.id)
            .await
            .expect("legacy find_by_id")
            .expect("legacy must find beta");
        assert_eq!(identity_as_row(&by_id), legacy_by_id);
        assert_eq!(legacy_by_id, identity_as_row(&beta));

        assert!(
            repository
                .find_by_id(IdentityId(Uuid::new_v4()))
                .await
                .expect("repository find missing id")
                .is_none()
        );
        assert_eq!(
            legacy_find_by_id(&pool, IdentityId(Uuid::new_v4()))
                .await
                .expect("legacy find missing id"),
            None
        );

        let requested_ids = [alpha.id, beta.id, gamma.id, IdentityId(Uuid::new_v4())];
        let mut legacy_by_ids = legacy_find_by_ids(&pool, &requested_ids)
            .await
            .expect("legacy find_by_ids");
        let mut sea_by_ids: Vec<IdentityRow> = repository
            .find_by_ids(&requested_ids)
            .await
            .expect("repository find_by_ids")
            .iter()
            .map(identity_as_row)
            .collect();

        sort_rows(&mut legacy_by_ids);
        sort_rows(&mut sea_by_ids);
        let mut expected_by_ids = vec![
            identity_as_row(&alpha),
            identity_as_row(&beta),
            identity_as_row(&gamma),
        ];
        sort_rows(&mut expected_by_ids);
        assert_eq!(
            legacy_by_ids.len(),
            3,
            "must return all three requested existing ids"
        );
        assert_eq!(sea_by_ids, legacy_by_ids);
        assert_eq!(
            sea_by_ids.len(),
            3,
            "array bind must not be truncated or limited to two rows"
        );
        assert_eq!(sea_by_ids, expected_by_ids);

        let empty_ids: Vec<IdentityId> = Vec::new();
        assert_eq!(
            legacy_find_by_ids(&pool, &empty_ids)
                .await
                .expect("legacy find_by_ids empty"),
            Vec::new()
        );
        assert!(
            repository
                .find_by_ids(&empty_ids)
                .await
                .expect("repository find_by_ids empty")
                .is_empty()
        );
    }

    #[sqlx::test]
    async fn create_success_matches_legacy(pool: PgPool) {
        let repository = PostgresIdentityRepository::new(pool.clone());
        let stamp = Uuid::new_v4();

        let legacy_identity = identity_fixture(
            Uuid::new_v4(),
            "legacy-created-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "created-hash",
            stamp,
            1_800_000_000,
            1_800_000_100,
        );
        let sea_identity = identity_fixture(
            Uuid::new_v4(),
            "sea-created-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "created-hash",
            stamp,
            1_800_000_000,
            1_800_000_100,
        );

        legacy_create(&pool, &legacy_identity)
            .await
            .expect("legacy create identity");
        repository
            .create(&sea_identity)
            .await
            .expect("repository create identity");

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM identities")
            .fetch_one(&pool)
            .await
            .expect("count identities");
        assert_eq!(count, 2, "both identities must be inserted");

        let legacy_row = fetch_identity_row(&pool, legacy_identity.id).await;
        let sea_row = fetch_identity_row(&pool, sea_identity.id).await;

        assert_eq!(legacy_row, identity_as_row(&legacy_identity));
        assert_eq!(sea_row, identity_as_row(&sea_identity));
        assert_eq!(legacy_row.password_hash, sea_row.password_hash);
        assert_eq!(legacy_row.role, sea_row.role);
        assert_eq!(legacy_row.status, sea_row.status);
        assert_eq!(
            legacy_row.session_security_stamp,
            sea_row.session_security_stamp
        );
        assert_eq!(legacy_row.created_at, sea_row.created_at);
        assert_eq!(legacy_row.updated_at, sea_row.updated_at);
        assert_eq!(legacy_row.username, "legacy-created-user");
        assert_eq!(sea_row.username, "sea-created-user");
        assert_eq!(legacy_row.password_hash, "created-hash");
        assert_eq!(sea_row.password_hash, "created-hash");
    }

    #[sqlx::test]
    async fn create_maps_unique_violations_like_legacy(pool: PgPool) {
        let repository = PostgresIdentityRepository::new(pool.clone());
        let stamp = Uuid::new_v4();

        let existing_username_user = identity_fixture(
            Uuid::new_v4(),
            "duplicate-username-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "existing-hash",
            stamp,
            1_800_000_000,
            1_800_000_000,
        );
        legacy_create(&pool, &existing_username_user)
            .await
            .expect("seed existing username");

        let duplicate_username = identity_fixture(
            Uuid::new_v4(),
            "duplicate-username-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "duplicate-hash",
            stamp,
            1_800_000_100,
            1_800_000_100,
        );
        let legacy_err = legacy_create(&pool, &duplicate_username)
            .await
            .expect_err("legacy duplicate username must fail");
        assert!(matches!(
            map_identity_insert_error(legacy_err),
            AuthError::UsernameTaken
        ));
        let sea_err = repository
            .create(&duplicate_username)
            .await
            .expect_err("repository duplicate username must fail");
        assert!(matches!(sea_err, AuthError::UsernameTaken));

        let username_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM identities WHERE username = $1")
                .bind("duplicate-username-user")
                .fetch_one(&pool)
                .await
                .expect("count duplicate username");
        assert_eq!(username_count, 1);

        let duplicate_primary_key = identity_fixture(
            existing_username_user.id.0,
            "duplicate-primary-key-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "duplicate-primary-key-hash",
            stamp,
            1_800_000_100,
            1_800_000_100,
        );
        let legacy_err = legacy_create(&pool, &duplicate_primary_key)
            .await
            .expect_err("legacy duplicate primary key must fail");
        assert!(
            matches!(
                map_identity_insert_error(legacy_err),
                AuthError::Database(_)
            ),
            "legacy primary-key violations must map to Database"
        );
        let sea_err = repository
            .create(&duplicate_primary_key)
            .await
            .expect_err("repository duplicate primary key must fail");
        assert!(
            matches!(sea_err, AuthError::Database(_)),
            "repository primary-key violations must map to Database"
        );

        let primary_key_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM identities WHERE username = $1")
                .bind("duplicate-primary-key-user")
                .fetch_one(&pool)
                .await
                .expect("count duplicate primary-key username");
        assert_eq!(primary_key_count, 0);

        let existing_admin = identity_fixture(
            Uuid::new_v4(),
            "existing-admin",
            IdentityRole::Admin,
            IdentityStatus::Active,
            "admin-hash",
            stamp,
            1_800_000_200,
            1_800_000_200,
        );
        legacy_create(&pool, &existing_admin)
            .await
            .expect("seed existing admin");

        let duplicate_admin = identity_fixture(
            Uuid::new_v4(),
            "duplicate-admin",
            IdentityRole::Admin,
            IdentityStatus::Active,
            "duplicate-admin-hash",
            stamp,
            1_800_000_300,
            1_800_000_300,
        );
        let legacy_err = legacy_create(&pool, &duplicate_admin)
            .await
            .expect_err("legacy duplicate admin must fail");
        assert!(matches!(
            map_identity_insert_error(legacy_err),
            AuthError::AdminAlreadyExists
        ));
        let sea_err = repository
            .create(&duplicate_admin)
            .await
            .expect_err("repository duplicate admin must fail");
        assert!(matches!(sea_err, AuthError::AdminAlreadyExists));

        let admin_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM identities WHERE role = 'admin'")
                .fetch_one(&pool)
                .await
                .expect("count admins");
        assert_eq!(admin_count, 1);
    }

    #[sqlx::test]
    async fn update_and_exists_admin_match_legacy(pool: PgPool) {
        let repository = PostgresIdentityRepository::new(pool.clone());

        let legacy_identity = identity_fixture(
            Uuid::new_v4(),
            "legacy-update-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "legacy-old-hash",
            Uuid::new_v4(),
            1_800_000_000,
            1_800_000_100,
        );
        let sea_identity = identity_fixture(
            Uuid::new_v4(),
            "sea-update-user",
            IdentityRole::User,
            IdentityStatus::Active,
            "sea-old-hash",
            Uuid::new_v4(),
            1_800_000_000,
            1_800_000_100,
        );
        legacy_create(&pool, &legacy_identity)
            .await
            .expect("seed legacy update identity");
        legacy_create(&pool, &sea_identity)
            .await
            .expect("seed sea update identity");

        assert!(
            !repository
                .exists_admin()
                .await
                .expect("repository exists_admin before admin")
        );
        assert_eq!(
            legacy_exists_admin(&pool)
                .await
                .expect("legacy exists_admin before admin"),
            (false,)
        );

        let updated_stamp = Uuid::new_v4();
        let mut legacy_updated = legacy_identity.clone();
        legacy_updated.password_hash = PasswordHash("legacy-updated-hash".to_owned());
        legacy_updated.status = IdentityStatus::Disabled;
        legacy_updated.session_security_stamp = SessionSecurityStamp(updated_stamp);
        legacy_updated.updated_at = timestamp(1_800_000_500);
        legacy_updated.username =
            Username::new("legacy-must-not-write-username").expect("valid username");
        legacy_updated.role = IdentityRole::Admin;
        legacy_updated.created_at = timestamp(1_700_000_000);
        let mut sea_updated = sea_identity.clone();
        sea_updated.password_hash = PasswordHash("sea-updated-hash".to_owned());
        sea_updated.status = IdentityStatus::Disabled;
        sea_updated.session_security_stamp = SessionSecurityStamp(updated_stamp);
        sea_updated.updated_at = timestamp(1_800_000_500);
        sea_updated.username =
            Username::new("sea-must-not-write-username").expect("valid username");
        sea_updated.role = IdentityRole::Admin;
        sea_updated.created_at = timestamp(1_700_000_000);

        legacy_update(&pool, &legacy_updated)
            .await
            .expect("legacy update identity");
        repository
            .update(&sea_updated)
            .await
            .expect("repository update identity");

        let legacy_row = fetch_identity_row(&pool, legacy_identity.id).await;
        let sea_row = fetch_identity_row(&pool, sea_identity.id).await;

        assert_eq!(legacy_row.username, "legacy-update-user");
        assert_eq!(sea_row.username, "sea-update-user");
        assert_eq!(legacy_row.role, "user");
        assert_eq!(sea_row.role, "user");
        assert_eq!(legacy_row.created_at, timestamp(1_800_000_000));
        assert_eq!(sea_row.created_at, timestamp(1_800_000_000));
        assert_eq!(legacy_row.password_hash, "legacy-updated-hash");
        assert_eq!(sea_row.password_hash, "sea-updated-hash");
        assert_eq!(legacy_row.status, "disabled");
        assert_eq!(sea_row.status, "disabled");
        assert_eq!(legacy_row.session_security_stamp, updated_stamp);
        assert_eq!(sea_row.session_security_stamp, updated_stamp);
        assert_eq!(legacy_row.updated_at, timestamp(1_800_000_500));
        assert_eq!(sea_row.updated_at, timestamp(1_800_000_500));
        assert_eq!(
            legacy_row.status, sea_row.status,
            "legacy and repository must update the same columns"
        );
        assert_eq!(
            legacy_row.session_security_stamp,
            sea_row.session_security_stamp
        );
        assert_eq!(legacy_row.updated_at, sea_row.updated_at);

        assert!(
            !repository
                .exists_admin()
                .await
                .expect("repository exists_admin after user update")
        );
        assert_eq!(
            legacy_exists_admin(&pool)
                .await
                .expect("legacy exists_admin after user update"),
            (false,)
        );

        let admin = identity_fixture(
            Uuid::new_v4(),
            "new-admin",
            IdentityRole::Admin,
            IdentityStatus::Active,
            "admin-hash",
            Uuid::new_v4(),
            1_800_000_600,
            1_800_000_600,
        );
        repository
            .create(&admin)
            .await
            .expect("create admin through repository");

        assert!(
            repository
                .exists_admin()
                .await
                .expect("repository exists_admin after admin")
        );
        assert_eq!(
            legacy_exists_admin(&pool)
                .await
                .expect("legacy exists_admin after admin"),
            (true,)
        );
        let admin_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM identities WHERE role = 'admin'")
                .fetch_one(&pool)
                .await
                .expect("count admins");
        assert_eq!(admin_count, 1);

        sqlx::query("UPDATE identities SET status = 'disabled' WHERE id = $1")
            .bind(admin.id.0)
            .execute(&pool)
            .await
            .expect("disable admin");
        let disabled_admin = fetch_identity_row(&pool, admin.id).await;
        assert_eq!(disabled_admin.status, "disabled");
        assert!(
            repository
                .exists_admin()
                .await
                .expect("repository exists_admin for disabled admin"),
            "exists_admin must check role only, not active status"
        );
        assert_eq!(
            legacy_exists_admin(&pool)
                .await
                .expect("legacy exists_admin for disabled admin"),
            (true,),
            "legacy exists_admin must check role only, not active status"
        );
    }
}

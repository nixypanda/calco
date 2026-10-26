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

#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
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

#[cfg(test)]
async fn legacy_find_by_identity_id(
    pool: &PgPool,
    identity_id: IdentityId,
) -> Result<Option<ProfileRow>, sqlx::Error> {
    sqlx::query_as::<_, ProfileRow>(
        "SELECT id, identity_id, display_name, created_at, updated_at \
         FROM user_profiles WHERE identity_id = $1",
    )
    .bind(identity_id.0)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_find_by_id(pool: &PgPool, id: Uuid) -> Result<Option<ProfileRow>, sqlx::Error> {
    sqlx::query_as::<_, ProfileRow>(
        "SELECT id, identity_id, display_name, created_at, updated_at \
         FROM user_profiles WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
async fn legacy_create(pool: &PgPool, profile: &UserProfile) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO user_profiles (id, identity_id, display_name, created_at, updated_at) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(profile.id)
    .bind(profile.identity_id.0)
    .bind(&profile.display_name)
    .bind(profile.created_at)
    .bind(profile.updated_at)
    .execute(pool)
    .await?;

    Ok(())
}

#[cfg(test)]
async fn legacy_list_all(pool: &PgPool) -> Result<Vec<ProfileRow>, sqlx::Error> {
    sqlx::query_as::<_, ProfileRow>(
        "SELECT id, identity_id, display_name, created_at, updated_at \
         FROM user_profiles ORDER BY created_at DESC",
    )
    .fetch_all(pool)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timestamp(seconds: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(seconds, 0).expect("valid timestamp")
    }

    fn profile_fixture(
        id: Uuid,
        identity_id: Uuid,
        display_name: &str,
        created_at: i64,
    ) -> UserProfile {
        UserProfile {
            id,
            identity_id: IdentityId(identity_id),
            display_name: display_name.to_owned(),
            created_at: timestamp(created_at),
            updated_at: timestamp(created_at + 10),
        }
    }

    fn profile_as_row(profile: &UserProfile) -> ProfileRow {
        ProfileRow {
            id: profile.id,
            identity_id: profile.identity_id.0,
            display_name: profile.display_name.clone(),
            created_at: profile.created_at,
            updated_at: profile.updated_at,
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

    async fn fetch_profile_row(pool: &PgPool, id: Uuid) -> ProfileRow {
        sqlx::query_as::<_, ProfileRow>(
            "SELECT id, identity_id, display_name, created_at, updated_at \
             FROM user_profiles WHERE id = $1",
        )
        .bind(id)
        .fetch_one(pool)
        .await
        .expect("fetch user profile")
    }

    #[sqlx::test]
    async fn create_and_find_match_legacy(pool: PgPool) {
        let legacy_identity_id = seed_identity(&pool, "profile-legacy").await;
        let sea_identity_id = seed_identity(&pool, "profile-sea").await;
        let missing_identity_id = seed_identity(&pool, "profile-missing").await;
        let repository = PostgresUserProfileRepository::new(pool.clone());

        let legacy_profile = profile_fixture(
            Uuid::new_v4(),
            legacy_identity_id,
            "Legacy Profile",
            1_800_000_000,
        );
        let sea_profile = profile_fixture(
            Uuid::new_v4(),
            sea_identity_id,
            "Sea Profile",
            1_800_000_100,
        );

        legacy_create(&pool, &legacy_profile)
            .await
            .expect("legacy create profile");
        repository
            .create(&sea_profile)
            .await
            .expect("repository create profile");

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_profiles")
            .fetch_one(&pool)
            .await
            .expect("count user profiles");
        assert_eq!(count, 2, "both profiles must be inserted");

        let legacy_row = fetch_profile_row(&pool, legacy_profile.id).await;
        let sea_row = fetch_profile_row(&pool, sea_profile.id).await;

        assert_eq!(legacy_row, profile_as_row(&legacy_profile));
        assert_eq!(sea_row, profile_as_row(&sea_profile));
        assert_eq!(legacy_row.identity_id, legacy_identity_id);
        assert_eq!(sea_row.identity_id, sea_identity_id);
        assert_eq!(legacy_row.display_name, "Legacy Profile");
        assert_eq!(sea_row.display_name, "Sea Profile");
        assert_eq!(legacy_row.created_at, timestamp(1_800_000_000));
        assert_eq!(sea_row.created_at, timestamp(1_800_000_100));
        assert_eq!(legacy_row.updated_at, timestamp(1_800_000_010));
        assert_eq!(sea_row.updated_at, timestamp(1_800_000_110));

        let legacy_by_identity = legacy_find_by_identity_id(&pool, IdentityId(legacy_identity_id))
            .await
            .expect("legacy find_by_identity_id")
            .expect("legacy must find the profile by identity id");
        let sea_by_identity = repository
            .find_by_identity_id(IdentityId(sea_identity_id))
            .await
            .expect("repository find_by_identity_id")
            .expect("repository must find the profile by identity id");
        assert_eq!(legacy_by_identity, legacy_row);
        assert_eq!(profile_as_row(&sea_by_identity), sea_row);
        assert_eq!(profile_as_row(&sea_by_identity).display_name, "Sea Profile");

        assert!(
            repository
                .find_by_identity_id(IdentityId(missing_identity_id))
                .await
                .expect("repository find missing identity id")
                .is_none()
        );
        assert_eq!(
            legacy_find_by_identity_id(&pool, IdentityId(missing_identity_id))
                .await
                .expect("legacy find missing identity id"),
            None
        );

        let legacy_by_id = legacy_find_by_id(&pool, legacy_profile.id)
            .await
            .expect("legacy find_by_id")
            .expect("legacy must find the profile by id");
        let sea_by_id = repository
            .find_by_id(sea_profile.id)
            .await
            .expect("repository find_by_id")
            .expect("repository must find the profile by id");
        assert_eq!(legacy_by_id, legacy_row);
        assert_eq!(profile_as_row(&sea_by_id), sea_row);

        assert!(
            repository
                .find_by_id(Uuid::new_v4())
                .await
                .expect("repository find missing id")
                .is_none()
        );
        assert_eq!(
            legacy_find_by_id(&pool, Uuid::new_v4())
                .await
                .expect("legacy find missing id"),
            None
        );
    }

    #[sqlx::test]
    async fn list_all_matches_legacy_ordering(pool: PgPool) {
        let repository = PostgresUserProfileRepository::new(pool.clone());

        let oldest_identity = seed_identity(&pool, "profile-list-oldest").await;
        let middle_identity = seed_identity(&pool, "profile-list-middle").await;
        let newest_identity = seed_identity(&pool, "profile-list-newest").await;

        let mut oldest = profile_fixture(
            Uuid::new_v4(),
            oldest_identity,
            "Oldest Profile",
            1_800_000_000,
        );
        oldest.updated_at = timestamp(1_800_002_000);
        let middle = profile_fixture(
            Uuid::new_v4(),
            middle_identity,
            "Middle Profile",
            1_800_000_100,
        );
        let newest = profile_fixture(
            Uuid::new_v4(),
            newest_identity,
            "Newest Profile",
            1_800_000_200,
        );
        assert!(
            oldest.updated_at > newest.updated_at,
            "fixture must invert updated_at relative to created_at"
        );

        for profile in [&oldest, &middle, &newest] {
            legacy_create(&pool, profile)
                .await
                .expect("seed profile for list");
        }

        let legacy_rows = legacy_list_all(&pool).await.expect("legacy list_all");
        let sea_rows: Vec<ProfileRow> = repository
            .list_all()
            .await
            .expect("repository list_all")
            .iter()
            .map(profile_as_row)
            .collect();

        assert_eq!(legacy_rows.len(), 3, "must list every profile");
        assert_eq!(sea_rows, legacy_rows);
        assert_eq!(
            sea_rows.iter().map(|row| row.id).collect::<Vec<_>>(),
            vec![newest.id, middle.id, oldest.id],
            "profiles must be ordered by created_at descending"
        );
        assert_eq!(sea_rows[0].display_name, "Newest Profile");
        assert_eq!(sea_rows[2].display_name, "Oldest Profile");
    }
}

# Auth Design

## Summary

Authentication is intentionally simple:

- Username/password only.
- No email flow.
- No OAuth/OIDC.
- No 2FA.
- Keep identity separate from user profile.
- Use server-managed sessions.
- On first start, prompt for creation of a bootstrap admin account.

The bootstrap admin is not an application user. It exists only to reset passwords for real users and perform minimal account recovery operations.

## Core Concepts

### Identity

`Identity` represents login credentials and authentication state.

```text
Identity
  id: IdentityId
  username: Username
  password_hash: PasswordHash
  role: IdentityRole
  status: IdentityStatus
  created_at
  updated_at
  last_login_at
```

Rules:

- Username is unique.
- Passwords are never stored directly.
- Password hashes should use Argon2id or another modern password hashing algorithm.
- Identity is about authentication, not nutrition data ownership.

### User Profile

`UserProfile` represents the application user.

```text
UserProfile
  id: UserId
  identity_id: IdentityId
  display_name: DisplayName
  created_at
  updated_at
```

Rules:

- A normal user identity maps to one user profile.
- Food logs, custom foods, meals, goals, and summaries are owned by `UserId`, not `IdentityId`.
- Admin identities do not need user profiles unless they also become normal app users later.

### Session

`Session` represents an authenticated browser/device session.

```text
Session
  id: SessionId
  identity_id: IdentityId
  session_token_hash: SessionTokenHash
  created_at
  last_seen_at
  expires_at
  revoked_at
```

Rules:

- Store only a hash of the session token in the database.
- Send the raw token to the browser in an HTTP-only, secure, same-site cookie.
- Sessions expire.
- Logout revokes the current session.
- Password reset should revoke all active sessions for that identity.

### Bootstrap Admin

The bootstrap admin is created on first start when no admin identity exists.

```text
IdentityRole
  User
  Admin
```

Admin rules:

- Admin can reset passwords for users.
- Admin cannot create food logs.
- Admin cannot create custom foods.
- Admin cannot read or modify user nutrition data.
- Admin cannot perform normal app operations unless explicitly given a separate normal user profile later.

This keeps account recovery separate from application ownership.

## First-Run Flow

On startup or first web access:

1. Backend checks whether any admin identity exists.
2. If no admin exists, unauthenticated requests to normal app routes are blocked.
3. Frontend shows first-run admin setup.
4. User enters admin username and password.
5. Backend creates an admin `Identity`.
6. Backend starts an admin session.
7. Admin can create/reset a normal user's password, but cannot use food-tracking features.

First-run endpoint:

```text
GET  /auth/bootstrap/status
POST /auth/bootstrap/admin
```

`GET /auth/bootstrap/status` response:

```json
{
  "admin_exists": false
}
```

`POST /auth/bootstrap/admin` request:

```json
{
  "username": "admin",
  "password": "long-password"
}
```

Rules:

- `POST /auth/bootstrap/admin` succeeds only if no admin identity exists.
- Once an admin exists, the endpoint returns a conflict error.

## Login Flow

```text
POST /auth/login
```

Request:

```json
{
  "username": "alice",
  "password": "password"
}
```

Behavior:

1. Find identity by username.
2. Reject missing, disabled, or locked identities.
3. Verify password hash.
4. Create session.
5. Set session cookie.
6. Return current identity and, for normal users, profile summary.

Response:

```json
{
  "identity": {
    "id": "identity-uuid",
    "username": "alice",
    "role": "user"
  },
  "profile": {
    "id": "user-uuid",
    "display_name": "Alice"
  }
}
```

For admin:

```json
{
  "identity": {
    "id": "identity-uuid",
    "username": "admin",
    "role": "admin"
  },
  "profile": null
}
```

## Session Flow

```text
GET  /auth/session
POST /auth/logout
```

`GET /auth/session` behavior:

- Read session cookie.
- Hash token.
- Load active, non-expired session.
- Load identity.
- Load profile if the identity is a normal user.
- Update `last_seen_at` opportunistically.

`POST /auth/logout` behavior:

- Revoke current session.
- Clear session cookie.

## User Management Flow

Admin-only account recovery endpoints:

```text
POST /admin/users
GET  /admin/users
POST /admin/users/{user_id}/reset-password
POST /admin/users/{user_id}/disable
POST /admin/users/{user_id}/enable
```

### Create User

```text
POST /admin/users
```

Request:

```json
{
  "username": "alice",
  "display_name": "Alice",
  "initial_password": "temporary-password"
}
```

Behavior:

- Create normal `Identity`.
- Create linked `UserProfile`.
- Return user profile and identity summary.

### Reset Password

```text
POST /admin/users/{user_id}/reset-password
```

Request:

```json
{
  "new_password": "new-password"
}
```

Behavior:

- Replace password hash for the user's linked identity.
- Revoke all sessions for that identity.
- Do not alter food logs, custom foods, meals, goals, or summaries.

## Self-Service User Flow

Normal user endpoints:

```text
GET  /me
PUT  /me/profile
POST /me/change-password
```

`GET /me` returns the current identity and user profile.

`PUT /me/profile` updates profile-only fields such as display name.

`POST /me/change-password` request:

```json
{
  "current_password": "old-password",
  "new_password": "new-password"
}
```

Behavior:

- Verify current password.
- Replace password hash.
- Revoke other active sessions for the identity.
- Keep current session or rotate it.

## Database Mapping

### `identities`

```text
id                  uuid primary key
username            text unique not null
password_hash       text not null
role                text not null
status              text not null
created_at          timestamptz not null
updated_at          timestamptz not null
last_login_at       timestamptz
```

### `user_profiles`

```text
id                  uuid primary key
identity_id         uuid unique not null references identities(id)
display_name        text not null
created_at          timestamptz not null
updated_at          timestamptz not null
```

Application data should reference `user_profiles.id` as `user_id`.

### `sessions`

```text
id                  uuid primary key
identity_id         uuid not null references identities(id)
session_token_hash  text unique not null
created_at          timestamptz not null
last_seen_at        timestamptz not null
expires_at          timestamptz not null
revoked_at          timestamptz
```

Suggested indexes:

```text
identities_username_idx
sessions_token_hash_idx
sessions_identity_id_idx
sessions_expires_at_idx
```

### `auth_audit_events`

Stores security-relevant account recovery events.

```text
id                  uuid primary key
actor_identity_id   uuid references identities(id)
target_identity_id  uuid references identities(id)
event_type          text not null
metadata            jsonb not null default '{}'
created_at          timestamptz not null
```

Initial event types:

```text
admin_user_created
admin_password_reset
admin_user_disabled
admin_user_enabled
self_password_changed
```

Do not store raw passwords or session tokens in audit metadata.

## Authorization Rules

Normal user:

- Can access own food logs.
- Can access own custom foods.
- Can access global catalog foods.
- Can access own meals and goals once those features exist.
- Cannot access another user's private data.

Admin:

- Can create users.
- Can reset user passwords.
- Can disable/enable users.
- Cannot access food logs, custom foods, meals, goals, or nutrition summaries.
- Cannot use normal food-tracking routes without a separate normal user profile.

Route handlers should require either:

```text
AuthenticatedIdentity
AuthenticatedUser
AuthenticatedAdmin
```

This prevents admin recovery sessions from accidentally satisfying normal user route requirements.

## Additional Auth Considerations

These are still part of username/password auth and should be included even though OAuth, email, and 2FA are out of scope.

- Password hashing with Argon2id.
- Minimum password length.
- Secure random session tokens.
- Store session token hashes, not raw tokens.
- HTTP-only session cookie.
- `Secure` cookie flag when served over HTTPS.
- `SameSite=Lax` or `SameSite=Strict`.
- CSRF protection for cookie-authenticated unsafe methods.
- Login rate limiting or simple lockout/backoff after repeated failures.
- Session expiry and idle timeout.
- Session revocation on logout and password reset.
- Audit log for admin password resets and disabled/enabled users.
- Clear separation between admin identity and normal user profile.
- Backup/restore documentation should include auth tables.

## API Summary

Bootstrap:

```text
GET  /auth/bootstrap/status
POST /auth/bootstrap/admin
```

Session:

```text
POST /auth/login
GET  /auth/session
POST /auth/logout
```

Self-service:

```text
GET  /me
PUT  /me/profile
POST /me/change-password
```

Admin:

```text
POST /admin/users
GET  /admin/users
POST /admin/users/{user_id}/reset-password
POST /admin/users/{user_id}/disable
POST /admin/users/{user_id}/enable
```

## Test Plan

Domain/application tests:

- Bootstrap admin can be created only once.
- Username uniqueness is enforced.
- Password verification succeeds and fails correctly.
- Password reset revokes existing sessions.
- Admin cannot satisfy normal user route authorization.
- Normal user cannot satisfy admin route authorization.
- Disabled users cannot log in.

Infrastructure tests:

- Password hashes are stored, not raw passwords.
- Session token hashes are stored, not raw session tokens.
- Expired and revoked sessions are rejected.

Interface tests:

- Login sets secure cookie attributes.
- Logout clears cookie and revokes session.
- Unauthenticated requests return stable auth errors.
- Admin password reset returns no sensitive credential data.

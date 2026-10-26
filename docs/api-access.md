# Personal API Access

CalCo personal API keys let a signed-in user give scripts and tools access to
their own CalCo data through the existing `/api` surface. A key replaces sharing
an account password or copying a browser session cookie.

Keys are personal credentials, not OAuth clients. Each key acts only as the user
who created it, with a limited scope. Keys never grant administration, catalog
imports, assistant access, or API-key management.

## Product Promise And Limitations

Personal API keys provide:

- Multiple named keys per user. CalCo normally allows up to 10 active keys. The
  limit is best-effort; simultaneous creates can occasionally leave you over it.
  The overage lasts until a key expires or is revoked, so revoke an unused key
  to get back under.
- Two scopes: `read` (default) and `read_write`.
- Optional expiry. The web UI defaults to 90 days and allows `Never`.
- A secret shown once at creation and never retrievable again.
- Immediate revocation from the web app.
- Access only to the owner's user-owned data, through the existing authorization
  and owner checks.

Current limitations:

- No OAuth, OIDC, delegated third-party access, or per-endpoint scopes.
- No admin keys, IP allowlists, or key rotation endpoint. To rotate a key,
  create a new one and revoke the old one.
- API keys are session-only for the AI assistant in v1. The assistant routes
  cannot be called with a key.
- API keys cannot create, list, or revoke API keys.
- Keys must not be embedded in browser apps or other distributed clients.

## Scopes

| Scope | Grants | Typical use |
| --- | --- | --- |
| `read` | Read-only access to the owner's logs, summaries, nutrition details, meals, goals, diary preferences, and catalog data. | Backups, exports, dashboards, and reporting scripts. |
| `read_write` | Everything `read` grants plus normal user-data create, update, and delete operations. | Logging food, editing goals, or automating diary updates. |

`read` is the default when a scope is not supplied.

`read_write` does not expand the resources a key can reach. It only permits
mutation of the owner's normal user data. Neither scope allows admin routes,
import routes, assistant routes, or key-management routes.

One read route has an existing write side effect:
`GET /api/foods/barcode/{barcode}` may persist a globally visible Open Food
Facts product when the barcode is not already cached. This is allowed for `read`
keys in v1.

## Create And Store A Key

Create keys from a signed-in browser session:

1. Open the profile menu and choose **API keys**, or navigate to
   `/settings/api-keys`, then choose **Create API key**.
2. Choose a name, scope, and expiry on `/settings/api-keys/new`. A blocking
   progress dialog covers the form while the key is being created; the app
   chrome behind it is inert and cannot be reached with Tab.
3. Copy the secret from the non-dismissible reveal dialog immediately. Choose
   **Done** to return to the key list. The app chrome behind the dialog is
   inert, so within the app only **Done** dismisses it; browser back, refresh,
   and closing the tab are not intercepted.
4. Store the secret in a password manager, secret manager, or environment
   variable on the machine that runs the script.

Key names are trimmed and must contain visible text. They reject control and
invisible formatting characters such as bidi controls, zero-width space,
line/paragraph separators, BOM, and soft hyphen. ZWNJ and ZWJ are allowed inside
normal text and emoji, but whitespace-only or invisible-only names are rejected.

> **Warning:** The full secret is shown exactly once. CalCo stores only a hash
> and a short display hint. If you lose the secret, revoke the key and create a
> new one. The old secret cannot be recovered.

Keys look like this:

```text
calco_pat_<random secret>
```

Treat the secret like a password. Do not put it in source control, URLs, logs,
screenshots, issue trackers, or analytics.

The 90-day default is a web-UI choice only. Choose `Never` in the UI to create a
key without an expiry. The management API does not apply that default: omitting
`expires_in_days` from `POST /api/auth/api-keys` creates a key with no expiry.
The accepted range is 1 to 3650 days.

## Authenticate Requests

Send the secret as a bearer token on every request:

```http
GET /api/logs?log_date=2026-10-26 HTTP/1.1
Host: calco.example.com
Authorization: Bearer calco_pat_<random secret>
Accept: application/json
```

`Authorization: Bearer` is the only supported API-key transport. Query-parameter
tokens and `X-API-Key` are not supported. Browser cookies authenticate the web
app, not API-key clients.

On user-data routes that accept API keys (`ReadUser` and `WriteUser` routes such
as logs, foods, meals, goals, diary preferences, and nutrition details), an
`Authorization` header takes precedence: CalCo authenticates with that bearer
token and does not fall back to a browser session cookie. A malformed, invalid,
expired, revoked, or security-stamp-invalidated key returns
`401 invalid_api_key`.

Key management, assistant, admin, and import routes are browser-session-only.
They ignore `Authorization`; a request with only a bearer token and no valid
session cookie returns `401 unauthorized` (or the relevant session rejection),
not `invalid_api_key`. API keys never authenticate these routes.

Set the base URL and key once in a shell:

```bash
export CALCO_BASE_URL="https://calco.example.com"
export CALCO_API_KEY="calco_pat_<random secret>"
```

## Read Examples

List the owner's logs for a date:

```bash
curl -sS "$CALCO_BASE_URL/api/logs?log_date=2026-10-26" \
  -H "Authorization: Bearer $CALCO_API_KEY"
```

Read the day's calorie and macro summary:

```bash
curl -sS \
  "$CALCO_BASE_URL/api/logs/summary?from_date=2026-10-26&to_date=2026-10-26" \
  -H "Authorization: Bearer $CALCO_API_KEY"
```

Search the shared catalog or list meals:

```bash
curl -sS -G "$CALCO_BASE_URL/api/foods/search" \
  --data-urlencode "q=paneer" \
  -H "Authorization: Bearer $CALCO_API_KEY"

curl -sS "$CALCO_BASE_URL/api/meals" \
  -H "Authorization: Bearer $CALCO_API_KEY"
```

Read endpoints include `GET /api/logs`, `GET /api/logs/summary`,
`GET /api/logs/recent-items`, `GET /api/logs/latest-slots`,
`GET /api/foods/search`, `GET /api/foods/categories`, `GET /api/foods/{id}`,
`GET /api/foods/custom`, `GET /api/nutrients`, `GET /api/units`,
`GET /api/nutrition/details`, `GET /api/meals`, `GET /api/goal`, and
`GET /api/diary-preferences`. `POST /api/logs/last-used` is also read-scoped
because it only returns prefill data.

## Write Examples

A `read_write` key can create a food log for the owner:

```bash
curl -sS -X POST "$CALCO_BASE_URL/api/logs" \
  -H "Authorization: Bearer $CALCO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "log_date": "2026-10-26",
    "meal_slot": "lunch",
    "item": { "type": "product", "id": "<product-id>" },
    "quantity": { "amount": 150, "unit": "g" }
  }'
```

The same scope covers the normal write routes for logs, custom foods, meals,
goals, and diary preferences:

- `POST /api/logs`, `POST /api/logs/ad-hoc`, `POST /api/logs/batch`,
  `PUT /api/logs/{id}`, `DELETE /api/logs/{id}`
- `POST /api/foods/custom`, `PUT /api/foods/custom/{id}`,
  `DELETE /api/foods/custom/{id}`
- `POST /api/meals`, `PUT /api/meals/{id}`, `DELETE /api/meals/{id}`
- `PUT /api/goal`, `PUT /api/diary-preferences`

A `read` key calling one of these routes receives `403 insufficient_scope`; the
request is rejected before any user data is changed. Key metadata such as
`last_used_at` may still be updated during authentication.

## Revocation

Revoke a key from **API keys** in the profile menu. Revocation takes effect
immediately for subsequent requests. Revoke any key that may have leaked or is
no longer in use.

Do not try to edit or extend an existing key. Create a replacement and revoke
the old key.

## Expiry, Password Resets, And Account Status

- Keys expire at their configured `expires_at`. An expired key returns
  `401 invalid_api_key`.
- Keys do not auto-renew. Create a new key when the old one expires.
- An admin password reset or account disable invalidates every existing key
  through the identity security stamp. Re-enabling the account does not restore
  old keys, because the security stamp remains rotated.
- Self-service password change is planned, not implemented. Until then, an admin
  password reset is the only password-change path.
- Key metadata includes `created_at`, `last_used_at`, and `expires_at`.
  `last_used_at` is refreshed best-effort and application-throttled to roughly
  once per 60 seconds. A failed metadata write does not fail authentication, so
  the value can remain stale. Concurrent requests may both refresh the
  timestamp.

## Do Not Use Keys In Browser Apps

Never put a CalCo API key in browser JavaScript, a single-page app, a mobile app,
`localStorage`, or any other client distributed to other people. Anyone who can
load the app can read the key and act as the owner.

The backend allows the `Authorization` header through CORS so trusted tools can
call the API, but CORS does not make an embedded secret safe. Browser clients
should use the normal CalCo login and session cookie.

> **Warning:** `CORS_ALLOWED_ORIGINS` is a credential-minting trust boundary.
> When it is non-empty, the backend enables credentialed CORS for exactly those
> origins. Any listed origin can use a signed-in user's session cookie to call
> the key-management route and read the raw token from the create response. List
> only first-party origins you control; never add third-party or untrusted
> origins.

Use API keys from server-side scripts or local tools on a machine you control.

## Shared Catalog And Meal Visibility

Personal API keys do not change CalCo's visibility rules:

- Food logs, goals, and diary preferences are user-owned.
- Catalog products, including custom foods, are globally visible to
  authenticated users. Custom-food writes remain creator-only.
- Meals are globally visible to authenticated users; writes remain
  creator-owned.
- `GET /api/foods/custom` lists all custom foods, not only the caller's.

A key can read shared catalog and meal data that any signed-in user can read. It
cannot read another user's logs, goals, diary preferences, or other user-owned
data; existing owner checks still apply.

If you need strict private custom foods or meals, that requires a separate
product change. Do not rely on API-key scopes to provide that isolation.

## Common Errors

| Status | Code | Meaning |
| --- | --- | --- |
| `401` | `invalid_api_key` | The bearer token on a user-data route is malformed, invalid, expired, revoked, or invalidated by a security-stamp change. |
| `401` | `unauthorized` (or session error) | A bearer token was sent to a browser-session-only route (key management, assistant, admin, or import) without a valid session cookie. These routes ignore `Authorization`. |
| `403` | `insufficient_scope` | The key is valid but its scope does not permit the route. |
| `404` | `api_key_not_found` | A key-management route referenced a key that does not exist for this user. |
| `409` | `api_key_limit_reached` | The account is at its soft limit of 10 active keys; revoke an unused key and retry. |
| `400` | `invalid_api_key_name` | The key name is empty, whitespace-only/invisible-only, too long, or contains a forbidden control/invisible formatting character. |
| `400` | `invalid_api_key_scope` | The scope is not `read` or `read_write`. |
| `400` | `invalid_api_key_expiry` | `expires_in_days` is outside 1 to 3650. |

API errors use the normal CalCo error envelope:

```json
{
  "error": {
    "code": "insufficient_scope",
    "message": "..."
  }
}
```

See [backend.md](backend.md) for route-level scope mappings and implementation
details.

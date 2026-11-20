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
- A required `X-CalCo-Account-ID` assertion that binds every account-scoped
  request to the authenticated profile.
- Required idempotency keys on every log create route for safe retries.

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

Create keys from a signed-in normal-user browser session. Admin identities
cannot open Settings or API key management:

1. Open **Settings** from the bottom navigation or drawer, choose **API keys**,
   or navigate directly to `/settings/api-keys`, then choose **Create API key**.
2. Choose a name, scope, and expiry on `/settings/api-keys/new`. A blocking
   progress dialog covers the form while the key is being created; the app
   chrome behind it is inert and cannot be reached with Tab.
3. Copy the secret from the non-dismissible reveal dialog immediately. Choose
   **Done** to return to the key list. The app chrome behind the dialog is
   inert, so within the app only **Done** dismisses it; browser back, refresh,
   and closing the tab are not intercepted.
4. Store the secret in a password manager, secret manager, or environment
   variable on the machine that runs the script.
5. If the client has only the key, discover its own profile UUID before calling
   account-scoped routes:

```bash
curl -sS "$CALCO_BASE_URL/api/auth/identity" \
  -H "Authorization: Bearer $CALCO_API_KEY"
```

The response is the same `{ "identity": ..., "profile": ... }` envelope as
login/session, and `profile.id` is the value to send as `X-CalCo-Account-ID`.
`GET /api/auth/identity` requires no account-binding header, returns only the
authenticated principal, and is available to both bearer keys and browser
sessions. It is read-only discovery; it does not unlock API-key management,
assistant, admin, import, or write routes.

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
X-CalCo-Account-ID: <user-profile-id>
Accept: application/json
```

`Authorization: Bearer` is the only supported API-key transport. Query-parameter
tokens and `X-API-Key` are not supported. Browser cookies authenticate the web
app, not API-key clients.

Every account-scoped user-data route also requires
`X-CalCo-Account-ID: <user_profiles.id UUID>`. It is not an API key and does not
authenticate anything by itself. The server authenticates the bearer token or
cookie first, then requires the header to name exactly that principal's profile
UUID. Send the profile ID returned in `profile.id` from `GET /api/auth/identity`
or from the browser-only `GET /api/auth/session`. A missing header returns
`400 missing_account_header`; a malformed, blank, or repeated header returns
`400 invalid_account_header`; a valid header for another profile returns
`401 session_account_changed`.

The binding applies to logs, foods, meals, goals, diary preferences, nutrition
details, API-key management, and assistant routes. Login, identity discovery,
session, logout, bootstrap, admin, and import routes do not require it.
API-key scope and expiry are checked before the account binding, so the header
cannot elevate a `read` key to a write route.

On user-data routes that accept API keys (`AccountBoundReadUser` and
`AccountBoundWriteUser` routes such as logs, foods, meals, goals, diary
preferences, and nutrition details), an `Authorization` header takes precedence:
CalCo authenticates with that bearer token and does not fall back to a browser
session cookie. A malformed, invalid, expired, revoked, or
security-stamp-invalidated key returns `401 invalid_api_key`.

Key management, assistant, admin, and import routes are browser-session-only.
They ignore `Authorization`; a request with only a bearer token and no valid
session cookie returns `401 unauthorized` (or the relevant session rejection),
not `invalid_api_key`. API keys never authenticate these routes.

Set the base URL, key, and profile ID once in a shell:

```bash
export CALCO_BASE_URL="https://calco.example.com"
export CALCO_API_KEY="calco_pat_<random secret>"
export CALCO_ACCOUNT_ID="<user-profile-id>"
```

## Read Examples

List the owner's logs for a date:

```bash
curl -sS "$CALCO_BASE_URL/api/logs?log_date=2026-10-26" \
  -H "Authorization: Bearer $CALCO_API_KEY" \
  -H "X-CalCo-Account-ID: $CALCO_ACCOUNT_ID"
```

Read the day's calorie and macro summary:

```bash
curl -sS \
  "$CALCO_BASE_URL/api/logs/summary?from_date=2026-10-26&to_date=2026-10-26" \
  -H "Authorization: Bearer $CALCO_API_KEY" \
  -H "X-CalCo-Account-ID: $CALCO_ACCOUNT_ID"
```

Search the shared catalog or list meals:

```bash
curl -sS -G "$CALCO_BASE_URL/api/foods/search" \
  --data-urlencode "q=paneer" \
  -H "Authorization: Bearer $CALCO_API_KEY" \
  -H "X-CalCo-Account-ID: $CALCO_ACCOUNT_ID"

curl -sS "$CALCO_BASE_URL/api/meals" \
  -H "Authorization: Bearer $CALCO_API_KEY" \
  -H "X-CalCo-Account-ID: $CALCO_ACCOUNT_ID"
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
  -H "X-CalCo-Account-ID: $CALCO_ACCOUNT_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "log_date": "2026-10-26",
    "meal_slot": "lunch",
    "item": { "type": "product", "id": "<product-id>" },
    "quantity": { "amount": 150, "unit": "g" },
    "idempotency_key": "lunch-2026-10-26-product-id-1"
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

### Meals With Unavailable Ingredients

A meal keeps its component IDs and quantities when a catalog product is
soft-deleted. `GET /api/meals` and `GET /api/meals/{id}` return `200` with an
explicit degraded shape instead of failing the list:

```json
{
  "id": "meal-id",
  "name": "Broken Porridge",
  "total_quantity": { "amount": "250", "unit": "g" },
  "nutrition": {
    "status": "unavailable",
    "unavailable_components": [
      {
        "component_id": "component-id",
        "item": { "type": "product", "id": "deleted-product-id" },
        "quantity": { "amount": "200", "unit": "g" },
        "reason": "product_unavailable"
      }
    ]
  },
  "components": [
    {
      "availability": "available",
      "id": "oats-component-id",
      "item": { "type": "product", "id": "oats-id" },
      "quantity": { "amount": "50", "unit": "g" },
      "nutrition_summary": { "energy_kcal": "190", "protein_g": "2.5", "carbs_g": "5", "fat_g": "1", "fiber_g": null }
    },
    {
      "availability": "unavailable",
      "id": "component-id",
      "item": { "type": "product", "id": "deleted-product-id" },
      "quantity": { "amount": "200", "unit": "g" },
      "reason": "product_unavailable"
    }
  ]
}
```

Healthy meals use `"nutrition": { "status": "available", "summary": {...} }`.
A meal without a declared `total_quantity` uses
`"nutrition": { "status": "not_declared" }`; this is legitimate and not an
error. A meal whose stored `total_quantity` can no longer be converted to grams
uses `"nutrition": { "status": "total_quantity_unavailable", "reason":
"quantity_not_convertible", "total_quantity": ... }`.

Every `available` component carries computed `nutrition_summary`. A component
keeps its identity and quantity and becomes `"availability": "unavailable"` with
a typed reason when it can no longer be used:

- `product_unavailable`: the product no longer exists or is no longer visible.
- `quantity_not_convertible`: the product exists, but its current servings and
  mass units cannot convert the stored quantity (for example, a product no
  longer defines the `cup` serving that the meal recorded).

This is a breaking wire-contract change from the earlier preview round:
`missing_components` is now `unavailable_components`, the component tag
`missing` is now `unavailable`, and `quantity_not_convertible` is a new reason.
Clients must switch on the typed reason rather than treating every degradation
as a deleted product.

Meal writes validate before persistence. The optional `total_quantity` must be a
positive amount with a nonblank unit supported as a mass quantity. Every supplied
component quantity must be convertible against the currently resolved product.
Invalid creates and updates return `400 validation` and write nothing. A later
catalog change can still invalidate a stored meal; that is reported by the
degraded read shape above, not by rejecting the whole list.

The meal quantity migration adds validated structural constraints. If a legacy
database contains a non-positive amount, blank unit, half-paired total, or meal
without components, the upgrade fails before schema mutation and reports the
affected row IDs. Blank means empty or containing only Unicode White_Space,
matching Rust `trim`. Repair those source rows explicitly; the server does not
delete or rewrite them. Structurally valid legacy quantities, including
non-mass declared totals, remain readable as dynamic degraded states, and
catalog-degraded meals remain readable.

Repair a broken meal with `PUT /api/meals/{id}` and a complete `components` array
using currently convertible products and quantities. `GET /api/meals/{id}/nutrients`
and meal-based log creates return `409 unavailable_components` with `meal_id` and
the same non-empty component objects. If the requested meal log/preview quantity
itself cannot be converted, they return `409 meal_quantity_not_convertible` with
the offending `quantity` and a typed `reason`.

### Durable Log Create Retries

Every log create requires a top-level `idempotency_key`. This applies to
`POST /api/logs`, `POST /api/logs/ad-hoc`, and `POST /api/logs/batch`. There is
no unkeyed fallback.

```bash
curl -sS -X POST "$CALCO_BASE_URL/api/logs" \
  -H "Authorization: Bearer $CALCO_API_KEY" \
  -H "X-CalCo-Account-ID: $CALCO_ACCOUNT_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "log_date": "2026-10-26",
    "meal_slot": "lunch",
    "item": { "type": "product", "id": "<product-id>" },
    "quantity": { "amount": 150, "unit": "g" },
    "idempotency_key": "lunch-2026-10-26-product-id-1"
  }'
```

For a batch, put one key beside `items`:

```json
{
  "idempotency_key": "breakfast-2026-10-26-1",
  "items": [
    {
      "log_date": "2026-10-26",
      "meal_slot": "breakfast",
      "item": { "type": "product", "id": "<product-id>" },
      "quantity": { "amount": 70, "unit": "g" }
    }
  ]
}
```

Keys are 1 to 128 characters, must not be blank, and reject control characters.
Omitting the key, sending `null`, sending a non-string JSON value, or sending an
invalid string value returns `400 validation` and writes nothing. Keys are
scoped to your profile, may be reused by another user, and are never included
in responses. A key on an individual batch item, including an explicit `null`
or a non-string value, is a validation error.

The first successful create returns `201 Created`. Retrying the same key,
logging route, and normalized input returns `200 OK` with the operation's logs
in their original order. The response reads the current stored log rows, not a
stored snapshot: later edits are visible, and stored nutrient snapshots are not
recalculated. Reusing the key with a different payload, a different batch order,
or a different logging route returns `409 conflict`.

Deleting a journal-backed created log does not free its key. A delayed replay
returns `409 conflict` and creates nothing. This guarantee covers operations
recorded by the durable journal. A key whose only legacy log was deleted before
the journal migration has no recoverable operation; the server does not guess
or reconstruct it, so a retry with that key can create a new log. Use a new key
for a new intentional submission. A malformed or incomplete operation also
returns `409 conflict` and never returns an empty or partial success. This
includes a stored fingerprint that is not a valid lowercase SHA-256 digest.
Operation rows and child links are retained indefinitely for the life of the
profile. There is no cleanup window after which a key becomes reusable.

Log create retries do not require a capability probe or version negotiation.
The routes are always keyed in this API contract; do not infer behavior from
`/api/health` or `/api/version`. If the server starts against an incompatible
database, it fails before serving rather than exposing an unkeyed path.

## Revocation

Revoke a key from **Settings** > **API keys**. Revocation takes effect
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

The backend allows the `Authorization` and `X-CalCo-Account-ID` headers through
CORS so trusted tools can call the API, but CORS does not make an embedded secret
safe. Browser clients should use the normal CalCo login and session cookie.

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
| `400` | `missing_account_header` | The account-scoped route was called without `X-CalCo-Account-ID`. |
| `400` | `invalid_account_header` | `X-CalCo-Account-ID` was blank, malformed, non-UUID, non-UTF-8, or supplied more than once. |
| `401` | `session_account_changed` | `X-CalCo-Account-ID` does not match the authenticated cookie/API-key profile. The response does not disclose either profile ID. |
| `404` | `api_key_not_found` | A key-management route referenced a key that does not exist for this user. |
| `409` | `conflict` | A log `idempotency_key` was reused with a changed payload, changed batch order, different logging route, a deleted operation log, or a malformed/incomplete operation. |
| `409` | `unavailable_components` | A meal preview or meal-based log references products or component quantities that can no longer be used. The error lists `meal_id` and the non-empty unavailable components with typed reasons; repair the meal or use another meal. |
| `409` | `meal_quantity_not_convertible` | The requested meal log/preview quantity cannot be converted to grams. The error lists `meal_id`, `quantity`, and reason `quantity_not_convertible`. |
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

# CalCo CLI

`calco` is a separate Rust command-line client for the CalCo personal API. It
uses a personal API key, calls only the documented `/api` routes, and never
talks to PostgreSQL directly.

This document is the user-facing behavior contract. The package lives in
`frontend-cli/` and is named `calco-cli`; the installed binary is `calco`.
`frontend-cli/IMPLEMENTATION.md` records module ownership and current status.

## Scope

The CLI supports:

- Authentication with an existing personal access token (PAT).
- Food search and food detail.
- Meal listing and detail.
- Log listing, detail, single-log creation, and deletion.
- Daily and ranged summaries.

It deliberately does not add custom-food or meal writes, log updates, ad-hoc
logs, batch/repeat logging, barcode lookup, goals, diary preferences, API-key
management, admin/import routes, assistant routes, pagination, or automatic
retries.

## Invocation

```text
calco [--json [--pretty]] [--base-url URL] <COMMAND>
```

Global flags may appear before or after the command:

```text
calco --json logs list today
calco logs list today --json
```

| Flag | Meaning |
| --- | --- |
| `--json` | Emit one compact JSON object on stdout. |
| `--json --pretty` | Emit the same JSON envelope with two-space indentation. |
| `--pretty` without `--json` | Usage error, exit `2`. |
| `--base-url URL` | Override `CALCO_BASE_URL` and the saved default server. |

Human output is the default. Success output goes to stdout; all errors go to
stderr. `--help` and `--version` are normal clap output.

`auth login` is human-only. `--json auth login` is rejected before any prompt or
storage operation.

## JSON Output

Successful commands emit exactly one envelope plus a trailing newline:

```json
{
  "schema_version": 1,
  "data": {},
  "meta": {}
}
```

- `schema_version` is the integer `1`.
- `data` is the command result described below.
- `meta` is always an object. It carries the command's effective date context:
  - single date: `{"date":"YYYY-MM-DD"}`
  - range: `{"from_date":"YYYY-MM-DD","to_date":"YYYY-MM-DD"}`
  - `logs add` also has `"replayed": true|false`; its `date` is the returned
    log's `log_date`, which on a replay may differ from the request date
  - commands without a date context emit `{}`
- `summary` always emits `from_date`/`to_date`, even for one day. `logs list`
  uses `date` when exactly one date resolves, and `from_date`/`to_date` for two
  or more dates.
- Decimal values are JSON strings such as `"150"`, `"12.5"`, or `"0"`. Optional
  values are `null`, and empty lists are `[]`; fields are not omitted from
  resource objects.
- IDs are full canonical hyphenated UUIDs. The CLI never abbreviates or
  truncates an ID.
- Resource objects use the backend wire fields unchanged. The supported field
  shapes are listed under each command.
- Compact JSON has no extra whitespace. Pretty JSON uses two spaces and a final
  newline. No other text is written to stdout.

### Successful command data

| Command | `data` |
| --- | --- |
| `foods search` | `{"items":[ProductSearchItem...]}` |
| `foods show` | `ProductDetail` |
| `meals list` | `{"items":[Meal...]}` |
| `meals show` | `Meal` |
| `logs list` (single date) | `{"items":[FoodLog...]}` |
| `logs list` (range) | `{"days":[{"date":"YYYY-MM-DD","items":[FoodLog...]}...]}` |
| `logs show` | `FoodLog` |
| `logs add` | `FoodLog` |
| `logs delete` | `{"id":"full-uuid","deleted":true}`; an interactive cancellation emits `{"id":"full-uuid","deleted":false,"cancelled":true}` in human mode. |
| `summary` | `{"days":[SummaryDay...],"totals":SummaryTotals,"averages":SummaryAverages}` |
| `auth status` | `AuthStatus` |
| `auth logout` | `LogoutResult` |
| `auth login` | No JSON form. |

## Errors And Exit Codes

Errors always go to stderr. In JSON mode the error is one structured object:

```json
{
  "schema_version": 1,
  "error": {
    "origin": "server",
    "code": "conflict",
    "message": "idempotency key was already used for another request",
    "http_status": 409,
    "uncertain": false,
    "recovery": "This key is bound to a different request. Retry the original body and key, or inspect the day's logs before choosing a new key."
  }
}
```

For a write transport failure, an ambiguous write HTTP response (`5xx`, `408`, or
redirect), or a malformed/unexpected write success, the error also includes the
full resolved request:

```json
{
  "schema_version": 1,
  "error": {
    "origin": "transport",
    "code": "timeout",
    "message": "request timed out",
    "http_status": null,
    "uncertain": true,
    "request": {
      "method": "POST",
      "url": "https://calco.example.com/api/logs",
      "body": {
        "log_date": "2026-11-15",
        "meal_slot": "lunch",
        "item": {"type": "product", "id": "full-uuid"},
        "quantity": {"amount": "150", "unit": "g"},
        "idempotency_key": "lunch-2026-11-15-1"
      }
    },
    "recovery": "Retry the identical request with the same idempotency key. A 200 response means the original write succeeded."
  }
}
```

The `request` object never contains the `Authorization` header or token. If any
error field contains the configured token—for example a reflected server message
or a caller-supplied note or query echoed in the request snapshot—the CLI redacts
that token before writing the error, including for transport and invalid-response
errors.

| Exit | Meaning |
| --- | --- |
| `0` | Success, including a `200` idempotent replay, a `204` delete, and a cancelled interactive delete that sent no request. |
| `1` | Unexpected local failure: config read/write, invalid saved config URL, keyring access, internal. |
| `2` | Argument, date, explicit URL, or CLI-side validation error; also backend `400 validation`. |
| `3` | Missing/invalid authentication credentials, insufficient scope, or another backend authorization failure. |
| `4` | Requested resource does not exist. |
| `5` | Conflict, including an idempotency-key conflict. |
| `6` | Network, transport, server, redirect, or malformed-response failure. |

`origin` is one of:

| Origin | Typical exit | Meaning |
| --- | --- | --- |
| `arguments` | `2` | CLI arguments, date selector, or local request validation. |
| `config` | `1` | Saved default-server file could not be read, parsed, validated, or written. |
| `credentials` | `3` | No token, rejected token, or insufficient scope. |
| `keyring` | `1` | OS credential store unavailable or denied. |
| `transport` | `6` | DNS, TLS, connect, timeout, or other network failure. |
| `server` | status-based | The server returned a non-2xx HTTP response. |
| `response` | `6` | A response status or payload did not match the expected success shape, including a redirect. |
| `internal` | `1` | An unexpected local error. |

`401` and `403` both exit `3`. Only the backend codes `invalid_api_key`,
`unauthorized`, and `insufficient_scope` use the `credentials` origin and auth
recovery. A generic `403 forbidden` (for example, an ownership failure) uses the
`server` origin with its backend message and does not get credential/login
guidance.

Backend HTTP status mapping:

| HTTP status | Exit |
| --- | --- |
| `400` | `2` |
| `401`, `403` | `3` |
| `404` | `4` |
| `409` | `5` |
| all other non-2xx, including `3xx`, `408`, `429`, and `5xx` | `6` |

`code` is the backend error code when a valid `{"error":{"code","message"}}`
body is present; otherwise it is a local code such as `invalid_arguments`,
`invalid_base_url`, `base_url_missing`, `invalid_date`, `invalid_date_range`,
`date_range_too_large`, `date_range_not_allowed`, `auth_missing`,
`invalid_credentials`, `keyring_unavailable`, `config_read_failed`,
`config_write_failed`, `network_error`, `timeout`, `invalid_response`, or
`http_error`.

`http_status` is the actual HTTP status, or `null` for local/transport errors.
`uncertain` is a boolean on every error. `recovery` is a string or `null`.

Human errors use a short, line-oriented form with the same fields:

```text
error: <message>
  origin: server
  code: conflict
  http_status: 409
  uncertain: false
  recovery: ...
```

When a resolved `request` is present, human output also prints its method, URL,
and full compact JSON body. Raw HTML or arbitrary response bodies are not
echoed. Backend error messages and request body text are treated as untrusted
and control characters are escaped in human output.

### Write uncertainty

The CLI never retries a write automatically.

- `POST /api/logs` sends the idempotency key in the JSON body, never in a
  custom header. The CLI requires the key; it never invents one.
- `201 Created` means a new log was created. `200 OK` means the same key and
  request replayed the existing log. Both exit `0`; `meta.replayed` and human
  output distinguish them.
- `POST /api/logs` accepts only `201` and `200` as success.
- `DELETE /api/logs/{id}` accepts only `204` as success.

Write transport failures, ambiguous write HTTP responses (`5xx`, `408`, and
redirects), and malformed/truncated success responses include the full resolved
`request` (method, URL, body with resolved date and idempotency key when
applicable). `uncertain` is `true` when the request may have reached the server
and the outcome is unknown: timeouts, connection loss after connect, write `5xx`,
`408`, or `3xx` responses, and malformed or unexpected success responses. A
connection failure that proves no request was sent has `uncertain: false`, still
includes the request for diagnosis, and says a retry is safe. Clear `4xx`
rejections are certain, do not echo the request, and are not retried
automatically.

Retrying `logs add` is safe only with the identical body and key. A retry that
returns `200` proves the original write succeeded. A `5xx`, `408`, or redirect can
occur after the server committed the create, so treat it as ambiguous and reuse
the same body and key rather than generating a new one.

`logs delete` has no idempotency key. If a connection failure proves the request
was not sent, retry the delete. If the outcome is uncertain (including a `5xx`,
`408`, or redirect), use `calco logs show ID`: `404` means the delete succeeded,
while `200` means the log still exists and the delete can be repeated.

## Dates

`logs list` and `summary` take an optional positional date selector. `logs add`
takes `--date`. The selector grammar is:

| Value | Meaning |
| --- | --- |
| `YYYY-MM-DD` | One calendar date. |
| `today` | Local system date when the command starts. |
| `yesterday` | One day before that local date. |
| `start..end` | Inclusive calendar range. |
| `start..` | From `start` through today, inclusive. |

The default is today. Date resolution happens once per process; a long-running
range does not change dates at midnight. `today` uses the system local date;
`--device-timezone` is sent to the API as metadata and does not change date
parsing.

The CLI rejects, with exit `2`:

- `..end`, bare `..`, and other open-start forms.
- Reversed ranges where `start` is after `end`.
- Malformed dates and extra whitespace.
- Ranges larger than 366 days of difference, i.e. more than 367 inclusive
  dates.
- A range selector anywhere a single date is required (`logs add --date`).

`logs add --date` accepts only `YYYY-MM-DD`, `today`, or `yesterday`.

## Authentication And Configuration

Base URL precedence:

1. `--base-url`
2. `CALCO_BASE_URL`
3. Saved default server from the platform config directory
4. Otherwise `base_url_missing` (exit `2`)

Token precedence:

1. `CALCO_API_KEY`
2. OS keyring credential bound to the selected normalized base URL
3. Otherwise `auth_missing` (exit `3`)

The environment token is not tied to a server and is used verbatim for whatever
base URL was selected. A keyring credential is tied to one normalized URL.

### URL rules

- The base URL must be an absolute `http` or `https` URL with a host.
- `http` is accepted only for loopback hosts: `localhost`, an IPv4 loopback
  address, or `::1`. Every other host requires `https`.
- Userinfo (`user:pass@`), query strings, and fragments are rejected.
- A path prefix is allowed. The API is addressed as `<base>/api/...`.
- URLs are normalized before saving or looking up a keyring credential:
  lowercase scheme/host, default port removed, no trailing slash. The original
  spelling is not used as an identity.
- An invalid `--base-url` or `CALCO_BASE_URL` exits `2`; it never falls back to
  a lower-precedence source. A saved default that cannot be parsed or validated
  is config corruption: origin `config` (`invalid_base_url`), exit `1`.

The CLI uses rustls, does not follow redirects, never sends or stores cookies,
and ignores HTTP proxy environment variables (`HTTP_PROXY`, `HTTPS_PROXY`,
`ALL_PROXY`, and lowercase variants). Proxy use is unsupported and explicitly
disabled, so the `Authorization: Bearer` header is sent only to the selected base
URL. It uses a 5-second connect timeout and a 30-second overall request timeout.
Any `3xx` response is an invalid response (exit `6`).

### Local storage

- The saved default server is a non-secret JSON file at the platform config
  directory for `calco`, normally `config.json` under the OS config directory
  (`directories::ProjectDirs` for `calco`).
- The file contains only `schema_version` and `default_base_url`. It never
  contains a token.
- Tokens are stored only in the OS credential store under the `calco-cli`
  service, keyed by the normalized server URL.
- There is no plaintext token fallback. If the keyring cannot store a prompted
  token, `auth login` fails, tells the user to set `CALCO_API_KEY` for later
  commands instead, and leaves the saved default server unchanged.
- Empty or whitespace-only environment values are treated as absent.

### Secrets

Tokens are never printed, included in JSON, put in URLs, or included in error
`request` objects. The token type has a redacted `Debug`/`Display` and zeroizes
its memory on drop. The CLI builds the `Authorization: Bearer` header only at
request time. Keyring/config errors may name the server but never the token.

## Commands

### `calco auth login`

```text
calco auth login [--base-url URL]
```

1. Resolve the base URL with the normal precedence. This command never prompts
   for a URL.
2. Require an interactive terminal. It prompts `CalCo API key: ` with echo
   disabled. There is no stdin-pipe or environment fallback for this prompt.
3. Verify the prompted token with `GET /api/units`, even if `CALCO_API_KEY` is
   set. The prompted value wins for this verification only.
4. On `200`, save the prompted token in the OS keyring for the normalized URL,
   then save that URL as the default server.
5. On verification failure, save nothing.

Keyring is written before the default-server file. If the keyring write fails,
nothing is saved, and the error says to use `CALCO_API_KEY` instead. If the
keyring write succeeds but the config write fails, login exits `1`; the
credential remains usable for that URL and the error says to pass `--base-url`
until the default can be saved.

Successful human output names the server and says the credential was saved. If
`CALCO_API_KEY` is set, it warns that the environment variable will continue to
override the saved credential for later commands. It never prints the token,
scope, identity, or key name.

```text
Logged in to https://calco.example.com.
Credential saved to the OS keyring.
Warning: CALCO_API_KEY is set and will override the saved credential for later commands.
```

The warning line is omitted when `CALCO_API_KEY` is absent or empty.

`--json`, a non-TTY stdin, or a missing base URL is rejected before prompting
with exit `2`. In JSON mode the rejection is a structured arguments error. The
login probe proves the route is reachable and the token is accepted; it does not
prove `read_write` scope because `GET /api/units` is read-scoped.

### `calco auth status`

```text
calco auth status
```

Reads the selected URL and token with normal precedence, then probes the
API-prefixed `GET /api/units` route. `probe.path` reports that API route
(`/api/units`), not the full request path: a path prefix on the selected base URL
is prepended when the request is sent. There is no server endpoint for
current-key metadata, so the CLI reports only facts it actually observed:

```json
{
  "schema_version": 1,
  "data": {
    "base_url": "https://calco.example.com",
    "credential_source": "environment",
    "probe": {
      "method": "GET",
      "path": "/api/units",
      "http_status": 200
    }
  },
  "meta": {}
}
```

`credential_source` is `environment` or `keyring`. No username, key name, scope,
expiry, hint, last-used time, or identity is invented or displayed. A missing
credential or failed probe is a normal structured error, not a successful
"logged out" payload.

Human output reports the same successful connection as three labels and does not
dump the probe fields:

```text
Server: https://calco.example.com
Credentials: CALCO_API_KEY (environment)
Connection: authenticated
```

The credentials line is `OS keyring` when the token came from the keyring.

### `calco auth logout`

```text
calco auth logout
```

Removes only the stored keyring credential for the selected normalized URL. It
does not call the server, clear `CALCO_API_KEY`, or remove the saved default
server. If `CALCO_API_KEY` is set, it remains active and the output says so.

```json
{
  "schema_version": 1,
  "data": {
    "base_url": "https://calco.example.com",
    "removed": true,
    "environment_key_active": false
  },
  "meta": {}
}
```

Removing an already-absent stored credential succeeds with `"removed": false`.
No token is displayed.

Human output is sentence-based. Removing a credential prints:

```text
Logged out of https://calco.example.com.
Removed the saved credential from the OS keyring.
```

When none was stored:

```text
No saved credential for https://calco.example.com.
```

If `CALCO_API_KEY` is active, this note is appended in both cases:

```text
Note: CALCO_API_KEY remains active and overrides the stored credential.
```

### `calco foods search`

```text
calco foods search QUERY [--scope all|history|custom]
```

Calls `GET /api/foods/search?q=...&scope=...`. `--scope` defaults to `all`.
`history` includes the user's history ranking; `custom` restricts the search
scope. The backend returns the full result list; the CLI does not paginate or
re-rank.

`ProductSearchItem` fields, as returned by the backend:

```text
id, source, source_id, barcode, name, brand, categories,
nutrition_summary.per_100g.{energy_kcal,protein_g,carbs_g,fat_g,fiber_g},
created_at, updated_at
```

Each nutrition value is a decimal string or `null`. Empty arrays are `[]`.

Human output is a match count followed by aligned columns for name, brand,
kilocalories per 100 g, and the full ID:

```text
2 matches
NAME       BRAND  KCAL/100G  ID
Oats       Home   389        11111111-1111-1111-1111-111111111111
Rye bread  -      250        11111111-1111-1111-1111-111111111112
```

Missing brands and missing energy values print `-`. Names and brands may widen
their columns; IDs are never truncated. No matches prints `No foods found.`

### `calco foods show`

```text
calco foods show ID
```

Calls `GET /api/foods/{id}` and returns `ProductDetail`: the search fields plus
`visibility`, `default_quantity`, `default_unit`, `nutrients`, `servings`, and
`allowed_units`. IDs must be full canonical UUIDs; abbreviated IDs are rejected.

Human output keeps the name, brand and full ID, the labelled per-100 g macros,
servings, and supported logging units. It does not dump source IDs, visibility,
barcodes, nutrient provenance, or timestamps:

```text
Oats
Home · 11111111-1111-1111-1111-111111111111
Per 100 g: Calories 389 kcal · Protein 12.5 g · Carbs 60 g · Fat 7 g · Fiber 9 g
Servings: cup = 80 g
Logging units: g (gram), cup
```

A missing per-100 g value prints `-`; missing zeroes are never inferred. Empty
servings or units print `-`.

### `calco meals list`

```text
calco meals list
```

Calls `GET /api/meals` and returns `{"items":[Meal...]}`. The backend returns all
visible meals; the CLI does not paginate.

Human output is one compact row per meal:

```text
NAME            QUANTITY  KCAL  ID
Breakfast bowl  250 g     450   22222222-2222-2222-2222-222222222222
```

`KCAL` is the meal's nutrition-summary energy value; missing values print `-`.
No meals prints `No meals.`

### `calco meals show`

```text
calco meals show ID
```

Calls `GET /api/meals/{id}` and returns one `Meal`:

```text
id, name, notes, total_quantity, nutrition_summary, components,
created_at, updated_at
```

A component is `{id, item:{type,id}, quantity, nutrition_summary}`. The API
currently exposes only the component product UUID, not its name; the CLI must
not invent a name or make extra per-component requests.

Human output keeps the meal name and full ID, total quantity and energy, notes
when present, and one component row with the component ID, item type plus full
item ID, and quantity:

```text
Breakfast bowl
22222222-2222-2222-2222-222222222222
Total: 250 g · 450 kcal
Notes: assembled
Components
ID                                    ITEM                                          QUANTITY
44444444-4444-4444-4444-444444444444  Product 11111111-1111-1111-1111-111111111111  50 g
```

No components prints `Components: -`. The component item UUID is shown; the CLI
does not invent a product name.

### `calco logs list`

```text
calco logs list [DATE] [--slot breakfast|lunch|dinner|snack|late_night_snack]
```

Calls `GET /api/logs?log_date=YYYY-MM-DD`.

- Single resolved date (including `start..start`): `data` is
  `{"items":[FoodLog...]}` and `meta` is `{"date":"..."}`.
- Range of two or more resolved dates: the CLI issues one request per date,
  sequentially in ascending order.
  It does not print partial output; every response must succeed before stdout
  is written. `data` is
  `{"days":[{"date":"...","items":[...]},...]}` with every date in the range
  present in ascending order, including empty days. `meta` has `from_date` and
  `to_date`.
- `--slot` is filtered by the CLI after each response because the backend list
  route has no slot query parameter. Empty days remain present in a range.

`FoodLog` fields:

```text
id, log_date, meal_slot, device_timezone, item, quantity, nutrients, notes,
created_at, updated_at
```

`item` is tagged by `type`:

```text
{"type":"product","id":"...","name":"...","brand":null}
{"type":"meal","id":"...","name":"..."}
{"type":"ad_hoc","name":"...","brand":null}
```

`quantity` is `{"amount":"decimal-string","unit":"..."}`. `nutrients` is an
array of `{code, amount, unit}`. `meal_slot` is `null` or one of the exact slot
strings above. The API returns `ad_hoc` items too; they are not filtered out.

Human output always names the resolved date, even when the day is empty, then
groups entries by `Breakfast`, `Lunch`, `Dinner`, `Snack`, `Late night snack`,
and `Unspecified` in that order. Each row is compact and keeps the full log ID on
the next line:

```text
Today · 2026-11-15
  Lunch
    Oats · 150.5 g · 580 kcal
    id: 33333333-3333-3333-3333-333333333333
  Dinner
    Breakfast bowl · 1 serving · -
    id: 33333333-3333-3333-3333-333333333334
  Unspecified
    Tea · 0 g · -
    id: 33333333-3333-3333-3333-333333333335
```

An empty day prints `No logs.` under its date. A ranged listing repeats a date
group for every date and prints the range boundaries at the top:

```text
Logs · 2026-11-15 .. 2026-11-16

Today · 2026-11-15
  Lunch
    Oats · 150.5 g · 580 kcal
    id: 33333333-3333-3333-3333-333333333333
  Dinner
    Breakfast bowl · 1 serving · -
    id: 33333333-3333-3333-3333-333333333334
  Unspecified
    Tea · 0 g · -
    id: 33333333-3333-3333-3333-333333333335

2026-11-16
  No logs.
```

The calorie value comes only from a recorded `ENERGY_KCAL` nutrient. A missing
energy value prints `-`; it is never inferred as zero. List rows do not repeat
brands, item UUIDs, device timezones, or timestamps.

Date headers use `Today · YYYY-MM-DD` for the resolved current date,
`Yesterday · YYYY-MM-DD` for the previous day, and `YYYY-MM-DD` otherwise.

### `calco logs show`

```text
calco logs show ID
```

Calls `GET /api/logs/{id}`, returns one `FoodLog`, and sets `meta.date` from the
returned `log_date`.

Human output shows the logged name, quantity, resolved date, slot, labelled
macros, the item reference when the item has one, notes only when provided, and
the full log ID:

```text
Oats
150.5 g · Today · 2026-11-15 · Lunch
Macros: Calories 580 kcal · Protein 18.6 g · Carbs 90 g · Fat 10.5 g · Fiber 13.5 g
Item: Product 11111111-1111-1111-1111-111111111111
Notes: lunch note
id: 33333333-3333-3333-3333-333333333333
```

Only nutrients present in the log are printed; a missing macro is not shown as
zero. With no known macro values the line is `Macros: -`.

### `calco logs add`

```text
calco logs add (--food ID | --meal ID) --amount DECIMAL --unit UNIT
              [--date DATE] [--slot SLOT] [--notes TEXT]
              [--device-timezone TZ] --idempotency-key KEY
```

Exactly one of `--food` or `--meal` is required. `--amount` must be a positive
base-10 decimal; `--unit` and `--device-timezone` must be non-empty. The CLI
does not look up or convert units; the backend remains the authority. `--slot`
accepts only the exact slot strings. Omitted optional fields are omitted from
the request body.

`--date` defaults to today and accepts only a single date (`YYYY-MM-DD`,
`today`, or `yesterday`). `--idempotency-key` is required, is not generated,
and must be 1-128 characters, non-blank, and free of control characters.

The request body is:

```json
{
  "log_date": "2026-11-15",
  "meal_slot": "lunch",
  "device_timezone": "Asia/Kolkata",
  "item": {"type": "product", "id": "full-uuid"},
  "quantity": {"amount": "150", "unit": "g"},
  "notes": "optional",
  "idempotency_key": "caller-supplied-key"
}
```

Omit `meal_slot`, `device_timezone`, or `notes` when their flags are absent.
The key is in the body, not a header.

A `201` returns the created log and `meta.replayed` is `false`. A `200` returns
the existing log and `meta.replayed` is `true`. Both are success. The returned
log is authoritative: `data.log_date`, `meta.date`, and the human date line use
its `log_date`, which on a replay may differ from the request date if the
existing entry was edited after the original write. A replay may likewise return
changed quantity, item, or notes from the original request; those differences
are not errors. A `409` is an idempotency-key conflict (exit `5`). The CLI never
retries automatically; see "Write uncertainty" for transport, ambiguous HTTP
response, and malformed-success recovery.

Human output starts with the action, then shows the returned log date, slot, and
full log ID:

```text
Added: Oats · 150.5 g · 580 kcal
Today · 2026-11-15 · Lunch
id: 33333333-3333-3333-3333-333333333333
```

A replay says so and states that nothing new was created:

```text
Already recorded: Oats · 150.5 g · 580 kcal
No new entry created.
Today · 2026-11-15 · Lunch
id: 33333333-3333-3333-3333-333333333333
```

An absent slot is `Unspecified`; a missing recorded `ENERGY_KCAL` value prints
`-`, never an inferred zero.

### `calco logs delete`

```text
calco logs delete ID [--yes]
```

In human mode on an interactive terminal, omitting `--yes` prompts on stderr:

```text
Delete log <full-uuid>? [y/N]
```

Only `y` or `yes`, case-insensitive, proceeds. Any other answer, an empty line,
or end-of-file cancels without sending a request; the command exits `0` with
`data` set to `{"id":"full-uuid","deleted":false,"cancelled":true}`. Human output
is one friendly sentence:

```text
Cancelled. Log 33333333-3333-3333-3333-333333333333 was not deleted.
```

`--yes` is required in JSON mode and whenever stdin is not an interactive
terminal. Those modes never prompt, and a missing `--yes` is an arguments error
(exit `2`) before any request. With `--yes`, no prompt is shown in any mode.

The command calls `DELETE /api/logs/{id}`; only `204` is success. A `404` is exit
`4`.

`data` for a completed delete is `{"id":"full-uuid","deleted":true}` and `meta`
is `{}`. Human output is:

```text
Deleted log 33333333-3333-3333-3333-333333333333.
```

Deletion does not use an idempotency key. If the error proves the request was not
sent, retrying the delete is safe; otherwise use the show-after-uncertain-delete
recovery above when the outcome is unknown.

### `calco summary`

```text
calco summary [DATE]
```

Calls `GET /api/logs/summary?from_date=...&to_date=...` once for the resolved
range. The backend returns only days that have logs. The CLI zero-fills every
date in the resolved range, in ascending order, and marks whether logs existed:

```json
{
  "schema_version": 1,
  "data": {
    "days": [
      {
        "date": "2026-11-14",
        "has_logs": true,
        "energy_kcal": "1850",
        "protein_g": "90",
        "carbs_g": "210",
        "fat_g": "60"
      },
      {
        "date": "2026-11-15",
        "has_logs": false,
        "energy_kcal": "0",
        "protein_g": "0",
        "carbs_g": "0",
        "fat_g": "0"
      }
    ],
    "totals": {
      "energy_kcal": "1850",
      "protein_g": "90",
      "carbs_g": "210",
      "fat_g": "60"
    },
    "averages": {
      "energy_kcal": "925",
      "protein_g": "45",
      "carbs_g": "105",
      "fat_g": "30"
    }
  },
  "meta": {"from_date": "2026-11-14", "to_date": "2026-11-15"}
}
```

`totals` sums the daily values across the whole resolved range; zero-filled
no-log days add zero. `averages` divides those totals by the number of calendar
days in the range, including days without logs, and rounds to at most two
decimal places (midpoint away from zero). Both objects always contain the four
summary nutrients as decimal strings; neither uses JSON numbers or floats. A
range with two dates therefore gives the two-day average even when only one date
has logs.

`has_logs: false` means "no logs recorded", not "measured zero intake". Human
output says `no logs (not zero intake)` for those days. A day with logs whose
totals happen to be zero has `has_logs: true` and zero strings. The backend
response must contain unique dates inside the requested range; anything else is
an invalid response (exit `6`). Totals and averages use checked fixed-point
arithmetic, so values whose sum would overflow are also an invalid response
(exit `6`), never a panic or partial output.

A single day is a short labelled block without redundant totals:

```text
Today · 2026-11-15
  Logged calories: 1600 kcal
  Protein: 75 g
  Carbs: 180 g
  Fat: 50 g
```

A range is a table with the range boundaries, one row per date, `Total`, and
`Daily avg`:

```text
Summary · 2026-11-15 .. 2026-11-16
DATE        KCAL  PROTEIN  CARBS  FAT
2026-11-15  1600  75       180    50
2026-11-16  no logs (not zero intake)
Total       1600  75       180    50
Daily avg   800   37.5     90     25
```

A single day with no logs prints only its date and the no-log phrase:

```text
2026-11-16
  no logs (not zero intake)
```

The single-day header uses the same `Today`/`Yesterday` prefixes as log
listings. Numbers are shown to at most two decimal places. Column width grows
when a value is wider; JSON values are unchanged.

## Human Output

Human output is line-oriented, deterministic, and has no ANSI color or terminal
width dependency. Lists use compact headed groups or space-aligned tables. The
only alignment input is the escaped cell text, so a long name widens its column
instead of truncating a UUID.

Missing scalar values print as `-`; empty servings or logging units print `-`;
an empty component list prints `Components: -`. Full canonical UUIDs are always
shown. Untrusted strings from the API (names, brands, notes, units, slot values,
messages) are escaped so C0/C1 controls, DEL, bidi controls, zero-width
characters, BOM, and soft hyphen cannot alter terminal output. Other Unicode is
preserved.

An empty result uses a human sentence: `No foods found.`, `No meals.`, or
`No logs.` for an empty single day or range date group. Single-date log listings
always print the resolved date, even with no entries. Ranged listings print the
range boundaries and repeat a date group for every date.

Human decimal values are rounded for display to at most two decimal places.
JSON keeps the exact decimal strings from the command contract. Log list rows
show only a recorded `ENERGY_KCAL` value; missing energy prints `-`, never zero.
The CLI does not print a daily log total because the nutrient arrays may be
partial; it does not invent missing values.

Summary days with no logs print `no logs (not zero intake)`, never four innocent
zeros. A range summary prints those dates inside the table and ends with the
four totals and calendar-day averages shown in JSON; a single-day summary uses
labelled lines without a redundant total.

`auth status` prints `Server:`, `Credentials:`, and
`Connection: authenticated`. It does not dump the probe method, route, or HTTP
status in human mode.

## Backend Caveats

These are current API facts the CLI must preserve, not gaps for the CLI to work
around by inventing data:

- The log list endpoint is single-date only and has no meal-slot filter.
  Ranged listing and `--slot` are CLI behavior built from those requests.
- The summary endpoint omits no-log days and does not provide `has_logs`,
  `totals`, or `averages`. Zero-filling, the flag, and the range aggregates are
  CLI output semantics.
- Summary and log-history requests allow at most 366 days of difference
  (367 inclusive dates).
- Meal components expose only the product ID and quantity, not the product
  name. Food-log items do include their snapshot name.
- `GET /api/units` proves authentication but exposes no key name, scope,
  identity, expiry, hint, or last-used metadata.
- Idempotency currently applies only to single `POST /api/logs`; the key is a
  body field. A replay returns `200`, a new create returns `201`, and a changed
  body with the same key returns `409`.
- Deletes return `204` with no body. Logs and meals list responses are
  unpaginated.
- Backend error bodies are `{"error":{"code","message"}}`; common codes include
  `validation`, `not_found`, `invalid_api_key`, `insufficient_scope`,
  `conflict`, `forbidden`, and `internal_error`.
- The API base path is `/api`; the CLI appends it to the selected base URL. A
  path prefix on the base URL therefore becomes `<prefix>/api/...`.

## Development Commands

Run inside the Nix development shell:

```bash
nix develop
just build-cli
just test-cli
just check-cli
cargo run --manifest-path frontend-cli/Cargo.toml -- --help
```

`just check-cli` runs the format check, clippy with `-D warnings`, and tests.
The repository also exposes the CLI as the Nix package `packages.cli`:

```bash
nix build .#cli
./result/bin/calco --help
nix profile install .#cli
```

Default CLI tests must not require PostgreSQL, a real OS keyring, or external
network access. Environment, storage, prompt, and confirmation dependencies are
injected/faked in unit tests, and binary integration tests use a local loopback
mock server. Real-keyring and live-server smoke tests are isolated and manual.

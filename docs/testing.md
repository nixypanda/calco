# Testing

## Layout

Two kinds of backend tests:

```text
backend/src/**/*.rs        inline #[cfg(test)] unit tests (domain + app, mocked repos)
backend/tests/all.rs       integration test entry point
backend/tests/suites/*.rs  integration tests (real HTTP router, real Postgres)
backend/tests/common/      shared harness (see below)
frontend-web/tests/**/*.elm Elm frontend unit tests
```

Integration tests cover the HTTP lifecycle of each entity end-to-end:

```text
tests/suites/product_lifecycle.rs   custom-food CRUD + search + auth required
tests/suites/search_lifecycle.rs    search hydration, category filters, scopes,
                                    soft-deleted/blank rows, category counts,
                                    HTTP category limit
tests/suites/product_repo.rs        external upsert + search-summary hydration
tests/suites/auth_lifecycle.rs      bootstrap, login, sessions + admin user management
tests/suites/diary_lifecycle.rs     food log CRUD, list ordering,
                                    recent/latest/last-used wire shape
tests/suites/diary_prefs_lifecycle.rs
                                    per-user enabled meal-slot preferences
tests/suites/goal_lifecycle.rs      goal defaults + save/overwrite flow
tests/suites/meal_lifecycle.rs      meal CRUD + /meals/{id}/nutrients
tests/suites/cross_entity.rs        product -> meal -> log -> summary wiring
tests/suites/import_lifecycle.rs    admin import flow + error path
```

## What We Test

Tests exist to catch behavior regressions, not to restate the implementation.
Keep a test only when it proves one of:

- a top-level wire roundtrip another system depends on;
- a non-trivial algorithm or branch (search tokenizing, nutrition scaling,
  ranking, date/calendar math, SQL filter builders);
- an async race or staleness rule (stale response ignored, double-submit
  blocked, two loads composed in order);
- a security or authorization rule (401 maps to session expiry, access checks,
  session/cache invalidation);
- validation and its user-facing error;
- navigation or effect output (the `OutMsg` a page returns).

Frontend-specific rules:

- response decoders are not tested directly, except the three intentional
  negative invariants in the allowed-exceptions list; only top-level types with
  both an encoder and a decoder get a roundtrip;
- no response fixtures or golden wire JSON beyond the minimal negative fixtures
  that prove those invariants;
- pure logic is tested as properties, not as restated examples;
- page tests are broad user stories, not one-message state transitions;
- UI tests assert user-visible output only, never DOM structure or CSS;
- keep the small set of allowed exceptions listed below.

Do not add tests that:

- assert a constructor or factory returned its arguments, or `init == literal`;
- only assert that one field equals the value just supplied to `update`;
- exercise no-op guards on states the caller cannot produce;
- assert something that cannot fail;
- duplicate a rule already covered by a pure-logic test.

Backend lifecycle suites under `backend/tests/suites/` are smoke-level
end-to-end tests: they prove the router, auth, handler, app, repository, and
Postgres wiring works and that the wire shape survives the round trip. Pure
validation, ranking, state transitions, and security-stamp rules belong in
inline unit tests. Constant/default assertions are only kept where they prove
an external contract; do not add a unit test that merely restates a literal.
Behavior that only exists in SQL (query ordering, filters, constraints,
conditional updates) stays in integration or repository tests, because a pure
unit test cannot cover it.

## Frontend Test Shape

Elm tests cannot drive a browser, so frontend coverage is layered:

- **Properties** (`Lib.*`, pure `Data.*`, `Access`, `Store`, `Page.reconcile`,
  `Ui.Workspace.paneVisibility`, `Ui.CategoryTag.rows`,
  `Main.classifyDevice`/`reclassifyDevice`, `Api.Client.failure`) state laws,
  invariants, or metamorphic properties. Whole-value equality is acceptable
  only when it is the law itself (for example, `addDays 0 date == date`).
- **Top-level roundtrips** cover only types that have both an encoder and a
  decoder. See the list below.
- **Page stories** (`Page.*`) seed a realistic screen state, drive 3-6 user
  actions through several user messages plus simulated server responses, and
  assert the observable outcome: the final `OutMsg`, a small local screen
  projection (`toScreen : Model -> Screen`), and any in-flight/disabled state
  the user can actually see. They do not assert an arbitrary internal field
  after a single message, and they do not compare whole models.
- **Component tests** (`Component.*`) keep pure validation, request/payload
  branches, and arithmetic. Update flows belong to page stories.
- **UI/view tests** assert labels, ARIA, enabled/disabled state, and other
  user-visible output. They never assert DOM structure, CSS classes, or layout.
- **Exceptions** are the small high-value cases listed below.

Async `Cmd` values are opaque, so the environment is modelled by feeding
completion messages in the order the server would produce them; a story
asserts that stale or duplicate completions do not change what the user sees.

### Top-level roundtrip types

Only these top-level **wire** types are roundtrip-tested:

| Type | Roundtrip |
|---|---|
| `Lib.Date.LocalDate` | `fromString (format date) == Just date` |
| `Data.Route.Route` | `fromUrl (routeToPath route) == Just route` |
| `Data.MealSlot.MealSlot` | exhaustive `fromString (toString slot) == Just slot` |
| `Data.DiaryPrefs.DiaryPrefs` | `decoder (encoder prefs) == Ok prefs` |

`Lib.JsonTest` is not a wire-type exception: it tests the generic
`Lib.Json.maybe`/`andMap` combinators with a local encoder/decoder pair, not a
production response or request shape.

Nested wire values such as `Data.Nutrition.Quantity` and
`Data.ItemRef.ItemRef` are not top-level and are not roundtrip-tested. Request
encoders get a property only when they have a real optional/omitted or
purpose-encoded branch (create log, update log, API-key create, ad-hoc log,
food-assistant conversation). Straight field-mapping encoders and response
decoders have no direct test beyond the negative decoder exceptions.

### Definition of a user story

A page story:

1. creates the page with a realistic route/context and feeds the initial
   successful server responses needed to reach the loaded state;
2. drives 3-6 user-level messages, plus the server completions they cause;
3. asserts the final `OutMsg` and/or a narrow user-visible projection;
4. may include a failure and retry, a 401, a double submit, a stale response,
   or a cancel/confirm delete as steps, not separate tests.

A story must not assert request IDs, generation counters, internal
`Submitting`/`CopyPending` constructors, `Cmd` internals, DOM structure, CSS
classes, or an intermediate model field that the user cannot see. If a
required step is ignored by `update`, the story should fail explicitly rather
than silently continuing with the previous model.

### Allowed exceptions

These survive outside properties, roundtrips, and stories:

1. `Api.Client.failure` maps 401 to `SessionExpired` (one property).
2. `Access.resolveRoute` exhaustive decision property.
3. `Store` request-token/session property.
4. API-key pane generation/re-entry race as one or two page-level pane-lifetime
   stories; the generation race is one of them. A story may read a request ID or
   copy ID to route a simulated completion, but must not assert equality on that
   ID; IDs are an implementation detail, not user-visible output.
5. Intentional decoder leniency/strictness:
   - unknown meal slot decodes to `Nothing`;
   - unknown API-key scope decodes to `UnknownScope`;
   - food-assistant extra-key rejection.
6. `Ui.CategoryTag` overflow render.

Every exception must carry a comment explaining why it is not a property or a
story; an uncommented exception is a test that has not justified its existence.
Do not add standalone per-page 401, stale-response, or double-submit tests;
fold those steps into the page story that owns them.

### Shared test support

`tests/Support/` holds small helpers shared by tests:

- `Support.Fuzz` — reusable fuzzers (dates, meal slots, amounts, routes, API
  errors, food logs). Fuzzers are reviewed like production code.
- `Support.Fixtures` — canonical dates, API errors, user-facing error strings,
  and tuple helpers. Page-specific model builders stay next to their page.
- `Support.Story` — `runSteps` and `runStepsResult` for sequential messages.
  It is deliberately small; it is not a test framework.

Support modules must not expose a top-level value of type `Test`. `elm-test`
compiles every `.elm` file under `tests/` and runs exposed `Test` values; the
filename is a naming convention, not the discovery mechanism.

### Fuzzer requirements

- Generators must not silently bias values with `Maybe.withDefault` fallbacks.
  If a value cannot be constructed, use `Fuzz.invalid` with a useful message.
- Include edge cases explicitly: month ends, leap days, century rules, years
  near 1 and 9999, empty and duplicate lists, blank/invalid strings.
- Prefer a weighted mix of arbitrary and edge-case values over `Fuzz.filter`
  retries.
- Do not generate enormous strings unless the property needs them.
- A safe-ID or constant-value generator that makes the property pass trivially
  is a bug in the test.

### Mutation sanity checks

Before declaring a frontend test change done, break each of these and confirm
a test fails:

- change the macro factors in `Data.Nutrition`;
- change `addDays`/`previousDay` month-end behavior;
- change `shiftMonth` year-boundary behavior;
- remove the generation check in `Store.settle`;
- change `Store.settle` so an `Err` result is not cached (the failed-settlement
  law must fail);
- remove the valid-date branch from `Data.LocalCtx.fromRaw` (a valid
  `YYYY-MM-DD` plus timezone must still return `Just`);
- change `Data.Route.fromUrl` so an unknown path does not decode to `NotFound`;
- change `Data.Search.applyCompletion` so a plain-token completion rewrites
  earlier tokens or drops the leading text;
- change `Data.Nutrition.scaledSnapshotForQuantity` so a non-numeric current
  amount is accepted instead of yielding `Nothing`;
- remove an optional-field branch from `createLogRequestEncoder` or the API-key
  expiry encoder;
- change `Page.reconcile` to reinitialize existing panes;
- change `Ui.Workspace.paneLimit`;
- change the `Ui.CategoryTag` overflow count;
- remove a required field from an encoder covered by a branch property.

If a mutation passes, the property or story is not testing what it claims.

## How Integration Tests Work

- The crate exposes a library (`backend/src/lib.rs`) with `build_router(pool, config)`. `main.rs` is a thin shim that calls it; tests call the same function.
- Each test is annotated `#[sqlx::test]`. sqlx provisions a fresh database per test from a migrated template, hands the test a `PgPool`, and drops the database when the test passes.
- The router is driven in-process via `tower::ServiceExt::oneshot` — no socket, no port binding.
- The shared harness (`tests/common/mod.rs`) provides `app(pool)`, `bootstrap_admin`, `create_user_session`, and JSON request/response helpers.

## Required Environment

A Postgres reachable as `DATABASE_URL` whose user has `CREATEDB` privilege.

Project default (matches `docker-compose.yml`):

```text
DATABASE_URL=postgres://calco:calco@localhost:5432/calco
```

Bring it up with:

```bash
just db-up
just db-wait
```

## Running

Standard:

```bash
cd backend && cargo test
```

Single integration file while iterating:

```bash
cd backend && cargo test --test product_lifecycle
```

Surface handler logs from a failing test:

```bash
RUST_LOG=info cargo test --test diary_lifecycle -- --nocapture
```

Elm frontend tests:

```bash
just test-frontend
```

Or directly:

```bash
cd frontend-web && elm-test
```

## Coverage

Coverage is produced by `cargo-llvm-cov`.

Install once:

```bash
cargo install cargo-llvm-cov --locked
rustup component add llvm-tools-preview
```

Terminal summary:

```bash
cd backend && cargo llvm-cov
```

Browsable HTML report:

```bash
cd backend && cargo llvm-cov --html --open
```

LCOV for CI / IDE integrations:

```bash
cd backend && cargo llvm-cov --lcov --output-path lcov.info
```

Exclude the test harness from coverage math:

```bash
cd backend && cargo llvm-cov --ignore-filename-regex 'tests/'
```

Instrumented builds use a separate `target/llvm-cov-target/` directory, so the first run recompiles from scratch. Subsequent runs are incremental.

## Gotchas

- Run only one `cargo test` process against a given PostgreSQL cluster at a
  time. `#[sqlx::test]` database names are cluster-global, so concurrent
  cargo-test processes can collide even when using separate target directories.
  This is an environment limitation, not a code bug.
- `.env` sets `DATABASE_URL` for `cargo run`/`cargo test`; if another Postgres is bound to port 5432 with different credentials, integration tests fail to connect. Either stop the conflicting container or override `DATABASE_URL` per command.
- Catalog `Source` values are uppercase enums (`OFF`, `USDA`, `IFCT`, `INDB`, `USER`). Tests that stage imports must use those exact codes.
- `GET /meals/{id}/nutrients?amount=X` scales by the meal's `total_quantity`. For predictable assertions, set `total_quantity` to match the sum of component weights.

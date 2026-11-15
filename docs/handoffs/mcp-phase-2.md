# MCP Phase 2 Handoff — Write Tools

## Status and base

- Base branch: `feat/mcp-read-tools`
- Phase 1 commit: `0613662970295f702cd3819c8bae5fa6eed028ce`
- Phase 1 result: authenticated, read-only MCP endpoint at `/api/mcp`
- Phase 1 tests: `cargo test --all-targets` → 418 passed, 4 pre-existing ignored

Start Phase 2 on a new branch from `feat/mcp-read-tools`:

```bash
git switch feat/mcp-read-tools
git switch -c feat/mcp-write-tools
```

Do not start from `main`.

## Goal

Close the common CalCo MCP loop:

```text
search_foods → get_food → create_log → list_logs → get_daily_summary
                                      ↘ delete_log (correction)
```

Phase 1 already provides `search_foods`, `get_food`, and `get_daily_summary`.
Phase 2 adds the write step and the minimum read-back needed to verify it.

Keep the slice focused. Do not add goal editing, custom-food management, meal
management, diary preferences, resources, or prompts unless they block the loop.

## What already exists

Read these before changing anything:

- `backend/src/mcp/module.rs` — narrow read ports, `McpModule`, `McpConfig`
- `backend/src/mcp/api/mod.rs` — `McpServer`, `McpUser`, three read tools
- `backend/src/mcp/api/http.rs` — stateless transport + bearer-only gate
- `backend/src/catalog/api/dto.rs` — shared REST/MCP catalog read models
- `backend/src/journal/food_log/api/dto.rs` — shared summary read model
- `backend/src/journal/food_log/app/services.rs` — `FoodLogService`
- `backend/src/journal/food_log/app/history.rs` — `FoodLogHistoryService`
- `backend/src/journal/food_log/api/http.rs` — REST handlers and DTOs to reuse
- `backend/tests/suites/mcp_lifecycle.rs` — Phase 1 integration suite
- `backend/tests/common/mcp.rs` — MCP request helpers
- `docs/architecture.md` — `mcp` is a transport adapter, not a bounded context

Important invariants:

- `mcp` owns no domain rules and no repositories.
- MCP tools call existing application services.
- REST and MCP use shared read models in API-layer DTO modules.
- No other module depends on `mcp`.
- `McpUser { profile_id, scope }` is inserted per request by the bearer gate.
- The transport currently accepts both `read` and `read_write` keys; per-tool
  scope checks belong in the tool handlers.

## Required production scope

### 1. `create_log`

Purpose: create one food log for the authenticated profile.

Arguments should mirror the REST `POST /api/logs` contract:

```text
log_date: YYYY-MM-DD
meal_slot?: breakfast | lunch | dinner | snack | late_night_snack
device_timezone?: string
item: { type: "product" | "meal", id: UUID }
quantity: { amount: decimal, unit: string }
notes?: string
```

Implementation:

- Reuse `FoodLogService::log_item`.
- Map the MCP arguments to `LogFoodInput`.
- Use `FoodLogItemRef::Product` / `FoodLogItemRef::Meal`.
- Return the shared `LogResponse` shape.
- Require `ApiKeyScope::ReadWrite`.
- Use `read_only_hint = false`.
- Do not accept `user_id`, `profile_id`, or any ownership override.

### 2. `list_logs`

Purpose: verify what was logged for a date.

Arguments:

```text
log_date: YYYY-MM-DD
```

Implementation:

- Reuse the existing day-log read path used by `GET /api/logs`.
- Return the shared `LogListResponse` shape.
- This is a read tool; both scopes may call it.
- Use the same ordering as REST.

### 3. `delete_log`

Purpose: correct a bad log without leaving the assistant.

Arguments:

```text
log_id: UUID
```

Implementation:

- Reuse the existing delete application path.
- Require `ApiKeyScope::ReadWrite`.
- Decide and document the return shape. A small `{ "deleted": true }` result is
  acceptable; do not invent a new aggregate. Use `destructive_hint = true`.
- Preserve existing owner checks.

### 4. Scope enforcement and discovery

- Add a helper such as:

```rust
fn require_write_scope(auth: &McpUser) -> Result<(), CallToolResult>
```

- A `read` key calling a write tool gets an MCP tool error with
  `isError: true`, for example `read_write API key scope required`.
- Do **not** return an HTTP 403 after MCP dispatch; the transport is already
  authenticated. Keep the distinction: HTTP 401 is authentication, tool error
  is authorization.
- Preferred `tools/list` behavior: hide write tools from `read` keys. Inspect
  `rmcp` 3.10 `ServerHandler::list_tools` / `ToolRouter` and filter from the
  `RequestContext` HTTP parts. If hiding is impractical, show the tools with a
  clear description and still enforce on call. Record the decision in docs and
  tests.

### 5. Optional, only after the core is green

- `create_ad_hoc_log` for foods not in the catalog.
- `update_log` for corrections.
- Do not add meals/custom-food/goal tools in this phase.

## Blocking design decision: idempotency

MCP clients retry tool calls. `POST /api/logs` is not idempotent. A retried
`create_log` can duplicate a meal.

Choose one approach before coding:

### A. Durable idempotency key (recommended)

- Add optional `idempotency_key` to `create_log` arguments.
- Persist it on the food log, or in a small `food_log_idempotency` table.
- Enforce uniqueness per `(user_profile_id, idempotency_key)`.
- On duplicate, return the existing log instead of creating another.
- Requires a migration, domain/repository port changes, application tests, and
  DDD review.

This is the safest option but expands the slice beyond the MCP adapter. Follow
the backend `AGENTS.md` rules: domain decides, repository stores.

### B. Adapter-level in-memory deduplication

- Keep a bounded, TTL-limited cache in `McpModule` keyed by
  `(profile_id, idempotency_key)`.
- Return the prior result on a duplicate.
- Not durable across restarts or multiple backend instances.
- Acceptable only if the user explicitly accepts single-process semantics.

### C. Defer idempotency

- Document that clients must not retry writes and require human confirmation.
- Add an explicit test showing a retry duplicates a log, so the behavior is
  visible.
- Not recommended for an assistant-facing write path.

Do not silently ignore this decision. If option A is judged too large, stop and
report the trade-off before implementing B or C.

## DTO reuse

Move the REST log response shapes into the shared journal API DTO module so MCP
and REST cannot drift:

- `LogResponse`
- `LogListResponse`
- `ItemDto`
- `QuantityDto`
- `MealSlotDto`
- `NutrientSnapshotDto`
- `NutrientSummaryDto` if needed

They should derive `Serialize + JsonSchema` and remain in the API layer, not in
domain or app. Update `journal/food_log/api/http.rs` to consume them. Preserve
the REST JSON exactly.

Prefer sharing the request shape too, but do not expose REST `Deserialize`
quirks as MCP schema accidentally. If needed, define a small MCP argument struct
and map it to `LogFoodInput`.

## Error mapping

Follow the Phase 1 pattern in `backend/src/mcp/api/mod.rs`:

- `JournalError::Validation` → bounded MCP tool error
- `JournalError::NotFound` / `Forbidden` → safe "not found"
- internal errors → log server-side, return generic "internal service error"
- scope failure → tool error, not HTTP 403
- no REST `{ "error": ... }` envelope inside MCP
- no SQL, table names, tokens, profile IDs, or stack traces in tool text

## Tests

The test agent owns these files. Add a separate
`backend/tests/suites/mcp_write_lifecycle.rs` or extend the existing MCP suite.
Register it in `backend/tests/suites/mod.rs`.

Minimum coverage:

1. `create_log` with a `read_write` key succeeds; `list_logs` returns the entry;
   `get_daily_summary` reflects its nutrients.
2. `create_log` with a `read` key is denied with `isError: true`; no row is
   created.
3. `delete_log` removes the entry; `list_logs` and summary update accordingly.
4. `delete_log` with a `read` key is denied.
5. `tools/list` behavior matches the chosen scope-filtering policy.
6. Cross-user isolation: A's key cannot create/delete/list as B; extra
   ownership arguments are rejected or ignored, never honored.
7. Invalid product/meal UUID, unit, date, quantity, missing args, and unknown
   enum values return tool errors, not 500 or REST envelopes.
8. Nutrient snapshot behavior: create a log, edit the catalog product, and
   confirm the log/summary keep the original snapshot.
9. Idempotency: same key twice creates one log; different keys create two (if
   option A or B is implemented). If option C, document the duplicate behavior.
10. Auth: cookie-only and read-only-key calls to write tools are rejected;
    revoked key is rejected on the next request.
11. Successful writes update `last_used_at`; failed auth does not.

Run:

```bash
cd backend && cargo test --test all mcp
cd backend && cargo test --all-targets
```

## Docs

Update:

- `docs/api-access.md` — tool table, write scope, idempotency/confirmation,
  examples, and what remains unavailable.
- `docs/backend.md` — MCP transport write tools, scope gate, idempotency
  decision, error mapping.
- `docs/testing.md` — new write suite.
- `docs/architecture.md` only if boundaries change.

## Review workflow

Use separate subagents, not one mixed agent:

1. **Implementation agent** — production code only.
2. **Test-plan agent** — independent acceptance plan; no edits.
3. **Test agent** — implements/runs tests after implementation.
4. **DDD reviewer** — adversarial review of boundaries, DTO reuse, scope gate,
   idempotency placement, repository/domain purity.
5. **Functional/security reviewer** — auth, cross-user isolation, retries,
   destructive annotations, error leakage, CORS/Host behavior.

Do not poll. Launch background subagents and wait for completion notifications.
Use `opencode-go/deepseek-v4.1-flash#max`.

## Definition of done

- Branch `feat/mcp-write-tools` starts from `feat/mcp-read-tools`.
- Common loop works with a `read_write` key.
- `read` keys cannot mutate data, and discovery reflects that.
- Idempotency decision is implemented and documented, or explicitly escalated.
- REST JSON shape is unchanged.
- MCP files and tests are rustfmt-clean.
- `cargo test --all-targets` passes.
- DDD and functional reviewers report no unresolved P0/P1.
- Changes are committed; no unrelated formatting changes are included.

## Ready-to-paste subagent prompts

### Implementation

> On branch `feat/mcp-write-tools`, implement the Phase 2 MCP write slice from
> `docs/handoffs/mcp-phase-2.md`. Read root/backend `AGENTS.md` before coding.
> Add `create_log`, `list_logs`, and `delete_log` using existing journal
> application services and shared API DTOs. Enforce `read_write` per tool,
> choose and implement the idempotency approach described in the handoff, and
> keep `mcp` a transport adapter with no domain or repository logic. Do not edit
> tests or docs; the test agent owns those. Run `cargo check --all-targets`.
> Report files changed, the idempotency decision, and any caveats. Do not
> commit.

### Test plan

> Independently design the Phase 2 MCP write test plan from
> `docs/handoffs/mcp-phase-2.md` and the current code. Do not edit files yet.
> Cover write scope denial, create/list/summary loop, delete correction,
> cross-user isolation, invalid inputs, snapshot stability, idempotency,
> `tools/list` filtering, auth, and `last_used_at`. Wait for the implementation
> handoff before writing tests. Return exact requests and expected assertions.

### Test implementation

> Implementation for the Phase 2 MCP write slice is complete. Implement and run
> the approved test plan. Own `backend/tests/common/**`,
> `backend/tests/suites/**`, and `docs/testing.md`; do not edit production
> source. If a test exposes a real defect, report it with file:line and keep the
> assertion. Run `cargo test --test all mcp` and `cargo test --all-targets`.
> Report exact counts. Do not commit.

### DDD review

> Adversarially review the Phase 2 MCP write diff for DDD and architecture
> adherence. Read `docs/handoffs/mcp-phase-2.md`, root/backend `AGENTS.md`, and
> `docs/architecture.md`. Check: application services only, no repository/domain
> leakage, shared REST/MCP DTOs, narrow write boundary, scope enforcement
> placement, idempotency ownership, and REST shape preservation. Do not edit
> files. Report file/line-backed P0/P1/P2 findings and a merge verdict.

### Functional/security review

> Adversarially review the Phase 2 MCP write diff for functional and security
> behavior. Check: bearer-only auth remains intact, `read` keys cannot mutate,
> cross-user isolation, retry/idempotency behavior, destructive tool
> annotations, error leakage, invalid-input handling, Host/Origin/CORS
> regressions, and REST/MCP parity. Do not edit files. Report prioritized
> file/line findings and a merge verdict.

# CLI Agent Instructions

`frontend-cli/` is a separate Rust package, `calco-cli`, producing the `calco`
binary. Read the repository root `../AGENTS.md` and `../docs/cli.md` before
changing it. `IMPLEMENTATION.md` records durable module ownership and current
status; it is not a second behavior contract.

## Boundaries

- The CLI is an HTTP client for the documented `/api` surface. It must not
  import the backend crate, query PostgreSQL, read migrations, or duplicate
  backend business logic.
- Keep the implementation in cohesive modules: `src/main.rs` (top-level parsing
  and delegation, output-mode handling, process exit), `src/auth.rs`
  (configuration, environment/credential stores, auth commands), `src/client.rs`
  (HTTP, REST DTOs, request recovery),
  `src/dates.rs` (date selector grammar and ranges), `src/output.rs` (errors,
  output envelopes/modes, shared human formatting including item references),
  and `src/commands/`: `mod.rs` (global args, `Command`/`Runtime`, dispatch,
  connection and UUID helpers), `foods.rs` (food args, execution, rendering),
  `meals.rs` (meal args, execution, rendering), `logs.rs` (log args,
  delete-confirmation trait and terminal gate, validation, request building,
  grouping, rendering), and `summary.rs` (summary merge, totals/averages,
  rendering). Update `IMPLEMENTATION.md` if ownership changes.
- Do not add commands outside the agreed scope without updating `docs/cli.md`:
  no custom-food/meal writes, log updates, ad-hoc/batch/repeat logging, barcode,
  goals, diary preferences, API-key management, imports, admin, assistant,
  pagination, or automatic retries unless the contract is deliberately changed.
- Keep the backend as the authority for unit conversion, ownership, catalog
  resolution, scope checks, and validation. CLI validation is only for clear,
  safe, early failure and stable output.

## Non-Negotiable Behavior

- `--json` is compact; `--json --pretty` is pretty; human output is the default.
  Success goes to stdout, errors to stderr. Never write partial success output.
- Successful JSON uses the versioned `{schema_version:1,data,meta}` envelope.
  Errors use the structured stderr contract in `docs/cli.md`. Decimal values are
  JSON strings. IDs are full canonical UUIDs; never abbreviate them.
- Exit codes are contractual: `0` success, `1` unexpected local, `2` arguments,
  `3` auth/scope, `4` missing, `5` conflict, `6` network/server/invalid response.
- Auth precedence is `CALCO_API_KEY` > OS keyring, and URL precedence is
  `--base-url` > `CALCO_BASE_URL` > saved default. Keyring credentials are bound
  to a normalized server URL.
- Tokens never appear in output, JSON, URLs, errors, or logs. There is no
  plaintext fallback. Login prompts an existing PAT, verifies `GET /api/units`,
  and saves only after success. `--json auth login` and non-TTY login fail
  before prompting.
- HTTPS is required except loopback. Reject userinfo, query, and fragment.
  Redirects and cookies are not used.
- Writes are never retried automatically. `logs add` requires a caller-supplied
  idempotency key in the JSON body. `201` is created, `200` is replay, and
  `409` is a conflict. Delete accepts only `204`. `--yes` is required in JSON
  and noninteractive modes; interactive human mode may instead prompt and
  cancels without a request when declined.
- Uncertain write errors (transport loss, malformed success, `5xx`, redirect)
  must include the full resolved request (method, URL, body with resolved
  date/key) and recovery guidance, but never the token. Clear `4xx` rejections
  are certain and do not echo the request; a connection failure that proves no
  request was sent is not uncertain and says retry is safe.
- Escape C0/C1, DEL, bidi controls, zero-width characters, BOM, and soft hyphen
  in untrusted human text. Summary no-log days must say `no logs (not zero
  intake)`, not imply measured zeroes. Summary totals and calendar-day averages
  are decimal strings, never floats.
- Dates resolve once per process. Enforce the inclusive 366-day difference
  limit. Log ranges are sequential requests; output is atomic.

## Testing And Quality

Run inside the Nix development shell:

```bash
just test-cli
just check-cli
just build-cli
```

`just check-cli` runs `cargo fmt --check`, clippy with `-D warnings`, and tests.
Default tests must not require PostgreSQL, a real OS keyring, or external
network access. Inline unit tests use injected environment/storage/prompt/
confirmation fakes and the local loopback mock server from the `#[cfg(test)]`
module at `src/test_support.rs`. `tests/cli_integration.rs` separately runs the
built executable with isolated HOME/XDG, environment, and stdin to test the
process boundary. Real-keyring and live-server smoke tests are isolated and
manual.

Before committing:

1. Update `docs/cli.md` if observable behavior or wire fields change.
2. Add or adjust tests for the behavior, not implementation trivia.
3. Check the backend DTO/handler sources listed in `IMPLEMENTATION.md` for wire
   drift.
4. Run `just check-cli` and `just build-cli`.

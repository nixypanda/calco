# CLI Implementation Notes

Durable module ownership and current status for `frontend-cli/`. The behavior
contract is `docs/cli.md`; do not restate command, output, authentication, or
error rules here.

## Ownership

```text
src/main.rs              top-level clap parser, delegates parsed commands to
                         commands::run, output-mode handling, process exit
src/auth.rs              base URL/token configuration, env/credential stores, auth commands
src/client.rs            HTTP transport, wire DTOs, request recovery, secret redaction
src/dates.rs             date selector grammar and inclusive DateSpan
src/output.rs            errors, output modes, envelopes, shared human formatting
src/commands/mod.rs      global args, Command/Runtime, dispatch, api_client,
                         parse_full_uuid
src/commands/foods.rs    food search/detail args, execution, human rendering
src/commands/meals.rs    meal list/detail args, execution, human rendering
src/commands/logs.rs     log list/show/add/delete args, DeleteConfirmation and
                         TTY gate, validation, request building, grouping,
                         human rendering
src/commands/summary.rs  summary args, range merging, totals/averages, human
                         rendering
src/commands/tests/mod.rs shared command-helper tests
src/test_support.rs      cfg(test) environment/store/prompt/confirmation fakes,
                         loopback mock server, runtime builders
```

`main` parses the process arguments, owns output-mode/exit handling, and
delegates command execution to `commands::run`. Category modules use `auth`,
`dates`, `output`, and `client`, and import shared command state and transport
helpers (`GlobalArgs`, `Runtime`, `api_client`, and `parse_full_uuid`) from the
parent. `output.rs` owns `item_reference_text` because meals and logs both
render item references. `logs.rs` owns `DeleteConfirmation` and
`TtyDeleteConfirmation`; the parent reexports the trait for `Runtime` plus the
category argument types needed by the command tree, and reexports `LogsCommand`
only under `#[cfg(test)]` for parser tests.

`auth`, `client`, and `commands` intentionally form a small module cycle:
`commands` resolves connections through `auth` and holds auth-owned injected
traits in `Runtime`; `auth` executes its commands against
`commands::{GlobalArgs, Runtime}` and verifies login through `client`; and
`client` depends on `auth::SecretToken` for transport credential handling.
Keeping configuration, stores, prompts, and auth commands in one module is a
deliberate tradeoff; no extra runtime module is needed for the current design,
though a future justified refactor may revisit that boundary.

The category split and shared test-support extraction changed no authentication,
HTTP, or date behavior.

`src/test_support.rs` is compiled only under `#[cfg(test)]` and is shared by
inline unit tests in `auth` and the command categories. Those tests call command
entry points with injected environment/store/prompt/confirmation fakes and a
local loopback HTTP mock. `tests/cli_integration.rs` stays a separate, inline
harness because it tests the built executable's process boundary with isolated
HOME/XDG roots, fake environment tokens, closed stdin, and a finite loopback
mock.

## Current Status

- Package `calco-cli`, Rust 2024, installed binary `calco`.
- Implemented and tested: auth login/status/logout; food search and detail;
  meal list and detail; log list/show/add/delete; daily and ranged summaries;
  compact/pretty JSON and human output; config/keyring resolution and uncertain
  write recovery.
- Repository integration is complete: `nix/cli.nix` exposes `packages.cli`
  (`nix build .#cli`), and `just build-cli`, `test-cli`, `format-cli`, and
  `check-cli` are wired into the root aggregate targets.
- Default tests are offline: inline unit tests use the injected
  environment/storage/prompt/confirmation fakes and loopback mock from
  `src/test_support.rs`; `tests/cli_integration.rs` runs the built executable in
  an isolated process environment. Neither layer requires PostgreSQL, a real OS
  keyring, or external network access. Real-keyring and live-server smoke tests
  are manual and isolated.
- Quality gates are the local `just` targets.

## Contract Sources

Re-check wire drift in:

```text
backend/src/catalog/api/http.rs
backend/src/catalog/api/shared.rs
backend/src/journal/food_log/api/dto.rs
backend/src/journal/food_log/api/http.rs
backend/src/journal/food_log/app/history.rs
backend/src/journal/meal/api/http.rs
backend/src/auth/api/http.rs
backend/src/lib.rs
docs/api-access.md
docs/backend.md
```

Do not duplicate their DTOs, routes, or status mapping here. Update
`docs/cli.md` when observable behavior or wire fields change.

## Change Workflow

1. Update `docs/cli.md` for contract changes and
   `.opencode/skills/calco-cli/SKILL.md` for agent-facing usage or recovery
   changes.
2. Add behavior tests, not implementation-trivia tests.
3. Run `just check-cli` and `just build-cli`.

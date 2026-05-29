# Agent Configuration

## Playwright E2E Tests

- **Location**: `frontend/e2e/`
- **Config**: `frontend/playwright.config.ts`
- **Browser**: Chromium (managed by Nix via `playwright-driver`)

### Commands

```bash
# Run all e2e tests (auto-starts Vite dev server)
cd frontend && pnpm exec playwright test

# Run with UI mode
cd frontend && pnpm exec playwright test --ui

# Run a specific test file
cd frontend && pnpm exec playwright test e2e/app.spec.ts
```

### Via just

```bash
just frontend-e2e        # run e2e tests
just test                 # runs all tests (backend + frontend unit + e2e)
```

### Playwright config notes

- The `webServer` option in `playwright.config.ts` auto-starts the Vite dev server on port 5173 before tests and kills it after.
- `reuseExistingServer: true` (non-CI) means you can keep the dev server running for faster iteration.
- Chromium path is set via `PLAYWRIGHT_BROWSERS_PATH` in the Nix flake dev shell.

### If browser is not found

Make sure you're in the Nix dev shell (`direnv allow` or `nix develop`). The `PLAYWRIGHT_BROWSERS_PATH` env var must point to the Nix-provided Chromium.

If you're **outside the Nix shell** (or on Darwin where Chromium isn't available via Nix):
```bash
# The CDN may fail with self-signed cert errors behind corporate proxies/VPNs
NODE_TLS_REJECT_UNAUTHORIZED=0 npx playwright install chromium
```

# CalCo

CalCo is a self-hosted food and nutrition tracker for a small homelab/household setup.

The app is intentionally simple: search or create foods, log what was eaten, snapshot nutrients at log time, and review the selected day. It also supports reusable meals/recipes and CLI-driven catalog imports from external food datasets.

## Mobile Showcase

The screenshots use the local development database and switch between light and
dark with the page theme.

| Daily diary and macro progress | Catalog search | Quantity-aware nutrition and logging | Reusable meal builder | Custom food creation |
| :---: | :---: | :---: | :---: | :---: |
| <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/mobile-diary.png"><img alt="CalCo mobile diary showing daily calorie and macro progress" src="docs/images/readme/light/mobile-diary.png" width="240"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/mobile-food-search.png"><img alt="CalCo mobile food catalog search results" src="docs/images/readme/light/mobile-food-search.png" width="240"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/mobile-food-nutrition.png"><img alt="CalCo mobile food logging form with calculated nutrition" src="docs/images/readme/light/mobile-food-nutrition.png" width="240"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/mobile-meal-builder.png"><img alt="CalCo mobile reusable meal builder" src="docs/images/readme/light/mobile-meal-builder.png" width="240"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/mobile-custom-food.png"><img alt="CalCo mobile custom food creation form" src="docs/images/readme/light/mobile-custom-food.png" width="240"></picture> |

## Desktop Showcase

The diary and food search stay visible together on wider screens, and opening a
food keeps the diary in view.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/desktop-diary-search.png">
    <img alt="CalCo desktop workspace showing the daily diary and food search side by side" src="docs/images/readme/light/desktop-diary-search.png" width="1200">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/dark/desktop-food-detail.png">
    <img alt="CalCo desktop workspace showing the daily diary and a food detail side by side" src="docs/images/readme/light/desktop-food-detail.png" width="1200">
  </picture>
</p>

## Stack

- Backend: Rust, axum, sqlx, PostgreSQL
- Frontend: Elm 0.19.2, elm-ui
- Database: PostgreSQL via Docker Compose
- Tooling: Nix flake, just, Python import scripts

## Current Scope

Implemented:

- Username/password auth with bootstrap admin and admin user management
- Food catalog search/detail, camera and manual barcode lookup, custom food CRUD
- Food logs with nutrient snapshots, daily summaries, recent-item defaults, and
  latest-slot repeat
- Meal/recipe CRUD and meal logging
- Responsive web frontend with configurable diary meal slots
- CLI import pipeline for USDA SR Legacy, Open Food Facts India, IFCT 2017, and INDB 2024 data

Not the goal right now:

- Analytics dashboards, trends, or charts
- Browser UI for import jobs
- Offline/service-worker behavior
- Native mobile app

## Documentation

- [Features](docs/features.md): product checklist and current scope
- [Architecture](docs/architecture.md): system structure and DDD decisions
- [Backend](docs/backend.md): backend domains, APIs, persistence, and invariants
- [Frontend](docs/frontend.md): frontend routes, UI structure, and design rules
- [Button System](docs/buttons.md): unified button API and documented exceptions
- [Local Development](docs/local-development.md): dev shell, services, env vars, tests, i18n
- [Deployment](docs/deployment.md): NixOS module, reverse proxy, and production setup
- [Imports](docs/imports.md): catalog CLI import pipeline and source merging
- [Personal Data Import](docs/personal-data-import.md): MyFitnessPal export workflow
- [Testing](docs/testing.md): automated test layout and commands
- [QA Runbook](docs/qa-runbook.md): end-to-end browser release checks

Setup details live in the docs above, not in this README. Start with
[Local Development](docs/local-development.md) for a working dev environment, or
[Deployment](docs/deployment.md) to run CalCo on a server.

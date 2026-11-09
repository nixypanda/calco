#!/usr/bin/env node

// Browser-level layout-stability harness for the skeleton-loader contract.
//
// Prerequisites:
//   - PostgreSQL and the backend running (`just dev` or `just dev-backend`).
//   - The Vite frontend running at --base-url (default http://localhost:1234).
//   - Chrome/Chromium installed; set CHROME to override discovery.
//   - CALCO_ADMIN_USER, CALCO_ADMIN_PASSWORD, CALCO_LAYOUT_USER and
//     CALCO_LAYOUT_PASSWORD set for the test accounts. Passwords are never
//     printed or written to artifacts.
//   - CALCO_URL overrides the default base URL and CALCO_LAYOUT_DATE overrides
//     the fixed route date (default 2026-10-27; a future date falls back).
//   - Optional CALCO_CUSTOM_FOOD_ID, CALCO_FOOD_ID, CALCO_MEAL_ID,
//     CALCO_LOG_ID and CALCO_ADMIN_EDIT_USER_ID override the ids discovered
//     from the API. Explicit overrides always win. Without an admin-edit
//     override the harness uses the `me`/layout user when present, then falls
//     back to the first user returned by /api/admin/users (normally the
//     authenticated admin).
//
// The harness is report-only by default: layout failures are printed, artifacts
// are written, and the process exits 0. Set CALCO_REQUIRE_LAYOUT=1 to make
// failures exit nonzero. `--report-only` forces report-only even when that env
// var is set. In required mode a missing optional fixture is a failure, not a
// skip.
//
// A clean database still needs either seed data or the fixture-id overrides
// above for custom-food-edit, meal-edit, food-show, food-log and meal-show.
// Required MVP
// cases (bootstrap-auth, diary-date-gate, diary, goals, diary-settings,
// api-keys, admin-boot, calendar, calendar-date-gate, transition-scroll) do not
// depend on those ids. The api-keys case creates one uniquely named layout-user key before the
// case and deletes it in a finally step.
//
// Usage:
//   node docs/scripts/check-skeleton-stability.mjs \
//     --base-url http://localhost:1234 --viewport phone \
//     [--case diary --case goals] [--headed] [--report-only]
//
// Artifacts: docs/images/skeleton-stability/<timestamp>/<case>/{loading.png,
// loaded.png,result.json}. Retries also write attempt-<n>/ screenshots. The
// directory is gitignored.

import { once } from "node:events";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  capture,
  connectToPage,
  evaluate,
  launchChrome,
  normalizeBaseUrl,
  setViewport,
  trackApiRequests,
} from "./lib/cdp.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "../..");
const ARTIFACT_ROOT = path.join(REPO_ROOT, "docs/images/skeleton-stability");
const DEFAULT_BASE_URL = "http://localhost:1234";
const DEFAULT_LAYOUT_DATE = "2026-10-27";
const FALLBACK_PAST_DATE = "2025-10-27";
const VIEWPORTS = {
  phone: { width: 390, height: 844, label: "Phone" },
  desktop: { width: 1440, height: 900, label: "Desktop" },
};
const XYW = ["x", "y", "width"];
const XYWH = ["x", "y", "width", "height"];
const ALL_CASE_NAMES = [
  "bootstrap-auth",
  "diary-date-gate",
  "diary",
  "goals",
  "diary-settings",
  "api-keys",
  "admin-boot",
  "admin-list",
  "admin-edit",
  "foods-list",
  "meals-list",
  "custom-food-edit",
  "meal-edit",
  "food-show",
  "custom-food-show",
  "food-log",
  "meal-show",
  "nutrition-details",
  "search",
  "search-recents",
  "calendar",
  "calendar-date-gate",
  "transition-scroll",
];

let chrome = null;
let chromeProfile = null;
let cdp = null;
let cleanupStarted = false;

class WaitTimeout extends Error {
  constructor(message) {
    super(message);
    this.name = "WaitTimeout";
  }
}

function delayOnly(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function parseArgs(argv) {
  const options = {
    cases: [],
    baseUrl: normalizeBaseUrl(process.env.CALCO_URL ?? DEFAULT_BASE_URL),
    viewport: "phone",
    headed: false,
    reportOnly: true,
    explicitReportOnly: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = () => {
      const next = argv[index + 1];
      if (next === undefined) throw new Error(`Missing value for ${arg}.`);
      index += 1;
      return next;
    };

    switch (arg) {
      case "--case":
        options.cases.push(
          ...value()
            .split(",")
            .map((name) => name.trim())
            .filter(Boolean),
        );
        break;
      case "--base-url":
        options.baseUrl = normalizeBaseUrl(value());
        break;
      case "--viewport":
        options.viewport = value();
        break;
      case "--headed":
        options.headed = true;
        break;
      case "--report-only":
        options.reportOnly = true;
        options.explicitReportOnly = true;
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!VIEWPORTS[options.viewport]) {
    throw new Error(
      `Unknown --viewport "${options.viewport}". ` +
        `Use one of: ${Object.keys(VIEWPORTS).join(", ")}.`,
    );
  }

  const unknownCases = options.cases.filter((name) => !ALL_CASE_NAMES.includes(name));
  if (unknownCases.length > 0) {
    throw new Error(
      `Unknown --case value(s): ${unknownCases.join(", ")}. ` +
        `Use one of: ${ALL_CASE_NAMES.join(", ")}.`,
    );
  }

  if (!options.explicitReportOnly && process.env.CALCO_REQUIRE_LAYOUT === "1") {
    options.reportOnly = false;
  }

  return options;
}

function readAuthEnv() {
  const required = [
    "CALCO_ADMIN_USER",
    "CALCO_ADMIN_PASSWORD",
    "CALCO_LAYOUT_USER",
    "CALCO_LAYOUT_PASSWORD",
  ];
  const missing = required.filter((name) => !process.env[name]);

  if (missing.length > 0) {
    throw new Error(
      `Missing required environment variable(s): ${missing.join(", ")}. ` +
        "Set the admin and layout test-account credentials before running the harness.",
    );
  }

  return {
    admin: {
      username: process.env.CALCO_ADMIN_USER,
      password: process.env.CALCO_ADMIN_PASSWORD,
    },
    layout: {
      username: process.env.CALCO_LAYOUT_USER,
      password: process.env.CALCO_LAYOUT_PASSWORD,
    },
  };
}

function resolveLayoutDate() {
  const requested = process.env.CALCO_LAYOUT_DATE ?? DEFAULT_LAYOUT_DATE;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(requested)) {
    throw new Error(`CALCO_LAYOUT_DATE must be YYYY-MM-DD, got "${requested}".`);
  }

  const today = new Date().toISOString().slice(0, 10);
  if (requested > today) {
    console.warn(
      `CALCO_LAYOUT_DATE ${requested} is in the future (today is ${today}); ` +
        `using ${FALLBACK_PAST_DATE} instead so the app does not clamp the route date.`,
    );
    return FALLBACK_PAST_DATE;
  }

  return requested;
}

async function ensureServerRunning(baseUrl) {
  const deadline = Date.now() + 10_000;
  let lastError = null;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/`);
      if (response.ok) return;
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await delayOnly(250);
  }

  throw new Error(
    `Could not reach ${baseUrl}. Start the app with \`just dev\` first.` +
      (lastError ? ` (${lastError.message})` : ""),
  );
}

function globToRegExp(pattern) {
  const escape = (value) => value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
  return new RegExp(`^${pattern.split("*").map(escape).join(".*")}$`);
}

function installFetchInterceptor(client) {
  const state = {
    mode: "continue",
    matchers: [],
    held: new Map(),
    pausedUrls: [],
  };
  let chain = Promise.resolve();

  const continueRequest = async (requestId) => {
    try {
      await client.send("Fetch.continueRequest", { requestId });
    } catch {
      // The request may already be gone (navigation, abort or release race).
    }
  };

  const handlePaused = async ({ requestId, request }) => {
    if (state.mode === "hold") {
      const matcher = state.matchers.find((candidate) => candidate.regex.test(request.url));
      if (matcher) {
        matcher.paused = true;
        matcher.urls.push(request.url);
        state.pausedUrls.push(request.url);
        state.held.set(requestId, { url: request.url, matcher });
        return;
      }
    }

    await continueRequest(requestId);
  };

  client.on("Fetch.requestPaused", (params) => {
    chain = chain.then(() => handlePaused(params)).catch(() => {});
  });

  return {
    hold(matchers) {
      state.mode = "hold";
      state.matchers = matchers.map((matcher) => ({
        ...matcher,
        regex: globToRegExp(matcher.pattern),
        paused: false,
        urls: [],
      }));
      state.held.clear();
      state.pausedUrls = [];
    },

    async waitForRequired(timeout = 8_000) {
      const deadline = Date.now() + timeout;
      const missing = () =>
        state.matchers
          .filter((matcher) => matcher.required && !matcher.paused)
          .map((matcher) => matcher.name);

      while (Date.now() < deadline) {
        if (missing().length === 0) return;
        await delayOnly(50);
      }

      throw new WaitTimeout(
        `Required request(s) never paused: ${missing().join(", ") || "(none)"}.`,
      );
    },

    async waitForMatcher(name, timeout = 8_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (state.matchers.some((matcher) => matcher.name === name && matcher.paused)) {
          return;
        }
        await delayOnly(50);
      }
      throw new WaitTimeout(`Request matcher "${name}" never paused.`);
    },

    async releaseAll() {
      state.mode = "continue";
      const requestIds = [...state.held.keys()];
      state.held.clear();
      await Promise.all(requestIds.map((requestId) => continueRequest(requestId)));
    },

    async continueAll() {
      state.mode = "continue";
      const requestIds = [...state.held.keys()];
      state.held.clear();
      await Promise.all(requestIds.map((requestId) => continueRequest(requestId)));
    },

    pausedUrls() {
      return [...new Set(state.pausedUrls)];
    },

    matcherStatus() {
      return state.matchers.map((matcher) => ({
        name: matcher.name,
        pattern: matcher.pattern,
        required: Boolean(matcher.required),
        paused: Boolean(matcher.paused),
        urls: matcher.urls,
      }));
    },
  };
}

async function login(client, network, credentials, baseUrl) {
  if (!credentials?.username || !credentials?.password) {
    throw new Error("Layout credentials are incomplete.");
  }

  await client.send("Network.clearBrowserCookies");
  await navigateFresh(client, `${baseUrl}/login`, network);

  const result = await evaluate(
    client,
    `(async () => {
      try {
        const response = await fetch("/api/auth/login", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({
            username: ${JSON.stringify(credentials.username)},
            password: ${JSON.stringify(credentials.password)}
          })
        });
        return { ok: response.ok, status: response.status };
      } catch (error) {
        return { ok: false, status: 0, error: String(error) };
      }
    })()`,
    true,
  );

  if (!result?.ok) {
    const status = result?.status ? `HTTP ${result.status}` : result?.error ?? "network error";
    throw new Error(`Login failed for "${credentials.username}" (${status}).`);
  }
}

function apiKeyFixtureName() {
  // Keep this under the Phone title width so the seeded key title stays one
  // line; the run prefix plus timestamp and pid still makes it unique.
  return `skel-${Date.now().toString(36)}-${process.pid}`;
}

async function createSkeletonMealFixture(client, discovered) {
  const foodId = discovered.chickenFoodId ?? discovered.customFoodId;
  if (!foodId) return null;

  const name = "CalCo Skeleton Meal";
  const result = await evaluate(
    client,
    `(async () => {
      try {
        const response = await fetch("/api/meals", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({
            name: ${JSON.stringify(name)},
            notes: null,
            total_quantity: null,
            components: [
              {
                item: { type: "product", id: ${JSON.stringify(foodId)} },
                quantity: { amount: "100", unit: "g" }
              }
            ]
          })
        });
        const text = await response.text();
        if (!response.ok) {
          return { ok: false, status: response.status, body: text.slice(0, 300) };
        }
        const data = JSON.parse(text);
        return { ok: true, id: data.id, name: data.name };
      } catch (error) {
        return { ok: false, status: 0, error: String(error) };
      }
    })()`,
    true,
  );

  if (!result?.ok || !result.id) {
    const detail =
      result?.status ? `HTTP ${result.status}` : result?.error ?? result?.body ?? "unknown error";
    console.warn(`meal-show: could not create a no-notes meal fixture (${detail}).`);
    return null;
  }

  discovered.mealId = result.id;
  discovered.mealReason = null;
  discovered.mealName = result.name ?? name;
  discovered.mealNameLength = discovered.mealName.length;
  discovered.mealNotesLength = 0;
  discovered.mealSeedSource = "fixture";
  return { id: result.id, name: discovered.mealName };
}

async function deleteSkeletonMealFixture(context, fixture) {
  const { client, network, auth, options, interceptor } = context;
  let lastFailure = null;

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      await interceptor.continueAll();
      await login(client, network, auth.layout, options.baseUrl);
      const result = await evaluate(
        client,
        `(async () => {
          try {
            const response = await fetch(
              ${JSON.stringify(`/api/meals/${encodeURIComponent(fixture.id)}`)},
              { method: "DELETE", credentials: "include" }
            );
            return { ok: response.ok, status: response.status };
          } catch (error) {
            return { ok: false, status: 0, error: String(error) };
          }
        })()`,
        true,
      );
      if (result?.ok) return;
      lastFailure = result?.status ? `HTTP ${result.status}` : result?.error ?? "unknown error";
    } catch (error) {
      lastFailure = String(error);
    }
  }

  throw new Error(
    `Could not delete the meal-show fixture "${fixture.name}" (id ${fixture.id}): ` +
      `${lastFailure ?? "unknown error"}. Remove it manually.`,
  );
}

async function createApiKeyFixture(context) {
  const { client, network, auth, options, interceptor } = context;
  const name = apiKeyFixtureName();

  await interceptor.continueAll();
  await login(client, network, auth.layout, options.baseUrl);

  const result = await evaluate(
    client,
    `(async () => {
      try {
        const response = await fetch("/api/auth/api-keys", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({
            name: ${JSON.stringify(name)},
            scope: "read_write"
          })
        });
        const text = await response.text();
        if (!response.ok) {
          return {
            ok: false,
            status: response.status,
            body: text.slice(0, 300)
          };
        }
        const data = JSON.parse(text);
        return { ok: true, id: data.id, name: data.name };
      } catch (error) {
        return { ok: false, status: 0, error: String(error) };
      }
    })()`,
    true,
  );

  if (!result?.ok || !result.id) {
    const detail =
      result?.status ? `HTTP ${result.status}` : result?.error ?? result?.body ?? "unknown error";
    throw new Error(
      `Could not create the api-keys fixture for "${name}" (${detail}). ` +
        "The api-keys case needs a layout-user key.",
    );
  }

  return { id: result.id, name: result.name ?? name };
}

async function deleteApiKeyFixture(context, fixture) {
  const { client, network, auth, options, interceptor } = context;
  let lastFailure = null;

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      await interceptor.continueAll();
      await login(client, network, auth.layout, options.baseUrl);
      const result = await evaluate(
        client,
        `(async () => {
          try {
            const response = await fetch(
              ${JSON.stringify(`/api/auth/api-keys/${encodeURIComponent(fixture.id)}`)},
              { method: "DELETE", credentials: "include" }
            );
            return { ok: response.ok, status: response.status };
          } catch (error) {
            return { ok: false, status: 0, error: String(error) };
          }
        })()`,
        true,
      );
      if (result?.ok) return;
      lastFailure = result?.status ? `HTTP ${result.status}` : result?.error ?? "unknown error";
    } catch (error) {
      lastFailure = String(error);
    }
  }

  throw new Error(
    `Could not delete the api-keys fixture "${fixture.name}" (id ${fixture.id}): ` +
      `${lastFailure ?? "unknown error"}. Remove it manually.`,
  );
}

async function discoverIds(client, layoutDate) {
  return evaluate(
    client,
    `(async () => {
      const result = {
        customFoodId: null,
        chickenFoodId: null,
        chickenFoodName: null,
        chickenFoodCategories: null,
        mealId: null,
        mealName: null,
        mealNotesLength: null,
        mealNameLength: null,
        mealSeedSource: null,
        logId: null,
        logName: null,
        logItemType: null,
        logBrand: null,
        logHasBrand: null,
        adminEditUserId: null,
        customFoodReason: null,
        chickenFoodReason: null,
        mealReason: null,
        logReason: null,
        adminEditUserReason: null
      };

      const logDate = ${JSON.stringify(layoutDate)};

      const firstId = (data) =>
        Array.isArray(data.items) && data.items[0] ? data.items[0].id : null;

      const firstWithoutCategories = (data) => {
        if (!Array.isArray(data.items)) return null;
        const zeroCategory = data.items
          .filter(
            (item) => Array.isArray(item.categories) && item.categories.length === 0,
          )
          .sort((left, right) => {
            const nameDelta = String(left.name ?? "").length - String(right.name ?? "").length;
            return nameDelta || String(left.name ?? "").localeCompare(String(right.name ?? ""));
          });
        return zeroCategory[0] ?? data.items[0] ?? null;
      };

      const itemHasBrand = (item) =>
        Boolean(
          item &&
            item.item &&
            typeof item.item.brand === "string" &&
            item.item.brand.length > 0,
        );

      const pickProductLog = (items) => {
        if (!Array.isArray(items)) return null;
        return (
          items.find(
            (item) =>
              item && item.item && item.item.type === "product" && itemHasBrand(item),
          ) ??
          items.find((item) => item && item.item && item.item.type === "product") ??
          items[0] ??
          null
        );
      };

      try {
        const response = await fetch("/api/foods/custom", { credentials: "include" });
        if (!response.ok) {
          result.customFoodReason = "GET /api/foods/custom returned HTTP " + response.status;
        } else {
          const data = await response.json();
          result.customFoodId = firstId(data);
          if (!result.customFoodId) {
            result.customFoodReason = "GET /api/foods/custom returned no items";
          }
        }
      } catch (error) {
        result.customFoodReason = "GET /api/foods/custom failed: " + String(error);
      }

      try {
        const response = await fetch("/api/foods/search?q=chicken&scope=all", {
          credentials: "include"
        });
        if (!response.ok) {
          result.chickenFoodReason =
            "GET /api/foods/search?q=chicken returned HTTP " + response.status;
        } else {
          const data = await response.json();
          const chosen = firstWithoutCategories(data);
          result.chickenFoodId = chosen ? chosen.id : null;
          result.chickenFoodName = chosen ? (chosen.name ?? null) : null;
          result.chickenFoodCategories =
            chosen && Array.isArray(chosen.categories) ? chosen.categories.length : null;
          if (!result.chickenFoodId) {
            result.chickenFoodReason = "chicken search returned no items";
          }
        }
      } catch (error) {
        result.chickenFoodReason = "chicken search failed: " + String(error);
      }

      try {
        const response = await fetch("/api/meals", { credentials: "include" });
        if (!response.ok) {
          result.mealReason = "GET /api/meals returned HTTP " + response.status;
        } else {
          const data = await response.json();
          const meals = Array.isArray(data.items) ? data.items : [];
          const notesRank = (meal) => {
            const length = meal && typeof meal.notes === "string" ? meal.notes.length : 0;
            if (length === 0) return 2;
            return length <= 40 ? 0 : 1;
          };
          const chosen =
            [...meals].sort((left, right) => {
              const byNotes = notesRank(left) - notesRank(right);
              if (byNotes !== 0) return byNotes;
              return (
                String(left.name ?? "").length - String(right.name ?? "").length ||
                String(left.name ?? "").localeCompare(String(right.name ?? ""))
              );
            })[0] ?? null;
          result.mealId = chosen ? chosen.id : null;
          result.mealName = chosen && typeof chosen.name === "string" ? chosen.name : null;
          result.mealNotesLength =
            chosen && typeof chosen.notes === "string" ? chosen.notes.length : 0;
          result.mealNameLength =
            chosen && typeof chosen.name === "string" ? chosen.name.length : null;
          result.mealSeedSource = chosen ? "existing" : null;
          if (!result.mealId) result.mealReason = "GET /api/meals returned no items";
        }
      } catch (error) {
        result.mealReason = "GET /api/meals failed: " + String(error);
      }

      try {
        let chosen = null;
        const dated = await fetch(
          "/api/logs?log_date=" + encodeURIComponent(logDate),
          { credentials: "include" }
        );
        if (dated.ok) {
          const data = await dated.json();
          chosen = pickProductLog(data.items);
        }
        if (!chosen) {
          const slots = await fetch(
            "/api/logs/latest-slots?before=" + encodeURIComponent(logDate) +
              "&lookback_days=365",
            { credentials: "include" }
          );
          if (slots.ok) {
            const data = await slots.json();
            const allItems = Array.isArray(data.slots)
              ? data.slots.flatMap((slot) =>
                  Array.isArray(slot.items) ? slot.items : [],
                )
              : [];
            chosen = pickProductLog(allItems);
          }
        }
        if (chosen) {
          result.logId = chosen.id;
          result.logName =
            chosen.item && typeof chosen.item.name === "string" ? chosen.item.name : null;
          result.logItemType = chosen.item ? (chosen.item.type ?? null) : null;
          result.logBrand =
            chosen.item && typeof chosen.item.brand === "string" ? chosen.item.brand : null;
          result.logHasBrand = itemHasBrand(chosen);
        } else {
          result.logReason =
            "No log found for " + logDate +
            " and none in the latest-slots lookback.";
        }
      } catch (error) {
        result.logReason = "Log discovery failed: " + String(error);
      }

      return result;
    })()`,
    true,
  );
}

async function discoverFoodCategoryCount(client, id) {
  return evaluate(
    client,
    `(async () => {
      try {
        const response = await fetch(
          "/api/foods/" + encodeURIComponent(${JSON.stringify(id)}),
          { credentials: "include" }
        );
        if (!response.ok) {
          return {
            count: null,
            name: null,
            reason: "GET /api/foods/{id} returned HTTP " + response.status
          };
        }
        const data = await response.json();
        return {
          count: Array.isArray(data.categories) ? data.categories.length : null,
          name: typeof data.name === "string" ? data.name : null,
          reason: null
        };
      } catch (error) {
        return {
          count: null,
          name: null,
          reason: "food category probe failed: " + String(error)
        };
      }
    })()`,
    true,
  );
}

async function discoverAdminEditUserId(client, layoutUsername) {
  const layoutLiteral = JSON.stringify(layoutUsername ?? "");
  return evaluate(
    client,
    `(async () => {
      try {
        const response = await fetch("/api/admin/users", { credentials: "include" });
        if (!response.ok) {
          return {
            id: null,
            reason: "GET /api/admin/users returned HTTP " + response.status
          };
        }
        const data = await response.json();
        const users = Array.isArray(data.users) ? data.users : [];
        const match =
          users.find((user) => user.username === "me") ??
          users.find((user) => user.username === ${layoutLiteral}) ??
          users[0];
        if (!match) {
          return {
            id: null,
            count: users.length,
            reason: "GET /api/admin/users returned an empty user list"
          };
        }
        return { id: match.id, count: users.length, reason: null };
      } catch (error) {
        return {
          id: null,
          count: null,
          reason: "GET /api/admin/users failed: " + String(error)
        };
      }
    })()`,
    true,
  );
}

function buildCases(layoutDate, discovered) {
  const date = encodeURIComponent(layoutDate);
  const diaryHolds = [
    { name: "diary-logs", pattern: "*/api/logs?log_date=*", required: true },
    { name: "diary-goal", pattern: "*/api/goal?date=*", required: true },
    { name: "latest-slots", pattern: "*/api/logs/latest-slots?*", required: true },
  ];
  const diaryFixed = {
    topbar: { axes: XYWH },
    pageRoot: { axes: XYW },
    panes: true,
    requirePanes: 1,
    pageContent: { axes: XYW },
    dateCards: { axes: XYWH },
    surfaces: { axes: XYW },
    surfaceHeaders: { axes: XYWH },
  };
  const calendarFixed = {
    topbar: { axes: XYWH },
    pageRoot: { axes: XYW },
    panes: true,
    requirePanes: 1,
    pageContent: { axes: XYW },
    surfaces: { axes: XYW },
    weekdayRows: { axes: XYWH },
  };
  const foodSeedCategories = discovered.chickenFoodCategories;
  const zeroCategoryFood = foodSeedCategories === 0;
  const foodSeed = discovered.chickenFoodId
    ? {
        id: discovered.chickenFoodId,
        name: discovered.chickenFoodName ?? null,
        categories: foodSeedCategories ?? null,
      }
    : null;
  const mealTitleSingleLine =
    discovered.mealNameLength !== null && discovered.mealNameLength <= 40;
  const mealRowStable =
    mealTitleSingleLine && discovered.mealNotesLength === 0;
  const mealSeed = discovered.mealId
    ? {
        id: discovered.mealId,
        name: discovered.mealName ?? null,
        nameLength: discovered.mealNameLength ?? null,
        notesLength: discovered.mealNotesLength ?? null,
        source: discovered.mealSeedSource ?? null,
      }
    : null;
  const logSeed = discovered.logId
    ? {
        id: discovered.logId,
        name: discovered.logName ?? null,
        itemType: discovered.logItemType ?? null,
        brand: discovered.logBrand ?? null,
        hasBrand: discovered.logHasBrand ?? null,
      }
    : null;

  const adminFooterAnchors = [
    // Footer x/width/height are stable regardless of the loaded row count; only
    // y moves when the loaded list has a different number of rows.
    { key: "listFooters", label: "admin footer box", axes: ["x", "width", "height"] },
    ...(discovered.adminUserCount === 3
      ? [{ key: "listFooters", label: "admin footer top", axes: ["y"] }]
      : []),
  ];

  return [
    {
      name: "bootstrap-auth",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: null,
      path: () => "/home",
      hold: [
        { name: "auth-session", pattern: "*/api/auth/session", required: true },
        { name: "bootstrap-status", pattern: "*/api/auth/bootstrap/status", required: true },
      ],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
      },
      anchors: [],
      nav: "bootstrap",
      loadedSelector: '[data-testid="page-content"]',
    },
    {
      name: "diary-date-gate",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => `/home?date=${date}&holdLocalCtx=1`,
      hold: diaryHolds,
      dateGate: true,
      fixed: diaryFixed,
      anchors: [{ key: "slotCards", label: "first meal-slot card" }],
      heightChecks: [
        {
          key: "mediaHeaders",
          label: "first meal-slot media header",
          expected: 118,
        },
      ],
      nav: "present",
      loadedSelector: '[data-testid="diary-date-card"]',
    },
    {
      name: "diary",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => `/home?date=${date}`,
      hold: diaryHolds,
      fixed: diaryFixed,
      anchors: [{ key: "slotCards", label: "first meal-slot card" }],
      heightChecks: [
        {
          key: "mediaHeaders",
          label: "first meal-slot media header",
          expected: 118,
        },
      ],
      nav: "present",
      loadedSelector: '[data-testid="diary-date-card"]',
    },
    {
      name: "goals",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => "/settings/goals",
      hold: [{ name: "goals-goal", pattern: "*/api/goal?date=*", required: true }],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "inputs", label: "first goals field" },
        { key: "actionPrimary", label: "first primary action" },
      ],
      heightChecks: [
        { key: "inputs", label: "first goals field wrapper", expected: 64 },
        { key: "actionPrimary", label: "first primary action", expected: 48 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="action-primary"]',
      unimplemented: [
        "The status message is data-derived. The skeleton reserves one 17px " +
          "description line, which matches the current en-US seed; longer " +
          "statuses and locales wrap and are variable, so one-line stability is " +
          "not promised.",
      ],
    },
    {
      name: "diary-settings",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => "/settings/diary",
      hold: [
        { name: "diary-preferences", pattern: "*/api/diary-preferences", required: true },
      ],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "checkboxRows", label: "first settings checkbox row" },
        { key: "actionPrimary", label: "first primary action" },
      ],
      heightChecks: [
        { key: "checkboxRows", label: "first settings checkbox row", expected: 44 },
        { key: "actionPrimary", label: "first primary action", expected: 48 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="action-primary"]',
      unimplemented: [
        "The static description is rendered as the real muted paragraph inside " +
          "the aria-hidden skeleton subtree, so its wrap and header height match; " +
          "the saved-status label swap does not change height.",
      ],
    },
    {
      name: "api-keys",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      setup: createApiKeyFixture,
      teardown: deleteApiKeyFixture,
      path: () => "/settings/api-keys",
      hold: [{ name: "api-keys", pattern: "*/api/auth/api-keys", required: true }],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "apiKeyDescriptions", label: "API keys description", axes: XYWH },
        { key: "rows", label: "first API key row", axes: XYWH },
      ],
      nav: "present",
      loadedSelector: '[data-testid="list-row"]',
      unimplemented: [
        "The key fixture is created per run and deleted in a finally step; the " +
          "backend revokes rather than hard-deletes, so a revoked row can remain " +
          "in the database.",
        "The empty API-keys case is deferred: the harness Fetch interceptor can " +
          "hold and continue requests but has no fulfillRequest response path. " +
          "The loaded empty paragraph carries data-testid=\"empty-state\" for " +
          "when that path lands.",
        "Row count, long key names, and long localized meta text remain variable " +
          "below the first-row anchor.",
      ],
    },
    {
      name: "admin-boot",
      kind: "skeleton",
      required: true,
      authRole: "admin",
      paneRole: "main",
      path: () => "/admin",
      hold: [{ name: "admin-users", pattern: "*/api/admin/users", required: true }],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [{ key: "rows", label: "first admin user row", axes: XYWH }],
      nav: "absent",
      loadedSelector: '[data-testid="list-footer"]',
    },
    {
      name: "admin-list",
      kind: "skeleton",
      required: true,
      authRole: "admin",
      paneRole: "main",
      path: () => "/admin",
      hold: [{ name: "admin-users", pattern: "*/api/admin/users", required: true }],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "rows", label: "first admin user row", axes: XYWH },
        ...adminFooterAnchors,
      ],
      nav: "absent",
      loadedSelector: '[data-testid="list-footer"]',
      unimplemented: [
        "The admin footer x/width/height are asserted; its y depends on the row count " +
          "and is only compared when the loaded user count equals the three-row " +
          `skeleton (this seed has ${discovered.adminUserCount ?? "an unknown number of"} ` +
          "user(s)).",
        "Empty admin list rendering is not covered yet: the three-row skeleton is a " +
          "populated-list over-approximation, and the loaded admin page has no " +
          "dedicated empty-state node to anchor.",
      ],
    },
    {
      name: "foods-list",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => "/foods/custom",
      hold: [{ name: "custom-foods", pattern: "*/api/foods/custom", required: true }],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [{ key: "rows", label: "first custom food row", axes: XYWH }],
      nav: "present",
      loadedSelector: '[data-testid="list-row"]',
      unimplemented: [
        "Empty custom-food list rendering is not covered yet: the three-row skeleton " +
          "is a populated-list over-approximation, and the loaded empty body collapses " +
          "to one muted paragraph.",
      ],
    },
    {
      name: "meals-list",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => "/meals",
      hold: [{ name: "meals", pattern: "*/api/meals", required: true }],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [{ key: "rows", label: "first meal row", axes: XYW }],
      minRowHeightChecks: [{ key: "rows", label: "meal row" }],
      nav: "present",
      loadedSelector: '[data-testid="list-row"]',
      unimplemented: [
        "The first seeded meal has a multi-line title, so only its top/width is " +
          "anchored; wrapping is variable. The minimum loaded row height is asserted " +
          "against the single-line skeleton row height.",
        "Empty meal list rendering is not covered yet: the three-row skeleton is a " +
          "populated-list over-approximation, and the loaded empty body collapses to " +
          "one muted paragraph.",
      ],
    },
    {
      name: "admin-edit",
      kind: "skeleton",
      optional: true,
      authRole: "admin",
      paneRole: "main",
      path: () =>
        discovered.adminEditUserId
          ? `/admin/users/${encodeURIComponent(discovered.adminEditUserId)}/edit`
          : null,
      skipReason: discovered.adminEditUserId
        ? null
        : `No admin edit target available (${discovered.adminEditUserReason ?? "discovery failed"}). ` +
          "Set CALCO_ADMIN_EDIT_USER_ID or ensure /api/admin/users returns at least one user.",
      hold: discovered.adminEditUserId
        ? [
            {
              name: "admin-user-detail",
              pattern: `*/api/admin/users/${discovered.adminEditUserId}`,
              required: true,
            },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "detailRows", label: "first detail row", axes: XYWH },
        { key: "fieldControls", label: "password field inner control", axes: ["x", "width"] },
        { key: "bottomActions", label: "first bottom action", axes: XYWH },
      ],
      heightChecks: [
        { key: "inputs", label: "password field wrapper", expected: 64 },
        { key: "fieldControls", label: "password field inner control", expected: 44 },
        { key: "bottomActions", label: "first bottom action", expected: 48 },
      ],
      nav: "absent",
      loadedSelector: '[data-testid="detail-row"]',
      unimplemented: [
        "The passing fixture uses a seeded short username; multi-line username wrapping is " +
          "outside this case's contract.",
        "paragraphLine currently models size+spacing (16/5 -> 21px), but a single-line 16px " +
          "paragraph measures ~17px. Admin Edit uses elLine 17 for its username/reset title; " +
          "revisit the primitive in a later phase.",
      ],
    },
    {
      name: "custom-food-edit",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "main",
      path: () =>
        discovered.customFoodId
          ? `/foods/custom/${encodeURIComponent(discovered.customFoodId)}/edit`
          : null,
      skipReason: discovered.customFoodId
        ? null
        : `No custom food id available (${discovered.customFoodReason ?? "discovery failed"}). ` +
          "Set CALCO_CUSTOM_FOOD_ID or seed a custom food.",
      hold: discovered.customFoodId
        ? [
            {
              name: "custom-food-detail",
              pattern: `*/api/foods/${discovered.customFoodId}`,
              required: true,
            },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "inputs", label: "first field" },
        { key: "fieldControls", label: "first field inner control", axes: ["x", "width"] },
      ],
      heightChecks: [
        { key: "inputs", label: "first text field wrapper", expected: 64 },
        { key: "selectFields", label: "first select field wrapper", expected: 61 },
        { key: "fieldControls", label: "first field inner control", expected: 44 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="action-primary"]',
      unimplemented: [
        "Text-field wrappers measure 64px (label 13 + 7 gap + 44). Category, nutrient rows " +
          "and save remain below variable content and are not asserted.",
      ],
    },
    {
      name: "meal-edit",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "main",
      path: () =>
        discovered.mealId ? `/meals/${encodeURIComponent(discovered.mealId)}/edit` : null,
      skipReason: discovered.mealId
        ? null
        : `No meal id available (${discovered.mealReason ?? "discovery failed"}). ` +
          "Set CALCO_MEAL_ID or seed a meal.",
      hold: discovered.mealId
        ? [
            {
              name: "meal-detail",
              pattern: `*/api/meals/${discovered.mealId}`,
              required: true,
            },
            { name: "units", pattern: "*/api/units", required: true },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [
        { key: "inputs", label: "first field" },
        { key: "componentRows", label: "first meal component row", axes: XYWH },
      ],
      heightChecks: [
        { key: "inputs", label: "first text field wrapper", expected: 64 },
        { key: "selectFields", label: "first select field wrapper", expected: 61 },
        { key: "fieldControls", label: "first field inner control", expected: 44 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="action-primary"]',
      unimplemented: [
        "Text-field wrappers measure 64px (label 13 + 7 gap + 44). The component row height " +
          "is compared (143px in this fixture); the nutrition card and save remain below " +
          "variable content and are not asserted.",
      ],
    },
    {
      name: "food-show",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "detail",
      path: () =>
        discovered.chickenFoodId
          ? `/foods/${encodeURIComponent(discovered.chickenFoodId)}` +
            `?date=${date}&meal_slot=breakfast`
          : null,
      skipReason: discovered.chickenFoodId
        ? null
        : `No food id available (${discovered.chickenFoodReason ?? "discovery failed"}). ` +
          "Set CALCO_FOOD_ID or seed a chicken food.",
      hold: discovered.chickenFoodId
        ? [
            {
              name: "food-detail",
              pattern: `*/api/foods/${discovered.chickenFoodId}`,
              required: true,
            },
            { name: "units", pattern: "*/api/units", required: true },
            { name: "last-used", pattern: "*/api/logs/last-used", required: true },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      seed: foodSeed,
      requiresZeroCategorySeed: true,
      anchors: zeroCategoryFood
        ? [
            { key: "pageHeader", label: "panel header", axes: XYWH },
            { key: "inputs", label: "first portion control", axes: XYWH },
            { key: "nutritionCards", label: "nutrition card top" },
          ]
        : [{ key: "pageHeader", label: "panel header", axes: XYWH }],
      heightChecks: zeroCategoryFood
        ? [
            {
              key: "selectFields",
              index: 0,
              label: "meal-slot select wrapper",
              expected: 61,
            },
            {
              key: "inputs",
              index: 1,
              label: "quantity amount field wrapper",
              expected: 64,
            },
            {
              key: "selectFields",
              index: 1,
              label: "quantity unit select wrapper",
              expected: 61,
            },
            {
              key: "inputs",
              index: 3,
              label: "notes field wrapper",
              expected: 64,
            },
          ]
        : [],
      nav: "present",
      loadedSelector: '[data-testid="nutrition-card"]',
      unimplemented: [
        ...(zeroCategoryFood
          ? []
          : [
              `Seed has ${foodSeedCategories ?? "unknown"} categories: first portion ` +
                "control and nutrition-card top assertions were skipped. Set " +
                "CALCO_FOOD_ID to a zero-category food for full coverage; required " +
                "mode fails this case.",
            ]),
        "The skeleton represents the no-category food. A category section pushes the " +
          "portion form and everything below it down.",
      ],
    },
    {
      name: "custom-food-show",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "detail",
      path: () =>
        discovered.customFoodId
          ? `/foods/custom/${encodeURIComponent(discovered.customFoodId)}`
          : null,
      skipReason: discovered.customFoodId
        ? null
        : `No custom food id available (${discovered.customFoodReason ?? "discovery failed"}). ` +
          "Set CALCO_CUSTOM_FOOD_ID or seed a custom food.",
      hold: discovered.customFoodId
        ? [
            {
              name: "custom-food-detail",
              pattern: `*/api/foods/${discovered.customFoodId}`,
              required: true,
            },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: { axes: XYWH },
      },
      anchors: [{ key: "pageHeader", label: "header title line", axes: XYWH }],
      nav: "present",
      loadedSelector: '[data-testid="nutrition-card"]',
      unimplemented: [
        "The category chip row is an over-approximation for custom foods without " +
          "categories. Nutrition and the action row sit below the variable category " +
          "row and are not asserted.",
      ],
    },
    {
      name: "meal-show",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "detail",
      path: () => (discovered.mealId ? `/meals/${encodeURIComponent(discovered.mealId)}` : null),
      skipReason: discovered.mealId
        ? null
        : `No meal id available (${discovered.mealReason ?? "discovery failed"}). ` +
          "Set CALCO_MEAL_ID or seed a meal.",
      hold: discovered.mealId
        ? [
            {
              name: "meal-detail",
              pattern: `*/api/meals/${discovered.mealId}`,
              required: true,
            },
            {
              name: "meal-nutrients",
              pattern: `*/api/meals/${discovered.mealId}/nutrients?*`,
              required: true,
            },
            { name: "units", pattern: "*/api/units", required: true },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContainer: { axes: XYW },
        pageContent: { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders: mealTitleSingleLine ? { axes: XYWH } : { axes: XYW },
      },
      seed: mealSeed,
      anchors: mealRowStable
        ? [{ key: "componentRows", label: "first meal component row", axes: XYWH }]
        : [
            {
              key: "componentRows",
              label: "first meal component row height",
              axes: ["height"],
            },
          ],
      heightChecks: [
        { key: "inputs", index: 0, label: "nutrition amount field", expected: 64 },
        { key: "selectFields", index: 0, label: "nutrition unit select", expected: 61 },
        { key: "fieldControls", index: 0, label: "nutrition amount inner control", expected: 44 },
        { key: "bottomActions", label: "first bottom action", expected: 48 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="page-header"]',
      unimplemented: [
        ...(mealRowStable
          ? []
          : [
              "No suitable no-notes meal seed was available, so the components-" +
                "section top is variable. Only the first component row height, " +
                "header x/y/width and the bottom action height were asserted; seed " +
                "or allow the harness to create a short-name, no-notes meal for full " +
                "coverage.",
            ]),
        "Component count and nutrition-card top sit below variable content and are " +
          "not asserted. The skeleton always shows two component rows as an " +
          "over-approximation.",
      ],
    },
    {
      name: "food-log",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "detail",
      path: () =>
        discovered.logId ? `/logs/${encodeURIComponent(discovered.logId)}` : null,
      skipReason: discovered.logId
        ? null
        : `No log id available (${discovered.logReason ?? "discovery failed"}). ` +
          "Set CALCO_LOG_ID or seed a log.",
      hold: discovered.logId
        ? [
            {
              name: "log-detail",
              pattern: `*/api/logs/${discovered.logId}`,
              required: true,
            },
            { name: "units", pattern: "*/api/units", required: true },
          ]
        : [],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
        pageHeader:
          discovered.logItemType === "product" && discovered.logHasBrand
            ? { axes: XYWH }
            : { axes: XYW },
        surfaces: { axes: XYW },
        surfaceHeaders:
          discovered.logItemType === "product" && discovered.logHasBrand
            ? { axes: XYWH }
            : { axes: XYW },
      },
      seed: logSeed,
      anchors: [
        {
          key: "pageHeader",
          label: "panel header",
          axes:
            discovered.logItemType === "product" && discovered.logHasBrand
              ? XYWH
              : XYW,
        },
      ],
      heightChecks: [
        { key: "selectFields", index: 0, label: "meal-slot select wrapper", expected: 61 },
        { key: "inputs", index: 1, label: "quantity amount field wrapper", expected: 64 },
        { key: "selectFields", index: 1, label: "quantity unit select wrapper", expected: 61 },
        { key: "inputs", index: 3, label: "notes field wrapper", expected: 64 },
        { key: "bottomActions", index: 0, label: "first footer action", expected: 48 },
      ],
      countChecks: [
        { key: "bottomActions", label: "footer action count", expected: 2 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="nutrition-card"]',
      unimplemented: [
        ...(discovered.logItemType === "product" && discovered.logHasBrand
          ? []
          : [
              "The Phone header reserves two subtitle lines, but this seed is " +
                `${discovered.logItemType ?? "an unknown item type"} with ` +
                `${discovered.logHasBrand ? "" : "no "}brand. The loaded subtitle may ` +
                "collapse to one line, so only the header x/y/width are asserted; " +
                "seed a branded product log for full header-band coverage.",
            ]),
        "Category chips are optional and unknown while loading. A log with " +
          "categories pushes the portion section and footer down; category, footer " +
          "position and nutrition-card top sit below variable content and are not " +
          "asserted.",
      ],
    },
    {
      name: "nutrition-details",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "detail",
      path: () => `/details?date=${date}`,
      hold: [
        {
          name: "nutrition-details",
          pattern: "*/api/nutrition/details?date=*",
          required: true,
        },
      ],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
      },
      anchors: [
        { key: "dateHeaders", label: "date header", axes: XYWH },
        { key: "coverageBanners", label: "coverage banner", axes: XYWH },
        { key: "nutritionOverviews", label: "overview section top" },
        { key: "stats", index: 0, label: "first overview stat width", axes: ["width"] },
        { key: "stats", index: 3, label: "last overview stat width", axes: ["width"] },
        { key: "nutrientSections", label: "first nutrient section top" },
      ],
      countChecks: [
        { key: "stats", label: "overview stat count", expected: 4 },
        { key: "nutrientSections", label: "nutrient section count", expected: 4 },
        { key: "nutritionReferences", label: "reference section count", expected: 1 },
      ],
      heightChecks: [
        { key: "stats", index: 0, label: "first overview stat", expected: 73 },
      ],
      nav: "present",
      loadedSelector: '[data-testid="coverage-banner"]',
      unimplemented: [
        "The coverage banner text is data-derived. The skeleton reserves the " +
          "seeded one-line desktop / two-line phone banner shell; a longer " +
          "localized message is variable and pushes the overview down.",
        "The third stat line is always reserved, so complete, partial and no " +
          "coverage tiles share the same height. Long localized coverage labels " +
          "can wrap and are variable.",
        "The number of nutrient rows is data-derived. Only the first nutrient " +
          "section top is asserted; rows below the first section are variable.",
      ],
    },
    {
      name: "search",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "detail",
      path: () =>
        discovered.chickenFoodId
          ? `/search?date=${date}&meal_slot=breakfast`
          : null,
      skipReason: discovered.chickenFoodId
        ? null
        : `No seeded food search result (${discovered.chickenFoodReason ?? "discovery failed"}). ` +
          "Set CALCO_FOOD_ID or seed a food matching \"chicken\".",
      hold: [
        {
          name: "recent-items",
          pattern: "*/api/logs/recent-items?*",
          required: true,
        },
        {
          name: "foods-search",
          pattern: "*/api/foods/search?*",
          required: false,
        },
      ],
      searchQuery: "chicken",
      searchQueryMatcher: "foods-search",
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
      },
      anchors: [
        { key: "searchControls", label: "search controls", axes: XYWH },
        { key: "searchResults", label: "results section top" },
        { key: "rows", label: "first result row top" },
      ],
      nav: "present",
      loadedSelector: '[data-testid="search-results"]',
      unimplemented: [
        "Search controls are real in both captures; only the results slot is an " +
          "in-place skeleton. Result category chips are omitted from the skeleton " +
          "because they depend on the matched food.",
        "The recents slot is covered by the separate search-recents case.",
      ],
    },
    {
      name: "search-recents",
      kind: "skeleton",
      optional: true,
      authRole: "layout",
      paneRole: "detail",
      path: () =>
        discovered.chickenFoodId
          ? `/search?date=${date}&meal_slot=breakfast`
          : null,
      skipReason: discovered.chickenFoodId
        ? null
        : `No seeded food search result (${discovered.chickenFoodReason ?? "discovery failed"}).`,
      hold: [
        {
          name: "recent-items",
          pattern: "*/api/logs/recent-items?*",
          required: true,
        },
      ],
      fixed: {
        topbar: { axes: XYWH },
        pageRoot: { axes: XYW },
        panes: true,
        requirePanes: 1,
        pageContent: { axes: XYW },
      },
      anchors: [
        { key: "searchControls", label: "search controls", axes: XYWH },
        { key: "searchRecents", label: "recents section top" },
        { key: "recentItems", label: "first recents item", axes: XYWH },
      ],
      nav: "present",
      loadedSelector: '[data-testid="search-recents"]',
      unimplemented: [
        "The item height is compared for the first single-line recent. Multi-line " +
          "recent titles and a different quick-add chip count are variable below " +
          "the first item.",
      ],
    },
    {
      name: "calendar",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => "/calendar",
      hold: [{ name: "calendar-summary", pattern: "*/api/logs/summary?*", required: true }],
      fixed: calendarFixed,
      anchors: [{ key: "weekdayRows", label: "calendar weekday row" }],
      nav: "present",
      loadedSelector: '[data-testid="calendar-grid"]',
    },
    {
      // An invalid month exercises `Page.calendarPlan`'s validMonth
      // normalization and the generic period=None, rows=5 boot shell. The
      // loaded page falls back to the current month, so month/row count is
      // deliberately variable across states.
      name: "calendar-date-gate",
      kind: "skeleton",
      required: true,
      authRole: "layout",
      paneRole: "main",
      path: () => "/calendar?month=garbage&holdLocalCtx=1",
      hold: [{ name: "calendar-summary", pattern: "*/api/logs/summary?*", required: true }],
      dateGate: true,
      fixed: calendarFixed,
      anchors: [{ key: "weekdayRows", label: "calendar weekday row" }],
      nav: "present",
      loadedSelector: '[data-testid="calendar-grid"]',
    },
    {
      name: "transition-scroll",
      kind: "scroll",
      required: true,
      authRole: "layout",
      paneRole: "main",
      viewportHeight: 500,
      longPath: () => `/home?date=${date}`,
      longLoadedSelector: '[data-testid="diary-date-card"]',
      targetLoadedSelector: '[data-testid="search-controls"]',
      targetPaneRole: "detail",
      targetPath: "/search",
      nav: "present",
      skipTargetTallViewports: ["desktop"],
      unimplemented: [
        "In-place retry at scroll 400 needs a failure-retry route; deferred.",
        "On Desktop the target /search page is exactly one 500px viewport tall, " +
          "so the tall-target scroll-reset guard is not applicable; navigation " +
          "method, route and scroll reset are still asserted.",
      ],
    },
  ];
}

const CAPTURE_EXPRESSION = `(() => {
  const box = (element) => {
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  };
  const visible = (element) => getComputedStyle(element).display !== "none";
  const paneElements = [...document.querySelectorAll('[data-testid="workspace-pane"]')]
    .filter(visible);
  const within = (pane, id) =>
    [...pane.querySelectorAll('[data-testid="' + id + '"]')].map(box);
  const panes = paneElements.map((pane) => ({
    role: pane.getAttribute("data-pane"),
    box: box(pane),
    pageContent: within(pane, "page-content"),
    pageHeader: within(pane, "page-header"),
    surfaces: within(pane, "surface"),
    surfaceHeaders: within(pane, "surface-header"),
    rows: within(pane, "list-row"),
    listFooters: within(pane, "list-footer"),
    detailRows: within(pane, "detail-row"),
    componentRows: within(pane, "component-row"),
    stats: within(pane, "stat"),
    nutritionCards: within(pane, "nutrition-card"),
    dateCards: within(pane, "diary-date-card"),
    slotCards: within(pane, "meal-slot-card"),
    calendars: within(pane, "calendar-grid"),
    weekdayRows: within(pane, "calendar-weekdays"),
    emptyStates: within(pane, "empty-state"),
    errorBanners: within(pane, "error-banner"),
    searchControls: within(pane, "search-controls"),
    searchResults: within(pane, "search-results"),
    searchRecents: within(pane, "search-recents"),
    dateHeaders: within(pane, "date-header"),
    coverageBanners: within(pane, "coverage-banner"),
    nutritionOverviews: within(pane, "nutrition-overview"),
    nutrientSections: within(pane, "nutrient-section"),
    nutritionReferences: within(pane, "nutrition-reference"),
    recentItems: within(pane, "recent-item"),
    actionPrimary: within(pane, "action-primary"),
    bottomActions: within(pane, "bottom-action"),
    inputs: within(pane, "field"),
    fieldControls: within(pane, "field-control"),
    checkboxRows: within(pane, "checkbox-row"),
    apiKeyDescriptions: within(pane, "api-keys-description"),
    selectFields: [
      ...pane.querySelectorAll('[data-testid="field"][data-field-kind="select"]'),
    ].map(box),
    controls: [...pane.querySelectorAll("input, select, textarea")].map(box),
    mediaHeaders: [
      ...pane.querySelectorAll(
        '[data-testid="meal-slot-card"] [data-testid="surface-header"]'
      ),
    ].map(box),
    skeletonRegions: pane.querySelectorAll('[data-skeleton-region]').length,
    pageSkeletons: pane.querySelectorAll('[data-skeleton-page]').length,
    pageLoaded: pane.querySelector('[data-page-loaded="true"]') !== null,
  }));
  const pageRoot = document.querySelector('[data-testid="page-root"]');
  const calendarGeometry = [...document.querySelectorAll('[data-testid="calendar-grid"]')]
    .filter(visible)
    .map((grid) => {
      const rows = [...grid.children];
      const cells = rows.flatMap((row) => [...row.children]);
      return {
        grid: box(grid),
        clientWidth: grid.clientWidth,
        scrollWidth: grid.scrollWidth,
        cellCount: cells.length,
        rowCount: rows.length,
        firstRow: box(rows[0]),
        secondRow: box(rows[1]),
        firstCell: box(cells[0]),
      };
    });
  return {
    viewport: { width: innerWidth, height: innerHeight },
    url: location.pathname + location.search,
    scrollY: window.scrollY,
    docHeight: document.documentElement.scrollHeight,
    topbar: box(document.querySelector('[data-testid="app-topbar"]')),
    bottomNav: box(document.querySelector('[data-testid="app-bottom-nav"]')),
    pageRoot: box(pageRoot),
    pageContainer: box(document.querySelector('[data-testid="page-container"]')),
    panes,
    calendarGeometry,
    skeletonRegions: document.querySelectorAll('[data-skeleton-region]').length,
    pageSkeletons: document.querySelectorAll('[data-skeleton-page]').length,
    pageRootSkeletons: pageRoot
      ? pageRoot.querySelectorAll('[data-skeleton-region]').length
      : null,
    focusableInSkeleton: document.querySelectorAll(
      '[data-skeleton-region] button, [data-skeleton-region] a, ' +
        '[data-skeleton-region] input, [data-skeleton-region] select, ' +
        '[data-skeleton-region] textarea, ' +
        '[data-skeleton-region] [contenteditable]:not([contenteditable="false"]), ' +
        '[data-skeleton-region] [tabindex]:not([tabindex="-1"])'
    ).length,
    pageLoaded: document.querySelector('[data-page-loaded="true"]') !== null,
    updateBanner: document.querySelector('[data-testid="update-banner"]') !== null,
  };
})()`;

const CAPTURE_STYLES = `(() => {
  let style = document.getElementById("calco-skeleton-stability-styles");
  if (!style) {
    style = document.createElement("style");
    style.id = "calco-skeleton-stability-styles";
    document.head.appendChild(style);
  }
  style.textContent =
    "*, *::before, *::after { transition: none !important; animation: none !important; " +
    "caret-color: transparent !important; scroll-behavior: auto !important; } " +
    "html, body { scrollbar-width: none !important; } " +
    "::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }";
  return true;
})()`;

async function prepareCapture(client) {
  await evaluate(client, CAPTURE_STYLES);
  await evaluate(
    client,
    `(async () => {
      if (document.fonts && document.fonts.ready) await document.fonts.ready;
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return true;
    })()`,
    true,
  );
  await delayOnly(50);
}

async function captureState(client, { resetScroll = true } = {}) {
  const scrollBeforeReset = await evaluate(client, "window.scrollY");
  if (resetScroll) await evaluate(client, "window.scrollTo(0, 0)");
  await prepareCapture(client);
  const state = await evaluate(client, CAPTURE_EXPRESSION);
  state.scrollBeforeReset = scrollBeforeReset;
  return state;
}

async function waitUntil(client, expression, description, timeout = 8_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(client, expression)) return;
    } catch {
      // The execution context can be replaced during navigation.
    }
    await delayOnly(50);
  }
  throw new WaitTimeout(`Timed out waiting for ${description}.`);
}

function scopeSelector(paneRole) {
  return paneRole
    ? `[data-testid="workspace-pane"][data-pane="${paneRole}"]`
    : '[data-testid="page-root"]';
}

function scopedSkeletonExpression(paneRole) {
  const scope = JSON.stringify(scopeSelector(paneRole));
  return `(() => {
    const scope = document.querySelector(${scope});
    return Boolean(scope && scope.querySelectorAll('[data-skeleton-region]').length > 0);
  })()`;
}

async function waitForScopedSkeleton(client, paneRole, timeout = 8_000) {
  await waitUntil(
    client,
    scopedSkeletonExpression(paneRole),
    paneRole ? `a skeleton in the ${paneRole} pane` : "a page-root skeleton",
    timeout,
  );
}

async function ensureSkeletonStillPresent(client, paneRole) {
  const present = await evaluate(client, scopedSkeletonExpression(paneRole));
  if (!present) {
    throw new WaitTimeout("The route skeleton disappeared before capture.");
  }
}

async function waitForLoaded(client, selector, paneRole, timeout = 12_000) {
  const scope = JSON.stringify(scopeSelector(paneRole));
  const selectorJson = JSON.stringify(selector);
  await waitUntil(
    client,
    `(() => {
      const scope = document.querySelector(${scope});
      if (!scope) return false;
      if (scope.querySelectorAll('[data-skeleton-region]').length !== 0) return false;
      return scope.matches(${selectorJson}) || Boolean(scope.querySelector(${selectorJson}));
    })()`,
    `the loaded state (${selector})`,
    timeout,
  );
}

async function waitForPaneCount(client, count, timeout = 8_000) {
  if (!count) return;
  await waitUntil(
    client,
    `document.querySelectorAll('[data-testid="workspace-pane"]').length >= ${count}`,
    `at least ${count} visible workspace pane(s)`,
    timeout,
  );
}

async function typeSearchQuery(client, query, timeout = 8_000) {
  await waitUntil(
    client,
    `Boolean(document.querySelector('[data-testid="search-controls"] input'))`,
    "the food-search input",
    timeout,
  );
  await evaluate(
    client,
    `(() => {
      const input = document.querySelector('[data-testid="search-controls"] input');
      const setter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype,
        "value",
      ).set;
      input.focus();
      setter.call(input, ${JSON.stringify(query)});
      input.dispatchEvent(new Event("input", { bubbles: true }));
      return input.value;
    })()`,
  );
}

async function settleNetwork(network) {
  try {
    await network.waitForIdle(20_000);
  } catch (error) {
    if (/Timed out/i.test(error.message)) throw new WaitTimeout(error.message);
    throw error;
  }
}

async function navigateFresh(client, url, network) {
  await network.start(null);
  const loaded = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      offLoad();
      reject(new WaitTimeout(`Timed out navigating to ${url}.`));
    }, 20_000);
    const offLoad = client.on("Page.loadEventFired", () => {
      clearTimeout(timer);
      offLoad();
      resolve();
    });
  });

  const result = await client.send("Page.navigate", { url });
  if (result.errorText) {
    throw new Error(`Could not navigate to ${url}: ${result.errorText}`);
  }
  network.start(result.loaderId);
  await loaded;
  await waitUntil(client, "document.readyState === 'complete'", "document load", 20_000);
}

function withinTolerance(actual, expected, tolerance) {
  return Number.isFinite(actual) && Number.isFinite(expected)
    ? Math.abs(actual - expected) <= tolerance
    : false;
}

function record(assertions, details) {
  assertions.push({
    name: details.name,
    passed: Boolean(details.passed),
    expected: details.expected,
    actual: details.actual,
    tolerance: details.tolerance ?? 0,
    message: details.passed ? null : details.message ?? "assertion failed",
  });
}

function paneRoles(capture) {
  return capture.panes.map((pane) => pane.role);
}

function findPane(capture, role) {
  return capture.panes.find((pane) => pane.role === role);
}

function firstAcrossPanes(capture, key) {
  for (const pane of capture.panes) {
    const values = pane[key];
    if (Array.isArray(values) && values.length > 0) return values[0];
  }
  return null;
}

function allAcrossPanes(capture, key) {
  for (const pane of capture.panes) {
    const values = pane[key];
    if (Array.isArray(values) && values.length > 0) return values;
  }
  return [];
}

function scopedSkeletonCount(capture, paneRole) {
  if (paneRole) {
    const pane = findPane(capture, paneRole);
    return pane ? pane.skeletonRegions : null;
  }
  return capture.pageRootSkeletons;
}

function compareBox(assertions, name, loadingBox, loadedBox, tolerance, axes = XYWH) {
  if (!loadingBox || !loadedBox) {
    record(assertions, {
      name: `${name} present in both captures`,
      passed: false,
      expected: "present in both captures",
      actual:
        `loading=${loadingBox ? "present" : "missing"}, ` +
        `loaded=${loadedBox ? "present" : "missing"}`,
      tolerance,
      message: `Missing landmark: ${name}`,
    });
    return;
  }

  for (const field of axes) {
    const expected = loadingBox[field];
    const actual = loadedBox[field];
    const delta = actual - expected;
    record(assertions, {
      name: `${name} ${field}`,
      passed: withinTolerance(actual, expected, tolerance),
      expected,
      actual,
      tolerance,
      message: `${name} ${field} moved ${delta.toFixed(2)}px (tolerance ${tolerance}px)`,
    });
  }
}

function compareAnchor(assertions, name, loadingBox, loadedBox, tolerance, axes = XYW) {
  if (!loadingBox || !loadedBox) {
    record(assertions, {
      name: `${name} present in both captures`,
      passed: false,
      expected: "present in both captures",
      actual:
        `loading=${loadingBox ? "present" : "missing"}, ` +
        `loaded=${loadedBox ? "present" : "missing"}`,
      tolerance,
      message: `Missing anchor: ${name}`,
    });
    return;
  }

  for (const field of axes) {
    const expected = loadingBox[field];
    const actual = loadedBox[field];
    const delta = actual - expected;
    record(assertions, {
      name: `${name} ${field}`,
      passed: withinTolerance(actual, expected, tolerance),
      expected,
      actual,
      tolerance,
      message: `${name} ${field} moved ${delta.toFixed(2)}px (tolerance ${tolerance}px)`,
    });
  }
}

const NESTED_FIXED_KEYS = [
  ["pageContent", "pageContent"],
  ["pageHeader", "pageHeader"],
  ["dateCards", "dateCards"],
  ["surfaces", "surfaces"],
  ["surfaceHeaders", "surfaceHeaders"],
  ["weekdayRows", "weekdayRows"],
];

function fixedAxes(spec, fallback = XYW) {
  return Array.isArray(spec?.axes) ? spec.axes : fallback;
}

function assertEnvelope(caseDef, loading, loaded, assertions) {
  const fixed = caseDef.fixed ?? {};
  const tolerance = 1;

  if (fixed.topbar) {
    compareBox(
      assertions,
      "topbar",
      loading.topbar,
      loaded.topbar,
      tolerance,
      fixedAxes(fixed.topbar, XYWH),
    );
  }
  if (fixed.pageRoot) {
    compareBox(
      assertions,
      "page-root",
      loading.pageRoot,
      loaded.pageRoot,
      tolerance,
      fixedAxes(fixed.pageRoot),
    );
  }
  if (fixed.pageContainer) {
    compareBox(
      assertions,
      "page-container",
      loading.pageContainer,
      loaded.pageContainer,
      tolerance,
      fixedAxes(fixed.pageContainer),
    );
  }

  if (fixed.requirePanes !== undefined) {
    for (const [label, capture] of [
      ["loading", loading],
      ["loaded", loaded],
    ]) {
      record(assertions, {
        name: `${label} workspace pane present`,
        passed: capture.panes.length >= fixed.requirePanes,
        expected: `>= ${fixed.requirePanes} visible workspace pane(s)`,
        actual: capture.panes.length,
        tolerance: 0,
        message: `${label} has ${capture.panes.length} visible workspace pane(s)`,
      });
    }
  }

  if (fixed.panes) {
    const loadingRoles = paneRoles(loading);
    const loadedRoles = paneRoles(loaded);
    record(assertions, {
      name: "pane roles/count match",
      passed: JSON.stringify(loadingRoles) === JSON.stringify(loadedRoles),
      expected: loadingRoles,
      actual: loadedRoles,
      tolerance: 0,
      message:
        `Pane roles changed: loading=${loadingRoles.join(",")} ` +
        `loaded=${loadedRoles.join(",")}`,
    });

    const roles = [...new Set([...loadingRoles, ...loadedRoles])];
    for (const role of roles) {
      const loadingPane = findPane(loading, role);
      const loadedPane = findPane(loaded, role);
      compareBox(
        assertions,
        `pane[${role}]`,
        loadingPane?.box,
        loadedPane?.box,
        tolerance,
        XYW,
      );

      for (const [configKey, captureKey] of NESTED_FIXED_KEYS) {
        const spec = fixed[configKey];
        if (!spec) continue;
        const loadingBox = loadingPane?.[captureKey]?.[0] ?? null;
        const loadedBox = loadedPane?.[captureKey]?.[0] ?? null;
        compareBox(
          assertions,
          `pane[${role}].${captureKey}[0]`,
          loadingBox,
          loadedBox,
          tolerance,
          fixedAxes(spec),
        );
      }
    }
  }
}

function shouldSkip(spec, viewportName) {
  return (spec.skipViewports ?? []).includes(viewportName);
}

function assertAnchors(caseDef, loading, loaded, assertions, viewportName) {
  const tolerance = 1;
  for (const anchor of caseDef.anchors ?? []) {
    if (shouldSkip(anchor, viewportName)) continue;
    const loadingBox =
      anchor.index === undefined
        ? firstAcrossPanes(loading, anchor.key)
        : allAcrossPanes(loading, anchor.key)[anchor.index] ?? null;
    const loadedBox =
      anchor.index === undefined
        ? firstAcrossPanes(loaded, anchor.key)
        : allAcrossPanes(loaded, anchor.key)[anchor.index] ?? null;
    compareAnchor(
      assertions,
      anchor.label,
      loadingBox,
      loadedBox,
      tolerance,
      anchor.axes ?? XYW,
    );
  }
}

function assertHeightChecks(caseDef, loading, loaded, assertions, viewportName) {
  const tolerance = 1;
  for (const check of caseDef.heightChecks ?? []) {
    if (shouldSkip(check, viewportName)) continue;
    const index = check.index ?? 0;
    const loadingBox = allAcrossPanes(loading, check.key)[index] ?? null;
    const loadedBox = allAcrossPanes(loaded, check.key)[index] ?? null;
    if (!loadingBox || !loadedBox) {
      record(assertions, {
        name: `${check.label} height present in both captures`,
        passed: false,
        expected: `${check.expected}px in both captures`,
        actual:
          `loading=${loadingBox?.height ?? "missing"}, ` +
          `loaded=${loadedBox?.height ?? "missing"}`,
        tolerance,
        message: `Missing height landmark: ${check.label}`,
      });
      continue;
    }

    for (const [label, box] of [
      ["loading", loadingBox],
      ["loaded", loadedBox],
    ]) {
      record(assertions, {
        name: `${label} ${check.label} height`,
        passed: withinTolerance(box.height, check.expected, tolerance),
        expected: check.expected,
        actual: box.height,
        tolerance,
        message: `${label} ${check.label} height was ${box.height}`,
      });
    }
  }
}

function assertCountChecks(caseDef, loading, loaded, assertions) {
  for (const check of caseDef.countChecks ?? []) {
    for (const [label, capture] of [
      ["loading", loading],
      ["loaded", loaded],
    ]) {
      const count = allAcrossPanes(capture, check.key).length;
      record(assertions, {
        name: `${label} ${check.label}`,
        passed: count === check.expected,
        expected: check.expected,
        actual: count,
        tolerance: 0,
        message: `${label} ${check.label} was ${count}`,
      });
    }
  }
}

function assertMinRowHeights(caseDef, loading, loaded, assertions) {  const tolerance = 1;
  for (const check of caseDef.minRowHeightChecks ?? []) {
    const loadingRows = allAcrossPanes(loading, check.key);
    const loadedRows = allAcrossPanes(loaded, check.key);
    const loadingMin = loadingRows.length
      ? Math.min(...loadingRows.map((row) => row.height))
      : null;
    const loadedMin = loadedRows.length
      ? Math.min(...loadedRows.map((row) => row.height))
      : null;
    record(assertions, {
      name: `${check.label} minimum row height`,
      passed:
        loadingMin !== null &&
        loadedMin !== null &&
        withinTolerance(loadedMin, loadingMin, tolerance),
      expected: loadingMin,
      actual: loadedMin,
      tolerance,
      message:
        `${check.label}: skeleton minimum ${loadingMin}, ` +
        `loaded minimum ${loadedMin}`,
    });
  }
}

function assertChrome(caseDef, viewportName, loading, loaded, assertions) {
  for (const [label, capture] of [
    ["loading", loading],
    ["loaded", loaded],
  ]) {
    if (!capture.topbar) {
      record(assertions, {
        name: `${label} topbar present`,
        passed: false,
        expected: "app-topbar element",
        actual: "missing",
        tolerance: 0,
        message: `${label} is missing app-topbar`,
      });
    } else {
      for (const [field, expected, tolerance] of [
        ["x", 0, 1],
        ["y", 0, 1],
        ["width", capture.viewport.width, 1],
        ["height", 58, 1],
      ]) {
        record(assertions, {
          name: `${label} topbar ${field}`,
          passed: withinTolerance(capture.topbar[field], expected, tolerance),
          expected,
          actual: capture.topbar[field],
          tolerance,
          message: `${label} topbar ${field} was ${capture.topbar[field]}`,
        });
      }
    }
  }

  if (caseDef.nav === "bootstrap") {
    record(assertions, {
      name: "bootstrap-auth loading has no bottom nav",
      passed: loading.bottomNav === null,
      expected: "no bottom nav while bootstrapping",
      actual: loading.bottomNav ? "present" : "absent",
      tolerance: 0,
      message: "bootstrap-auth must not show the bottom nav while auth is held",
    });
    return;
  }

  const isPhone = viewportName === "phone";
  if (!isPhone || caseDef.nav === "absent") {
    for (const [label, capture] of [
      ["loading", loading],
      ["loaded", loaded],
    ]) {
      record(assertions, {
        name: `${label} bottom nav absent`,
        passed: capture.bottomNav === null,
        expected: "no bottom nav",
        actual: capture.bottomNav ? "present" : "absent",
        tolerance: 0,
        message: `${label} bottom nav must be absent`,
      });
    }
    return;
  }

  if (caseDef.nav === "present") {
    for (const [label, capture] of [
      ["loading", loading],
      ["loaded", loaded],
    ]) {
      if (!capture.bottomNav) {
        record(assertions, {
          name: `${label} bottom nav present`,
          passed: false,
          expected: "app-bottom-nav element",
          actual: "missing",
          tolerance: 0,
          message: `${label} is missing app-bottom-nav`,
        });
        continue;
      }

      for (const [field, expected, tolerance] of [
        ["x", 0, 1],
        ["width", capture.viewport.width, 1],
        ["height", 56, 1],
      ]) {
        record(assertions, {
          name: `${label} bottom nav ${field}`,
          passed: withinTolerance(capture.bottomNav[field], expected, tolerance),
          expected,
          actual: capture.bottomNav[field],
          tolerance,
          message: `${label} bottom nav ${field} was ${capture.bottomNav[field]}`,
        });
      }

      const bottom = capture.bottomNav.y + capture.bottomNav.height;
      record(assertions, {
        name: `${label} bottom nav bottom alignment`,
        passed: withinTolerance(bottom, capture.viewport.height, 1),
        expected: capture.viewport.height,
        actual: bottom,
        tolerance: 1,
        message: `${label} bottom nav bottom was ${bottom}, viewport ${capture.viewport.height}`,
      });
    }
  }
}

function assertCalendars(label, capture, assertions) {
  if ((capture.calendarGeometry ?? []).length > 0) {
    const weekdayRow = firstAcrossPanes(capture, "weekdayRows");
    record(assertions, {
      name: `${label} calendar weekday row present`,
      passed: Boolean(weekdayRow),
      expected: "calendar weekday row",
      actual: weekdayRow ? "present" : "missing",
      tolerance: 0,
      message: `${label} calendar grid has no weekday row`,
    });
  }

  for (const [index, geometry] of (capture.calendarGeometry ?? []).entries()) {
    const name = `${label} calendar[${index}]`;
    if (!geometry.firstCell) {
      record(assertions, {
        name: `${name} first cell present`,
        passed: false,
        expected: "a calendar cell",
        actual: "missing",
        tolerance: 0,
        message: `${name} has no measurable first cell`,
      });
      continue;
    }

    record(assertions, {
      name: `${name} cell height`,
      passed: withinTolerance(geometry.firstCell.height, 68, 1),
      expected: 68,
      actual: geometry.firstCell.height,
      tolerance: 1,
      message: `${name} cell height was ${geometry.firstCell.height}`,
    });

    const expectedWidth = geometry.clientWidth / 7;
    record(assertions, {
      name: `${name} cell width`,
      passed: withinTolerance(geometry.firstCell.width, expectedWidth, 1),
      expected: expectedWidth,
      actual: geometry.firstCell.width,
      tolerance: 1,
      message: `${name} cell width was ${geometry.firstCell.width}, grid/7 was ${expectedWidth}`,
    });

    record(assertions, {
      name: `${name} horizontal overflow`,
      passed: geometry.scrollWidth <= geometry.clientWidth + 1,
      expected: `<= ${geometry.clientWidth + 1}`,
      actual: geometry.scrollWidth,
      tolerance: 1,
      message: `${name} scrollWidth ${geometry.scrollWidth} > clientWidth ${geometry.clientWidth}`,
    });
  }
}

function assertCalendarStability(caseDef, loading, loaded, assertions) {
  const loadingCalendars = loading.calendarGeometry ?? [];
  const loadedCalendars = loaded.calendarGeometry ?? [];

  if (loadedCalendars.length > 0) {
    record(assertions, {
      name: "loading calendar present",
      passed: loadingCalendars.length > 0,
      expected: "> 0 calendar grids",
      actual: loadingCalendars.length,
      tolerance: 0,
      message: "The loading capture has no calendar grid",
    });
  }

  for (const [label, calendars] of [
    ["loading", loadingCalendars],
    ["loaded", loadedCalendars],
  ]) {
    for (const [index, geometry] of calendars.entries()) {
      const name = `${label} calendar[${index}]`;
      const rowCount = geometry.rowCount ?? 0;
      record(assertions, {
        name: `${name} row count`,
        passed: rowCount >= 4 && rowCount <= 6,
        expected: "4-6 rows",
        actual: rowCount,
        tolerance: 0,
        message: `${name} rendered ${rowCount} grid rows`,
      });

      if (!geometry.firstRow || !geometry.secondRow) {
        record(assertions, {
          name: `${name} second grid row present`,
          passed: false,
          expected: "first and second grid rows",
          actual:
            `first=${geometry.firstRow ? "present" : "missing"}, ` +
            `second=${geometry.secondRow ? "present" : "missing"}`,
          tolerance: 0,
          message: `${name} is missing a measurable grid row`,
        });
        continue;
      }

      const pitch = geometry.secondRow.y - geometry.firstRow.y;
      record(assertions, {
        name: `${name} row pitch`,
        passed: withinTolerance(pitch, 68, 1),
        expected: 68,
        actual: pitch,
        tolerance: 1,
        message: `${name} first-to-second row pitch was ${pitch}`,
      });
    }
  }

  const count = Math.min(loadingCalendars.length, loadedCalendars.length);
  for (let index = 0; index < count; index += 1) {
    compareBox(
      assertions,
      `calendar[${index}] first grid row`,
      loadingCalendars[index].firstRow,
      loadedCalendars[index].firstRow,
      1,
      ["y", "height"],
    );
    compareBox(
      assertions,
      `calendar[${index}] second grid row`,
      loadingCalendars[index].secondRow,
      loadedCalendars[index].secondRow,
      1,
      ["y", "height"],
    );
    if (!caseDef.dateGate) {
      record(assertions, {
        name: `calendar[${index}] row count stable`,
        passed:
          loadingCalendars[index].rowCount === loadedCalendars[index].rowCount,
        expected: loadingCalendars[index].rowCount,
        actual: loadedCalendars[index].rowCount,
        tolerance: 0,
        message:
          `calendar[${index}] row count changed from ` +
          `${loadingCalendars[index].rowCount} to ${loadedCalendars[index].rowCount}`,
      });
    }
  }
}

function assertCaptures(caseDef, viewportName, loading, loaded, assertions) {
  record(assertions, {
    name: "loading skeleton present",
    passed: loading.skeletonRegions > 0,
    expected: "> 0 skeleton regions",
    actual: loading.skeletonRegions,
    tolerance: 0,
    message: "No skeleton region was present in the loading capture",
  });

  const loadingTargetSkeletons = scopedSkeletonCount(loading, caseDef.paneRole);
  record(assertions, {
    name: "loading target pane skeleton present",
    passed:
      loadingTargetSkeletons !== null && loadingTargetSkeletons > 0,
    expected: caseDef.paneRole
      ? `> 0 skeleton regions in pane[${caseDef.paneRole}]`
      : "> 0 skeleton regions under page-root",
    actual:
      loadingTargetSkeletons === null
        ? "target pane missing"
        : loadingTargetSkeletons,
    tolerance: 0,
    message: "The loading capture did not contain a target-scoped skeleton",
  });

  const loadedSkeletons = scopedSkeletonCount(loaded, caseDef.paneRole);
  record(assertions, {
    name: "loaded target skeleton gone",
    passed: loadedSkeletons === 0,
    expected: 0,
    actual:
      loadedSkeletons === null ? "target pane missing" : loadedSkeletons,
    tolerance: 0,
    message: `${loadedSkeletons ?? "unknown"} skeleton region(s) remained in the target pane`,
  });

  for (const [label, capture] of [
    ["loading", loading],
    ["loaded", loaded],
  ]) {
    record(assertions, {
      name: `${label} has no focusable skeleton elements`,
      passed: capture.focusableInSkeleton === 0,
      expected: 0,
      actual: capture.focusableInSkeleton,
      tolerance: 0,
      message: `${capture.focusableInSkeleton} focusable element(s) inside skeletons`,
    });
  }

  if (loading.pageSkeletons > 0 || loaded.pageSkeletons > 0) {
    record(assertions, {
      name: "page-level skeleton marker present while loading",
      passed: loading.pageSkeletons >= 1,
      expected: ">= 1 page-level skeleton",
      actual: loading.pageSkeletons,
      tolerance: 0,
      message: "data-skeleton-page exists but the loading capture has none",
    });
  }

  for (const pane of loading.panes) {
    if (pane.pageSkeletons === 0) continue;
    record(assertions, {
      name: `pane[${pane.role ?? "unknown"}] has exactly one page status region`,
      passed: pane.pageSkeletons === 1,
      expected: 1,
      actual: pane.pageSkeletons,
      tolerance: 0,
      message:
        `pane[${pane.role ?? "unknown"}] has ${pane.pageSkeletons} ` +
        "page-level skeleton status region(s)",
    });
  }

  record(assertions, {
    name: "update banner presence identical",
    passed: loading.updateBanner === loaded.updateBanner,
    expected: loading.updateBanner,
    actual: loaded.updateBanner,
    tolerance: 0,
    message: "Update banner appeared or disappeared between captures",
  });

  assertEnvelope(caseDef, loading, loaded, assertions);
  assertAnchors(caseDef, loading, loaded, assertions, viewportName);
  assertHeightChecks(caseDef, loading, loaded, assertions, viewportName);
  assertCountChecks(caseDef, loading, loaded, assertions);
  assertMinRowHeights(caseDef, loading, loaded, assertions);
  assertChrome(caseDef, viewportName, loading, loaded, assertions);
  assertCalendars("loading", loading, assertions);
  assertCalendars("loaded", loaded, assertions);
  assertCalendarStability(caseDef, loading, loaded, assertions);
}

function assertScrollCase(caseDef, run, assertions, viewportName) {
  const scrolled = run.captures?.scrolledLong;
  const after = run.captures?.transitionedTarget;
  const scroll = run.scroll ?? {};

  if (!scrolled || !after) {
    record(assertions, {
      name: "scroll captures present",
      passed: false,
      expected: "scrolled long page and transitioned target page captures",
      actual: "missing capture(s)",
      tolerance: 0,
      message: "The transition-scroll case did not produce all captures",
    });
    return;
  }

  record(assertions, {
    name: "deep scroll reached before navigation",
    passed: Number.isFinite(scroll.beforeNavigation) && scroll.beforeNavigation >= 399,
    expected: ">= 399",
    actual: scroll.beforeNavigation,
    tolerance: 1,
    message: `Deep scroll only reached ${scroll.beforeNavigation}`,
  });

  const inAppMethods = ["bottom-nav-search-tab", "topbar-menu-search-item"];
  record(assertions, {
    name: "in-app route change used",
    passed: inAppMethods.includes(scroll.navigationMethod),
    expected: inAppMethods.join(" or "),
    actual: scroll.navigationMethod ?? "missing",
    tolerance: 0,
    message: "transition-scroll must not use a full document navigation",
  });

  record(assertions, {
    name: "target route reached",
    passed:
      typeof after.url === "string" &&
      after.url.includes(caseDef.targetPath ?? "/search"),
    expected: `URL contains ${caseDef.targetPath ?? "/search"}`,
    actual: after.url ?? "missing",
    tolerance: 0,
    message: `Target URL was ${after.url}`,
  });

  record(assertions, {
    name: "target search controls present",
    passed: Boolean(firstAcrossPanes(after, "searchControls")),
    expected: "search-controls element",
    actual: firstAcrossPanes(after, "searchControls") ? "present" : "missing",
    tolerance: 0,
    message: "The target route did not render search controls",
  });

  const skipTargetTall = (caseDef.skipTargetTallViewports ?? []).includes(viewportName);
  if (!skipTargetTall) {
    record(assertions, {
      name: "target page taller than viewport",
      passed: after.docHeight > after.viewport.height + 1,
      expected: `docHeight > ${after.viewport.height + 1}`,
      actual: after.docHeight,
      tolerance: 1,
      message:
        `Target docHeight ${after.docHeight} is not taller than ` +
        `viewport ${after.viewport.height}; browser clamping would hide a missing reset`,
    });
  }

  record(assertions, {
    name: "target page scroll reset",
    passed: withinTolerance(after.scrollY, 0, 1),
    expected: 0,
    actual: after.scrollY,
    tolerance: 1,
    message: `Target page scrollY was ${after.scrollY}`,
  });
}

function deferredAssertions(caseDef, captures) {
  const items = [];
  const loading = captures.loading;
  const loaded = captures.loaded;
  if (!loading?.pageLoaded && !loaded?.pageLoaded) {
    items.push("pageLoaded/data-page-loaded marker (Phase 1)");
  }
  if ((loading?.pageSkeletons ?? 0) + (loaded?.pageSkeletons ?? 0) === 0) {
    items.push("pageSkeletons/data-skeleton-page marker (Phase 1)");
  }
  if (captures.scrolledLong && captures.transitionedTarget) {
    items.push("scroll-position preservation for in-place retries (later phase)");
  }
  if (caseDef.unimplemented) items.push(...caseDef.unimplemented);
  return [...new Set(items)];
}

async function screenshot(client) {
  return capture(client);
}

async function diagnosticCapture(client, partial) {
  try {
    partial.captures.loading = await captureState(client);
    partial.images.loading = await screenshot(client);
  } catch {
    // Diagnostics are best-effort; the original error is more useful.
  }
}

async function runSkeletonCase(context, caseDef, partial) {
  const { client, network, interceptor, options } = context;
  interceptor.hold(caseDef.hold);

  const relativePath = caseDef.path();
  if (!relativePath) throw new Error(`Case ${caseDef.name} has no path.`);
  const url = `${options.baseUrl}${relativePath}`;

  await navigateFresh(client, url, network);

  if (caseDef.dateGate) {
    // Auth resolves normally; the date gate is held by the dev-only seam, so
    // there are no route-data requests to pause before the seam is released.
    await settleNetwork(network);
    await waitForScopedSkeleton(client, null);
    await ensureSkeletonStillPresent(client, null);

    partial.captures.loading = await captureState(client);
    partial.images.loading = await screenshot(client);

    const seamAvailable = await evaluate(
      client,
      "typeof window.__calcoSendLocalCtx === 'function'",
    );
    if (!seamAvailable) {
      throw new Error(
        "Date-gate seam is unavailable. The dev server must expose " +
          "window.__calcoSendLocalCtx for /home?...&holdLocalCtx=1.",
      );
    }
    await evaluate(client, "window.__calcoSendLocalCtx()");
    await interceptor.waitForRequired();
  } else {
    await interceptor.waitForRequired();
    if (caseDef.searchQuery) {
      await typeSearchQuery(client, caseDef.searchQuery);
      await interceptor.waitForMatcher(caseDef.searchQueryMatcher ?? "foods-search");
    }
    // Wait for the documented final pane count before capturing, so a
    // date-gated 1→2 pane promotion is not mistaken for a loading jump.
    await waitForPaneCount(client, caseDef.fixed?.requirePanes ?? 1);
    await waitForScopedSkeleton(client, caseDef.paneRole);
    await ensureSkeletonStillPresent(client, caseDef.paneRole);

    partial.captures.loading = await captureState(client);
    partial.images.loading = await screenshot(client);
  }

  await interceptor.releaseAll();
  await settleNetwork(network);
  await waitForLoaded(client, caseDef.loadedSelector, caseDef.paneRole);

  partial.captures.loaded = await captureState(client);
  partial.images.loaded = await screenshot(client);

  return {
    pausedUrls: interceptor.pausedUrls(),
    matcherStatus: interceptor.matcherStatus(),
  };
}

async function navigateToSearchInApp(client) {
  const bottomNavMethod = await evaluate(
    client,
    `(() => {
      const nav = document.querySelector('[data-testid="app-bottom-nav"]');
      if (!nav) return null;
      const tabs = [...nav.querySelectorAll('[tabindex="0"]')];
      const target = tabs[1] || nav.children[1];
      if (!target) return null;
      target.click();
      return "bottom-nav-search-tab";
    })()`,
  );
  if (bottomNavMethod) return bottomNavMethod;

  const openedMenu = await evaluate(
    client,
    `(() => {
      const topbar = document.querySelector('[data-testid="app-topbar"]');
      if (!topbar) return false;
      const buttons = [...topbar.querySelectorAll('button, [role="button"]')];
      const menu = buttons.find((button) => {
        const title = button.getAttribute("title") ?? "";
        const label = button.getAttribute("aria-label") ?? "";
        return title === "Menu" || label === "Menu";
      });
      if (!menu) return false;
      menu.click();
      return true;
    })()`,
  );
  if (!openedMenu) return null;

  await waitUntil(
    client,
    `(() => {
      const buttons = [...document.querySelectorAll('button, [role="button"]')];
      return buttons.some((button) => (button.textContent ?? "").trim() === "Search Foods");
    })()`,
    "the top-bar drawer Search Foods item",
    4_000,
  );

  const clickedItem = await evaluate(
    client,
    `(() => {
      const buttons = [...document.querySelectorAll('button, [role="button"]')];
      const search = buttons.find(
        (button) => (button.textContent ?? "").trim() === "Search Foods",
      );
      if (!search) return false;
      search.click();
      return true;
    })()`,
  );
  return clickedItem ? "topbar-menu-search-item" : null;
}

async function runScrollCase(context, caseDef, partial) {
  const { client, network, interceptor, options, viewport } = context;
  interceptor.hold([]);

  const caseHeight = caseDef.viewportHeight ?? viewport.height;
  const resized = caseHeight !== viewport.height;
  if (resized) await setViewport(client, viewport.width, caseHeight);

  try {
    const longUrl = `${options.baseUrl}${caseDef.longPath()}`;

    await navigateFresh(client, longUrl, network);
    await settleNetwork(network);
    await waitForLoaded(
      client,
      caseDef.longLoadedSelector,
      caseDef.paneRole,
    );
    const beforeNavigation = await evaluate(
      client,
      `(() => {
        document.documentElement.style.scrollBehavior = "auto";
        window.scrollTo(0, 400);
        return window.scrollY;
      })()`,
    );
    await delayOnly(50);
    partial.captures.scrolledLong = await captureState(client, {
      resetScroll: false,
    });
    partial.images.loading = await screenshot(client);

    const navigationMethod = await navigateToSearchInApp(client);
    if (!navigationMethod) {
      throw new Error(
        "Could not find an in-app Search path (bottom nav or top-bar menu).",
      );
    }

    await waitUntil(
      client,
      "location.pathname === '/search'",
      "in-app navigation to /search",
      10_000,
    );
    await settleNetwork(network);
    await waitForLoaded(
      client,
      caseDef.targetLoadedSelector,
      caseDef.targetPaneRole ?? caseDef.paneRole,
    );

    partial.captures.transitionedTarget = await captureState(client, {
      resetScroll: false,
    });
    partial.images.loaded = await screenshot(client);

    return {
      scroll: {
        beforeNavigation,
        afterNavigation: partial.captures.transitionedTarget.scrollY,
        navigationMethod,
        urlBefore: partial.captures.scrolledLong.url,
        urlAfter: partial.captures.transitionedTarget.url,
      },
      pausedUrls: interceptor.pausedUrls(),
      matcherStatus: interceptor.matcherStatus(),
    };
  } finally {
    if (resized) await setViewport(client, viewport.width, viewport.height);
  }
}

async function runCaseOnce(context, caseDef, partial) {
  const { client, network, interceptor, auth, options } = context;
  const credentials = auth[caseDef.authRole ?? "layout"];

  await interceptor.continueAll();
  await client.send("Network.setCacheDisabled", { cacheDisabled: true });
  await login(client, network, credentials, options.baseUrl);

  try {
    if (caseDef.kind === "scroll") {
      return await runScrollCase(context, caseDef, partial);
    }
    return await runSkeletonCase(context, caseDef, partial);
  } catch (error) {
    if (!partial.images.loading) {
      await diagnosticCapture(client, partial);
    }
    throw error;
  } finally {
    await interceptor.continueAll();
  }
}

function attemptRecord(attempt, partial, error, context) {
  return {
    attempt,
    error: error?.message ?? null,
    pausedUrls: context.interceptor.pausedUrls(),
    matcherStatus: context.interceptor.matcherStatus(),
    captures: {
      loading: Boolean(partial.captures?.loading),
      loaded: Boolean(partial.captures?.loaded),
      scrolledLong: Boolean(partial.captures?.scrolledLong),
      transitionedTarget: Boolean(partial.captures?.transitionedTarget),
    },
    images: partial.images ?? {},
  };
}

async function runCaseWithRetry(context, caseDef) {
  const attempts = [];
  let fixture = null;

  try {
    fixture = caseDef.setup ? await caseDef.setup(context) : null;
  } catch (error) {
    return {
      error: `Fixture setup failed: ${error.message}`,
      captures: {},
      images: {},
      attempts,
    };
  }

  try {
    return await runCaseAttempts(context, caseDef, attempts);
  } finally {
    if (fixture) {
      try {
        await caseDef.teardown(context, fixture);
      } catch (error) {
        console.warn(`  ${caseDef.name}: fixture cleanup failed: ${error.message}`);
      }
    }
  }
}

async function runCaseAttempts(context, caseDef, attempts) {
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const partial = { captures: {}, images: {} };
    try {
      const payload = await runCaseOnce(context, caseDef, partial);
      attempts.push(attemptRecord(attempt, partial, null, context));
      return { ...partial, ...payload, attempt, attempts };
    } catch (error) {
      attempts.push(attemptRecord(attempt, partial, error, context));
      if (error.name === "WaitTimeout" && attempt === 1) {
        console.warn(`  ${caseDef.name}: ${error.message} Retrying once...`);
        continue;
      }
      return {
        ...partial,
        error: error.message,
        pausedUrls: context.interceptor.pausedUrls(),
        matcherStatus: context.interceptor.matcherStatus(),
        attempt,
        attempts,
      };
    }
  }

  return {
    error: "Case failed.",
    pausedUrls: context.interceptor.pausedUrls(),
    matcherStatus: context.interceptor.matcherStatus(),
    attempt: 2,
    attempts,
  };
}

function serializableAttempts(attempts) {
  return (attempts ?? []).map((attempt) => ({
    attempt: attempt.attempt,
    error: attempt.error,
    pausedUrls: attempt.pausedUrls,
    matcherStatus: attempt.matcherStatus,
    captures: attempt.captures,
    screenshots: {
      loading: Boolean(attempt.images?.loading),
      loaded: Boolean(attempt.images?.loaded),
    },
  }));
}

function skipResult(caseDef, context) {
  return {
    case: caseDef.name,
    viewport: context.options.viewport,
    viewportSize: context.viewport,
    layoutDate: context.layoutDate,
    baseUrl: context.options.baseUrl,
    required: Boolean(caseDef.required),
    optional: Boolean(caseDef.optional),
    skipped: true,
    skipReason: caseDef.skipReason,
    seed: caseDef.seed ?? null,
    error: null,
    assertions: [],
    pausedUrls: [],
    matcherStatus: [],
    captures: {},
    screenshots: {},
    attempt: 0,
    attempts: [],
    scroll: null,
    unimplemented: ["Optional case skipped because its fixture id is missing."],
  };
}

function buildResult(caseDef, context, run) {
  const assertions = [];
  const captures = run.captures ?? {};

  if (run.error) {
    record(assertions, {
      name: "case completed",
      passed: false,
      expected: "case completes without a timeout or error",
      actual: run.error,
      tolerance: 0,
      message: run.error,
    });
  }

  if (caseDef.kind === "scroll") {
    assertScrollCase(caseDef, run, assertions, context.options.viewport);
  } else if (captures.loading && captures.loaded) {
    assertCaptures(
      caseDef,
      context.options.viewport,
      captures.loading,
      captures.loaded,
      assertions,
    );
  } else {
    record(assertions, {
      name: "loading and loaded captures present",
      passed: false,
      expected: "both loading and loaded captures",
      actual:
        `loading=${captures.loading ? "present" : "missing"}, ` +
        `loaded=${captures.loaded ? "present" : "missing"}`,
      tolerance: 0,
      message: "The case did not produce both captures",
    });
  }

  return {
    case: caseDef.name,
    viewport: context.options.viewport,
    viewportSize: context.viewport,
    layoutDate: context.layoutDate,
    baseUrl: context.options.baseUrl,
    required: Boolean(caseDef.required),
    optional: Boolean(caseDef.optional),
    skipped: false,
    skipReason: null,
    seed: caseDef.seed ?? null,
    error: run.error ?? null,
    assertions,
    pausedUrls: run.pausedUrls ?? [],
    matcherStatus: run.matcherStatus ?? [],
    captures,
    scroll: run.scroll ?? null,
    screenshots: {
      loading: run.images?.loading ? "loading.png" : null,
      loaded: run.images?.loaded ? "loaded.png" : null,
    },
    attempt: run.attempt ?? 1,
    attempts: serializableAttempts(run.attempts),
    unimplemented: deferredAssertions(caseDef, captures),
  };
}

async function persistResult(runRoot, result, images, attempts = []) {
  const caseDir = path.join(runRoot, result.case);
  await fs.mkdir(caseDir, { recursive: true });

  if (images?.loading) {
    await fs.writeFile(path.join(caseDir, "loading.png"), images.loading);
  }
  if (images?.loaded) {
    await fs.writeFile(path.join(caseDir, "loaded.png"), images.loaded);
  }

  for (const attempt of attempts) {
    if (!attempt.images?.loading && !attempt.images?.loaded) continue;
    const attemptDir = path.join(caseDir, `attempt-${attempt.attempt}`);
    await fs.mkdir(attemptDir, { recursive: true });
    if (attempt.images?.loading) {
      await fs.writeFile(path.join(attemptDir, "loading.png"), attempt.images.loading);
    }
    if (attempt.images?.loaded) {
      await fs.writeFile(path.join(attemptDir, "loaded.png"), attempt.images.loaded);
    }
  }

  await fs.writeFile(
    path.join(caseDir, "result.json"),
    `${JSON.stringify(result, null, 2)}\n`,
  );

  return path.relative(REPO_ROOT, caseDir);
}

function printCaseSummary(result, artifactDir) {
  if (result.skipped) {
    console.log(`SKIP ${result.case}: ${result.skipReason}`);
    return;
  }

  const failures = result.assertions.filter((assertion) => !assertion.passed);
  if (failures.length === 0 && !result.error) {
    console.log(`PASS ${result.case}`);
  } else {
    console.log(`FAIL ${result.case} (${failures.length} failed assertion(s))`);
    for (const failure of failures.slice(0, 12)) {
      console.log(`  - ${failure.name}: ${failure.message}`);
      console.log(
        `    expected=${JSON.stringify(failure.expected)} ` +
          `actual=${JSON.stringify(failure.actual)} tolerance=${failure.tolerance}`,
      );
    }
    if (failures.length > 12) {
      console.log(`  ... ${failures.length - 12} more failure(s) in result.json`);
    }
  }

  if (result.seed) {
    console.log(`     seed: ${JSON.stringify(result.seed)}`);
  }

  if (result.unimplemented?.length) {
    console.log(`     unimplemented: ${result.unimplemented.join("; ")}`);
  }
  console.log(`     artifacts: ${artifactDir}`);
}

async function cleanup() {
  if (cleanupStarted) return;
  cleanupStarted = true;

  if (cdp) {
    try {
      cdp.close();
    } catch {
      // Ignore close errors.
    }
    cdp = null;
  }

  if (chrome) {
    chrome.child.kill("SIGTERM");
    await Promise.race([once(chrome.child, "exit").catch(() => {}), delayOnly(2_000)]);
    chrome = null;
  }

  if (chromeProfile) {
    await fs.rm(chromeProfile, { recursive: true, force: true }).catch(() => {});
    chromeProfile = null;
  }
}

function installSignalHandlers() {
  for (const [signal, code] of [
    ["SIGINT", 130],
    ["SIGTERM", 143],
  ]) {
    process.once(signal, () => {
      cleanup()
        .catch(() => {})
        .finally(() => process.exit(code));
    });
  }
}

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(
      "Usage: node docs/scripts/check-skeleton-stability.mjs " +
        "[--case <name>]... [--base-url <url>] [--viewport phone|desktop] " +
        "[--headed] [--report-only]",
    );
    return;
  }

  installSignalHandlers();

  const auth = readAuthEnv();
  const layoutDate = resolveLayoutDate();
  const viewport = VIEWPORTS[options.viewport];

  await ensureServerRunning(options.baseUrl);

  const runRoot = path.join(ARTIFACT_ROOT, timestamp());
  const results = [];
  let runContext = null;
  let mealFixture = null;

  try {
    chromeProfile = await fs.mkdtemp(path.join(os.tmpdir(), "calco-skeleton-stability-"));
    chrome = await launchChrome(chromeProfile, { headed: options.headed });
    cdp = await connectToPage(chrome.port);

    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Network.enable");
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });
    await setViewport(cdp, viewport.width, viewport.height);
    await cdp.send("Emulation.setTimezoneOverride", { timezoneId: "UTC" }).catch(() => {});
    await cdp.send("Emulation.setLocaleOverride", { locale: "en-US" }).catch(() => {});
    await cdp.send("Emulation.setScrollbarsHidden", { hidden: true }).catch(() => {});
    await cdp.send("Fetch.enable", {
      patterns: [{ urlPattern: "*", requestStage: "Request" }],
    });

    const network = trackApiRequests(cdp);
    const interceptor = installFetchInterceptor(cdp);
    const context = {
      client: cdp,
      network,
      interceptor,
      auth,
      options,
      viewport,
      layoutDate,
    };
    runContext = context;

    // Discover optional route ids with the layout session. Each case logs in
    // again after this so no case depends on another case's page state.
    await interceptor.continueAll();
    await login(cdp, network, auth.layout, options.baseUrl);
    const discovered = await discoverIds(cdp, layoutDate);

    if (process.env.CALCO_CUSTOM_FOOD_ID) {
      discovered.customFoodId = process.env.CALCO_CUSTOM_FOOD_ID;
      discovered.customFoodReason = null;
    }
    if (process.env.CALCO_FOOD_ID) {
      discovered.chickenFoodId = process.env.CALCO_FOOD_ID;
      discovered.chickenFoodName = null;
      discovered.chickenFoodReason = null;
    }

    // Probe the selected food as the layout user, before the admin login below.
    // Always probe so the case knows whether the full no-category anchors are
    // available. Discovery treats a missing categories field as unknown, not
    // as zero.
    if (discovered.chickenFoodId) {
      await interceptor.continueAll();
      const foodMeta = await discoverFoodCategoryCount(cdp, discovered.chickenFoodId);
      if (foodMeta.count !== null) discovered.chickenFoodCategories = foodMeta.count;
      if (foodMeta.name) discovered.chickenFoodName = foodMeta.name;
      if (foodMeta.reason) {
        console.warn(`food-show: seed category probe failed: ${foodMeta.reason}`);
      }
    }

    if (process.env.CALCO_MEAL_ID) {
      discovered.mealId = process.env.CALCO_MEAL_ID;
      discovered.mealReason = null;
      discovered.mealName = null;
      discovered.mealNotesLength = null;
      discovered.mealNameLength = null;
      discovered.mealSeedSource = "override";
    }
    if (process.env.CALCO_LOG_ID) {
      discovered.logId = process.env.CALCO_LOG_ID;
      discovered.logName = null;
      discovered.logItemType = null;
      discovered.logBrand = null;
      discovered.logHasBrand = null;
      discovered.logReason = null;
    }

    // The Meal Show contract is the no-notes header body. If the database has no
    // no-notes meal, create a short-name fixture as the layout user and delete it
    // after the run. An explicit CALCO_MEAL_ID always wins.
    const mealCaseSelected =
      options.cases.length === 0 || options.cases.includes("meal-show");
    if (
      mealCaseSelected &&
      !process.env.CALCO_MEAL_ID &&
      discovered.mealNotesLength !== 0
    ) {
      await interceptor.continueAll();
      mealFixture = await createSkeletonMealFixture(cdp, discovered);
    }

    if (process.env.CALCO_ADMIN_EDIT_USER_ID) {
      discovered.adminEditUserId = process.env.CALCO_ADMIN_EDIT_USER_ID;
      discovered.adminEditUserReason = null;
      discovered.adminUserCount = null;
    } else {
      await interceptor.continueAll();
      await login(cdp, network, auth.admin, options.baseUrl);
      const adminEdit = await discoverAdminEditUserId(cdp, auth.layout.username);
      discovered.adminEditUserId = adminEdit.id;
      discovered.adminEditUserReason = adminEdit.reason;
      discovered.adminUserCount = adminEdit.count;
    }

    const allCases = buildCases(layoutDate, discovered);
    const selectedCases =
      options.cases.length > 0
        ? allCases.filter((caseDef) => options.cases.includes(caseDef.name))
        : allCases;

    for (const caseDef of selectedCases) {
      if (
        !options.reportOnly &&
        caseDef.requiresZeroCategorySeed &&
        caseDef.seed?.categories !== 0
      ) {
        caseDef.skipReason =
          `${caseDef.name} requires a zero-category food seed, but ` +
          `${caseDef.seed?.id ?? "no food id"} ` +
          `(${JSON.stringify(caseDef.seed?.name ?? null)}) has ` +
          `${caseDef.seed?.categories ?? "unknown"} categories. ` +
          "Set CALCO_FOOD_ID to a zero-category food for required mode.";
      }
    }

    console.log(
      `Skeleton layout harness: ${selectedCases.length} case(s), ` +
        `${viewport.label} ${viewport.width}x${viewport.height}, date ${layoutDate}` +
        `${options.reportOnly ? " (report-only)" : " (failures are fatal)"}.`,
    );
    console.log(`Base URL: ${options.baseUrl}`);

    const missingOptional = [
      ["custom-food-edit", discovered.customFoodReason],
      ["meal-edit", discovered.mealReason],
      ["food-show", discovered.chickenFoodReason],
      ["custom-food-show", discovered.customFoodReason],
      ["meal-show", discovered.mealReason],
      ["food-log", discovered.logReason],
      ["admin-edit", discovered.adminEditUserReason],
    ];
    for (const [name, reason] of missingOptional) {
      if (reason) {
        console.log(
          name +
            ": " +
            reason +
            (options.reportOnly ? " (will skip)" : " (required mode: failure)"),
        );
      }
    }

    for (const caseDef of selectedCases) {
      if (caseDef.skipReason && options.reportOnly) {
        const result = skipResult(caseDef, context);
        const artifactDir = await persistResult(runRoot, result, {});
        results.push(result);
        printCaseSummary(result, artifactDir);
        continue;
      }

      const run = caseDef.skipReason
        ? {
            error:
              `Missing required fixture for ${caseDef.name}: ${caseDef.skipReason}`,
            captures: {},
            images: {},
            attempts: [],
          }
        : await runCaseWithRetry(context, caseDef);
      const result = buildResult(caseDef, context, run);
      const artifactDir = await persistResult(
        runRoot,
        result,
        run.images ?? {},
        run.attempts ?? [],
      );
      results.push(result);
      printCaseSummary(result, artifactDir);
    }
  } finally {
    if (mealFixture && runContext) {
      try {
        await deleteSkeletonMealFixture(runContext, mealFixture);
      } catch (error) {
        console.warn(`meal-show: fixture cleanup failed: ${error.message}`);
      }
    }
    await cleanup();
  }

  const failed = results.filter(
    (result) =>
      !result.skipped && (result.error || result.assertions.some((a) => !a.passed)),
  );
  const skipped = results.filter((result) => result.skipped);
  const passed = results.length - failed.length - skipped.length;

  console.log(
    `\n${passed} passed, ${failed.length} failed, ${skipped.length} skipped. ` +
      `Artifacts: ${path.relative(REPO_ROOT, runRoot)}/`,
  );

  if (options.reportOnly) {
    console.log("Report-only: layout failures did not change the exit code.");
  } else if (failed.length > 0) {
    process.exitCode = 1;
  }
}

if (process.argv[1]) {
  try {
    const isDirectRun = fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
    if (isDirectRun) {
      await main();
    }
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exitCode = 1;
  }
}

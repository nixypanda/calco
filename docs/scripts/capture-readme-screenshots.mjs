#!/usr/bin/env node

// Capture the light/dark screenshots used by README.md.
//
// Run `just dev` first, then `just screenshots`. This uses the Chrome
// DevTools Protocol directly instead of adding a browser automation dependency.
// Set CHROME to override Chrome/Chromium discovery and CALCO_URL to capture
// from a different frontend address.

import { once } from "node:events";
import { promises as fs, realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  capture,
  clickButton,
  connectToPage,
  delay,
  evaluate,
  injectStaticStyles,
  launchChrome,
  navigate,
  normalizeBaseUrl,
  setViewport,
  trackApiRequests,
  typeIntoInput,
  waitForLoad,
  waitForText,
} from "./lib/cdp.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "../..");
const OUTPUT_ROOT = path.join(REPO_ROOT, "docs/images/readme");
const BASE_URL = normalizeBaseUrl(process.env.CALCO_URL ?? "http://localhost:1234");
const THEMES = ["light", "dark"];
const DEMO_DATE = process.env.CALCO_SCREENSHOT_DATE ?? "2026-10-27";
const PHONE_WIDTH = 390;
const PHONE_HEIGHT = 844;
const DESKTOP_WIDTH = 1600;
const DESKTOP_HEIGHT = 1000;

let chrome = null;
let chromeProfile = null;
let cdp = null;

async function main() {
  try {
    await ensureServerRunning();
    chromeProfile = await fs.mkdtemp(path.join(os.tmpdir(), "calco-readme-shots-"));
    chrome = await launchChrome(chromeProfile);
    cdp = await connectToPage(chrome.port);
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Network.enable");
    const network = trackApiRequests(cdp);
    await navigate(cdp, BASE_URL, network);

    let foodId = null;
    let mealId = null;

    for (const theme of THEMES) {
      await evaluate(cdp, `localStorage.setItem("themeMode", ${JSON.stringify(theme)})`);
      await evaluate(cdp, "location.reload()");
      await waitForLoad(cdp);
      await delay(500);
      await login(cdp, network, "me", "mepass123");

      if (!foodId) {
        foodId = await fetchFirstProductId(cdp, "chicken");
        mealId = await fetchFirstMealId(cdp);
      }

      const mobileShots = [
        {
          name: "mobile-diary",
          path: `/home?date=${encodeURIComponent(DEMO_DATE)}`,
          waitFor: "CALORIES",
        },
        {
          name: "mobile-food-search",
          path: `/search?date=${encodeURIComponent(DEMO_DATE)}&meal_slot=breakfast`,
          waitFor: "All",
          searchQuery: "chicken",
          searchWaitFor: "Chicken",
        },
        {
          name: "mobile-food-nutrition",
          path: `/foods/${encodeURIComponent(foodId)}?date=${encodeURIComponent(DEMO_DATE)}&meal_slot=breakfast`,
          waitFor: "Portion",
        },
        {
          name: "mobile-meal-builder",
          path: mealId ? `/meals/${encodeURIComponent(mealId)}` : "/meals/new",
          waitFor: mealId ? "Meal" : "Create Meal",
        },
        {
          name: "mobile-custom-food",
          path: "/foods/custom/new",
          waitFor: "Create Food",
        },
      ];

      const desktopShots = [
        {
          name: "desktop-diary-search",
          path: `/search?date=${encodeURIComponent(DEMO_DATE)}&meal_slot=breakfast`,
          waitFor: "All",
          searchQuery: "chicken",
          searchWaitFor: "Chicken",
        },
        {
          name: "desktop-food-detail",
          path: `/foods/${encodeURIComponent(foodId)}?date=${encodeURIComponent(DEMO_DATE)}&meal_slot=breakfast`,
          waitFor: "Portion",
        },
      ];

      for (const shot of mobileShots) {
        await captureMobileShot(cdp, network, shot, theme);
      }
      for (const shot of desktopShots) {
        await captureDesktopShot(cdp, network, shot, theme);
      }
    }

    console.log(`\nScreenshots written to ${path.relative(REPO_ROOT, OUTPUT_ROOT)}/`);
  } finally {
    await cleanup();
  }
}

async function login(client, network, username, password) {
  await navigate(client, `${BASE_URL}/login`, network);
  await delay(300);
  const ok = await evaluate(
    client,
    `fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ username: ${JSON.stringify(username)}, password: ${JSON.stringify(password)} })
    }).then((response) => response.ok).catch(() => false)`,
    true,
  );
  if (!ok) throw new Error(`Login failed for ${username}.`);
  await evaluate(client, "location.reload()");
  await waitForLoad(client);
  await delay(500);
}

async function fetchFirstProductId(client, query) {
  const value = await evaluate(
    client,
    `(async () => {
      const response = await fetch("/api/foods/search?q=${encodeURIComponent(query)}&scope=all", { credentials: "include" });
      const data = await response.json();
      return Array.isArray(data.items) && data.items.length ? data.items[0].id : null;
    })()`,
    true,
  );
  if (!value) throw new Error(`No product found for query "${query}".`);
  return value;
}

async function fetchFirstMealId(client) {
  const value = await evaluate(
    client,
    `(async () => {
      const response = await fetch("/api/meals", { credentials: "include" });
      const data = await response.json();
      return Array.isArray(data.items) && data.items.length ? data.items[0].id : null;
    })()`,
    true,
  );
  return value;
}

async function captureMobileShot(client, network, shot, theme) {
  await setViewport(client, PHONE_WIDTH, PHONE_HEIGHT);
  await navigate(client, `${BASE_URL}${shot.path}`, network);
  await waitForText(client, shot.waitFor);
  await network.waitForIdle();

  if (shot.searchQuery) {
    await clickButton(client, "All");
    await typeIntoInput(client, shot.searchQuery);
    await waitForText(client, shot.searchWaitFor);
    await network.waitForIdle();
    await delay(400);
  }

  await removeDevChrome(client);
  await scrollToTop(client);
  await injectStaticStyles(client);
  await delay(250);

  const image = await capture(client);
  await writeImage(
    path.join(OUTPUT_ROOT, theme, `${shot.name}.png`),
    image,
    PHONE_WIDTH,
    PHONE_HEIGHT,
  );
}

async function captureDesktopShot(client, network, shot, theme) {
  await setViewport(client, DESKTOP_WIDTH, DESKTOP_HEIGHT);
  await navigate(client, `${BASE_URL}${shot.path}`, network);
  await waitForText(client, shot.waitFor);
  await network.waitForIdle();

  if (shot.searchQuery) {
    await clickButton(client, "All");
    await typeIntoInput(client, shot.searchQuery);
    await waitForText(client, shot.searchWaitFor);
    await network.waitForIdle();
    await delay(400);
  }

  await removeDevChrome(client);
  await scrollToTop(client);
  await injectStaticStyles(client);
  await delay(250);

  const image = await capture(client);
  await writeImage(
    path.join(OUTPUT_ROOT, theme, `${shot.name}.png`),
    image,
    DESKTOP_WIDTH,
    DESKTOP_HEIGHT,
  );
}

function parseArgs(values) {
  const parsed = new Map();
  for (const value of values) {
    const [key, ...rest] = value.split("=");
    parsed.set(key, rest.join("="));
  }
  return parsed;
}

async function ensureServerRunning() {
  const deadline = Date.now() + 10_000;
  let lastError = null;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${BASE_URL}/`);
      if (response.ok) return;
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await delay(200);
  }

  throw new Error(
    `Could not reach ${BASE_URL}. Start the app with \`just dev\` first.` +
      (lastError ? ` (${lastError.message})` : ""),
  );
}

async function removeDevChrome(client) {
  await evaluate(
    client,
    `(() => {
      document.querySelectorAll("vite-error-overlay").forEach((element) => element.remove());
      document
        .querySelectorAll('body > div[style*="bottom: 2em"]')
        .forEach((element) => element.remove());
      return true;
    })()`,
  );
  await delay(200);
}

async function scrollToTop(client) {
  await evaluate(
    client,
    `(() => {
      window.scrollTo(0, 0);
      document.querySelectorAll(".ui-workspace-pane").forEach((element) => {
        element.scrollTop = 0;
      });
      return true;
    })()`,
  );
}

async function writeImage(filePath, image, expectedWidth, expectedHeight) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, image);
  const { width, height } = pngSize(image);
  if (width !== expectedWidth || height !== expectedHeight) {
    throw new Error(
      `${filePath} is ${width}x${height}; expected ${expectedWidth}x${expectedHeight}.`,
    );
  }
  console.log(
    `${path.relative(REPO_ROOT, filePath)} (${width}x${height}, ${Math.round(image.length / 1024)} KiB)`,
  );
}

function pngSize(buffer) {
  if (buffer.toString("ascii", 1, 4) !== "PNG") {
    throw new Error("Screenshot is not a PNG.");
  }
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20),
  };
}

async function cleanup() {
  if (cdp) {
    try {
      cdp.close();
    } catch {
      // Ignore close errors.
    }
  }

  if (chrome) {
    chrome.child.kill("SIGTERM");
    await Promise.race([once(chrome.child, "exit").catch(() => {}), delay(2_000)]);
  }

  if (chromeProfile) {
    await fs.rm(chromeProfile, { recursive: true, force: true }).catch(() => {});
  }
}

function isDirectRun() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return import.meta.url === pathToFileURL(process.argv[1]).href;
  }
}

if (isDirectRun()) {
  await main();
}

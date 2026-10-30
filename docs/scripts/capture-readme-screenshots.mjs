#!/usr/bin/env node

// Capture the light/dark screenshots used by README.md.
//
// Run `just dev` first, then `just screenshots`. This uses the Chrome
// DevTools Protocol directly instead of adding a browser automation dependency.
// Set CHROME to override Chrome/Chromium discovery and CALCO_URL to capture
// from a different frontend address.

import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { accessSync, constants, promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

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

async function typeIntoInput(client, text) {
  const typed = await evaluate(
    client,
    `(() => {
      const input = [...document.querySelectorAll("input")].find((element) => {
        const placeholder = (element.placeholder || "").toLowerCase();
        const label = (element.getAttribute("aria-label") || "").toLowerCase();
        return placeholder.includes("search") || label.includes("search");
      });
      if (!input) return false;
      input.focus();
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
      setter.call(input, ${JSON.stringify(text)});
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`,
  );
  if (!typed) throw new Error("Could not find the search input.");
}

function parseArgs(values) {
  const parsed = new Map();
  for (const value of values) {
    const [key, ...rest] = value.split("=");
    parsed.set(key, rest.join("="));
  }
  return parsed;
}

function normalizeBaseUrl(value) {
  return value.replace(/\/+$/, "");
}

function findChrome() {
  const explicit = process.env.CHROME;
  if (explicit) return explicit;

  const candidates =
    process.platform === "darwin"
      ? [
          "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          "/Applications/Chromium.app/Contents/MacOS/Chromium",
          "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
        ]
      : [];

  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Try the next candidate.
    }
  }

  for (const command of [
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "chrome",
  ]) {
    const result = spawnSync("which", [command]);
    if (result.status === 0) return result.stdout.toString().trim();
  }

  throw new Error("Chrome/Chromium was not found. Set CHROME=/path/to/chrome and retry.");
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

async function launchChrome(profileDir) {
  const chromePath = findChrome();
  const child = spawn(
    chromePath,
    [
      "--headless=new",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--hide-scrollbars",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-sync",
      "--disable-translate",
      "--metrics-recording-only",
      "--mute-audio",
      "--safebrowsing-disable-auto-update",
      "--no-service-autorun",
      "--password-store=basic",
      "--use-mock-keychain",
      "--disable-features=BackForwardCache,Translate,MediaRouter,OptimizationHints",
      "--remote-allow-origins=*",
      "--remote-debugging-port=0",
      `--user-data-dir=${profileDir}`,
      "--window-size=1600,1200",
      "--force-device-scale-factor=1",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  const exited = once(child, "exit").then(([code, signal]) => {
    throw new Error(
      `Chrome exited before the DevTools endpoint was ready` +
        ` (code ${code ?? "null"}, signal ${signal ?? "none"}).\n${stderr}`,
    );
  });
  exited.catch(() => {});

  const portFile = path.join(profileDir, "DevToolsActivePort");
  const deadline = Date.now() + 15_000;

  while (Date.now() < deadline) {
    try {
      const contents = await fs.readFile(portFile, "utf8");
      const [port] = contents.split("\n");
      if (port) {
        return { child, port: Number(port), stderr: () => stderr };
      }
    } catch {
      // Chrome has not written the port file yet.
    }
    await delay(100);
  }

  child.kill("SIGTERM");
  throw new Error(`Timed out waiting for Chrome's DevTools endpoint.\n${stderr}`);
}

async function connectToPage(port) {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((target) => target.type === "page");
  if (!page?.webSocketDebuggerUrl) {
    throw new Error("Chrome did not expose a page target.");
  }

  const client = new CdpClient(page.webSocketDebuggerUrl);
  await client.connect();
  return client;
}

function trackApiRequests(client) {
  const inFlight = new Set();
  let loaderId = null;
  let tracking = false;
  client.on("Network.requestWillBeSent", ({ requestId, request, loaderId: requestLoaderId }) => {
    const url = request.url;
    if (!tracking) return;
    if (loaderId && requestLoaderId && requestLoaderId !== loaderId) return;
    if (url.includes("/api/") && !url.includes("/api/events")) {
      inFlight.add(requestId);
    }
  });
  const finish = ({ requestId }) => {
    inFlight.delete(requestId);
  };
  client.on("Network.loadingFinished", finish);
  client.on("Network.loadingFailed", finish);

  return {
    start(nextLoaderId) {
      inFlight.clear();
      loaderId = nextLoaderId || null;
      tracking = true;
    },
    async waitForIdle(timeout = 20_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (inFlight.size === 0) {
          await delay(350);
          if (inFlight.size === 0) return;
        }
        await delay(50);
      }
      throw new Error("Timed out waiting for API requests to settle.");
    },
  };
}

async function setViewport(client, width, height) {
  await client.send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
    screenWidth: width,
    screenHeight: height,
  });
}

async function navigate(client, url, network = null) {
  network?.start(null);
  const loaded = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      offLoad();
      reject(new Error(`Timed out navigating to ${url}.`));
    }, 20_000);
    const offLoad = client.on("Page.loadEventFired", () => {
      clearTimeout(timeout);
      offLoad();
      resolve();
    });
  });

  const result = await client.send("Page.navigate", { url });
  if (result.errorText) {
    throw new Error(`Could not navigate to ${url}: ${result.errorText}`);
  }
  network?.start(result.loaderId);
  await loaded;
  await waitForLoad(client);
}

async function waitForLoad(client, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(client, "document.readyState === 'complete'")) return;
    } catch {
      // The execution context is being replaced during navigation.
    }
    await delay(50);
  }
  throw new Error("Timed out waiting for the page to load.");
}

async function waitForText(client, text, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      const found = await evaluate(
        client,
        `Boolean(document.body && document.body.innerText.includes(${JSON.stringify(text)}))`,
      );
      if (found) return;
    } catch {
      // The execution context is being replaced during navigation.
    }
    await delay(100);
  }
  throw new Error(`Timed out waiting for page text: ${text}`);
}

async function clickButton(client, label) {
  const clicked = await evaluate(
    client,
    `(() => {
      const button = [...document.querySelectorAll('button, [role="button"]')].find(
        (candidate) => candidate.textContent.trim() === ${JSON.stringify(label)}
      );
      if (!button) return false;
      button.click();
      button.blur();
      return true;
    })()`,
  );
  if (!clicked) throw new Error(`Could not find the "${label}" button.`);
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

async function injectStaticStyles(client) {
  await evaluate(
    client,
    `(() => {
      let style = document.getElementById("calco-readme-shot-styles");
      if (!style) {
        style = document.createElement("style");
        style.id = "calco-readme-shot-styles";
        document.head.appendChild(style);
      }
      style.textContent =
        "*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }";
      return true;
    })()`,
  );
}

async function capture(client) {
  const result = await client.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false,
  });
  return Buffer.from(result.data, "base64");
}

async function evaluate(client, expression, awaitPromise = false) {
  const result = await client.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise,
  });
  if (result.exceptionDetails) {
    throw new Error(
      result.exceptionDetails.text ??
        result.exceptionDetails.exception?.description ??
        "Page evaluation failed.",
    );
  }
  return result.result.value;
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

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
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

class CdpClient {
  constructor(url) {
    this.url = url;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.url);
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, { once: true });
      this.socket.addEventListener("error", reject, { once: true });
    });
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) {
          pending.reject(new Error(`${message.error.message} (${message.error.code})`));
        } else {
          pending.resolve(message.result);
        }
        return;
      }

      if (message.method) {
        for (const listener of this.listeners.get(message.method) ?? []) {
          listener(message.params);
        }
      }
    });
    this.socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) {
        pending.reject(new Error("Chrome DevTools connection closed."));
      }
      this.pending.clear();
    });
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
    return () => {
      const index = listeners.indexOf(listener);
      if (index >= 0) listeners.splice(index, 1);
    };
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    this.socket?.close();
  }
}

await main();

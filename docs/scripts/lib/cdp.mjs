// Reusable Chrome DevTools Protocol plumbing for the docs scripts.
//
// This module has no top-level side effects, so scripts can import it without
// launching Chrome or running their own main().

import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { accessSync, constants, promises as fs } from "node:fs";
import path from "node:path";

export class CdpClient {
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

export function normalizeBaseUrl(value) {
  return value.replace(/\/+$/, "");
}

export function findChrome() {
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

export async function launchChrome(profileDir, { headed = false } = {}) {
  const chromePath = findChrome();
  const child = spawn(
    chromePath,
    [
      ...(headed ? [] : ["--headless=new"]),
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

export async function connectToPage(port) {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((target) => target.type === "page");
  if (!page?.webSocketDebuggerUrl) {
    throw new Error("Chrome did not expose a page target.");
  }

  const client = new CdpClient(page.webSocketDebuggerUrl);
  await client.connect();
  return client;
}

export function trackApiRequests(client) {
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

export async function setViewport(client, width, height) {
  await client.send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
    screenWidth: width,
    screenHeight: height,
  });
}

export async function navigate(client, url, network = null) {
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

export async function waitForLoad(client, timeout = 20_000) {
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

export async function waitForText(client, text, timeout = 20_000) {
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

export async function clickButton(client, label) {
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

export async function typeIntoInput(client, text) {
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
      const setter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype,
        "value"
      ).set;
      setter.call(input, ${JSON.stringify(text)});
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`,
  );
  if (!typed) throw new Error("Could not find the search input.");
}

export async function injectStaticStyles(client) {
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
        "*, *::before, *::after { transition: none !important; " +
        "animation: none !important; caret-color: transparent !important; }";
      return true;
    })()`,
  );
}

export async function capture(client) {
  const result = await client.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false,
  });
  return Buffer.from(result.data, "base64");
}

export async function evaluate(client, expression, awaitPromise = false) {
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

export function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

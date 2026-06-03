import { createReadStream, existsSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";
import { createServer } from "node:http";

const port = Number(process.env.PORT ?? 1234);
const apiTarget = process.env.API_TARGET ?? "http://localhost:3001";
const root = resolve(import.meta.dirname);

const mimeTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
]);

createServer((req, res) => {
  if (!req.url) {
    res.writeHead(400);
    res.end("Bad request");
    return;
  }

  if (req.url.startsWith("/api/")) {
    proxyApi(req, res);
    return;
  }

  serveStatic(req.url, res);
}).listen(port, () => {
  console.log(`frontend-web dev server: http://localhost:${port}`);
  console.log(`proxying /api to ${apiTarget}`);
});

function serveStatic(url, res) {
  const pathname = new URL(url, `http://localhost:${port}`).pathname;
  const requested = normalize(pathname === "/" ? "/index.html" : pathname);
  const filePath = join(root, requested);
  const safePath = filePath.startsWith(root) && existsSync(filePath) ? filePath : join(root, "index.html");
  const contentType = mimeTypes.get(extname(safePath)) ?? "application/octet-stream";

  res.writeHead(200, { "Content-Type": contentType });
  createReadStream(safePath).pipe(res);
}

function proxyApi(req, res) {
  const target = new URL(req.url, apiTarget);
  const headers = { ...req.headers, host: target.host };

  const options = {
    method: req.method,
    headers,
    redirect: "manual",
  };

  if (req.method !== "GET" && req.method !== "HEAD") {
    options.body = req;
    options.duplex = "half";
  }

  fetch(target, options)
    .then(async (apiRes) => {
      res.writeHead(apiRes.status, Object.fromEntries(apiRes.headers.entries()));
      if (apiRes.body) {
        const reader = apiRes.body.getReader();
        await pump(reader, res);
      } else {
        res.end();
      }
    })
    .catch((error) => {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { code: "proxy_error", message: error.message } }));
    });
}

async function pump(reader, res) {
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      res.end();
      return;
    }
    res.write(value);
  }
}

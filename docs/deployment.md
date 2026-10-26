# Deployment

This document covers running CalCo on a host. For a local dev environment, see
[local-development.md](local-development.md).

The flake exports:

- `packages.${system}.backend` — axum binary + `share/calco/migrations/`
- `packages.${system}.frontend` — static Elm/Vite bundle in `share/calco/web/`
- `nixosModules.default` — `services.calco`

It does **not** know about your host, secrets, or SSH keys. Wire those up
from your own system flake (dotfiles / nixos-config repo).

## Files

- `nix/backend.nix` — Rust derivation (no `.sqlx/` needed; backend uses runtime queries only).
- `nix/frontend.nix` — Elm + Vite static site. Pinned via `elm-srcs.nix`, `registry.dat`, and `npmDepsHash`.
- `nix/module.nix` — defines `services.calco`. Sets up `services.postgresql`, a migrate oneshot, the backend systemd unit, and an nginx vhost.

## Consuming from your system flake

```nix
{
  inputs = {
    nixpkgs.url   = "github:NixOS/nixpkgs/nixos-unstable";
    agenix.url    = "github:ryantm/agenix";
    calco.url     = "github:nixypanda/CalCo";
    calco.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, agenix, calco, ... }: {
    nixosConfigurations.homelab = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        agenix.nixosModules.default
        calco.nixosModules.default
        ./hosts/homelab/hardware-configuration.nix
        ./hosts/homelab/default.nix
        ./hosts/homelab/calco.nix    # wires services.calco + reverse proxy
      ];
    };
  };
}
```

The module is intentionally web-tier-agnostic. It runs the backend on
`127.0.0.1:cfg.port` and exposes the frontend bundle as a Nix package —
you point your own reverse proxy at both.

### Example: Caddy

```nix
# hosts/homelab/calco.nix
{ config, ... }: let calco = config.services.calco; in {
  age.secrets.calco-env.file = ../../secrets/calco-env.age;

  services.calco = {
    enable = true;
    secretsFile = config.age.secrets.calco-env.path;
  };

  services.caddy = {
    enable = true;
    virtualHosts."calco.example.com".extraConfig = ''
      root * ${calco.frontendPackage}/share/calco/web

      handle /api/* {
        reverse_proxy 127.0.0.1:${toString calco.port}
      }

      # Hashed bundles are immutable, so cache them hard. Do not let a
      # missing chunk fall through to index.html: a 200 HTML response for a
      # .js request surfaces as a module-load error instead of a clean 404.
      handle /assets/* {
        header Cache-Control "public, max-age=31536000, immutable"
        file_server
      }

      # index.html and version.json must be revalidated so a redeploy can
      # point clients at the new hashed chunks.
      handle {
        header Cache-Control "no-cache"
        try_files {path} /index.html
        file_server
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

### Example: nginx

```nix
{ config, ... }: let calco = config.services.calco; in {
  services.calco = {
    enable = true;
    secretsFile = config.age.secrets.calco-env.path;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."calco.example.com" = {
      root = "${calco.frontendPackage}/share/calco/web";

      # Hashed bundles are immutable. `tryFiles = "$uri =404"` keeps a
      # missing chunk a 404 instead of the SPA fallback returning index.html.
      locations."/assets/" = {
        tryFiles = "$uri =404";
        extraConfig = "add_header Cache-Control \"public, max-age=31536000, immutable\";";
      };

      # Revalidate the entry document and version manifest on every request.
      locations."= /index.html" = {
        extraConfig = "add_header Cache-Control \"no-cache\";";
      };

      locations."= /version.json" = {
        extraConfig = "add_header Cache-Control \"no-cache\";";
      };

      locations."/".tryFiles = "$uri $uri/ /index.html";
      locations."/api/".proxyPass = "http://127.0.0.1:${toString calco.port}/";
    };
  };
}
```

### Static assets and the SPA fallback

Vite emits content-hashed bundles under `/assets/`. Keep that prefix out of the
`try_files ... /index.html` fallback so a missing or retired chunk returns a
404 rather than `index.html`. Otherwise the browser receives HTML with a 200
status for a `.js` request and reports a module-load error, and a lazily loaded
chunk from a previous deploy fails in a way that looks like a scanner/code bug.

Because the hashes are immutable, serve `/assets/*` with a long-lived
`Cache-Control`, and serve `index.html` and `version.json` with `no-cache` so a
redeploy can point clients at the new hashes. The frontend is shipped as an
immutable Nix store path, so the entry document and every chunk always come
from the same build within a deploy.

### Example: assistant provider

Assistant configuration is generated as TOML and passed to the backend through
`CALCO_CONFIG_FILE`. API-key files are referenced by runtime path and are not
read or copied into the Nix store.

```nix
services.calco.assistant = {
  enable = true;
  endpoint = "https://provider.example/v1/chat/completions";
  model = "provider-model";
  supportsImages = true;
  authentication = {
    kind = "bearer";
    apiKeyFile = "/run/secrets/calco-assistant-api-key";
  };
};
```

## `services.calco` options

| option | type | default | description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | turn on the backend, postgres, migrate oneshot |
| `port` | port | `8080` | backend listens on `127.0.0.1:port` |
| `secretsFile` | path | — | `EnvironmentFile` for the backend (see below) |
| `backendPackage` | package | `calco.packages.<sys>.backend` | override the backend build |
| `frontendPackage` | package | `calco.packages.<sys>.frontend` | static bundle root — point your proxy at `${pkg}/share/calco/web` |
| `assistant.enable` | bool | `false` | enable the food assistant |
| `assistant.endpoint` | string | `""` | complete OpenAI-compatible Chat Completions endpoint URL |
| `assistant.model` | string | `""` | provider model identifier |
| `assistant.supportsImages` | bool | `false` | whether the model accepts image input |
| `assistant.authentication.kind` | `none`, `bearer`, or `header` | `none` | provider authentication method |
| `assistant.authentication.headerName` | null or string | `null` | header used by `header` authentication |
| `assistant.authentication.apiKeyFile` | null or string | `null` | runtime API-key file path |

## Secrets file format

Plaintext `KEY=VALUE` lines passed via systemd `EnvironmentFile`:

```text
CORS_ALLOWED_ORIGINS=https://calco.example.com
SESSION_COOKIE_NAME=calco_session
SESSION_COOKIE_SECURE=true
SESSION_TTL_SECONDS=604800
```

`DATABASE_URL`, `APP_HOST`, `APP_PORT` are set by the module itself — do
not put them in this file.

> **Warning:** `CORS_ALLOWED_ORIGINS` is a credential-minting trust boundary.
> When it is non-empty, the backend enables credentialed CORS for those origins.
> Any listed origin can use a signed-in user's session cookie to call the
> API-key management route and read the raw token from the create response. List
> only first-party origins you control.

The module reads only the environment variables in `backend/src/config/`; everything there
has a sane default except `DATABASE_URL` (set by the module).

## What the module sets up

- `services.postgresql` with a `calco` DB + role, peer auth on the Unix socket (no DB password needed).
- `services.postgresqlBackup` — nightly zstd dump to `/var/backup/postgresql/`.
- `calco-migrate.service` — oneshot, runs `sqlx migrate run` against the migrations baked into the backend package, before `calco-backend.service` starts.
- `calco-backend.service` — hardened systemd unit (`ProtectSystem=strict`, `MemoryDenyWriteExecute`, etc.), runs as a dedicated `calco` system user, listens on `127.0.0.1:cfg.port`.

The module does **not** configure a reverse proxy, TLS, or open firewall
ports — that's the consumer's job.

## Backups

The NixOS module enables nightly PostgreSQL backups through
`services.postgresqlBackup`. Outside NixOS, back up PostgreSQL with normal
PostgreSQL tooling such as `pg_dump` or volume snapshots.

Tables worth treating as user-critical:

- `identities`
- `user_profiles`
- `sessions` if preserving login sessions matters
- `products`
- `product_nutrients`
- `product_servings`
- `food_logs`
- `food_log_nutrients`
- `meals`
- `meal_components`

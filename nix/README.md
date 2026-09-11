# CalCo NixOS module

This flake exports:

- `packages.${system}.backend` — axum binary + `share/calco/migrations/`
- `packages.${system}.frontend` — static Elm/Vite bundle in `share/calco/web/`
- `nixosModules.default` — `services.calco`

It does **not** know about your host, secrets, or SSH keys. Wire those up
from your own system flake (dotfiles / nixos-config repo).

## Files

- `backend.nix` — Rust derivation (no `.sqlx/` needed; backend uses runtime queries only).
- `frontend.nix` — Elm + Vite static site. Pinned via `elm-srcs.nix`, `registry.dat`, and `npmDepsHash`.
- `module.nix` — defines `services.calco`. Sets up `services.postgresql`, a migrate oneshot, the backend systemd unit, and an nginx vhost.

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
      file_server
      try_files {path} /index.html
      handle /api/* {
        reverse_proxy 127.0.0.1:${toString calco.port}
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
      locations."/".tryFiles = "$uri $uri/ /index.html";
      locations."/api/".proxyPass = "http://127.0.0.1:${toString calco.port}/";
    };
  };
}
```

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

```
CORS_ALLOWED_ORIGINS=https://calco.example.com
SESSION_COOKIE_NAME=calco_session
SESSION_COOKIE_SECURE=true
SESSION_TTL_SECONDS=604800
```

`DATABASE_URL`, `APP_HOST`, `APP_PORT` are set by the module itself — do
not put them in this file.

The module reads only the environment variables in `backend/src/config/`; everything there
has a sane default except `DATABASE_URL` (set by the module).

## What the module sets up

- `services.postgresql` with a `calco` DB + role, peer auth on the Unix socket (no DB password needed).
- `services.postgresqlBackup` — nightly zstd dump to `/var/backup/postgresql/`.
- `calco-migrate.service` — oneshot, runs `sqlx migrate run` against the migrations baked into the backend package, before `calco-backend.service` starts.
- `calco-backend.service` — hardened systemd unit (`ProtectSystem=strict`, `MemoryDenyWriteExecute`, etc.), runs as a dedicated `calco` system user, listens on `127.0.0.1:cfg.port`.

The module does **not** configure a reverse proxy, TLS, or open firewall
ports — that's the consumer's job.

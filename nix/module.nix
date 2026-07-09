{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.calco;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;
in
{
  options.services.calco = {
    enable = mkEnableOption "CalCo nutrition tracker";

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Localhost port the backend listens on (127.0.0.1).";
    };

    databaseUser = mkOption {
      type = types.str;
      default = "calco";
      description = "PostgreSQL user name and Linux system user for CalCo services.";
    };

    databaseName = mkOption {
      type = types.str;
      default = "calco";
      description = "PostgreSQL database name.";
    };

    secretsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        EnvironmentFile for the backend. Plaintext KEY=VALUE lines for any of:
        CORS_ALLOWED_ORIGINS, SESSION_COOKIE_NAME, SESSION_COOKIE_SECURE,
        SESSION_TTL_SECONDS, DATABASE_URL.

        The module auto-generates DATABASE_URL from databaseUser and
        databaseName for local peer-auth. Set DATABASE_URL here to override
        the default (e.g. for remote PostgreSQL or password auth).

        Typically points at an agenix- or sops-decrypted path.
      '';
    };

    backendPackage = mkOption {
      type = types.package;
      default = self.packages.${pkgs.system}.backend;
      description = "Backend package to deploy.";
    };

    frontendPackage = mkOption {
      type = types.package;
      default = self.packages.${pkgs.system}.frontend;
      description = ''
        Frontend static-asset package. Consumers point their reverse proxy
        (caddy/nginx/...) at `''${cfg.frontendPackage}/share/calco/web`.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.databaseUser} = {
      isSystemUser = true;
      group = cfg.databaseUser;
    };
    users.groups.${cfg.databaseUser} = { };

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
      ensureDatabases = [ cfg.databaseName ];
      ensureUsers = [
        {
          name = cfg.databaseUser;
          ensureDBOwnership = true;
        }
      ];
    };

    services.postgresqlBackup = {
      enable = true;
      databases = [ cfg.databaseName ];
      startAt = "*-*-* 02:00:00";
      compression = "zstd";
    };

    systemd.services.calco-migrate = {
      description = "CalCo database migrations";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      requiredBy = [ "calco-backend.service" ];
      before = [ "calco-backend.service" ];

      # Re-run when the backend package (and thus its migrations) changes.
      # Already implied because ExecStart embeds the store path, but explicit
      # is friendlier to future refactors.
      restartTriggers = [ cfg.backendPackage ];

      path = [ pkgs.sqlx-cli ];
      environment.DATABASE_URL = "postgres://${cfg.databaseUser}@localhost/${cfg.databaseName}?host=/run/postgresql";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.databaseUser;
        Group = cfg.databaseUser;
        ExecStart = "${pkgs.sqlx-cli}/bin/sqlx migrate run --source ${cfg.backendPackage}/share/calco/migrations";
      };
    };

    systemd.services.calco-backend = {
      description = "CalCo backend (axum)";
      after = [
        "calco-migrate.service"
        "network.target"
      ];
      requires = [ "calco-migrate.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        APP_HOST = "127.0.0.1";
        APP_PORT = toString cfg.port;
        DATABASE_URL = "postgres://${cfg.databaseUser}@localhost/${cfg.databaseName}?host=/run/postgresql";
        RUST_LOG = "info";
      };

      serviceConfig = {
        User = cfg.databaseUser;
        Group = cfg.databaseUser;
        ExecStart = lib.getExe cfg.backendPackage;
        EnvironmentFile = lib.optional (cfg.secretsFile != null) cfg.secretsFile;
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = "native";
      };
    };
  };
}

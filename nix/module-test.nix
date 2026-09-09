{
  self,
  nixpkgs,
  pkgs,
}:

let
  lib = nixpkgs.lib;

  evalCalco =
    ai:
    lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        self.nixosModules.default
        {
          system.stateVersion = "24.11";

          services.calco = {
            enable = true;
            backendPackage = pkgs.hello;
            inherit ai;
          };
        }
      ];
    };

  disabled = evalCalco { };
  bearerWithMissingSecret = evalCalco {
    enable = true;
    endpoint = "https://provider.example/v1/chat/completions";
    model = "provider-model";
    supportsImages = true;
    authentication = {
      kind = "bearer";
      # This deliberately does not exist. Evaluation and generation must retain
      # this as metadata without reading it or copying it into the Nix store.
      apiKeyFile = "/run/secrets/calco-ai-api-key-that-does-not-exist";
    };
  };

  header = evalCalco {
    enable = true;
    endpoint = "https://provider.example/v1/chat/completions";
    model = "provider-model";
    authentication = {
      kind = "header";
      headerName = "api-key";
      apiKeyFile = "/run/secrets/calco-ai-api-key-that-does-not-exist";
    };
  };
in
pkgs.runCommand "calco-nixos-module-evaluation"
  {
    disabledConfig = disabled.config.systemd.services.calco-backend.environment.CALCO_CONFIG_FILE;
    bearerConfig =
      bearerWithMissingSecret.config.systemd.services.calco-backend.environment.CALCO_CONFIG_FILE;
    headerConfig = header.config.systemd.services.calco-backend.environment.CALCO_CONFIG_FILE;
  }
  ''
    touch "$out"
  ''

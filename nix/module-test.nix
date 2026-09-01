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
      system = pkgs.system;
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

  validNone = evalCalco {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
    model = "gemma3:12b";
    authentication.kind = "none";
  };

  validBearer = evalCalco {
    enable = true;
    endpoint = "https://api.example.com/v1/chat/completions";
    model = "vision-model";
    supportsImages = true;
    authentication = {
      kind = "bearer";
      apiKeyFile = "/run/secrets/calco-ai-api-key";
    };
  };

  validHeader = evalCalco {
    enable = true;
    endpoint = "https://provider.example.com/chat/completions?api-version=2026-01-01";
    model = "deployment-name";
    supportsImages = true;
    authentication = {
      kind = "header";
      headerName = "api-key";
      apiKeyFile = "/run/secrets/calco-ai-api-key";
    };
  };

  assertionFails =
    ai: !(builtins.tryEval (evalCalco ai).config.system.build.toplevel.drvPath).success;

  invalidEndpoint = assertionFails {
    enable = true;
    model = "model";
  };
  invalidModel = assertionFails {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
  };
  invalidBearer = assertionFails {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
    model = "model";
    authentication.kind = "bearer";
  };
  invalidHeaderKey = assertionFails {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
    model = "model";
    authentication = {
      kind = "header";
      headerName = "api-key";
    };
  };
  invalidHeaderName = assertionFails {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
    model = "model";
    authentication = {
      kind = "header";
      apiKeyFile = "/run/secrets/calco-ai-api-key";
    };
  };
  invalidNoneKey = assertionFails {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
    model = "model";
    authentication = {
      kind = "none";
      apiKeyFile = "/run/secrets/calco-ai-api-key";
    };
  };
  invalidNoneHeader = assertionFails {
    enable = true;
    endpoint = "http://127.0.0.1:11434/v1/chat/completions";
    model = "model";
    authentication = {
      kind = "none";
      headerName = "api-key";
    };
  };

  checkAssertions =
    assert invalidEndpoint;
    assert invalidModel;
    assert invalidBearer;
    assert invalidHeaderKey;
    assert invalidHeaderName;
    assert invalidNoneKey;
    assert invalidNoneHeader;
    true;
in
assert checkAssertions;
pkgs.runCommand "calco-nixos-module-evaluation"
  {
    noneConfig = validNone.config.systemd.services.calco-backend.environment.CALCO_CONFIG_FILE;
    bearerConfig = validBearer.config.systemd.services.calco-backend.environment.CALCO_CONFIG_FILE;
    headerConfig = validHeader.config.systemd.services.calco-backend.environment.CALCO_CONFIG_FILE;
  }
  ''
    grep -F 'enabled = true' "$noneConfig"
    grep -F 'kind = "none"' "$noneConfig"
    ! grep -Eq 'api_key_file|header_name' "$noneConfig"

    grep -F 'kind = "bearer"' "$bearerConfig"
    grep -F 'api_key_file = "/run/secrets/calco-ai-api-key"' "$bearerConfig"

    grep -F 'kind = "header"' "$headerConfig"
    grep -F 'header_name = "api-key"' "$headerConfig"
    grep -F 'api_key_file = "/run/secrets/calco-ai-api-key"' "$headerConfig"

    touch "$out"
  ''

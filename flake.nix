{
  description = "CalCo — Food & Nutrition Tracker";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
    }:
    let
      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          toolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rust-analyzer"
              "llvm-tools"
            ];
          };

          rustPlatform = pkgs.makeRustPlatform {
            cargo = toolchain;
            rustc = toolchain;
          };

          frontendVersion =
            self.shortRev or (self.dirtyShortRev or (toString (self.lastModified or 0)));
        in
        {
          packages.backend = pkgs.callPackage ./nix/backend.nix {
            inherit rustPlatform;
            rustToolchain = toolchain;
          };

          packages.frontend = pkgs.callPackage ./nix/frontend.nix {
            inherit frontendVersion;
          };

          packages.default = self.packages.${system}.backend;

          checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            calco-nixos-module-evaluation = import ./nix/module-test.nix {
              inherit self nixpkgs pkgs;
            };
          };

          devShells.default = pkgs.mkShell {
            buildInputs = with pkgs; [
              # Backend
              toolchain
              cargo-nextest
              cargo-llvm-cov
              sqlx-cli

              # Frontend
              nodejs_22
              elmPackages.elm
              elmPackages.elm-format
              elmPackages.elm-review
              elmPackages.elm-test

              # Tools
              just
              docker-compose
              uv

              # i18n code generation (i18n2elm escript build only)
              beam29Packages.elixir_1_20
              beam29Packages.erlang
            ];

            shellHook = ''
              echo "CalCo dev shell"
              echo "  Rust:  $(cargo --version)"
              echo "  Node:  $(node --version)"
              echo "  Elm:   $(elm --version)"
              echo "  Elixir: $(elixir --version | tail -n 1)"
              echo ""
              if [ ! -d frontend-web/node_modules ]; then
                echo "  Installing frontend-web npm dependencies (one-time)..."
                (cd frontend-web && npm install)
              fi
              echo ""
              echo "  Commands:"
              echo "    just db-up        — start PostgreSQL"
              echo "    just dev-backend  — run backend"
              echo "    just dev-frontend — run frontend"
            '';
          };
        }
      );
    in
    perSystem
    // {
      nixosModules.default = import ./nix/module.nix { inherit self; };
    };
}

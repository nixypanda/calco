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
        in
        {
          packages.backend = pkgs.callPackage ./nix/backend.nix {
            inherit rustPlatform;
          };

          packages.frontend = pkgs.callPackage ./nix/frontend.nix { };

          packages.default = self.packages.${system}.backend;

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
            ];

            shellHook = ''
              echo "CalCo dev shell"
              echo "  Rust:  $(cargo --version)"
              echo "  Node:  $(node --version)"
              echo "  Elm:   $(elm --version)"
              echo ""
              if [ ! -d frontend-web/node_modules ]; then
                echo "  Installing frontend-web npm dependencies (one-time)..."
                (cd frontend-web && npm install)
              fi
              echo ""
              echo "  Commands:"
              echo "    just up         — start PostgreSQL"
              echo "    just backend-dev — run backend"
              echo "    just frontend-web-dev — run frontend"
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

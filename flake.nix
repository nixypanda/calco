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
    flake-utils.lib.eachDefaultSystem (
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
      in
      {
        # Dev shell with all tooling for both backend and frontend
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Backend
            toolchain
            cargo-nextest
            cargo-llvm-cov
            sqlx-cli

            # Frontend
            nodejs_22
            pnpm

            # Tools
            just
            docker-compose
            uv
          ];

          shellHook = ''
            echo "CalCo dev shell"
            echo "  Rust:  $(cargo --version)"
            echo "  Node:  $(node --version)"
            echo ""
            echo "  Commands:"
            echo "    just up         — start PostgreSQL"
            echo "    just backend-dev — run backend"
            echo "    just frontend-dev — run frontend"
          '';
        };

      }
    );
}

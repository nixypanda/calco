{
  lib,
  stdenv,
  rustPlatform,
  rustToolchain,
}:

rustPlatform.buildRustPackage {
  pname = "calco-cli";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../frontend-cli;
    filter =
      name: type:
      let
        base = baseNameOf name;
      in
      !(builtins.elem base [ "target" ]);
  };

  cargoLock.lockFile = ../frontend-cli/Cargo.lock;

  # Keyring 4.2 uses the macOS Security framework and, on Linux, the Secret
  # Service D-Bus API through zbus. Neither adds a build-time system library,
  # but Linux users need a running Secret Service provider (for example
  # gnome-keyring) in their session.

  # Keep the toolchain and build paths out of the binary's runtime closure for
  # the same reason as nix/backend.nix. `$NIX_BUILD_TOP` is only available
  # during the build.
  preBuild = ''
    mkdir -p .cargo
    cat >> .cargo/config.toml <<EOF

    [target."cfg(all())"]
    rustflags = [
      "--remap-path-prefix=${rustToolchain}=/rustc",
      "--remap-path-prefix=$NIX_BUILD_TOP=/",
    ]
    EOF
  '';

  doCheck = true;

  # The CLI tests start loopback-only mock HTTP servers. Darwin's Nix sandbox
  # blocks network access by default, including localhost, so allow only local
  # networking instead of disabling the sandbox. This is a property of the
  # machine running the build. On Linux the attribute has no effect; the build
  # sandbox already provides loopback networking there.
  __darwinAllowLocalNetworking = stdenv.buildPlatform.isDarwin;

  meta = {
    description = "CalCo command-line client";
    license = lib.licenses.agpl3Only;
    mainProgram = "calco";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}

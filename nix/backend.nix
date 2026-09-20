{
  lib,
  rustPlatform,
  rustToolchain,
  pkg-config,
  openssl,
}:

rustPlatform.buildRustPackage {
  pname = "calco-backend";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../backend;
    filter =
      name: type:
      let
        base = baseNameOf name;
      in
      !(builtins.elem base [ "target" ]);
  };

  cargoLock.lockFile = ../backend/Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  # The backend uses only runtime sqlx queries (no `query!` macros), so no
  # offline metadata is required and SQLX_OFFLINE is unnecessary.

  # Mirror the path remapping that upstream `buildRustCrate` performs but
  # `buildRustPackage` does not (see nixpkgs
  # pkgs/build-support/rust/build-rust-crate/build-crate.nix):
  #
  # 1. Rust embeds the standard-library source paths from the toolchain
  #    sysroot into panic `Location` strings. When the toolchain ships
  #    `rust-src` (as rust-overlay's does), those are real store paths, and
  #    Nix's reference scanner then pulls the whole compiler toolchain
  #    (rustc, cargo, rust-src, llvm, clang, the Apple SDK, rust-docs) into
  #    the binary's *runtime* closure.
  # 2. Cargo compiles dependencies from a vendor directory inside the
  #    non-deterministic build directory, so those paths must be remapped
  #    for reproducible output.
  #
  # These are appended to cargo's own `target."cfg(all())".rustflags` instead
  # of being set through `RUSTFLAGS`, because Cargo treats `RUSTFLAGS` and
  # `target.*.rustflags` as mutually exclusive: setting `RUSTFLAGS` would
  # silently drop the `-Cforce-frame-pointers=yes` that `cargoSetupHook`
  # writes into `.cargo/config.toml`. Cargo joins all matching
  # `target.<triple>.rustflags` and `target.<cfg>.rustflags` entries.
  #
  # `$NIX_BUILD_TOP` is only known during the build, hence `preBuild`.
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

  # Ship migrations next to the binary so the migrate oneshot can find them.
  postInstall = ''
    mkdir -p $out/share/calco
    cp -r ${../backend/migrations} $out/share/calco/migrations
  '';

  doCheck = false;

  meta = {
    description = "CalCo backend (axum + sqlx)";
    mainProgram = "calco-backend";
  };
}

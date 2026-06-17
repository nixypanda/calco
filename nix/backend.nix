{
  lib,
  rustPlatform,
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

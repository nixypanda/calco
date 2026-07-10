{
  lib,
  stdenv,
  buildNpmPackage,
  elmPackages,
  nodejs_22,
  git,
  frontendVersion ? "dev",
}:

buildNpmPackage {
  pname = "calco-frontend-web";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../frontend-web;
    filter =
      name: type:
      let
        base = baseNameOf name;
      in
      !(builtins.elem base [
        "node_modules"
        "dist"
        "elm-stuff"
      ]);
  };

  npmDepsHash = "sha256-wQ/wjmwl0a/k68JpHd3BnLFe5c5i2UB6qjaKbwoRU8I=";
  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    elmPackages.elm
    nodejs_22
    git
  ];

  # Elm needs its package registry cache; fetchElmDeps wires it up offline.
  postConfigure = elmPackages.fetchElmDeps {
    elmPackages = import ./elm-srcs.nix;
    elmVersion = "0.19.1";
    registryDat = ./registry.dat;
  };

  buildPhase = ''
    runHook preBuild
    export CALCO_FRONTEND_VERSION=${lib.escapeShellArg frontendVersion}
    npm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/calco/web
    cp -r dist/* $out/share/calco/web/
    runHook postInstall
  '';

  dontNpmPrune = true;

  meta.description = "CalCo frontend (Elm + Vite)";
}

{ lib, stdenv, buildNpmPackage, elmPackages, nodejs_22 }:

buildNpmPackage {
  pname = "calco-frontend-web";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../frontend-web;
    filter = name: type:
      let base = baseNameOf name; in
      !(builtins.elem base [ "node_modules" "dist" "elm-stuff" ]);
  };

  npmDepsHash = "sha256-r8nQlU7455FEgJvhbGY2N2bFZyiXLtwOCMt6qWSxdiU=";

  nativeBuildInputs = [
    elmPackages.elm
    nodejs_22
  ];

  # Elm needs its package registry cache; fetchElmDeps wires it up offline.
  configurePhase = ''
    runHook preConfigure
    ${elmPackages.fetchElmDeps {
      elmPackages = (import ./elm-srcs.nix);
      elmVersion = "0.19.1";
      registryDat = ./registry.dat;
    }}
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
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

# Swish, built from this checkout and Swiit's source. Swish names Swiit by path
# (`.package(path: "../Swiit")`), so the build lays the two out side by side,
# as they are checked out.
{
  lib,
  stdenv,
  runCommand,
  swift,
  swiftpm,
  fetchSwiftPMDeps,
  src,
  swiit,
}:

let
  sources = runCommand "swish-sources" { } ''
    mkdir -p "$out"
    cp -r ${src} "$out/Swish"
    cp -r ${swiit} "$out/Swiit"
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "swish";
  version = "0-unstable";

  src = sources;
  sourceRoot = "${sources.name}/Swish";

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  # What Package.resolved pins: swift-syntax and swift-system, Swiit's as well.
  swiftpmDeps = fetchSwiftPMDeps {
    inherit (finalAttrs) pname version;
    inherit src;
    hash = "sha256-Jr5rrxrVdJFjJcLAVqJ6okC13pXHzMoSZ77/RQNRFyU=";
  };

  # The SwiftPM hooks write into the tree; the sources were copied from the store read-only.
  postUnpack = ''
    chmod -R u+w "$sourceRoot" "$sourceRoot/../Swiit"
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$(swiftpmBinPath)/swish" "$out/bin/"
    runHook postInstall
  '';

  # The tests drive processes and a terminal, which the build sandbox doesn't have.
  doCheck = false;

  passthru.shellPath = "/bin/swish";

  meta = {
    description = "A shell whose language is Swift";
    homepage = "https://github.com/raklaptudirm/Swish";
    mainProgram = "swish";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})

# The scan engine: Objective-C, x86_64 (drives Canon's TWAIN driver under Rosetta).
{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "drs150scan";
  version = "0.1.0";
  src = ../src;
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    clang -arch x86_64 -fobjc-arc -o drs150scan scanjob.m \
      -framework Foundation -framework AppKit
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 drs150scan $out/bin/drs150scan
    runHook postInstall
  '';
  meta = {
    description = "Headless ADF scan engine for the Canon DR-S150";
    license = lib.licenses.eupl12;
    platforms = lib.platforms.darwin;
  };
}

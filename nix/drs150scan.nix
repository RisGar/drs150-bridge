# The scan engine: Objective-C, x86_64 (drives Canon's TWAIN driver under Rosetta).
#
#   pkgs.callPackage ./nix/drs150scan.nix { }
{
  stdenv,
  version ? "0.3.0",
}:

stdenv.mkDerivation {
  pname = "drs150scan";
  inherit version;
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
  meta.description = "Headless ADF scan engine for the Canon DR-S150";
}

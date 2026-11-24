# eSCL 2.0 subset + Bonjour, runs natively (no cross target, no Rosetta).
{
  lib,
  rustPlatform,
}:

let
  version = (fromTOML (builtins.readFile ../rust/escl-server/Cargo.toml)).package.version;
in
rustPlatform.buildRustPackage {
  pname = "escl-server";
  inherit version;
  src = ../rust/escl-server;
  cargoLock.lockFile = ../rust/escl-server/Cargo.lock;
  doCheck = false; # the tests manipulate $HOME; the dev shell runs them
  meta = {
    description = "eSCL (AirScan) bridge for the Canon DR-S150, driving the ObjC scan engine";
    license = lib.licenses.eupl12;
    platforms = lib.platforms.darwin;
  };
}

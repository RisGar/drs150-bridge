# eSCL 2.0 subset + Bonjour, runs natively (no cross target, no Rosetta).
#
#   pkgs.callPackage ./nix/escl-server.nix { }
{
  rustPlatform,
  version ? "0.3.0",
}:

rustPlatform.buildRustPackage {
  pname = "escl-server";
  inherit version;
  src = ../rust/escl-server;
  cargoLock.lockFile = ../rust/escl-server/Cargo.lock;
  doCheck = false; # the tests manipulate $HOME; the dev shell runs them
}

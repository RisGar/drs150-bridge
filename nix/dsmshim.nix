# libdsmshim2 — minimal TWAIN source manager that the copied Canon driver imports `DSM_Entry`
# from. Loaded by the x86_64 scan engine under Rosetta, so the dylib must be x86_64 too:
# pass a `rustPlatform` whose toolchain has the `x86_64-apple-darwin` std (see ./default.nix).
#
#   pkgs.callPackage ./nix/dsmshim.nix { }
{
  rustPlatform,
  clang,
  version ? "0.3.0",
}:

rustPlatform.buildRustPackage {
  pname = "dsmshim";
  inherit version;
  src = ../rust/shim;
  cargoLock.lockFile = ../rust/shim/Cargo.lock;
  # buildRustPackage only cross-builds when the target is in the cargo flags.
  CARGO_BUILD_TARGET = "x86_64-apple-darwin";
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER = "${clang}/bin/clang";
  cargoBuildFlags = [
    "--target"
    "x86_64-apple-darwin"
  ];
  doCheck = false; # the tests are host-targeted; `nix develop` runs them
  installPhase = ''
    mkdir -p $out/lib
    install -m755 target/x86_64-apple-darwin/release/libdsmshim.dylib \
      $out/lib/libdsmshim2.dylib
  '';
}

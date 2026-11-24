# The three derivations plus the combined `default`, as a plain callPackage-able set:
#
#   pkgs.callPackage ./. { }                                      # host rustPlatform for the shim
#   pkgs.callPackage ./. { rustPlatform = crossRustPlatform; }     # x86_64 shim (what Rosetta needs)
#
# The individual packages live in ./nix and are callPackage-able on their own too, e.g.
# `pkgs.callPackage ./nix/escl-server.nix { }`. The shim is the only one that cares about the
# target: it is dlopen-ed by the x86_64 engine, so with a host `rustPlatform` it builds for the
# host and the engine cannot load it.
{
  callPackage,
  rustPlatform,
  symlinkJoin,
  version ? "0.3.0",
}:

let
  rustArgs = {
    inherit version rustPlatform;
  };
in
rec {
  dsmshim = callPackage ./nix/dsmshim.nix rustArgs;
  escl-server = callPackage ./nix/escl-server.nix rustArgs;
  drs150scan = callPackage ./nix/drs150scan.nix { inherit version; };

  default = symlinkJoin {
    pname = "drs150-bridge";
    inherit version;
    paths = [
      dsmshim
      escl-server
      drs150scan
    ];
    meta = {
      description = "eSCL bridge for the Canon DR-S150 (drives the Canon TWAIN driver)";
      mainProgram = "escl-server";
    };
  };
}

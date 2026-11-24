{
  description = "Canon DR-S150 → eSCL/AirScan bridge (Objective-C engine + Rust shim/server)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      systems = [ "aarch64-darwin" ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ (import rust-overlay) ];
            }
          )
        );

      # Canon's driver is x86_64-only and runs under Rosetta, so the engine and the shim it loads must be x86_64 while the server stays native
      mkRust =
        pkgs:
        pkgs.rust-bin.stable.latest.default.override {
          targets = [ "x86_64-apple-darwin" ];
        };

    in
    {
      # The derivations are plain `pkgs.callPackage` calls on the repo-root ./default.nix; the flake
      # only supplies what that file cannot take from nixpkgs: the x86_64-capable rustPlatform.
      packages = forAllSystems (
        pkgs:
        let
          rust = mkRust pkgs;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rust;
            rustc = rust;
          };
          # callPackage also hands back `override`/`overrideDerivation`, which are not derivations
          # and so are not allowed in a flake's `packages`; pick the four outputs explicitly.
          bridge = pkgs.callPackage ./. {
            inherit rustPlatform;
          };
        in
        {
          inherit (bridge)
            dsmshim
            escl-server
            drs150scan
            default
            ;
        }
      );

      # home-manager: `services.drs150-bridge.enable = true;`
      homeModules.default = self.homeModules.drs150-bridge;

      devShells = forAllSystems (
        pkgs:
        let
          rust = mkRust pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              rust
              pkgs.clang
              pkgs.jq
              pkgs.curl
            ];
            shellHook = ''
              echo "DR-S150 bridge — cargo $(cargo --version | cut -d' ' -f2)"
              echo "  build:  nix build .#default"
              echo "  test:   (cd rust/shim && cargo test) && (cd rust/escl-server && cargo test)"
              echo "  deploy: home-manager services.drs150-bridge.enable = true"
            '';
          };
        }
      );
      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}

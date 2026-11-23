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
      packages = forAllSystems (
        pkgs:
        let
          rust = pkgs.rust-bin.stable.latest.default.override {
            targets = [ "x86_64-apple-darwin" ];
          };
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rust;
            rustc = rust;
          };
          version = "0.3.0";
        in
        rec {
          # Minimal TWAIN source manager: the copied driver imports DSM_Entry from this dylib.
          dsmshim = rustPlatform.buildRustPackage {
            pname = "dsmshim";
            inherit version;
            src = ./rust/shim;
            cargoLock.lockFile = ./rust/shim/Cargo.lock;
            # Loaded by the x86_64 engine under Rosetta, so the dylib must be x86_64.
            # buildRustPackage only cross-builds when the target is in the cargo flags.
            CARGO_BUILD_TARGET = "x86_64-apple-darwin";
            CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER = "${pkgs.clang}/bin/clang";
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
          };

          # eSCL 2.0 subset + Bonjour, runs natively.
          escl-server = rustPlatform.buildRustPackage {
            pname = "escl-server";
            inherit version;
            src = ./rust/escl-server;
            cargoLock.lockFile = ./rust/escl-server/Cargo.lock;
            doCheck = false; # the tests manipulate $HOME; the dev shell runs them
          };

          # The scan engine: Objective-C, x86_64 (drives Canon's TWAIN driver under Rosetta).
          drs150scan = pkgs.stdenv.mkDerivation {
            pname = "drs150scan";
            inherit version;
            src = ./src;
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
          };

          default = pkgs.symlinkJoin {
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
      );

      # home-manager: `services.drs150-bridge.enable = true;`
      homeModules.default = self.homeModules.drs150-bridge;
      homeModules.drs150-bridge = import ./module.nix { inherit self; };

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

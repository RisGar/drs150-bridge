{
  description = "Canon DR-S150 → eSCL/AirScan bridge (Objective-C engine + Rust shim/server)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      }));

      # Canon's driver is x86_64-only and runs under Rosetta, so the engine and the shim it
      # loads must be x86_64 while the server stays native. rust-overlay gives us a Rust
      # toolchain that ships the x86_64-apple-darwin std (nixpkgs' own rustc does not).
      mkRust = pkgs: pkgs.rust-bin.stable.latest.default.override {
        targets = [ "x86_64-apple-darwin" ];
      };

      mkPackages = pkgs:
        let
          rust = mkRust pkgs;
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
            cargoBuildFlags = [ "--target" "x86_64-apple-darwin" ];
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
            paths = [ dsmshim escl-server drs150scan ];
            meta = {
              description = "eSCL bridge for the Canon DR-S150 (drives the Canon TWAIN driver)";
              mainProgram = "escl-server";
            };
          };
        };
    in
    {
      packages = forAll mkPackages;

      # home-manager: `services.drs150-bridge.enable = true;`
      homeModules.default = import ./nix/home-module.nix { inherit self; };
      homeModules.drs150-bridge = self.homeModules.default;

      devShells = forAll (pkgs:
        let rust = mkRust pkgs; in {
          default = pkgs.mkShell {
            packages = [ rust pkgs.clang pkgs.jq pkgs.curl ];
            shellHook = ''
              echo "DR-S150 bridge — cargo $(cargo --version | cut -d' ' -f2)"
              echo "  build:  nix build .#default"
              echo "  test:   (cd rust/shim && cargo test) && (cd rust/escl-server && cargo test)"
              echo "  deploy: home-manager services.drs150-bridge.enable = true"
            '';
          };
        });

      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${mkPackages pkgs.default}/bin/escl-server";
        };
      });

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}

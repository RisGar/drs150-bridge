# home-manager module for the DR-S150 eSCL bridge (home-manager >= 23.05, `launchd.agents`).
#
#   {
#     imports = [ inputs.drs150-bridge.homeModules.default ];
#     services.drs150-bridge.enable = true;
#   }
#
# It runs the Rust server as a launchd user agent. Everything the service owns lives in the XDG
# base directories (logs in `$XDG_STATE_HOME/drs150-bridge`, spool and the patched driver copy in
# `$XDG_DATA_HOME/drs150-bridge`), never in ~/Library.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.drs150-bridge;
  system = pkgs.stdenv.hostPlatform.system;
  stateDir = "${config.xdg.stateHome}/drs150-bridge";
  dataDir = "${config.xdg.dataHome}/drs150-bridge";
in
{
  options.services.drs150-bridge = {
    enable = lib.mkEnableOption "the Canon DR-S150 eSCL/AirScan bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.default;
      defaultText = lib.literalExpression "drs150-bridge.packages.\${system}.default";
      description = "Package providing `bin/escl-server`, `bin/drs150scan` and the TWAIN shim.";
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address to listen on. Loopback by default: the endpoint has no authentication and every
        job physically pulls a sheet from the scanner.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8632;
      description = "eSCL HTTP port.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Canon imageFORMULA DR-S150";
      description = "Bonjour service instance name shown in Image Capture.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "services.drs150-bridge drives Canon's macOS TWAIN driver; it is darwin-only.";
      }
    ];

    home.activation.drs150-bridge-state = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "${stateDir}" "${dataDir}"
    '';

    launchd.agents.drs150-bridge = {
      enable = true;
      config = {
        ProgramArguments = [ "${cfg.package}/bin/escl-server" ];
        EnvironmentVariables = {
          ESCL_BIND = cfg.bind;
          ESCL_PORT = toString cfg.port;
          ESCL_NAME = cfg.name;
          XDG_DATA_HOME = config.xdg.dataHome;
          XDG_STATE_HOME = config.xdg.stateHome;
        };
        RunAtLoad = true;
        # restart when it fails, but do not spin if it cannot bind its port
        KeepAlive = {
          SuccessfulExit = false;
        };
        ThrottleInterval = 10;
        ProcessType = "Background";
        StandardOutPath = "${stateDir}/stdout.log";
        StandardErrorPath = "${stateDir}/stderr.log";
      };
    };
  };
}

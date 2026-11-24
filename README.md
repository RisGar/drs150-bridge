# DR-S150 eSCL Bridge

Use a **Canon imageFORMULA DR-S150** (USB) with macOS **Image Capture** — no CaptureOnTouch UI,
no vendor scanning app.

macOS no longer lets Image Capture talk to TWAIN scanners, and Canon's macOS driver is TWAIN-only.
This project bridges the gap: a small daemon advertises a virtual **eSCL / AirScan** scanner over
Bonjour, and services each scan by driving the real Canon TWAIN driver headlessly.

```
Image Capture / Preview / NAPS2        this project                    hardware
┌──────────────────────┐   eSCL/HTTP   ┌──────────────────┐  TWAIN   ┌──────────────┐
│  AirScanScanner.app  │ ────────────► │ eSCL server (py) │ ───────► │ DRS150.ds    │ ──► DR-S150
│  (built into macOS)  │ ◄──────────── │  + scan engine   │ ◄─────── │ (Canon)      │      USB
└──────────────────────┘   image/jpeg  └──────────────────┘          └──────────────┘
```

## Why this exists

- Image Capture on current macOS only speaks **eSCL/AirScan**. The legacy `ICADevices` plugin API
  that third-party scanner drivers used is gone (the framework has no binary), and Apple's only
  device module is `AirScanScanner.app`.
- Canon's macOS driver for the DR-S150 is a **TWAIN data source** (`DRS150.ds`), and Apple's TWAIN
  source manager is a stub on modern macOS, so nothing can drive it any more.
- The driver _can_ still be driven — it just needs a source manager. Canon ships one
  (`ApTWAIN.framework`, inside CaptureOnTouch) that works, plus some persuasion documented in
  [`docs/REVERSE-ENGINEERING.md`](docs/REVERSE-ENGINEERING.md).

## Requirements

|                          |                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------------- |
| macOS                    | tested on macOS 27 (Tahoe) on Apple Silicon under Rosetta                                       |
| Canon DR-S150 Mac driver | installs `/Library/Image Capture/TWAIN Data Sources/DRS150.ds`                                  |
| CaptureOnTouch for Mac   | must stay installed — it provides `ApTWAIN.framework`, the working source manager               |
| Xcode command line tools | `clang` (Rosetta 2 needed for the x86_64 engine)                                                |
| Nix (flakes)             | builds everything: Rust via rust-overlay (with the `x86_64-apple-darwin` std), engine via clang |
| Canon scanner            | connected over **USB**, scanner panel set to USB connection mode                                |

> The scanner only honours one interface at a time. If its panel is set to wired LAN or Wi-Fi,
> USB commands are ignored and scans will fail.

## Build

```sh
nix build .#default          # -> result/bin/{escl-server,drs150scan} + result/lib/libdsmshim2.dylib
nix develop                  # dev shell: Rust (aarch64 + x86_64-darwin std), clang, jq, curl
nix run                      # run the server straight from the flake
```

Three derivations, no host toolchain and no `rustup`:

| Output                 | Language / target       | Why                                                                               |
| ---------------------- | ----------------------- | --------------------------------------------------------------------------------- |
| `packages.drs150scan`  | Objective-C, **x86_64** | Canon's TWAIN driver is x86_64-only, so the process loading it runs under Rosetta |
| `packages.dsmshim`     | Rust cdylib, **x86_64** | the driver's `DSM_Entry` import points at it; same architecture as the engine     |
| `packages.escl-server` | Rust, native            | eSCL/HTTP + Bonjour (`tiny_http`, `image`, `mdns-sd`)                             |

The derivations are plain `callPackage` functions — the repo-root [`default.nix`](default.nix)
assembles them from the per-package files in [`nix/`](nix) — so they also work without the flake as
long as your `pkgs` has `rust-overlay` applied:

```nix
let
  # only the shim cares: it is dlopen-ed by the Rosetta (x86_64) engine
  rust = pkgs.rust-bin.stable.latest.default.override {
    targets = [ "x86_64-apple-darwin" ];
  };
  rustPlatform = pkgs.makeRustPlatform { cargo = rust; rustc = rust; };
in
# -> { dsmshim, escl-server, drs150scan, default }
pkgs.callPackage /path/to/drs150-bridge { inherit rustPlatform; }
# or one at a time: pkgs.callPackage /path/to/drs150-bridge/nix/escl-server.nix { }
```

Nothing about Canon's installation is baked into the store: the system driver stays untouched, and
the server prepares a **patched copy** under `$XDG_DATA_HOME/drs150-bridge/driver/` at startup
(copy → `install_name_tool` → ad-hoc `codesign`), reusing it until the system driver changes.

## Deploy (home-manager)

```nix
{
  imports = [ inputs.drs150-bridge.homeModules.default ];

  services.drs150-bridge = {
    enable = true;
    # bind = "127.0.0.1";   # default: loopback only
    # port = 8632;
  };
}
```

That installs a launchd user agent (`gui/$UID/drs150-bridge`) that runs `bin/escl-server`, restarts
it when it fails, and creates the XDG directories. There is no install script and no LaunchAgent
plist to manage by hand; `home-manager switch` is the whole deployment.

State lives in XDG base directories (macOS defaults shown):

| Path                                                                         | Contents                                                                |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `$XDG_STATE_HOME/drs150-bridge/` (`~/.local/state/drs150-bridge`)            | `server.log`, `scan-engine.log`, `shim.log`, `stdout.log`, `stderr.log` |
| `$XDG_DATA_HOME/drs150-bridge/spool/` (`~/.local/share/drs150-bridge/spool`) | `page-<n>.raw`, `page.meta`, `mode.txt`                                 |
| `$XDG_DATA_HOME/drs150-bridge/driver/`                                       | the patched copy of `DRS150.ds`                                         |

Then open **Image Capture** → the scanner appears as **“Canon DR-S150 (bridge)”**. Anything else
that speaks AirScan (NAPS2, `scanimage` with sane-airscan, …) sees it too.

Configuration is per service instance:

| Variable                           | Default                  | Meaning                                                   |
| ---------------------------------- | ------------------------ | --------------------------------------------------------- |
| `ESCL_BIND`                        | `127.0.0.1`              | listen address; loopback only unless you opt into sharing |
| `ESCL_PORT`                        | `8632`                   | HTTP port                                                 |
| `ESCL_MDNS_HOST`                   | `drs150-bridge.local.`   | SRV target the bridge publishes (see below)               |
| `ESCL_NAME`                        | `Canon DR-S150 (bridge)` | Bonjour service name shown in Image Capture               |
| `ESCL_UUID`                        | fixed UUID               | must stay stable across restarts for Image Capture        |
| `ESCL_DATA_DIR` / `ESCL_STATE_DIR` | XDG defaults             | override the spool / log locations                        |

Colour is per job, not per server: it is taken from the `<scan:ColorMode>` element of the
`ScanSettings` the client posts, so Image Capture's colour picker just works.

### When the scanner is not plugged in

The scanner can come and go, so the service stays up regardless:

- `ScannerStatus` reports `<pwg:State>Stopped</pwg:State>` and `<scan:AdfState>ScannerAdfEmpty</scan:AdfState>`
  while the device is unreachable, so Image Capture greys it out instead of failing mid-scan.
- `POST /eSCL/ScanJobs` answers `503` and no ADF pass is started.
- Detection is a cached `drs150scan --probe` run (opens the TWAIN data source and exits, ~2 s,
  re-checked every 20 s), not a full scan — an unplugged scanner costs nothing but a probe.
- A scan that loses the scanner mid-pass ends with a clean `STOPFEEDER`/`CLOSEDS` and a `500`.

## Share it on the network

The daemon binds **loopback only** by default and registers `_uscan._tcp` with its own mDNS
responder, so the local Image Capture always sees it. To let other machines use it, set
`services.drs150-bridge.bind = "0.0.0.0"` (or `ESCL_BIND=0.0.0.0`) — and read this first:

- **macOS firewall.** With the firewall enabled, inbound connections are dropped until the process
  is allowed — that is now `result/bin/escl-server` from the Nix store: System Settings → Network →
  Firewall → Options, or `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <path>` plus
  `--unblockapp <path>`. Stealth mode also suppresses probe traffic.
- **Bonjour is link-local.** Multicast does not cross routers, so only hosts in the same
  segment/VLAN discover the scanner. Elsewhere, point the client at the address directly:
  `http://<this-mac>.local:8632/eSCL/ScannerStatus` (or the raw IP). Everything except discovery
  works over plain TCP.

**On the Bonjour host name.** The server runs its own mDNS responder (`mdns-sd`), so it publishes
its own A record. That record must _not_ be the Mac's `.local` name: two responders claiming
`<mac>.local` looks like a conflict to `mDNSResponder`, which then renames the machine's
LocalHostName to `<mac>-2`. Hence the bridge-specific `drs150-bridge.local.` (override with
`ESCL_MDNS_HOST`). If your Local hostname ever picked up a `-2` suffix, restore it with
`sudo scutil --set LocalHostName "<old name>"` or System Settings → General → Sharing.

There is **no authentication**. Anyone who can reach the port can start a job, and every job pulls
real paper through the ADF on your desk. Requests are logged with the client address in
`server.log`, one job owns the scanner at a time (others get `503`), and `ESCL_BIND=127.0.0.1`
plus `ESCL_NAME=<unique>` are available if you want it narrower or with a distinguishable name.

## Verify without Image Capture

```sh
curl http://127.0.0.1:8632/eSCL/ScannerStatus
curl http://127.0.0.1:8632/eSCL/ScannerCapabilities
# a real scan (drains the ADF; one NextDocument call per page, then 404).
# Swap Grayscale8 for RGB24 for a colour scan:
LOC=$(curl -si -X POST -H 'Content-Type: text/xml' \
  --data '<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"><scan:InputSource>Feeder</scan:InputSource><scan:XResolution>200</scan:XResolution><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ScanSettings>' \
  http://127.0.0.1:8632/eSCL/ScanJobs | awk '/^Location:/{print $2}' | tr -d '\r')
curl -o page.jpg "$LOC/NextDocument"
```

Logs: `$XDG_STATE_HOME/drs150-bridge/` (`server.log`, `scan-engine.log`, `shim.log`).
Scratch: `$XDG_DATA_HOME/drs150-bridge/spool/`.

## Troubleshooting

| Symptom                                                         | Cause / fix                                                                                                                                                                |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ScannerStatus` says `Stopped`, jobs get `503`                  | The scanner is not connected (or powered off / set to LAN). Plug it in; the probe re-checks every 20 s, no restart needed.                                                 |
| `OPENDS=1` in `scan-engine.log`, scans return 500               | The scanner is present but busy or showing a dialog. Clear it on the panel, or power-cycle (hold power ~4 s), then retry. Check `ioreg -p IOUSB \| grep DR-S150`.          |
| `ENABLEDS=3`                                                    | Scanner is still finishing a previous pass; wait a few seconds.                                                                                                            |
| `ENABLEDS=1` / `condition=11 (TWCC_SEQERROR)` with an empty ADF | The driver refuses to start a session when the feeder holds no paper. Load a sheet and retry; the engine still closes the session cleanly (`OPENDS=0` on the next run).    |
| Scanner not listed in Image Capture                             | Service not running (`launchctl print gui/$(id -u)/drs150-bridge`), or Bonjour not registered (`dns-sd -B _uscan._tcp`). Check `$XDG_STATE_HOME/drs150-bridge/server.log`. |
| `ApTWAIN source manager not found`                              | CaptureOnTouch was removed — reinstall it from Canon.                                                                                                                      |
| Scans are black/blank                                           | Load the ADF with the printed side facing the correct direction; check `page-<n>.raw` in the spool dir.                                                                    |

**Paper warning:** every scan request starts a real pass over the ADF, and the scanner's panel
page counter is cumulative. Test with a single sheet.

## Limitations

- **Grayscale8 and RGB24 are supported.** The mode comes from the job's `<scan:ColorMode>` (Image
  Capture's _Kind_ menu / NAPS2's colour setting): `RGB24` scans 24-bit colour, anything else
  8-bit grey. The server writes the choice to `<spool>/mode.txt` and passes the paths to the
  engine through its environment.
- One ADF pass per eSCL job: the engine drains the whole feeder (up to 100 pages) in a single
  session and the Rust server hands out one page per `NextDocument`, ending with `404`. Image
  Capture therefore returns a multi-page document, but a job cannot be resumed after the ADF is
  emptied — reload paper and start a new scan.
- The scanner panel shows **Scanning** for the whole pass; it returns to idle when the ADF is
  empty. Cancelling a pass early requires the engine to call `MSG_STOPFEEDER` (see `scanjob.m`).
- ADF only (the DR-S150 has no flatbed); the advertised platen is a stub.
- Requires CaptureOnTouch **installed** (not running) — it is used purely as a shared library.
- The server copies the driver into `$XDG_DATA_HOME/drs150-bridge/driver/` and repoints its
  `DSM_Entry` import at the Rust shim. The system driver at
  `/Library/Image Capture/TWAIN Data Sources/` is never modified.

## Layout

```
src/scanjob.m        scan engine (Objective-C): opens the driver, pulls every ADF page
src/twain.h          minimal TWAIN definitions used by the engine
rust/shim/           TWAIN source-manager shim (Rust cdylib, notification bridge)
rust/escl-server/    eSCL 2.0 subset + Bonjour (Rust: tiny_http, image, mdns-sd)
flake.nix            packages, dev shell, apps, home-manager module
nix/home-module.nix  launchd user agent + XDG dirs + legacy-state cleanup
scripts/smoke-test.sh  curl the eSCL surface, optionally drain the ADF
docs/REVERSE-ENGINEERING.md   how the driver/DSM protocols were worked out
```

## Legal

Not affiliated with Canon. It uses Canon's own driver and CaptureOnTouch framework already present
on your machine; it does not redistribute them. Use at your own risk.

## License

EUPL-1.2 — see [LICENSE](LICENSE).

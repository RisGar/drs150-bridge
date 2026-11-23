# How this was reverse-engineered

Notes from building the bridge, in case the driver changes or someone needs to port it.
Everything below was verified against **DRS150.ds v1.4.25.1015** and
**CaptureOnTouch 4.18.26.0309** (`ApTWAIN.framework`) on macOS 27 / Apple Silicon.

## 1. Why the obvious paths are all dead ends

* **Image Capture cannot use TWAIN.** On current macOS `ICADevices.framework/Versions/A` has no
  binary, and Apple's only device module is `/System/Library/Image Capture/Devices/AirScanScanner.app`.
  → eSCL is the only supported protocol.
* **Apple's TWAIN source manager is a stub.** `DSM_Entry` still resolves out of the dyld shared cache
  (`/System/Library/Frameworks/TWAIN.framework/Versions/A/TWAIN` does not exist on disk), but it
  reports no data sources and enumerates nothing.
* **Canon's source manager is private.** `ApTWAIN.framework` (inside CaptureOnTouch) exposes
  `ApDSM_Entry`; calling it naively traps in `CDSM::CDSM(char*)` / `CFRetain`.

## 2. Driver ABI

`DS_Entry` in the driver uses the **legacy Mac argument order** — there is no `pDest`:

```
TW_UINT16 DS_Entry(TW_IDENTITY *pOrigin, TW_UINT16 MSG, TW_UINT16 DAT, TW_UINT32 DG, TW_MEMREF pData)
```

`TW_IDENTITY` is **168 bytes with a pointer-sized `Id`**:

| offset | field |
|---|---|
| 0 | `Id` (pointer-sized!) |
| 8 | `Version` (4 × u16 + `Info[34]`) |
| 50 / 52 | `ProtocolMajor` / `ProtocolMinor` |
| 56 | `SupportedGroups` |
| 60 / 94 / 128 | `Manufacturer` / `ProductFamily` / `ProductName` (34 bytes each) |

Other driver facts:

* It takes an exclusive lock on **`/tmp/dr_s150`** before opening.
* It loads its USB module via `+[NSBundle bundleWithIdentifier:@"com.canonElectronics.drS150"]`
  → `Contents/Frameworks/DRUSBScanner.bundle`, so it must be loaded *as a bundle*, not `dlopen`ed
  by path alone.
* It has a "trusted client" check comparing the caller's `Manufacturer` with
  `" 1044FFCC35D84CBC86B6B0CC1B64595C"`.
* Its logger is gated by `CeiLogger::isEnabled()` on marker files (`/tmp/DRS150.log`,
  `/usr/local/etc/DRC225.log`); the default log path needs root.

## 3. Canon's source manager (`ApDSM_Entry`) conventions

These are the details that cost the most time:

| Call | Correct form |
|---|---|
| `OPENDSM` | `pData` **must be a `CFStringRef`** holding the sources folder, e.g. `CFSTR("/Library/Image Capture/TWAIN Data Sources")`. `NULL` → no sources at all; a C string → crash (it `CFRetain`s the pointer). |
| enumeration | `DAT_IDENTITY` with **`MSG_GETFIRST` (4)** and **`MSG_GETNEXT` (5)** — *not* `MSG_GET` (1). Unhandled triplets return `TWRC_FAILURE` with condition code **9**, which looks like "bad protocol" but only means "not implemented". |
| source identity | `MSG_GETFIRST` writes a full 168-byte `TW_IDENTITY` into `pData`; use that buffer as `pDest` for all later DS-level calls (the DSM routes by `CDSM::GetDataSource(pDest)`). |
| `OPENDS` | `pDest = NULL`, `pData` = that identity, `MSG_OPENDS`. |
| `CLOSEDS` | `pDest = NULL`, `pData` = that same identity. `ApDSM_Entry` resolves the source through `CDSM::GetDataSource(pData)` and then tail-jumps its vtable; with `pData = NULL` that jump lands outside `ApTWAIN.__text` (`EXC_BAD_ACCESS` at `0x3c`), which looks like a driver crash but is a bad close call. |
| capability read | `MSG_GET` returns a **handle** in `hContainer`; dereference once to reach the container. `TW_IMAGEMEMXFER`/containers use Mac-style handles: `data = *(void**)handle`. |
| capability write | `hContainer = &ptr_to_container` (single indirection), `Flags = 0`. |
| `REGISTER_CALLBACK` | `pDest = NULL`, `DAT_CALLBACK (0x10)`, `MSG 0x0902`, `pData` = 16-byte `{proc, refCon}`. Callback signature: `(pOrigin, pDest, DG, DAT, MSG, pData)`. |

Device capabilities as reported by the driver: 100 / 150 / 200 / 240 / **300 (default)** / 400 / 600 dpi,
BW/Gray/RGB, transfer mechanisms enum `[2, 0, 3]` (memory), `SETUPMEMXFER` min 32 KB / max 4 GB /
preferred 2 MB, ADF present.

Colour: `SET ICAP_PIXELTYPE = TWPT_RGB (2)` is accepted (`rc=0`) and the driver then transfers
24 bpp with **interleaved RGB** bytes (`BytesPerRow = width * 3`). `SET ICAP_BITDEPTH = 24`
returns `TWRC_FAILURE` and can be ignored — the bit depth follows the pixel type. Buffer sizes
must allow ~26 MB per page at 300 dpi (A4 colour), not the 3.9 MB a grey page needs.

## 4. The notification problem (and the shim)

The driver posts `MSG_XFERREADY` / device events **to its source manager** via
`DSM_Entry(DG_CONTROL, DAT_CALLBACK, MSG_INVOKE_CALLBACK)`, with the notification message as a
**`uint16` at `pData+16`** (`0x0101` = XFERREADY, `0x0104` = device event).

Its import of `DSM_Entry` points at `/System/Library/Frameworks/TWAIN.framework` — the dead stub — so
those notifications vanish. That is why the driver only ever worked inside CaptureOnTouch (which is
both source manager and host).

Fix used here: the server copies the driver into `$XDG_DATA_HOME/drs150-bridge/driver/` at
startup and repoints that one import at `libdsmshim2.dylib` (`rust/shim`, ~180 lines of Rust:
entry point, memory services, notification capture; the exported globals `shim_ready` /
`shim_calls` / `shim_lastmsg` keep the same C ABI),
and re-signs the copy ad-hoc. The image data still arrives through the normal
`DAT_IMAGEMEMXFER` call — the shim is only needed for the notification channel.

## 5. The transfer sequence that finally worked

```c
OPENDSM(CFString sources folder)
GETFIRST(identity)                 // fills a TW_IDENTITY
OPENDS(identity)
DISABLEDS                          // clear any stale session
SET: CAP_XFERCOUNT=-1, CAP_FEEDERENABLED=TRUE,
     ICAP_PIXELTYPE=GRAY, ICAP_XFERMECH=MEMORY
ENABLEDS(ShowUI = FALSE)
  per page:
    wait for XFERREADY (via the shim)     // one notification per page in the feeder
    DAT_IMAGEINFO                         // ★ mandatory: flips the transfer-ready flag
    DAT_IMAGEMEMXFER  (loop)              // Memory{Flags=0, Length, TheMem=buffer} → XFERDONE
    ENDXFER (DG_CONTROL/DAT_PENDINGXFERS) // → Count: 0xFFFF / >0 = pull again, 0 = drained
  STOPFEEDER                              // only if we stopped before the ADF ran dry
DISABLEDS / CLOSEDS(identity)
```

Two details about that loop, both learned the hard way: the driver answers `MSG_ENDXFER`
only on `DAT_PENDINGXFERS` (not on the `DAT_XFERGROUP` alias, which returns `TWRC_FAILURE`),
and with `CAP_XFERCOUNT = -1` it reports `Count = 0xFFFF` — "as many as the feeder holds" —
so the app must pull the next page itself instead of waiting for a second `XFERREADY`. The
`0` comes only after the last sheet, which is where the session can be closed cleanly.

`CAP_XFERCOUNT = 1` is a trap: the driver transfers one page but keeps scanning the ADF in its
own thread, so `DISABLEDS`/`CLOSEDS` pull the session out from under `CCanoDR::ScanImage` —
`SIGSEGV` in `CCanoDR::GetResponseSelf` (a pthread frame, not main), the panel stays on
"Scanning", and the *next* `OPENDS`/`ENABLEDS` fails with `TWCC_SEQERROR` (condition code 9,
"Command Sequence Error" in the driver's own strings). Use `-1` and either drain the feeder or
call `MSG_STOPFEEDER` (DG_CONTROL/DAT_USERINTERFACE) before tearing down.

Two details that each cost a diagnosis:

* **`DAT_IMAGEINFO` must be called after XFERREADY and before the first `IMAGEMEMXFER`.**
  `CDataSource::GetImageInfo` is what sets the byte flag at `this+0xD1`; until then
  `ImageMemXfer` returns `TWRC_CANCEL` (3) forever. Calling `IMAGEINFO` *before* `ENABLEDS` is a
  sequence error and poisons the session.
* **Buffer convention:** `TW_IMAGEMEMXFER.Memory.TheMem` is used *directly* unless
  `Flags & 0x10` (TWMF_HANDLE), in which case it is dereferenced once. Passing a double pointer with
  `Flags = 0` makes the driver write into the pointer slot itself.

`ENABLEDS` return codes seen in practice: `0` ok, `3` (`TWRC_CANCEL`) = scanner still busy finishing a
pass, `1` (`TWRC_FAILURE`) = no device on the bus (or device showing a dialog).

## 6. eSCL side

Apple's `AirScanScanner.app` browses `_uscan._tcp` and expects the eSCL 2.0 HTTP surface:
`/eSCL/ScannerCapabilities`, `/eSCL/ScannerStatus`, `POST /eSCL/ScanJobs` → `201` + `Location`,
`GET /eSCL/ScanJobs/<id>/NextDocument` → image bytes. The TXT record needs at least
`txtvers=1 rs=eSCL ty=… pdl=image/jpeg cs=… is=… uuid=…`.

The server (Rust, `rust/escl-server`) advertises with `mdns-sd` on `drs150-bridge.local.` — it must
not publish an A record for the Mac's own `.local` name, or `mDNSResponder` treats it as a duplicate
and renames the machine — runs the engine as a child process with paths in the environment
(`DRS150_SPOOL`, `DRS150_SHIM`, `DRS150_DRIVER_DIR`), waits for the JSON metadata the engine writes,
and converts the raw samples (8-bit grey or RGB24) to JPEG with the `image` crate — no `sips`,
`dns-sd` or Python subprocesses. A `drs150scan --probe` run (cached 20 s) answers whether the
scanner is plugged in at all.

One portability trap: the server must run **natively** (arm64 here). A Rosetta (x86_64) process
cannot load `/usr/bin/python3` on current macOS, which is why the engine is x86_64 (needs Rosetta for
the Canon driver) but the launcher is universal.

## 7. Instrumentation tricks that helped

* Apple's `DSMDebug.plist` inside TWAIN.framework contains the complete constant tables
  (DAT/MSG/condition codes) — invaluable, because several numbers differ from the values you might
  assume (e.g. `DAT_SETUPFILEXFER = 0x0007`, `DAT_USERINTERFACE = 0x0009`, `MSG_ENABLEDS = 0x0502`).
* `llvm-objdump --disassemble-symbols=…` on the driver resolves these questions directly:
  which capability handler runs, what offsets it reads, which state byte gates a call.
* The driver's own strings name its stages (`ERROR: CDataSource::OpenDS SetupScanner`, …), which is
  how the failure points were located.

/*
 * DRS150Scan — ADF scan through Canon's TWAIN driver, driven headlessly.
 *
 * The driver (DRS150.ds) is a TWAIN data source. This tool:
 *   1. loads a *patched copy* of the driver that lives in this app's Resources
 *      (its DSM_Entry import is repointed at libdsmshim2.dylib, see
 * src/shim.c),
 *   2. opens Canon's own source manager (ApTWAIN, shipped with CaptureOnTouch),
 *   3. opens the device, configures it, starts a session,
 *   4. pulls *every* page the ADF holds: XFERREADY announces the first one,
 * each page is read with DAT_IMAGEINFO + DAT_IMAGEMEMXFER and then closed with
 *      DAT_PENDINGXFERS/MSG_ENDXFER, whose Count says whether to keep going
 * (0xFFFF with CAP_XFERCOUNT = -1) or stop (0 = feeder drained). Stopping
 * before the feeder is drained (page cap, timeout, transfer error) requires
 * MSG_STOPFEEDER — otherwise the driver keeps scanning in its own thread while
 * we disable the session, which crashes it and leaves the scanner showing
 * "Scanning" until it is power-cycled.
 *
 * Output: <AppSupport>/DRS150Bridge/page-<n>.raw (8-bit grey, one per page)
 *         <AppSupport>/DRS150Bridge/page.meta  (JSON, rewritten after every
 * page)
 */
#include "twain.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

typedef TW_UINT16 (*DSMENTRY)(void *, void *, TW_UINT32, TW_UINT16, TW_UINT16,
                              void *);

#define MAXPAGES 100
#define FIRST_WAIT_TICKS 100 /* 0.2 s per tick -> 20 s for the first page */
#define PAGE_WAIT_TICKS                                                        \
  250 /* 50 s for the following ones (paper may need feeding) */

static DSMENTRY F;
static unsigned char appraw[256], dsraw[512];
static unsigned char
    ubuf[64]; /* TW_USERINTERFACE, needed by DISABLEDS/STOPFEEDER */
static FILE *LOG;
static NSString *SPOOL, *RES;

static void L(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  if (LOG) {
    vfprintf(LOG, fmt, ap);
    fputc('\n', LOG);
    fflush(LOG);
  }
  va_end(ap);
}

/* XDG base directories (macOS defaults: ~/.local/share, ~/.local/state). The Rust server
   passes DRS150_SPOOL / DRS150_LOG_DIR explicitly; these fallbacks keep the engine usable
   when it is run by hand. */
static NSString *homePath(void) {
  const char *h = getenv("HOME");
  return h ? [NSString stringWithUTF8String:h] : @"/tmp";
}
static NSString *xdgPath(const char *env, const char *fallback) {
  const char *v = getenv(env);
  NSString *base = v ? [NSString stringWithUTF8String:v]
                     : [homePath() stringByAppendingPathComponent:
                                      [NSString stringWithUTF8String:fallback]];
  return [base stringByAppendingPathComponent:@"drs150-bridge"];
}
static NSString *appSupport(void) {
  return [xdgPath("XDG_DATA_HOME", ".local/share")
      stringByAppendingPathComponent:@"spool"];
}
static NSString *logDir(void) { return xdgPath("XDG_STATE_HOME", ".local/state"); }

static NSString *envString(const char *name) {
  const char *v = getenv(name);
  return v ? [NSString stringWithUTF8String:v] : nil;
}

/* ---- capability helper: hContainer is a handle (deref once) ---- */
static unsigned char cbcont[512];
static void *chandle;
static TW_UINT16 setcap(unsigned short id, unsigned short type,
                        unsigned int val) {
  memset(cbcont, 0, sizeof cbcont);
  TW_ONEVALUE *v = (TW_ONEVALUE *)cbcont;
  v->ItemType = type;
  v->Item = val;
  chandle = cbcont;
  unsigned char cap[64];
  memset(cap, 0, sizeof cap);
  TW_CAPABILITY *c = (TW_CAPABILITY *)cap;
  c->Cap = id;
  c->ConType = TWON_ONEVALUE;
  c->hContainer = &chandle;
  TW_UINT16 rc = F(appraw, dsraw, DG_CONTROL, DAT_CAPABILITY, MSG_SET, c);
  L("SET cap 0x%04x=%u rc=%u", id, val, rc);
  return rc;
}

/* ---- page spool ---- */
static volatile int *shim_ready = NULL;
static unsigned char *buf = NULL;
static const unsigned int BUFSZ = 48u
                                  << 20; /* a 300 dpi colour page is ~26 MB */
static int imgDpi = 0;
static int colour = 0; /* 1 = RGB24 from <spool>/mode.txt, 0 = 8-bit grey */
static int ticks = 0, finishing = 0;
static int ready = 0; /* a page is (or should be) available to pull */
static int npages = 0;
static struct {
  int w, h;
  long bytes;
} pages[MAXPAGES];

static const char *pagefile(int idx) {
  static char name[32];
  snprintf(name, sizeof name, "page-%d.raw", idx + 1);
  return name;
}

/* page.meta is the handshake with escl_server.py: it is rewritten after *every*
   page (so the server can hand out page 1 while the ADF is still feeding) and
   once more with done = 1, which is the server's signal that the session is
   over. */
static void writeMeta(int done) {
  NSMutableArray *arr = [NSMutableArray array];
  for (int i = 0; i < npages; i++) {
    [arr addObject:@{
      @"file" : [NSString stringWithUTF8String:pagefile(i)],
      @"width" : @(pages[i].w),
      @"height" : @(pages[i].h),
      @"bytes" : @(pages[i].bytes)
    }];
  }
  NSDictionary *meta = @{
    @"ok" : [NSNumber numberWithBool:npages > 0],
    @"done" : [NSNumber numberWithBool:done],
    @"count" : @(npages),
    @"dpi" : @(imgDpi ? imgDpi : 200),
    @"channels" : @(colour ? 3 : 1),
    @"colormode" : (colour ? @"RGB24" : @"Grayscale8"),
    @"pages" : arr
  };
  NSData *jd = [NSJSONSerialization dataWithJSONObject:meta
                                               options:0
                                                 error:nil];
  [jd writeToFile:[SPOOL stringByAppendingPathComponent:@"page.meta"]
       atomically:YES];
}

/* ---- session ---- */
static void finish(void) {
  [NSApp stop:nil];
  [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                       subtype:0
                                         data1:0
                                         data2:0]
           atStart:YES];
}

/* Ask the driver to stop feeding. Must happen whenever we end the session with
   pages still in the ADF: without it the driver keeps scanning in its own
   thread while we tear the session down (SIGSEGV inside CCanoDR::ScanImage) and
   the panel stays on "Scanning" until the scanner is power-cycled. */
static void stopFeeder(void) {
  L("STOPFEEDER=%u",
    F(appraw, dsraw, DG_CONTROL, DAT_USERINTERFACE, MSG_STOPFEEDER, ubuf));
}

static void giveUp(const char *why) {
  if (finishing)
    return;
  L("giving up: %s (pages=%d)", why, npages);
  stopFeeder();
  finishing = 1;
  finish();
}

/* DAT_IMAGEINFO is mandatory: it flips the driver's internal transfer-ready
 * flag */
static int scanOnePage(void) {
  if (npages >= MAXPAGES)
    return 0;

  unsigned char ii[128];
  memset(ii, 0, sizeof ii);
  TW_UINT16 ir = F(appraw, dsraw, DG_IMAGE, DAT_IMAGEINFO, MSG_GET, ii);
  int xres = 0, yres = 0, len = 0, bpp = 0;
  memcpy(&xres, ii, 4);
  memcpy(&yres, ii + 8, 4);
  memcpy(&len, ii + 20, 4);
  memcpy(&bpp, ii + 42, 2);
  L("IMAGEINFO[%d] rc=%u xres=%d yres=%d len=%d bpp=%d", npages + 1, ir, xres,
    yres, len, bpp);
  if (ir != TWRC_SUCCESS)
    return 0;
  if (xres > 0)
    imgDpi = xres;

  NSString *path = [SPOOL
      stringByAppendingPathComponent:[NSString
                                         stringWithUTF8String:pagefile(
                                                                  npages)]];
  int fd =
      open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);

  int w = 0, h = 0;
  long bytes = 0;
  int done = 0;
  for (int i = 0; i < 400 && !done; i++) {
    unsigned char mb[128];
    memset(mb, 0, sizeof mb);
    /* Memory{Flags@32, Length@36, TheMem@40}; Flags=0 => TheMem used directly
     */
    unsigned int flags = 0, blen = BUFSZ;
    memcpy(mb + 32, &flags, 4);
    memcpy(mb + 36, &blen, 4);
    memcpy(mb + 40, &buf, 8);
    TW_UINT16 r = F(appraw, dsraw, DG_IMAGE, DAT_IMAGEMEMXFER, MSG_GET, mb);
    unsigned int bpr = 0, cols = 0, rows = 0, written = 0;
    memcpy(&bpr, mb + 4, 4);
    memcpy(&cols, mb + 8, 4);
    memcpy(&rows, mb + 12, 4);
    memcpy(&written, mb + 24, 4);
    L("xfer[%d,%d] rc=%u bpr=%u cols=%u rows=%u written=%u", npages + 1, i, r,
      bpr, cols, rows, written);
    if ((r == TWRC_SUCCESS || r == TWRC_XFERDONE) && written) {
      if (fd >= 0)
        write(fd, buf, written);
      bytes += written;
      if (!w)
        w = cols;
      h += rows;
    }
    if (r == TWRC_XFERDONE) {
      done = 1;
      break;
    }
    if (r == TWRC_CANCEL)
      continue; /* page not complete yet */
    if (r != TWRC_SUCCESS)
      break;
  }
  if (fd >= 0)
    close(fd);
  if (!bytes)
    return 0;

  pages[npages].w = w;
  pages[npages].h = h;
  pages[npages].bytes = bytes;
  npages++;
  L("page %d done: %dx%d %ld bytes (%d channel%s)", npages, w, h, bytes,
    colour ? 3 : 1, colour ? "s" : "");
  writeMeta(0); /* publish immediately */
  return 1;
}

static void logStatus(const char *what); /* defined below */

/* ENDXFER closes the current page and reports whether the feeder still holds
   more. TWAIN defines that as DG_CONTROL/DAT_PENDINGXFERS/MSG_ENDXFER; some
   sources (and the TWAIN 2.x DAT_XFERGROUP alias) only answer one of the two
   forms, so try both and fall back to a plain MSG_GET, which reports the count
   without ending the transfer. */
static int endxfer(unsigned int *pending) {
  struct {
    int dat;
  } forms[] = {{DAT_PENDINGXFERS}, {DAT_XFERGROUP}};
  for (unsigned int i = 0; i < sizeof forms / sizeof forms[0]; i++) {
    TW_PENDINGXFERS pend;
    memset(&pend, 0, sizeof pend);
    TW_UINT16 rc =
        F(appraw, dsraw, DG_CONTROL, forms[i].dat, MSG_ENDXFER, &pend);
    L("ENDXFER(dat=0x%04x) rc=%u pending=%u", forms[i].dat, rc, pend.Count);
    if (rc == TWRC_SUCCESS || rc == TWRC_XFERDONE) {
      *pending = pend.Count;
      return 1;
    }
    logStatus("ENDXFER");
  }
  TW_PENDINGXFERS pend;
  memset(&pend, 0, sizeof pend);
  TW_UINT16 rc = F(appraw, dsraw, DG_CONTROL, DAT_PENDINGXFERS, MSG_GET, &pend);
  L("PENDINGXFERS(GET) rc=%u pending=%u", rc, pend.Count);
  if (rc == TWRC_SUCCESS) {
    *pending = pend.Count;
    return 1;
  }
  logStatus("PENDINGXFERS");
  return 0;
}

/* close the page and decide whether another one is coming */
static void advance(void) {
  if (npages >= MAXPAGES) {
    L("page limit %d reached", MAXPAGES);
    giveUp("page limit");
    return;
  }

  unsigned int pending = 0;
  if (endxfer(&pending) && pending > 0) {
    /* Non-zero (the DR-S150 answers 0xFFFF = "as many as the feeder holds")
       means another page is available. The driver does *not* post a second
       XFERREADY for it, so pull the next page straight away; when the feeder
       turns out to be empty that transfer fails and giveUp() ends the session
       with STOPFEEDER. */
    ready = 1;
    return;
  }
  finishing = 1;
  finish();
}

static void tick(void) {
  if (finishing)
    return;
  if (!ready && shim_ready && *shim_ready) {
    *shim_ready = 0;
    ready = 1;
  }
  if (ready) {
    ready = 0;
    ticks = 0;
    L("pull page %d", npages + 1);
    if (scanOnePage())
      advance();
    else
      giveUp("no page available (feeder empty?)");
    return;
  }
  if (++ticks > (npages ? PAGE_WAIT_TICKS : FIRST_WAIT_TICKS))
    giveUp("timeout waiting for a page");
}

static const char *ccName(unsigned cc) {
  switch (cc) {
  case 0:
    return "TWCC_SUCCESS";
  case 1:
    return "TWCC_BUMMER";
  case 2:
    return "TWCC_LOWMEMORY";
  case 3:
    return "TWCC_NODS";
  case 4:
    return "TWCC_MAXCONNECTIONS";
  case 5:
    return "TWCC_OPERATIONERROR";
  case 6:
    return "TWCC_BADCAP";
  case 9:
    return "TWCC_BADPROTOCOL";
  case 10:
    return "TWCC_BADVALUE";
  case 11:
    return "TWCC_SEQERROR";
  case 12:
    return "TWCC_BADDEST";
  case 13:
    return "TWCC_CAPUNSUPPORTED";
  case 14:
    return "TWCC_CAPBADOPERATION";
  case 15:
    return "TWCC_CAPSEQERROR";
  case 16:
    return "TWCC_DENIED";
  case 20:
    return "TWCC_PAPERJAM";
  default:
    return "TWCC_?";
  }
}

/* TWAIN condition codes (TWCC_*) from Apple's DSMDebug.plist: they say *why* a
   call failed
   -- 3 = no source (panel busy / wedged), 11 = sequence error (stale session).
 */
static void logStatus(const char *what) {
  unsigned char st[16];
  memset(st, 0, sizeof st);
  if (F(appraw, dsraw, DG_CONTROL, DAT_STATUS, MSG_GET, st) == TWRC_SUCCESS) {
    TW_UINT16 cc = 0;
    memcpy(&cc, st, 2);
    L("%s condition=%u (%s)", what, cc, ccName(cc));
  }
}

int main(int argc, char **argv) {
  @autoreleasepool {
    /* --probe: open the data source and exit. Lets the server answer "is the scanner plugged
       in?" cheaply instead of starting a scan that cannot work. */
    BOOL probe = (argc > 1 && strcmp(argv[1], "--probe") == 0);

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    RES = [[NSBundle mainBundle] resourcePath];
    SPOOL = envString("DRS150_SPOOL") ?: appSupport();
    NSString *logs = envString("DRS150_LOG_DIR") ?: logDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:SPOOL
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:logs
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    /* A probe is a separate, tiny run: giving it its own log keeps it from truncating the
       log of a scan that may be running at the same time. */
    LOG = fopen([[logs stringByAppendingPathComponent:
                             (probe ? @"probe.log" : @"scan-engine.log")] UTF8String],
                "w");
    alarm(probe ? 15 : 600);
    L("engine start: resources=%s probe=%d", [RES UTF8String], probe);
    NSString *modeFile = [SPOOL stringByAppendingPathComponent:@"mode.txt"];
    NSString *mode = [NSString stringWithContentsOfFile:modeFile
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    colour =
        [mode rangeOfString:@"colo" options:NSCaseInsensitiveSearch].location !=
            NSNotFound ||
        [mode rangeOfString:@"rgb" options:NSCaseInsensitiveSearch].location !=
            NSNotFound;
    L("mode=%s", colour ? "RGB24" : "Grayscale8");
    /* only a scan publishes results: a probe must never disturb them */
    if (!probe)
      writeMeta(0);

    /* Canon's source manager (installed with CaptureOnTouch) */
    NSString *dsmPath = @"/Applications/CaptureOnTouch.app/Contents/Frameworks/"
                        @"ApTWAIN.framework";
    NSBundle *dsmBundle = [NSBundle bundleWithPath:dsmPath];
    [dsmBundle load];
    void *h =
        dlopen([[dsmPath stringByAppendingPathComponent:@"Versions/A/ApTWAIN"]
                   UTF8String],
               RTLD_LAZY | RTLD_GLOBAL);
    F = h ? (DSMENTRY)dlsym(h, "ApDSM_Entry") : NULL;
    if (!F) {
      L("FATAL: ApTWAIN source manager not found (is CaptureOnTouch "
        "installed?)");
    }
    L("ApTWAIN=%p", (void *)F);

    /* our minimal source manager that forwards the driver's notifications */
    NSString *shimPath = envString("DRS150_SHIM")
                             ?: [RES stringByAppendingPathComponent:@"libdsmshim2.dylib"];
    void *sh = dlopen([shimPath UTF8String], RTLD_LAZY | RTLD_GLOBAL);
    if (sh)
      shim_ready = (volatile int *)dlsym(sh, "shim_ready");
    L("shim=%p ready_flag=%p", sh, (void *)shim_ready);

    int opened = -1;
    if (F) {
      memset(appraw, 0, sizeof appraw);
      memset(dsraw, 0, sizeof dsraw);
      TW_IDENTITY8 *APP = (TW_IDENTITY8 *)appraw;
      APP->Version.MajorNum = 1;
      APP->ProtocolMajor = 1;
      APP->ProtocolMinor = 9;
      APP->SupportedGroups = DG_CONTROL | DG_IMAGE;
      strcpy((char *)APP->Manufacturer, " 1044FFCC35D84CBC86B6B0CC1B64595C");
      strcpy((char *)APP->ProductName, "CaptureOnTouch");

      NSString *driverDir = envString("DRS150_DRIVER_DIR")
                            ?: [RES stringByAppendingPathComponent:@"driver"];
      CFStringRef dir = CFStringCreateWithCString(NULL, [driverDir UTF8String],
                                                  kCFStringEncodingUTF8);
      L("OPENDSM=%u",
        F(appraw, NULL, DG_CONTROL, DAT_PARENT, MSG_OPENDSM, (void *)dir));
      L("GETFIRST=%u",
        F(appraw, NULL, DG_CONTROL, DAT_IDENTITY, MSG_GETFIRST, dsraw));
      int tries = probe ? 4 : 40;
      for (int k = 0; k < tries; k++) {
        opened = F(appraw, NULL, DG_CONTROL, DAT_IDENTITY, MSG_OPENDS, dsraw);
        if (opened == 0)
          break;
        usleep(500000);
      }
      L("OPENDS=%d", opened);
      if (opened != 0)
        logStatus("OPENDS");

      if (probe) {
        /* no session, no spool writes: just answer "can the driver see the scanner?" */
        L("probe: %s", opened == 0 ? "scanner present" : "scanner absent");
        if (opened == 0)
          L("CLOSEDS=%u",
            F(appraw, NULL, DG_CONTROL, DAT_IDENTITY, MSG_CLOSEDS, dsraw));
        if (LOG) {
          fclose(LOG);
          LOG = NULL;
        }
        return opened == 0 ? 0 : 1;
      }
    }

    if (opened == 0) {
      TW_USERINTERFACE *ui = (TW_USERINTERFACE *)ubuf;
      ui->ShowUI = 0;
      F(appraw, dsraw, DG_CONTROL, DAT_USERINTERFACE, MSG_DISABLEDS, ui);

      buf = malloc(BUFSZ);
      memset(buf, 0, BUFSZ);

      /* -1 = "every page in the feeder": one session for the whole ADF */
      setcap(CAP_XFERCOUNT, TWTY_INT16, 0xffff);
      setcap(CAP_FEEDERENABLED, TWTY_BOOL, 1);
      setcap(ICAP_PIXELTYPE, TWTY_UINT16, colour ? TWPT_RGB : TWPT_GRAY);
      if (colour)
        setcap(ICAP_BITDEPTH, TWTY_UINT16, 24);
      setcap(ICAP_XFERMECH, TWTY_UINT16, TWSX_MEMORY);

      TW_UINT16 er = 3;
      for (int k = 0; k < 20; k++) {
        er = F(appraw, dsraw, DG_CONTROL, DAT_USERINTERFACE, MSG_ENABLEDS, ui);
        if (er == 0)
          break;
        usleep(500000);
      }
      L("ENABLEDS=%u", er);
      if (er == 0) {
        NSTimer *t = [NSTimer timerWithTimeInterval:0.2
                                            repeats:YES
                                              block:^(NSTimer *timer) {
                                                tick();
                                              }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSDefaultRunLoopMode];
        [NSApp run];
      } else {
        logStatus("ENABLEDS");
      }

      /* Publish the result *before* touching the driver again: a failure in
         DISABLEDS/CLOSEDS must never throw away pages we already have. */
      writeMeta(1);
      F(appraw, dsraw, DG_CONTROL, DAT_USERINTERFACE, MSG_DISABLEDS, ui);
      /* CLOSEDS is a DS-level call: ApDSM_Entry resolves the source through the
         same pData identity OPENDS was given. Passing NULL here makes
         CDSM::CloseDS tail-jump through a garbage vtable slot (SIGSEGV in
         KERN_INVALID_ADDRESS). */
      L("CLOSEDS=%u",
        F(appraw, NULL, DG_CONTROL, DAT_IDENTITY, MSG_CLOSEDS, dsraw));
    } else {
      writeMeta(1); /* let the server fail fast instead of waiting */
    }

    L("done ok=%d pages=%d dpi=%d", npages > 0, npages, imgDpi);
    if (LOG) {
      fclose(LOG);
      LOG = NULL;
    }
    return npages > 0 ? 0 : 1;
  }
}

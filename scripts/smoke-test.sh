#!/bin/sh
# Quick check that the bridge is running and can enumerate a scan job.
# Does NOT pull paper unless you pass --scan.
set -e
PORT="${ESCL_PORT:-8632}"
base="http://127.0.0.1:$PORT/eSCL"

echo "status:";      curl -sf --max-time 5 "$base/ScannerStatus" | tr -d '\n' | head -c 300; echo
echo "capabilities:"; curl -sf --max-time 5 "$base/ScannerCapabilities" | head -c 200; echo
echo "bonjour:";     ( dns-sd -B _uscan._tcp >/tmp/_uscan.$$ 2>&1 & echo $! >/tmp/_uscan.pid.$$ ; \
                       sleep 3; kill "$(cat /tmp/_uscan.pid.$$)" 2>/dev/null ) ; \
                     grep -i "DR-S150" /tmp/_uscan.$$ | head -2; rm -f /tmp/_uscan.$$ /tmp/_uscan.pid.$$

[ "$1" = "--scan" ] || { echo "job creation:"; \
  curl -si --max-time 5 -X POST -H 'Content-Type: text/xml' \
    --data '<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"><scan:InputSource>Feeder</scan:InputSource><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ScanSettings>' \
    "$base/ScanJobs" | head -6; exit 0; }

echo "scanning (drains the ADF)..."
LOC=$(curl -si --max-time 5 -X POST -H 'Content-Type: text/xml' \
  --data '<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"><scan:InputSource>Feeder</scan:InputSource><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ScanSettings>' \
  "$base/ScanJobs" | awk '/^Location:/{print $2}' | tr -d '\r')
OUT=$(mktemp -d /tmp/drs150-pages.XXXXXX)
n=0
while :; do
  n=$((n+1))
  code=$(curl -s -o "$OUT/page-$n.jpg" -w '%{http_code}' --max-time 300 "$LOC/NextDocument")
  case "$code" in
    200) ls -l "$OUT/page-$n.jpg" ;;
    404) rm -f "$OUT/page-$n.jpg"; echo "job complete after $((n-1)) page(s)"; break ;;
    *)   rm -f "$OUT/page-$n.jpg"; echo "NextDocument failed: HTTP $code"; break ;;
  esac
done
file "$OUT"/page-*.jpg 2>/dev/null
echo "pages written to $OUT"

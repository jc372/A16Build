#!/usr/bin/env bash
# a16-wifi-tune.sh -- why the radio "works" but browsing crawls, and the fix.
#
#   sudo bash /home/jc/a16-payload/a16-wifi-tune.sh                  # measure, then apply the fix
#   sudo bash /home/jc/a16-payload/a16-wifi-tune.sh --measure        # measure only, change nothing
#   sudo bash /home/jc/a16-payload/a16-wifi-tune.sh --band bg        # prefer 2.4 GHz instead of 5 GHz
#   sudo bash /home/jc/a16-payload/a16-wifi-tune.sh --bssid 58:D8:12:08:90:D9   # pin one AP radio
#
# Measured on 2026-09-16 after the board-data fix: the radio is up (29 Mbit/s, LAN gateway
# reachable) but the profile picks the *weakest* BSSID of the AP -- the 6 GHz one at 44%,
# RSSI -77 dBm, TX 17 Mbit/s -- while the same AP's 5 GHz/2.4 GHz radios report 100 %, and
# powersave is on (gateway pings 32-77 ms).  Nothing loads over Wi-Fi while the Ethernet
# dongle is plugged in, because the dongle legitimately holds the default route.
set -u

CONN="${A16_CONN:-hn}"
IFACE="${A16_IFACE:-wlP4p1s0}"
BAND="a"            # 5 GHz: the AP's 5 GHz BSSID measured 100 %
POWERSAVE=2         # NetworkManager: 2 = disable power save
BSSID=""
MEASURE_ONLY=0
LOG="${A16_LOG:-$HOME/a16-payload/A16WIFITUNE-$(date +%Y%m%d-%H%M%S).log}"

while [ $# -gt 0 ]; do
  case "$1" in
    --measure)   MEASURE_ONLY=1 ;;
    --band)      BAND="${2:-a}" ;;
    --bssid)     BSSID="${2:-}" ;;
    --conn)      CONN="${2:-hn}" ;;
    --iface)     IFACE="${2:-wlP4p1s0}" ;;
    *) echo "usage: $0 [--measure] [--band a|bg] [--bssid MAC] [--conn NAME] [--iface DEV]" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
: > "$LOG" 2>/dev/null || LOG=/var/tmp/a16-wifi-tune.log
: > "$LOG"
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

sec "current state"
say "[tune] conn=$CONN iface=$IFACE"
{ iw dev "$IFACE" link 2>&1 | sed -n '1,10p'; \
  iw dev "$IFACE" get power_save 2>&1; \
  nmcli -t dev status 2>&1 | grep -E "^$IFACE|enx"; } | sed 's/^/    /' | tee -a "$LOG"

measure() {
  sec "measure"
  local gw rtt
  gw="$(ip route | awk '$1=="default"{print $3; exit}')"
  if [ -n "$gw" ]; then
    say "[tune] gateway $gw (route via $(ip route | awk '$1=="default"{print $5; exit}'))"
    ping -I "$IFACE" -c 5 -W 2 "$gw" 2>&1 | tail -2 | sed 's/^/    /' | tee -a "$LOG"
  fi
  local addr
  addr="$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  if [ -n "$addr" ]; then
    say "[tune] throughput bound to $addr (12 s):"
    python3 - "$addr" <<'PY' 2>&1 | sed 's/^/    /' | tee -a "$LOG"
import socket, sys, time
src = (sys.argv[1], 0); host = "us.archive.ubuntu.com"
try:
    ip = socket.gethostbyname(host)
    s = socket.create_connection((ip, 80), timeout=15, source_address=src)
    s.sendall(b"GET /ubuntu/ls-lR.gz HTTP/1.0\r\nHost: %s\r\n\r\n" % host.encode())
    t = time.time(); n = 0
    while time.time() - t < 12:
        b = s.recv(65536)
        if not b: break
        n += len(b)
    dt = time.time() - t
    print("read %.2f MB in %.1fs = %.2f Mbit/s" % (n/1e6, dt, n*8/1e6/dt))
except Exception as e:
    print("throughput test failed:", type(e).__name__, e)
PY
  else
    say "[tune] $IFACE has no IPv4 address -- not connected yet"
  fi
  say "[tune] visible APs for this SSID (signal %, strongest first):"
  nmcli -f BSSID,SSID,FREQ,SIGNAL dev wifi list 2>/dev/null | awk -v s="$CONN" 'NR==1 || $2==s' \
    | sed 's/^/    /' | tee -a "$LOG"
}

measure
[ $MEASURE_ONLY = 1 ] && { say ""; say "[tune] --measure: nothing changed.  log: $LOG"; exit 0; }

sec "applying"
say "[tune] nmcli: band=$BAND, powersave=$POWERSAVE (2 = disabled)$([ -n "$BSSID" ] && echo ", bssid=$BSSID")"
nmcli con modify "$CONN" 802-11-wireless.band "$BAND"     2>&1 | sed 's/^/    /' | tee -a "$LOG"
nmcli con modify "$CONN" wifi.powersave "$POWERSAVE"      2>&1 | sed 's/^/    /' | tee -a "$LOG"
[ -n "$BSSID" ] && nmcli con modify "$CONN" 802-11-wireless.bssid "$BSSID" 2>&1 | sed 's/^/    /' | tee -a "$LOG"
iw dev "$IFACE" set power_save off 2>&1 | sed 's/^/    /' | tee -a "$LOG"
say "[tune] reconnecting"
nmcli con down "$CONN" >/dev/null 2>&1; sleep 2; nmcli con up "$CONN" 2>&1 | sed 's/^/    /' | tee -a "$LOG"
sleep 6
{ iw dev "$IFACE" link 2>&1 | sed -n '1,10p'; iw dev "$IFACE" get power_save 2>&1; } \
  | sed 's/^/    /' | tee -a "$LOG"
measure

sec "verdict"
say "[tune] if the 6 GHz BSSID still wins, pin the good radio:  $0 --bssid <MAC from the list above>"
say "[tune] the Ethernet dongle keeps the default route while plugged in -- unplug it and re-run --measure"
say "[tune] log: $LOG"
exit 0

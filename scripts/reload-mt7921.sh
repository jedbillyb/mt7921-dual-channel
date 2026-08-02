#!/bin/bash
# Swap in the patched mt7921 driver. Leaves cfg80211 alone, so run
# reload-cfg80211.sh first if monitor_any_chan is also wanted.
#
# Rolls back to the stock driver automatically if the link does not return.
# Nothing is written to /lib/modules; a reboot is always a clean recovery.
set -u
D=/mnt/shared/kernel/linux-6.18.33/drivers/net/wireless/mediatek/mt76/mt7921
LOG=/tmp/mt7921-reload.log
exec >>"$LOG" 2>&1
echo "=== $(date) start"

wait_for_link() {
  for _ in $(seq "$1"); do
    iw dev wlp2s0 link 2>/dev/null | grep -q '^Connected' && return 0
    sleep 1
  done
  return 1
}

reload_stock() {
  echo "ROLLBACK: restoring stock mt7921"
  modprobe -r mt7921e mt7921_common 2>/dev/null
  modprobe mt7921e
}

for f in "$D/mt7921-common.ko" "$D/mt7921e.ko"; do
  [ -f "$f" ] || { echo "FAILED: missing $f"; exit 1; }
done

modprobe -r mt7921e 2>/dev/null
modprobe -r mt7921_common 2>/dev/null
if lsmod | grep -q '^mt7921'; then
  echo "FAILED: mt7921 still loaded; aborting without changes"
  lsmod | grep mt79
  exit 1
fi

# Pull the unchanged dependencies back in first: insmod does not resolve deps.
modprobe mt792x-lib 2>/dev/null

if ! insmod "$D/mt7921-common.ko"; then
  echo "FAILED: insmod mt7921-common"; reload_stock; exit 1
fi
if ! insmod "$D/mt7921e.ko"; then
  echo "FAILED: insmod mt7921e"; reload_stock; exit 1
fi
echo "patched mt7921 inserted"

if wait_for_link 45; then
  echo "OK: link is back"
  iw dev wlp2s0 link | head -3
else
  echo "no link after 45s"
  reload_stock
  wait_for_link 45 && echo "stock link restored" || echo "STILL NO LINK - needs attention"
  exit 1
fi
echo "=== done"

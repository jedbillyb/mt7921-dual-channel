#!/bin/bash
# Load all three patched modules together: cfg80211, mac80211, mt7921.
#
# Rolls back to the stock stack automatically if the link does not return.
# Nothing is written to /lib/modules; a reboot is always a clean recovery.
set -u
K=/mnt/shared/kernel/linux-6.18.33
MT=$K/drivers/net/wireless/mediatek/mt76/mt7921
LOG=/tmp/stack-reload.log
exec >>"$LOG" 2>&1
echo "=== $(date) start"

unload() {
  modprobe -r mt7921e 2>/dev/null
  modprobe -r mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null
  modprobe -r mac80211 2>/dev/null
  modprobe -r cfg80211 2>/dev/null
}

reload_stock() {
  echo "ROLLBACK: restoring stock stack"
  unload
  modprobe cfg80211; modprobe mac80211; modprobe mt7921e
}

wait_for_link() {
  for _ in $(seq "$1"); do
    iw dev 2>/dev/null | grep -q 'Interface wl' && \
      iw dev wlp2s0 link 2>/dev/null | grep -q '^Connected' && return 0
    sleep 1
  done
  return 1
}

for f in "$K/net/wireless/cfg80211.ko" "$K/net/mac80211/mac80211.ko" \
         "$MT/mt7921-common.ko" "$MT/mt7921e.ko"; do
  [ -f "$f" ] || { echo "FAILED: missing $f"; exit 1; }
done

unload
if lsmod | grep -q '^cfg80211'; then
  echo "FAILED: cfg80211 still loaded (in use); aborting without changes"
  lsmod | grep -E 'cfg80211|mac80211|mt7'
  exit 1
fi

insmod "$K/net/wireless/cfg80211.ko" monitor_any_chan=1 || { reload_stock; exit 1; }
insmod "$K/net/mac80211/mac80211.ko" monitor_concurrent=1 || { reload_stock; exit 1; }
# Unpatched dependencies of mt7921 come from /lib/modules as usual.
modprobe mt792x-lib 2>/dev/null
insmod "$MT/mt7921-common.ko" || { reload_stock; exit 1; }
insmod "$MT/mt7921e.ko" || { reload_stock; exit 1; }
echo "patched stack inserted"

if wait_for_link 45; then
  echo "OK: link is back"
  echo "monitor_any_chan=$(cat /sys/module/cfg80211/parameters/monitor_any_chan)"
  echo "monitor_concurrent=$(cat /sys/module/mac80211/parameters/monitor_concurrent)"
  iw dev wlp2s0 link | head -3
else
  echo "no link after 45s"
  reload_stock
  wait_for_link 45 && echo "stock link restored" || echo "STILL NO LINK - needs attention"
  exit 1
fi
echo "=== done"

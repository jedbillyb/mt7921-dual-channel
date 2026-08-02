#!/bin/bash
# Swap in the patched cfg80211 with monitor_any_chan=1, and put the stock stack
# back automatically if the link does not return. Nothing is written to
# /lib/modules, so a reboot is always a clean recovery path.
set -u
KO=/mnt/shared/kernel/linux-6.18.33/net/wireless/cfg80211.ko
LOG=/tmp/cfg80211-reload.log
exec >>"$LOG" 2>&1
echo "=== $(date) start"

unload() {
  modprobe -r mt7921e 2>/dev/null
  modprobe -r mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null
  modprobe -r mac80211 2>/dev/null
  modprobe -r cfg80211 2>/dev/null
}

reload_stock() {
  echo "ROLLBACK: restoring stock modules"
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

unload
if lsmod | grep -q '^cfg80211'; then
  echo "FAILED: cfg80211 still loaded (in use); aborting without changes"
  lsmod | grep -E 'cfg80211|mac80211|mt7'
  exit 1
fi

if ! insmod "$KO" monitor_any_chan=1; then
  echo "FAILED: insmod of patched cfg80211"
  reload_stock
  exit 1
fi
echo "patched cfg80211 inserted"
modprobe mac80211 && modprobe mt7921e || { reload_stock; exit 1; }

if wait_for_link 45; then
  echo "OK: link is back"
  cat /sys/module/cfg80211/parameters/monitor_any_chan
  iw dev wlp2s0 link | head -3
else
  echo "no link after 45s"
  reload_stock
  wait_for_link 45 && echo "stock link restored" || echo "STILL NO LINK - needs attention"
  exit 1
fi
echo "=== done"

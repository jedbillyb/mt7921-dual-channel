#!/bin/bash
# Prove (or disprove) that mt7921 firmware services 2 channels: managed on the AP's
# channel + P2P-GO beaconing on ch149. Ground truth = a real client associating.
VIFTYPE="${1:-__p2pgo}"
DUR="${2:-90}"
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/run-$(date +%Y%m%d-%H%M%S)-${VIFTYPE#__}"
mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1)
STA=wlp2s0
GO=go0
RESTORED=0

restore() {
  [ "$RESTORED" = 1 ] && return; RESTORED=1
  echo "--- restore ---" | tee -a "$RUN/run.log"
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null
  sleep 1
  sudo iw dev $GO del 2>/dev/null
  ip -br link show $STA | tee -a "$RUN/run.log"
}
trap 'restore' EXIT
trap 'restore; exit 130' INT TERM

# detached watchdog: survives kill -9 of this script
setsid bash -c "sleep $((DUR+60)); pkill -f 'hostapd.*hostapd-149.conf'; iw dev $GO del 2>/dev/null" \
  >/dev/null 2>&1 < /dev/null &
WD=$!

{
echo "=== BEFORE ==="
iw dev $STA link | head -4
echo "=== create $GO type $VIFTYPE ==="
sudo iw phy $PHY interface add $GO type $VIFTYPE 2>&1 && echo "vif add OK" || echo "vif add FAILED"
sudo ip link set $GO up 2>&1
iw dev $GO info 2>&1
} 2>&1 | tee -a "$RUN/run.log"

# uplink survival monitor
GW=$(ip route | awk '/^default/{print $3; exit}')
( ping -i 1 -c "$DUR" "$GW" > "$RUN/uplink-ping.log" 2>&1 ) &
PINGPID=$!

echo "=== hostapd (ch149) ===" | tee -a "$RUN/run.log"
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd -dd "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
sleep 8

{
echo "=== AFTER 8s ==="
echo "--- go0 info ---";  iw dev $GO info 2>&1
echo "--- sta link ---";  iw dev $STA link | head -4
echo "--- hostapd tail ---"; tail -25 "$RUN/hostapd.log"
} 2>&1 | tee -a "$RUN/run.log"

echo "RUNDIR=$RUN"

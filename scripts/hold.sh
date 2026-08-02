#!/bin/bash
# Hold a P2P-GO up on ch149 while associated, so a real client can be tried.
DIR="$(cd "$(dirname "$0")" && pwd)"
DUR="${1:-420}"
RUN="$DIR/hold-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1); GO=go0; RESTORED=0
restore() { [ "$RESTORED" = 1 ] && return; RESTORED=1
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null; sleep 1
  sudo iw dev $GO del 2>/dev/null; echo "restored" >> "$RUN/run.log"; }
trap 'restore' EXIT; trap 'restore; exit 130' INT TERM
setsid bash -c "sleep $((DUR+90)); pkill -f 'hostapd.*hostapd-149.conf'; iw dev $GO del 2>/dev/null" >/dev/null 2>&1 </dev/null &
sudo iw phy $PHY interface add $GO type __p2pgo && sudo ip link set $GO up
sudo ip addr add 192.168.77.1/24 dev $GO 2>/dev/null
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd -dd "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
GW=$(ip route | awk '/^default/{print $3; exit}')
( ping -i 2 -c $((DUR/2)) "$GW" > "$RUN/uplink-ping.log" 2>&1 ) &
sleep 6
grep -q 'AP-ENABLED' "$RUN/hostapd.log" && echo "GO UP on ch149, SSID awdl-mcc-test" || { echo "GO FAILED"; tail -5 "$RUN/hostapd.log"; }
iw dev $GO info | grep -E 'type|channel'
echo "RUNDIR=$RUN"
sleep "$DUR"

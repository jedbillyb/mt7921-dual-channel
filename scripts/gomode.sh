#!/bin/bash
# AWDL on a GO-held chanctx: mon0's MAC aliased to go0's so injected AWDL frames
# resolve to go0's sdata (chanctx on 5745) via ieee80211_monitor_start_xmit().
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/gomode-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1); GO=go0; RESTORED=0
restore() { [ "$RESTORED" = 1 ] && return; RESTORED=1
  sudo pkill -f 'airdrop-owl|build/daemon/owl' 2>/dev/null
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null; sleep 1
  for v in mon1 mon0 $GO; do sudo iw dev $v del 2>/dev/null; done
  echo "--- restored ---"; ip -br link show | grep -E 'wl|mon|go0|awdl'; }
trap 'restore' EXIT; trap 'restore; exit 130' INT TERM
setsid bash -c "sleep 300; pkill -f 'airdrop-owl|build/daemon/owl'; pkill -f 'hostapd.*hostapd-149.conf'; for v in mon1 mon0 go0; do iw dev \$v del 2>/dev/null; done" >/dev/null 2>&1 </dev/null &

# 1. GO holds chanctx on 149
sudo iw phy $PHY interface add $GO type __p2pgo && sudo ip link set $GO up
GOMAC=$(cat /sys/class/net/$GO/address); echo "GOMAC=$GOMAC" | tee "$RUN/meta.txt"
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
sleep 6
grep -q 'AP-ENABLED' "$RUN/hostapd.log" || { echo "GO FAILED"; tail -5 "$RUN/hostapd.log"; exit 1; }
echo "GO up on ch149"

# 2. monitor vif, MAC ALIASED to the GO
sudo iw phy $PHY interface add mon0 type monitor
sudo ip link set mon0 down
sudo ip link set mon0 address "$GOMAC" && echo "mon0 MAC aliased to $GOMAC" || echo "ALIAS FAILED"
sudo ip link set mon0 up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep" 2>/dev/null
ip -br link show | grep -E 'mon0|go0'

# 3. OWL on the aliased monitor
sudo tcpdump -i mon0 -w "$RUN/awdl.pcap" -U >/dev/null 2>&1 & TD=$!
sudo /usr/local/bin/airdrop-owl -i mon0 -c 149 -N -vv > "$RUN/owl.log" 2>&1 &
sleep 25
echo "=== awdl0 ==="; ip -br addr show awdl0 2>&1 | head -3
echo "=== peers ==="; grep -oP 'add peer \K\S+' "$RUN/owl.log" | sort -u | tee "$RUN/peers.txt"
echo "=== uplink still up? ==="; ping -c 2 -W 2 $(ip route | awk '/^default/{print $3; exit}') 2>&1 | tail -1
echo "RUNDIR=$RUN"

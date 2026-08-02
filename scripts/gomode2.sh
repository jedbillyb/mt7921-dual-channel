#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/go2-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1); GO=go0; RESTORED=0
restore() { [ "$RESTORED" = 1 ] && return; RESTORED=1
  sudo pkill -f 'airdrop-owl|build/daemon/owl' 2>/dev/null
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null; sleep 1
  for v in mon0 $GO; do sudo iw dev $v del 2>/dev/null; done; echo "--- restored ---"; }
trap 'restore' EXIT; trap 'restore; exit 130' INT TERM
setsid bash -c "sleep 300; pkill -f 'airdrop-owl|build/daemon/owl'; pkill -f 'hostapd.*hostapd-149.conf'; for v in mon0 go0; do iw dev \$v del 2>/dev/null; done" >/dev/null 2>&1 </dev/null &

sudo iw phy $PHY interface add $GO type __p2pgo && sudo ip link set $GO up
GOMAC=$(cat /sys/class/net/$GO/address)
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
sleep 6
grep -q 'AP-ENABLED' "$RUN/hostapd.log" || { echo "GO FAILED"; exit 1; }
sudo iw phy $PHY interface add mon0 type monitor
sudo ip link set mon0 down; sudo ip link set mon0 address "$GOMAC"; sudo ip link set mon0 up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep" 2>/dev/null
echo "GO on 149, mon0 aliased to $GOMAC"
sudo tcpdump -i mon0 -w "$RUN/awdl.pcap" -U >/dev/null 2>&1 & TD=$!
sudo /usr/local/bin/airdrop-owl -i mon0 -c 149 -N -vv > "$RUN/owl.log" 2>&1 &
sleep 20
GW=$(ip route | awk '/^default/{print $3; exit}')
( ping -i 1 -c 60 "$GW" > "$RUN/uplink.log" 2>&1 ) &
echo "=== awdl0 ==="; ip -br addr show awdl0 2>&1 | head -2
for MAC in $(grep -oP 'add peer \K\S+' "$RUN/owl.log" | sort -u); do
  # EUI-64 link-local from peer MAC
  IFS=: read a b c d e f <<< "$MAC"
  a=$(printf '%02x' $((0x$a ^ 2)))
  LL="fe80::${a}${b}:${c}ff:fe${d}:${e}${f}"
  echo "--- ping6 $MAC -> $LL ---" | tee -a "$RUN/ping6.log"
  ping6 -c 5 -W 2 -I awdl0 "$LL" 2>&1 | tail -3 | tee -a "$RUN/ping6.log"
done
echo "=== uplink during test ==="; tail -2 "$RUN/uplink.log"
echo "RUNDIR=$RUN"

#!/bin/bash
# Inject with sa = go0's MAC so mac80211 picks go0's sdata (chanctx on 5745).
# Arm A: go0 MAC (expect TX). Arm B: invented MAC (expect drop) = control.
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/tx2-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1); GO=go0; FAKE=02:11:22:33:44:55; RESTORED=0
restore() { [ "$RESTORED" = 1 ] && return; RESTORED=1
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null; sleep 1
  for v in mon0 $GO; do sudo iw dev $v del 2>/dev/null; done; echo "--- restored ---"; }
trap 'restore' EXIT; trap 'restore; exit 130' INT TERM
setsid bash -c "sleep 260; pkill -f 'hostapd.*hostapd-149.conf'; for v in mon0 go0; do iw dev \$v del 2>/dev/null; done" >/dev/null 2>&1 </dev/null &

sudo iw phy $PHY interface add $GO type __p2pgo && sudo ip link set $GO up
GOMAC=$(cat /sys/class/net/$GO/address); echo "GOMAC=$GOMAC" | tee "$RUN/meta.txt"
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
sleep 6
grep -q 'AP-ENABLED' "$RUN/hostapd.log" || { echo "GO FAILED"; exit 1; }
echo "GO up on 149"
sudo iw phy $PHY interface add mon0 type monitor && sudo ip link set mon0 up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep" 2>/dev/null
sudo tcpdump -i mon0 -w "$RUN/tx2.pcap" -U 'type mgt' >/dev/null 2>&1 & TD=$!
sleep 2
B0=$(cat /sys/class/net/$GO/statistics/tx_packets)
echo "--- ARM A: sa = $GOMAC ---"
sudo python3 "$DIR/inject.py" mon0 $GOMAC 30
A1=$(cat /sys/class/net/$GO/statistics/tx_packets)
echo "go0 tx_packets: $B0 -> $A1"
sleep 2
echo "--- ARM B (control): sa = $FAKE ---"
sudo python3 "$DIR/inject.py" mon0 $FAKE 30
sleep 3
sudo kill $TD 2>/dev/null; sleep 1; sudo chown jed: "$RUN/tx2.pcap"
echo "RUNDIR=$RUN"

#!/bin/bash
# CONTROL: is the injector sound at all? Monitor pair, NO GO, associated on 5260.
# If probe responses to our fake MAC come back on 5260, the injector works.
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/ctrl-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1); FAKE=02:11:22:33:44:55; RESTORED=0
restore() { [ "$RESTORED" = 1 ] && return; RESTORED=1
  for v in mon1 mon0; do sudo iw dev $v del 2>/dev/null; done; echo "--- restored ---"; }
trap 'restore' EXIT; trap 'restore; exit 130' INT TERM
setsid bash -c "sleep 200; for v in mon1 mon0; do iw dev \$v del 2>/dev/null; done" >/dev/null 2>&1 </dev/null &
sudo iw phy $PHY interface add mon0 type monitor && sudo ip link set mon0 up
sudo iw phy $PHY interface add mon1 type monitor flags active && sudo ip link set mon1 up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep" 2>/dev/null
sudo tcpdump -i mon0 -w "$RUN/ctrl.pcap" -U 'type mgt' >/dev/null 2>&1 & TD=$!
sleep 2
echo "--- arm 1: inject on mon1 (active) ---"
sudo python3 "$DIR/inject.py" mon1 $FAKE 25
sleep 2
echo "--- arm 2: inject on mon0 (plain) ---"
sudo python3 "$DIR/inject.py" mon0 $FAKE 25
sleep 3
sudo kill $TD 2>/dev/null; sleep 1; sudo chown jed: "$RUN/ctrl.pcap"
echo "RUNDIR=$RUN"

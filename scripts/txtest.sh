#!/bin/bash
# Does TX actually leave the radio on 5745 while associated elsewhere?
# Proof = probe RESPONSES addressed to a MAC we invented.
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/tx-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1)
GO=go0; FAKE=02:11:22:33:44:55; RESTORED=0
restore() { [ "$RESTORED" = 1 ] && return; RESTORED=1
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null; sleep 1
  for v in mon1 mon0 $GO; do sudo iw dev $v del 2>/dev/null; done
  echo "--- restored ---"; ip -br link show | grep -E 'wl|mon|go0'; }
trap 'restore' EXIT; trap 'restore; exit 130' INT TERM
setsid bash -c "sleep 240; pkill -f 'hostapd.*hostapd-149.conf'; for v in mon1 mon0 go0; do iw dev \$v del 2>/dev/null; done" >/dev/null 2>&1 </dev/null &

# 1. GO holds a chanctx on 149
sudo iw phy $PHY interface add $GO type __p2pgo && sudo ip link set $GO up
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
sleep 6
grep -q 'AP-ENABLED' "$RUN/hostapd.log" || { echo "GO FAILED"; tail -5 "$RUN/hostapd.log"; exit 1; }
echo "GO up on 149"

# 2. THE PAIR (FINDINGS §14): plain first, then active alongside
sudo iw phy $PHY interface add mon0 type monitor && sudo ip link set mon0 up
sudo iw phy $PHY interface add mon1 type monitor flags active && sudo ip link set mon1 up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep" 2>/dev/null
ip -br link show | grep -E 'mon|go0'

# 3. capture while injecting
sudo tcpdump -i mon0 -w "$RUN/tx.pcap" -U 'type mgt' >/dev/null 2>&1 &
TD=$!
sleep 2
sudo python3 "$DIR/inject.py" mon1 $FAKE 40 2>&1 | tee "$RUN/inject.log"
sleep 3
sudo kill $TD 2>/dev/null; sleep 1
sudo chown jed: "$RUN/tx.pcap" 2>/dev/null
echo "RUNDIR=$RUN"

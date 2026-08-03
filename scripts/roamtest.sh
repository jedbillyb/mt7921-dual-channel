#!/bin/bash
# Does the P2P-GO + MAC-aliased-mon0 rig survive a STA-side reassociation?
# Only the fixed-channel case has been measured so far (HANDOFF.md, README.md).
# This forces a reassociation (same-BSSID reconnect by default, or a roam to a
# named target BSSID) while the GO is up, and checks three things:
#   1. does wlp2s0 come back associated at all
#   2. does ch149 traffic on mon0 keep flowing across the transition
#   3. which mt7921/mac80211 chanctx functions actually ran, and on which vif
#      (ftrace — "iw" and return codes are not evidence, see README.md)
#
# Usage: sudo ./scripts/roamtest.sh [target_bssid]
#   no arg          -> disconnect/reconnect to the CURRENT bssid (NM autoconnect)
#   target_bssid     -> `iw dev wlp2s0 roam <bssid>` to a specific, already-seen AP
#
# Does not touch cfg80210/mac80211 module parameters; the kernel here is stock.

DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$DIR/roam-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1)
STA=wlp2s0
GO=go0
MON=mon0
TARGET_BSSID="$1"
BASELINE_SECS=15
POSTROAM_SECS=25
REASSOC_TIMEOUT=30
TRACE_FUNCS="ieee80211_set_disassoc ieee80211_prep_channel ieee80211_mgd_setup_link
             ieee80211_mgd_setup_link_sta drv_assign_vif_chanctx drv_switch_vif_chanctx
             drv_unassign_vif_chanctx mt792x_assign_vif_chanctx mt7921_switch_vif_chanctx
             mt7921_change_chanctx mt76_assign_vif_chanctx mt76_switch_vif_chanctx
             mt76_connac_mcu_uni_set_chctx"
RESTORED=0

restore() {
  [ "$RESTORED" = 1 ] && return; RESTORED=1
  echo "--- restore ---" | tee -a "$RUN/run.log"
  [ -n "$TD" ] && sudo kill "$TD" 2>/dev/null
  sudo pkill -f "hostapd.*hostapd-149.conf" 2>/dev/null
  sleep 1
  for v in $MON $GO; do sudo iw dev $v del 2>/dev/null; done
  sudo sh -c 'echo 0 > /sys/kernel/tracing/tracing_on' 2>/dev/null
  sudo sh -c 'echo nop > /sys/kernel/tracing/current_tracer' 2>/dev/null
  sudo sh -c 'echo > /sys/kernel/tracing/set_ftrace_filter' 2>/dev/null
  # Safety net: if the STA isn't connected by the time we get here (autoconnect
  # backed off, see the note above the disconnect call), don't leave the user
  # stranded -- nudge it once more on the way out.
  if ! iw dev $STA link 2>&1 | head -1 | grep -q "^Connected"; then
    echo "*** $STA not connected at cleanup, nudging with nmcli device connect ***" \
      | tee -a "$RUN/run.log"
    sudo nmcli device connect $STA 2>&1 | tee -a "$RUN/run.log"
  fi
  sudo chown -R "${SUDO_USER:-$(id -un)}" "$RUN" 2>/dev/null
  echo "RUNDIR=$RUN"
}
trap 'restore' EXIT
trap 'restore; exit 130' INT TERM

# detached watchdog: survives kill -9 of this script
setsid bash -c "sleep $((BASELINE_SECS+REASSOC_TIMEOUT+POSTROAM_SECS+90));
  pkill -f 'hostapd.*hostapd-149.conf';
  for v in $MON $GO; do iw dev \$v del 2>/dev/null; done;
  echo 0 > /sys/kernel/tracing/tracing_on 2>/dev/null;
  echo nop > /sys/kernel/tracing/current_tracer 2>/dev/null" \
  >/dev/null 2>&1 </dev/null &

echo "=== BEFORE: STA state ===" | tee -a "$RUN/run.log"
iw dev $STA link | tee -a "$RUN/run.log"

echo "=== GO up on ch149 ===" | tee -a "$RUN/run.log"
sudo iw phy $PHY interface add $GO type __p2pgo && sudo ip link set $GO up
GOMAC=$(cat /sys/class/net/$GO/address)
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd \
     "$DIR/hostapd-149.conf" > "$RUN/hostapd.log" 2>&1 &
sleep 6
grep -q 'AP-ENABLED' "$RUN/hostapd.log" || { echo "GO FAILED"; tail -10 "$RUN/hostapd.log"; exit 1; }

sudo iw phy $PHY interface add $MON type monitor
sudo ip link set $MON down
sudo ip link set $MON address "$GOMAC"
sudo ip link set $MON up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep" 2>/dev/null
echo "GO on 149, $MON aliased to $GOMAC" | tee -a "$RUN/run.log"

echo "=== BEFORE roam: GO state ===" | tee -a "$RUN/run.log"
iw dev $GO info 2>&1 | grep -E 'type|channel' | tee -a "$RUN/run.log"

echo "=== ftrace: mac80211/mt7921 chanctx path ===" | tee -a "$RUN/run.log"
sudo mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null
sudo sh -c 'echo 0 > /sys/kernel/tracing/tracing_on'
sudo sh -c 'echo nop > /sys/kernel/tracing/current_tracer'
sudo sh -c 'echo > /sys/kernel/tracing/set_ftrace_filter'
for f in $TRACE_FUNCS; do
  sudo sh -c "echo $f >> /sys/kernel/tracing/set_ftrace_filter" 2>/dev/null
done
sudo sh -c 'echo function > /sys/kernel/tracing/current_tracer'
sudo sh -c 'echo 1 > /sys/kernel/tracing/tracing_on'

# continuous radiotap capture across the whole test
sudo tcpdump -i $MON -tt -w "$RUN/roam.pcap" -U >/dev/null 2>&1 & TD=$!
sleep 2

echo "=== baseline: ${BASELINE_SECS}s on ch149 before touching $STA ===" | tee -a "$RUN/run.log"
sleep "$BASELINE_SECS"

T_ROAM=$(date +%s)
echo "T_ROAM=$T_ROAM" | tee -a "$RUN/run.log"
if [ -n "$TARGET_BSSID" ]; then
  echo "=== roam: iw dev $STA roam $TARGET_BSSID ===" | tee -a "$RUN/run.log"
  sudo iw dev $STA roam "$TARGET_BSSID" 2>&1 | tee -a "$RUN/run.log"
  echo "  (NM owns this nl80211 socket; if this also fails with 'Operation not" \
       "permitted', NM is blocking non-owner commands the same way disconnect" \
       "is below -- there is no plain-iw workaround, use nmcli instead)" \
    | tee -a "$RUN/run.log"
else
  # wlp2s0 is NetworkManager-managed: only NM's own nl80211 socket is the
  # "owner" of the connection, so `iw dev disconnect` from this script gets
  # -EPERM. Go through NM instead, which does the real teardown/reassoc.
  #
  # Do NOT also call `nmcli device connect` here. An earlier version did, to
  # force the reconnect rather than wait on autoconnect, and it raced NM's
  # own autoconnect: NM logged "New connection activation was enqueued", the
  # two activations collided, wlp2s0 associated for ~1s then deauthenticated
  # again on its own, and autoconnect did NOT retry after that -- wifi stayed
  # down until manually reconnected. `nmcli device disconnect` alone is
  # sufficient; NM's autoconnect handles the reconnect on its own.
  echo "=== reassoc: nmcli disconnect, wait for NM autoconnect ===" | tee -a "$RUN/run.log"
  sudo nmcli device disconnect $STA 2>&1 | tee -a "$RUN/run.log"
fi

echo "=== polling $STA for up to ${REASSOC_TIMEOUT}s (must read Connected 3x in a" \
     "row, 1s apart, before this counts -- a single read can catch a connection" \
     "that drops again a second later, see note above) ===" | tee -a "$RUN/run.log"
i=0
STABLE=0
RETRIED=0
while [ $i -lt $((REASSOC_TIMEOUT * 2)) ]; do
  STATE=$(iw dev $STA link 2>&1 | head -1)
  echo "$(date +%s.%N) $STATE" >> "$RUN/sta-poll.log"
  if echo "$STATE" | grep -q "^Connected"; then
    STABLE=$((STABLE+1))
    [ $STABLE -ge 3 ] && break
    sleep 1
    i=$((i+2))
    continue
  fi
  STABLE=0
  # halfway through the timeout with no stable connection: NM's autoconnect
  # may have backed off (as it did the time this raced, see above). Give it
  # one explicit nudge, but only once, and not stacked on the disconnect
  # above -- this is a fallback, not the normal path.
  if [ $RETRIED -eq 0 ] && [ $i -ge $REASSOC_TIMEOUT ]; then
    echo "=== no stable reconnect at ${REASSOC_TIMEOUT}s in, nudging with nmcli device connect ===" \
      | tee -a "$RUN/run.log"
    sudo nmcli device connect $STA 2>&1 | tee -a "$RUN/run.log"
    RETRIED=1
  fi
  sleep 0.5
  i=$((i+1))
done
T_REASSOC_DONE=$(date +%s)
if [ $STABLE -ge 3 ]; then
  echo "T_REASSOC_DONE=$T_REASSOC_DONE (elapsed $((T_REASSOC_DONE - T_ROAM))s, stable)" \
    | tee -a "$RUN/run.log"
else
  echo "T_REASSOC_DONE=$T_REASSOC_DONE (elapsed $((T_REASSOC_DONE - T_ROAM))s, *** NOT" \
       "confirmed stable -- check sta-poll.log and consider reconnecting manually ***)" \
    | tee -a "$RUN/run.log"
fi
echo "=== AFTER: STA state ===" | tee -a "$RUN/run.log"
iw dev $STA link | tee -a "$RUN/run.log"
echo "=== AFTER roam: GO state ===" | tee -a "$RUN/run.log"
iw dev $GO info 2>&1 | grep -E 'type|channel' | tee -a "$RUN/run.log"
if ! iw dev $GO info 2>&1 | grep -q 'channel'; then
  echo "  *** GO reports no channel after the roam - compare against BEFORE" \
       "above; if BEFORE had one, the reassociation cost the GO its chanctx ***" \
    | tee -a "$RUN/run.log"
fi

echo "=== post-roam window: ${POSTROAM_SECS}s ===" | tee -a "$RUN/run.log"
sleep "$POSTROAM_SECS"

[ -n "$TD" ] && sudo kill "$TD" 2>/dev/null
sleep 1
sudo sh -c 'echo 0 > /sys/kernel/tracing/tracing_on'
sudo cat /sys/kernel/tracing/trace > "$RUN/ftrace.log" 2>/dev/null
sudo sh -c 'echo nop > /sys/kernel/tracing/current_tracer'
sudo sh -c 'echo > /sys/kernel/tracing/set_ftrace_filter'
sudo chown "${SUDO_USER:-$(id -un)}" "$RUN/roam.pcap" "$RUN/ftrace.log" 2>/dev/null

echo "=== frame counts by window (pre / roam-to-reassoc / post), 5745 MHz vs other ===" \
  | tee -a "$RUN/run.log"
sudo tcpdump -tt -e -n -r "$RUN/roam.pcap" 2>/dev/null | awk -v troam="$T_ROAM" -v tdone="$T_REASSOC_DONE" '
  {
    ts=$1
    freq="other"
    if ($0 ~ /5745 MHz/) freq="5745"
    win = (ts < troam) ? "pre" : (ts <= tdone ? "during" : "post")
    count[win, freq]++
    total[win]++
  }
  END {
    for (w in total)
      printf "%-8s total=%-6d 5745MHz=%-6d\n", w, total[w], count[w, "5745"]+0
  }' | tee -a "$RUN/run.log"

echo "=== ftrace hits by function ===" | tee -a "$RUN/run.log"
grep -oE '\b[a-z0-9_]+\(' "$RUN/ftrace.log" 2>/dev/null | sort | uniq -c | sort -rn \
  | tee -a "$RUN/run.log"

echo "RUNDIR=$RUN"

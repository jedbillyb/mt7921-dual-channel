# Handoff — session of 2026-08-03

> **Snapshot from 2026-08-03, kept as written.** Local paths and "State of the
> machine" describe the author's laptop that day. The mechanism has since been
> built into `airdropd` in
> [airdrop-mt7921](https://github.com/jedbillyb/airdrop-mt7921); see the
> README here for the current summary.

Read this first, then `README.md`. Companion userspace project is
`/mnt/shared/projects/airdrop-mt7921` (FINDINGS §43–§46).

**This supersedes the 2026-08-02 handoff.** That document proposed the P2P-GO
experiment, called it "maybe-promising, not likely", and left it unstarted.
It was run on 2026-08-03. **It works.**

## The question

Make a **single MT7921** do Wi-Fi and AirDrop/AWDL at the same time, with no
second radio and no router configuration.

## ANSWERED: yes, on a STOCK KERNEL

Measured on ch149 (5745) while associated to `student` on ch52 (5260).
**Nothing was written to `/lib/modules`. No kernel module was patched or even
rebuilt.** The only patched component is hostapd.

| | monitor vif (2026-08-02) | P2P-GO vif (this session) |
|---|---|---|
| kernel accepts | only after 3 patches | **yes, stock** |
| radio actually moves | **no** — 593/593 on AP chan | **yes** |
| RX on 149 | 0 frames | **222 frames, 75 from external devices** |
| TX on 149 | never reached | **82 solicited probe responses, 5 APs** |
| AWDL peers | — | **4 discovered, sync locked** |
| AWDL data path | — | **iPhone replied to ping6, 460 ms** |

Uplink survived every run: 0% packet loss throughout.

## The two mechanisms

### 1. P2P-GO is the only iftype that gets two channels

`iw phy phy0 info` interface combinations:

```
* #{managed,P2P-client} <= 2, #{P2P-GO} <= 1, #{P2P-device} <= 1,
  total <= 3, #channels <= 2      <-- two channels, P2P-GO only
* #{managed,P2P-client} <= 2, #{AP} <= 1, #{P2P-device} <= 1,
  total <= 3, #channels <= 1      <-- plain AP is single-channel
```

hostapd **unconditionally forces iftype AP**, so out of the box you get
`nl80211: Beacon set failed: -16 (Device or resource busy)`.

`patches/0004-hostapd-p2p-go-iftype.patch` makes hostapd keep `P2P_GO` when
`HOSTAPD_P2P_GO=1`. `is_ap_interface()` already accepts `P2P_GO`, so nothing
else in hostapd changes. Built at `/mnt/shared/build/hostapd-2.11`.

### 2. Monitor TX borrows another vif's chanctx BY MAC ADDRESS

`ieee80211_monitor_start_xmit()` (`net/mac80211/tx.c:~2377`) loops
`local->interfaces` and, if an injected frame's `addr2` equals a **running
non-monitor vif's** MAC, uses that sdata's chanctx. Monitor vifs are explicitly
skipped by the loop, so **aliasing a monitor vif's MAC to the GO's is safe and
is the whole integration trick.**

No MAC match → falls back to `local->monitor_sdata` (only exists when
`open_count == 0`) → else `goto fail_rcu`.

## THE SILENT-DROP TRAP — cost one void test

While associated, an injected frame from a monitor vif is dropped inside
mac80211 with **`tx_packets`, `tx_dropped` AND `tx_errors` all staying 0**, and
`socket.send()` returning success. No error anywhere, no dmesg line.

The first TX test read as "MCC TX doesn't work". **The control — same injection
with no GO at all — also gave zero**, proving the monitor-TX path was at fault,
not MCC. Then injecting with the GO's MAC gave 82 responses vs 0 for an invented
MAC. **Always run the no-GO control before blaming the channel.**

## Working recipe

```sh
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1)
sudo iw phy $PHY interface add go0 type __p2pgo && sudo ip link set go0 up
GOMAC=$(cat /sys/class/net/go0/address)
sudo -E env HOSTAPD_P2P_GO=1 /mnt/shared/build/hostapd-2.11/hostapd/hostapd \
     scripts/hostapd-149.conf &
# wait for AP-ENABLED, then:
sudo iw phy $PHY interface add mon0 type monitor
sudo ip link set mon0 down
sudo ip link set mon0 address "$GOMAC"      # <-- the trick
sudo ip link set mon0 up
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/runtime-pm"
sudo sh -c "echo 0 > /sys/kernel/debug/ieee80211/$PHY/mt76/deep-sleep"
sudo /usr/local/bin/airdrop-owl -i mon0 -c 149 -N -vv
```

`scripts/gomode2.sh` does all of this plus ping6 and cleanup.
`iw dev mon0 set freq` is **still EBUSY** and `mon0` **still reports no
channel** — the kernel's story never changed, the radio's behaviour did. Do not
use `iw` as evidence here.

## THE COST — this is the open design problem

| | uplink to gateway |
|---|---|
| baseline | ~2.6 ms avg, 7.6 ms max |
| GO up on a different channel | **~40 ms median, 280–590 ms max** |

0% packet loss, pure latency. Fine for browsing/streaming, **bad for Discord VC
and Minecraft** — which is the user's existing sore point (see the onboard
mt7921 jitter notes). A permanently-armed GO on a non-AP channel is therefore
not acceptable as-is.

macOS pays the same cost — one radio, same physics. Apple hides it by not
keeping AWDL up (BLE-triggered, torn down after) and by sequence design.

## NEXT: "always armed at zero cost" — the slot-8 plan (NOT YET TESTED)

**If the GO sits on the AP's own channel there is no time-slicing at all** —
one channel, zero cost, AWDL genuinely up 24/7.

The enabling fact, from our own captures: **slot 8 is always the 2.4 GHz social
slot.** Every peer sequence ever recorded:

```
112,112,149,0,0,0,0,112,6,112,149,112,0,0,0,112
 36, 36,149,0,0,0,0, 36,6, 36,149, 36,0,0,0, 36
```

ch6 at slot 8, both times. Structure, not luck.

**Plan A (zero cost, always armed):** at home, move `2142-WiFi`'s 2.4 GHz BSS
from **ch2 to ch6**, park the GO on ch6. Note this is NOT §40b's rejected
proposal (which moved 5 GHz to 149 and depended on where the phone roams) — it
is a one-click change to a band not used for throughput, and slot 8 is always
2.4 GHz regardless of roaming. Downside: 1/16 slots ≈ 6% duty ≈ ~22 kB/s
(extrapolated from the 2/16 → 45 kB/s baseline). Fine for discovery, slow for
a photo.

**Plan B (removes Plan A's downside):** hostapd `chan_switch` (CSA) to move the
GO to the phone's dominant channel for the duration of a transfer, then back.
Pay the 40 ms only while a file is actually moving. **Untested — unknown
whether mt7921 honours CSA on a GO.**

**Plan C (polish):** wire up Opportunistic Power Save. The chain is built except
the last hop:
- firmware command exists: `MCU_CE_CMD(SET_P2P_OPPPS)`
- driver function exists and is exported:
  `mt76_connac_mcu_set_p2p_oppps()` (`mt76_connac_mcu.c:2320`)
- hostapd implements the userspace side (`src/ap/p2p_hostapd.c`, `set_noa`)
- **but only mt7615 calls it** (`mt7615/main.c:591`).
  `mt7921_bss_info_changed()` handles `ERP_SLOT/BEACON/QOS/PS/CQM/ASSOC/
  ARP_FILTER` and **not `BSS_CHANGED_P2P_PS`.**

~5 lines copying mt7615's pattern. **Caution: this chip's signature failure is
accepting an MCU command and ignoring it** — `MCU_UNI_CMD(SNIFFER)` returned
success three times while the radio sat still. Verify by measurement, not by
return code. Full NoA is not in mt76 for any chip.

## Also still open

- **A real file transfer has NOT been done in GO mode.** ping6 got 1/5 replies
  (80% loss) — categorical PASS per §23/§26, but ping6 **cannot size an effect**.
  The 80% is explained: the phone offered ch149 only 2/16 slots that run
  (112 was dominant at 6/16), and we shared those with the AP.
- `.venv-opendrop` is **missing** from the airdrop-mt7921 repo and must be
  rebuilt with the three patches before any transfer test.
- **SECURITY, blocks anything always-on:** opendrop's `handle_ask` in
  `server.py` unconditionally accepts — no prompt, no hook.
  `patches/opendrop-ask-confirm.patch` exists but is not applied.
- Active-monitor (`flags active`) ACKs against a GO-held chanctx: untested.
  If unicast fails, try the §14 PAIR with both vifs MAC-aliased.

## Superseded, but still true: the MONITOR route is closed

Do not re-attempt retuning a monitor vif while associated. Three gates found,
patched, ftrace-confirmed to execute, `MCU_UNI_CMD(SNIFFER)` returns success,
**radio does not move** (593/593 frames on the AP's channel).

| # | layer | gate | patch |
|---|---|---|---|
| 1 | cfg80211 | `cfg80211_has_monitors_only()` (`net/wireless/chan.c:1550`) | 0001 |
| 2 | mac80211 | virtual monitor only when `open_count == 0` (`iface.c:1403`) | 0003 |
| 3 | mt7921 | `mt7921_mcu_config_sniffer()` only from `->change_chanctx` | 0002 |

Patches 0001–0003 are kept as the documented negative result. **They are no
longer needed for anything.**

Firmware analysis stands: unencrypted RAM code, re-uploaded each boot, cannot
brick; CNM time-slicing scheduler present (`CnmFastChReqQuotaInUs`,
`CnmGOAbsenceMarginInUs`, `EnCnmSyncTBTT`); **zero sniffer strings** — which is
precisely why P2P-GO works and monitor does not. **Firmware editing is now
moot.**

## State of the machine

Left clean and verified: stock modules, no leftover vifs, no hostapd running,
`wlp2s0` associated and passing traffic at 0% loss, nothing in `/lib/modules`.

`/mnt/shared/kernel/linux-6.18.33` is **2.3 GB and now safe to delete** — no
kernel patching is required by the working solution. `/` is at 95%.
`/mnt/shared/build/{hostapd-2.11,wpa_supplicant-2.11}` hold the hostapd build
(needed) and a P2P-enabled wpa_supplicant build (turned out unnecessary).

## Traps already paid for

1. **`iw` lies.** `iw dev mon0 info` reports what the kernel believes, which is
   exactly what is in question. Only radiotap frequencies are evidence.
2. **Silent TX drop** — see above. Counters stay 0, `send()` succeeds.
3. **hostapd's stock `defconfig` lacks `CONFIG_IEEE80211AC`** — `ieee80211ac=1`
   in the conf is a fatal "unknown configuration item".
4. **hostapd renames the vif on exit** — `udevd: could not rename interface
   'go0' to 'wlp2s0': File exists` appears in dmesg; harmless.
5. Test scripts must have a `trap` on EXIT/INT/TERM **plus** a `setsid`-detached
   watchdog; a trap cannot survive `kill -9`. All scripts here do.
6. If a kernel rebuild is ever needed again: use `/proc/config.gz` verbatim,
   test loads with `crypto/michael_mic.ko`, never build `M=<dir>` twice without
   cleaning, and note **phy renumbers phy0→phy1 on driver reload**.

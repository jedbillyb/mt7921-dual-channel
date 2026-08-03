# mt7921-awdl-kernel

> **Unsupported personal project.** This is my own research, done on my own
> laptop, published in case it is useful. It is not affiliated with the Open
> Wireless Link project, OpenDrop, MediaTek, or Apple. There is no support, no
> warranty, and no promise that any of this works on your hardware or
> regulatory domain. Issues and PRs may sit unread.
>
> The userspace side that actually uses this -
> [`airdrop-mt7921`](https://github.com/jedbillyb/airdrop-mt7921) - and the
> AWDL protocol engine - [`owl`](https://github.com/jedbillyb/owl) - are
> separate repos. This one is kernel/driver-level: what makes a single MT7921
> radio service two Wi-Fi channels at once in the first place.

> ## Solved 2026-08-03: Wi-Fi + AWDL on one MT7921, stock kernel
>
> A **P2P-GO vif + MAC-aliased monitor injection** gets simultaneous RX and TX
> on ch149 (5745) while associated to the home AP on ch52 (5260), on a
> **stock, unpatched kernel**. Nothing is written to `/lib/modules`; the only
> patched component is hostapd (`patches/0004-hostapd-p2p-go-iftype.patch`).
> Measured: 222 RX frames at 5745 (75 from external devices), 82 solicited
> probe responses TX'd, 4 AWDL peers discovered with sync locked, and an
> iPhone replying to `ping6` at 460 ms. Uplink survived at 0% packet loss
> throughout, though at added latency (see "The cost" below).
>
> This **supersedes** the monitor-vif / firmware-sniffer route documented
> further down. That route is a **confirmed dead end**: the mt7921
> firmware's sniffer channel is not independent of the BSS channel. Three
> kernel gates were found, patched, and ftrace-confirmed to execute end to
> end; `MCU_UNI_CMD(SNIFFER)` returns success and the radio never leaves the
> associated channel (593/593 captured frames stayed on the AP's channel).
> No kernel patch can fix that - it is a firmware boundary. **Do not
> re-attempt or re-derive this; the patches are kept only as a documented
> negative result.** See "The dead end: monitor-vif retuning" below for the
> full analysis.
>
> Full session detail, open items, and the next-step plans (slot-8 zero-cost
> parking, CSA, Opportunistic Power Save) live in `HANDOFF.md` - read that
> first for anything beyond a summary.

Kernel/driver-adjacent work to let a **single MT7921** do Wi-Fi and
AWDL/AirDrop at the same time, with no second radio and no router
configuration change beyond channel choice.

Userspace AirDrop stack lives in [`airdrop-mt7921`](../airdrop-mt7921); this
repo holds the patches, test scripts, and the build/load procedure for the
(now superseded) kernel route, plus the hostapd patch for the working route.

## The problem, restated

`airdrop.sh` / `airdropd` work, but only when the phone's AWDL happens to
land on the channel our AP is already on. AWDL social channels are 6, 44 and
149, chosen by the peer and drifting between transfers. A plain monitor vif
cannot retune while associated (`EBUSY`), so without a second channel path
the transfer only sees AWDL when luck lines the channel up.

## The working solution: P2P-GO + MAC-aliased injection

### Mechanism 1 - P2P-GO is the only iftype that gets a second channel

`iw phy phy0 info` interface combinations:

```
* #{managed,P2P-client} <= 2, #{P2P-GO} <= 1, #{P2P-device} <= 1,
  total <= 3, #channels <= 2      <-- two channels, P2P-GO only
* #{managed,P2P-client} <= 2, #{AP} <= 1, #{P2P-device} <= 1,
  total <= 3, #channels <= 1      <-- plain AP is single-channel
```

hostapd unconditionally forces iftype AP, so out of the box you get
`nl80211: Beacon set failed: -16 (Device or resource busy)`.
`patches/0004-hostapd-p2p-go-iftype.patch` keeps the iftype as `P2P_GO` when
`HOSTAPD_P2P_GO=1` is set in the environment. `is_ap_interface()` already
accepts `P2P_GO`, so no other hostapd path needs changing. Built at
`/mnt/shared/build/hostapd-2.11`.

### Mechanism 2 - monitor TX borrows another vif's chanctx by MAC address

`ieee80211_monitor_start_xmit()` (`net/mac80211/tx.c:~2377`) resolves an
injected frame's `addr2` against **running non-monitor vifs**, and uses that
vif's chanctx if it matches. Monitor vifs are skipped by that lookup, so
**aliasing a monitor vif's MAC address to the GO's** routes AWDL injection
onto the GO's channel - the whole integration trick, no driver or firmware
changes involved.

`iw dev mon0 set freq` is still `EBUSY` and `mon0` still reports no channel
throughout - the kernel's bookkeeping never changes, only the firmware's
actual behaviour. Don't use `iw` as evidence either way; only a radiotap
capture shows the truth.

### Working recipe

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

`scripts/gomode2.sh` does all of the above plus ping6 verification and
cleanup (with a `trap`-based teardown and a `setsid`-detached watchdog, since
a trap alone doesn't survive `kill -9`).

### The cost - open design problem

| | uplink to gateway |
|---|---|
| baseline | ~2.6 ms avg, 7.6 ms max |
| GO up on a different channel | ~40 ms median, 280–590 ms max |

0% packet loss, pure added latency from time-slicing between the AP's
channel and the GO's. Fine for browsing/streaming, bad for latency-sensitive
traffic (Discord VC, Minecraft). A permanently-armed GO on a channel other
than the AP's is therefore not acceptable as a default-on setup.

The **slot-8 plan** (park the GO on the same channel the AP already uses,
since AWDL's slot 8 is consistently the 2.4 GHz social slot in every capture
so far) would make this zero-cost and always-on, but is not yet tested. See
`HANDOFF.md` for that plan plus the CSA and Opportunistic Power Save
alternatives, and for what's still open (no real file transfer done in GO
mode yet, `opendrop`'s unconditional `handle_ask` accept is a security gap
for anything always-on, etc).

## The dead end: monitor-vif retuning (kept for the negative result)

This was the original approach: retune a **monitor** vif's channel while
staying associated, rather than using a second vif type. It does not work,
and the reason is the firmware, not the kernel.

Full chain - `set_monitor_channel` → `new_chanctx` → `mt7921_add_chanctx` →
`mt7921_assign_vif_chanctx` → `mt7921_mcu_config_sniffer` - was patched
through and confirmed by ftrace to execute completely. The MCU command
**returns success**, and the firmware continues receiving only the
associated BSS's channel regardless.

Measured: associated on ch2 (2417 MHz), monitor requested on ch149
(5745 MHz). 593 of 593 captured frames were 2417 MHz, zero on 5745. The
association survived throughout at 0% packet loss.

**The mt7921 firmware's sniffer channel is not independent of the BSS
channel.** No kernel patch can fix that from above. Firmware analysis
(`/lib/firmware/mediatek/WIFI_RAM_CODE_MT7961_1.bin.zst`) found it
unencrypted RAM code containing a channel manager with time-slicing support
(`CnmFastChReqQuotaInUs`, `CnmGOAbsenceMarginInUs`, `EnCnmSyncTBTT`) tied to
P2P/GO naming, but **zero sniffer strings** - which is exactly why the P2P-GO
route above works and this one doesn't. Editing the firmware to add that
capability would be months of reverse-engineering a stripped ~792 KB binary
with no symbols; the P2P-GO route made that moot.

The patches below are kept only because the analysis is reusable and the
negative result is worth not re-deriving. They are **not** a working feature
and should not be loaded expecting one.

### Where the EBUSY actually came from

Traced through 6.18.33:

1. **Not the interface-combination table.** `mac80211/main.c:1354` puts
   monitor in `wiphy->software_iftypes`, and
   `ieee80211_check_combinations()` returns 0 early for software iftypes
   (`util.c:4186`). mt7921 does not set `NO_VIRTUAL_MONITOR` (only mt7996
   does). The `#channels <= 2` line in `iw phy0 info` is never consulted for
   a monitor vif.
2. **Not `ieee80211_set_monitor_channel()`.** In 6.18 it has no
   `open_count != monitors` gate; that check exists in older kernels. It
   calls `ieee80211_link_use_channel()` directly.
3. **Not `find_available_radio()`.** `wiphy->n_radio == 0` here, so it
   returns true immediately.
4. **Not the driver.** `mt7921_add_chanctx()` is `dev->new_ctx = ctx; return
   0;` and `mt792x_assign_vif_chanctx()` is pure bookkeeping. Neither can
   fail.

The gate was one line up in **cfg80211**, `net/wireless/chan.c:1550`:

```c
int cfg80211_set_monitor_channel(...)
{
	if (!rdev->ops->set_monitor_channel)
		return -EOPNOTSUPP;
	if (!cfg80211_has_monitors_only(rdev))
		return -EBUSY;
	return rdev_set_monitor_channel(rdev, dev, chandef);
}
```

where `cfg80211_has_monitors_only()` (`net/wireless/core.h:252`) is

```c
return rdev->num_running_ifaces == rdev->num_running_monitor_ifaces &&
       rdev->num_running_ifaces > 0;
```

### Three gates, not one

Each patch removed a gate and revealed the next one below it. Each one
**fails by succeeding** - returns 0, logs nothing - which is why this took
several rounds of patch-and-measure rather than one reading of the source.

**Gate 1 - cfg80211.** `cfg80211_has_monitors_only()`. Patch 0001
(`cfg80211.monitor_any_chan=1`). After it, `iw set freq` returned 0 instead
of EBUSY. Capture: still 100% on the AP's channel. ftrace showed no driver
function ran at all.

**Gate 2 - mac80211.** `net/mac80211/iface.c:1403`:

```c
if (local->virt_monitors == 0 && local->open_count == 0)
        res = ieee80211_add_virtual_monitor(local);
```

The virtual monitor is only created when nothing else is up. With an
association, `local->monitor_sdata` stays NULL, and
`ieee80211_set_monitor_channel()` hits its `goto done`: record the channel,
return 0, never reach the driver. Patch 0003
(`mac80211.monitor_concurrent=1`).

**Gate 3 - the driver.** `mt7921_mcu_config_sniffer()` is reachable only
from `->change_chanctx`, which a *newly created* context never triggers. So
even with a monitor chanctx, the firmware was never told. Patch 0002 calls
it from `->assign_vif_chanctx`.

With all three, ftrace confirms the complete chain executes and the MCU
command returns success. The radio still does not move. **Gate 4 is the
firmware, and it is not patchable from the kernel.**

### mt76's own admission this chip is single-channel

`mt7921_change_chanctx()` treats monitor vifs specially:

```c
if (vif->type == NL80211_IFTYPE_MONITOR)
        mt7921_mcu_config_sniffer(mvif, ctx);
else
        mt76_connac_mcu_uni_set_chctx(...);
```

and mt76's generic chanctx code is explicit about single-channel hardware
(`channel.c:47`):

```c
if (!phy->chanctx)
        ret = mt76_phy_update_channel(phy, conf);
else
        ret = 0;        /* second chanctx: accepted, ignored */
```

A second chanctx is accepted and silently ignored - this chip's signature
failure mode, and the reason patch 0001 is opt-in: removing the check does
not create multi-channel capability, it only stops the kernel refusing on
your behalf.

### Reproducing the negative result

```sh
sudo scripts/reload-stack.sh          # loads all three, auto-rollback on no link
PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1)   # renumbers on driver reload
sudo iw phy "$PHY" interface add mon0 type monitor && sudo ip link set mon0 up
sudo iw dev mon0 set freq 5745
sudo timeout 20 tcpdump -i mon0 -e -n -c 600 2>/dev/null \
  | grep -oE '[0-9]{4} MHz' | sort | uniq -c | sort -rn
```

To restore stock: `modprobe -r mt7921e mt7921_common mt792x_lib
mt76_connac_lib mt76 mac80211 cfg80211` then `modprobe cfg80211 mac80211
mt7921e`. Nothing was ever written to `/lib/modules`, so a reboot also
suffices.

### Build (only relevant if re-deriving the negative result)

Two facts make this cheap on this box:

- `CONFIG_MODVERSIONS` is **off** - no symbol CRCs, so a rebuilt module only
  needs a matching vermagic string.
- `CONFIG_MODULE_SIG_FORCE` is **off** - unsigned modules load (taint only).

`/` is at 95%, so build on `/mnt/shared`.

```sh
cd /mnt/shared/kernel
curl -O https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.33.tar.xz
tar xf linux-6.18.33.tar.xz && cd linux-6.18.33
patch -p1 < /mnt/shared/projects/mt7921-awdl-kernel/patches/0001-cfg80211-monitor_any_chan.patch

zcat /proc/config.gz > .config
scripts/config --disable DEBUG_INFO_BTF --disable DEBUG_INFO_BTF_MODULES \
               --disable MODULE_SIG --disable DEBUG_INFO --enable DEBUG_INFO_NONE
make olddefconfig
make -s kernelrelease        # must print 6.18.33_1, i.e. `uname -r`

make -j16 modules_prepare
make M=net/wireless clean                      # see below - do NOT skip
KBUILD_MODPOST_WARN=1 make -j16 M=net/wireless
strip --strip-debug net/wireless/cfg80211.ko
```

**Never build this directory twice without cleaning.** The obvious sequence -
run `make M=net/wireless`, watch modpost fail on unresolved symbols, re-run
it with `KBUILD_MODPOST_WARN=1` - produces a module that builds cleanly,
passes `modinfo`, matches vermagic, and then dies at `insmod` with:

```
Invalid module format
module: x86/modules: Invalid relocation target, existing value is nonzero for type 1
```

Type 1 is `R_X86_64_64`: the second pass incrementally re-links
`cfg80211.o` into itself and applies the relocations twice. The tell is that
a correct build prints `LD [M] cfg80211.o` *and* `LD [M] cfg80211.ko`; the
bad one only prints the latter, because it reused the stale object.

`strip --strip-debug` is cosmetic but worth it: `olddefconfig` re-enables
`CONFIG_DEBUG_INFO` through a `select` even after `scripts/config --disable`,
giving a 25 MB module. Stripped it is 2.7 MB, against 3.08 MB for stock.

`KBUILD_MODPOST_WARN=1` is required and is safe **only because MODVERSIONS
is off**: there is no `Module.symvers` from a vmlinux build, so modpost
cannot resolve kernel symbols and errors out. Those symbols are resolved by
the module loader at insert time instead.

Confirm before loading:

```sh
modinfo net/wireless/cfg80211.ko | grep -E 'vermagic|monitor_any_chan'
```

Requires tearing down the whole 802.11 stack, which **drops the network
link**. Nothing is written to `/lib/modules`, so rebooting fully restores
the stock stack.

```sh
sudo ./scripts/reload-cfg80211.sh
```

The script unloads mt7921e → mac80211 → cfg80211, inserts the patched module
with `monitor_any_chan=1`, reloads the rest, and **rolls back to the stock
modules automatically** if the link has not returned within 45 s. Log:
`/tmp/cfg80211-reload.log`.

## Gotcha that cost the most time: vermagic is necessary, not sufficient

`MODVERSIONS` being off means no symbol CRCs - but it also means **nothing
checks that your config matches the running kernel's**. Building with
`CONFIG_DEBUG_INFO_BTF_MODULES` disabled removes four fields from
`struct module`:

```c
#ifdef CONFIG_DEBUG_INFO_BTF_MODULES
	unsigned int btf_data_size;      /* module.h:511 */
	unsigned int btf_base_data_size;
	void *btf_data;
	void *btf_base_data;
#endif
```

`init` sits at module.h:458, *before* that block; `exit` at :572, *after* it.
So the struct shrinks by 24 bytes and the `.gnu.linkonce.this_module`
relocation for `exit` lands 24 bytes early, inside a field the loader has
already written. Result:

```
insmod: ERROR: could not insert module: Invalid module format
module: x86/modules: Invalid relocation target, existing value is nonzero for type 1
```

It affects **every** module built that way, not just the one you care about
- verify with a throwaway like `crypto/michael_mic.ko`, which costs no
network. The `.ko` is clean on disk; the fault only appears at load.
**Build with `/proc/config.gz` verbatim.** `pahole` is installed here, and
module BTF generation skips itself gracefully when `vmlinux` is absent.

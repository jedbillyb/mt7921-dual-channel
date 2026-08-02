# mt7921-awdl-kernel

Kernel-side work to let a **single MT7921** do Wi-Fi and AWDL/AirDrop at the
same time, with no second radio and no router configuration.

Userspace lives in [`airdrop-mt7921`](../airdrop-mt7921); this repo is only the
patches and the build/load procedure.

## The problem, restated

`airdrop.sh` and `airdropd` work, but only when the phone's AWDL happens to land
on the channel our AP is already on. AWDL social channels are 6, 44 and 149,
chosen by the peer and drifting between transfers. Observed distribution across
every run so far:

| channel | frames |
|---|---|
| 149 | 2870 |
| 6 | 499 |
| 36 | 312 |
| 44 | 112 |
| 132 | 15 |

The AP here sits on 36. Retuning the monitor vif to 149 while associated fails
with `EBUSY`, so the transfer never sees a single AWDL frame.

## Where the EBUSY actually comes from

Not where the earlier notes guessed. Traced through 6.18.33:

1. **Not the interface-combination table.** `mac80211/main.c:1354` puts monitor
   in `wiphy->software_iftypes`, and `ieee80211_check_combinations()` returns 0
   early for software iftypes (`util.c:4186`). mt7921 does not set
   `NO_VIRTUAL_MONITOR` (only mt7996 does). The `#channels <= 2` line in
   `iw phy0 info` is never consulted for a monitor vif.
2. **Not `ieee80211_set_monitor_channel()`.** In 6.18 it has no `open_count !=
   monitors` gate; that check exists in older kernels. It calls
   `ieee80211_link_use_channel()` directly.
3. **Not `find_available_radio()`.** `wiphy->n_radio == 0` here, so it returns
   true immediately.
4. **Not the driver.** `mt7921_add_chanctx()` is `dev->new_ctx = ctx; return 0;`
   and `mt792x_assign_vif_chanctx()` is pure bookkeeping. Neither can fail.

The gate is one line up in **cfg80211**, `net/wireless/chan.c:1550`:

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

So it is **cfg80211.ko**, a third module, and neither of the two I expected.

## Why upstream is right to refuse

`mt7921` has exactly one hardware channel. `mt7921_config()` handles
`IEEE80211_CONF_CHANGE_CHANNEL` by calling `mt76_update_channel()`, which
programs `phy->chandef` — the whole PHY. mt76's own generic chanctx code is
explicit about being single-channel (`channel.c:47`):

```c
if (!phy->chanctx)
        ret = mt76_phy_update_channel(phy, conf);
else
        ret = 0;        /* second chanctx: accepted, ignored */
```

A second chanctx is **accepted and silently ignored**. That is this chip's
signature failure mode, and the reason the patch below is opt-in: removing the
check does not create multi-channel capability, it only stops the kernel
refusing on your behalf.

## The one thing that might make it real

`mt7921_change_chanctx()` treats monitor vifs specially:

```c
if (vif->type == NL80211_IFTYPE_MONITOR)
        mt7921_mcu_config_sniffer(mvif, ctx);
else
        mt76_connac_mcu_uni_set_chctx(...);
```

`mt7921_mcu_config_sniffer()` (`mt7921/mcu.c:1161`) sends the firmware a
**sniffer channel of its own** — band, bandwidth, control channel, center
channel — separate from the associated BSS's channel. If that firmware path is
a genuinely independent receive context rather than another way of writing the
global channel, single-chip concurrency is real. If it is not, it will retune
the PHY and drop the association.

**This is the open question, and it is answered by experiment, not by reading.**
Note the ordering problem: `config_sniffer` is only reached from
`change_chanctx`, never from `add_chanctx`/`assign_vif_chanctx`, so a freshly
created monitor chanctx may never configure the firmware sniffer at all.

## Patch

`patches/0001-cfg80211-monitor_any_chan.patch` adds a module parameter, default
off:

```
cfg80211.monitor_any_chan=1
```

A parameter rather than a deletion, so the behaviour is opt-in, runtime
togglable via `/sys/module/cfg80211/parameters/monitor_any_chan`, and a plain
reboot is a full recovery.

## Build

Two facts make this cheap on this box:

- `CONFIG_MODVERSIONS` is **off** — no symbol CRCs, so a rebuilt module only
  needs a matching vermagic string.
- `CONFIG_MODULE_SIG_FORCE` is **off** — unsigned modules load (taint only).

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

**Never build this directory twice without cleaning.** The obvious sequence —
run `make M=net/wireless`, watch modpost fail on unresolved symbols, re-run it
with `KBUILD_MODPOST_WARN=1` — produces a module that builds cleanly, passes
`modinfo`, matches vermagic, and then dies at `insmod` with:

```
Invalid module format
module: x86/modules: Invalid relocation target, existing value is nonzero for type 1
```

Type 1 is `R_X86_64_64`: the second pass incrementally re-links `cfg80211.o`
into itself and applies the relocations twice. The tell is that a correct build
prints `LD [M] cfg80211.o` *and* `LD [M] cfg80211.ko`; the bad one only prints
the latter, because it reused the stale object.

`strip --strip-debug` is cosmetic but worth it: `olddefconfig` re-enables
`CONFIG_DEBUG_INFO` through a `select` even after `scripts/config --disable`,
giving a 25 MB module. Stripped it is 2.7 MB, against 3.08 MB for stock.

`KBUILD_MODPOST_WARN=1` is required and is safe **only because MODVERSIONS is
off**: there is no `Module.symvers` from a vmlinux build, so modpost cannot
resolve kernel symbols and errors out. Those symbols are resolved by the module
loader at insert time instead.

Confirm before loading:

```sh
modinfo net/wireless/cfg80211.ko | grep -E 'vermagic|monitor_any_chan'
```

## Load

Requires tearing down the whole 802.11 stack, which **drops the network link**.
Nothing is written to `/lib/modules`, so rebooting fully restores the stock
stack.

```sh
sudo ./scripts/reload-cfg80211.sh
```

The script unloads mt7921e → mac80211 → cfg80211, inserts the patched module
with `monitor_any_chan=1`, reloads the rest, and **rolls back to the stock
modules automatically** if the link has not returned within 45 s. Log:
`/tmp/cfg80211-reload.log`.

## Test

With `wlp2s0` associated on 36:

```sh
sudo iw phy phy0 interface add mon0 type monitor
sudo ip link set mon0 up
sudo iw dev mon0 set freq 5745        # ch149; EBUSY before the patch
iw dev wlp2s0 link                    # DID THE ASSOCIATION SURVIVE?
iw dev mon0 info                      # did the channel actually change?
```

Three outcomes, and the middle one is the trap:

| result | meaning |
|---|---|
| `set freq` succeeds, association drops | one PHY, as feared. Patch is a footgun; stop. |
| `set freq` succeeds, association holds, **no ch149 frames captured** | the silent no-op. Chanctx accepted and ignored. Needs driver work in `mt7921_change_chanctx`, or is impossible. |
| `set freq` succeeds, association holds, **ch149 frames arrive** | the firmware sniffer context is real. Single-chip AirDrop works. |

Only a radiotap capture distinguishes the last two. Do not trust `iw dev mon0
info` alone — it reports what the kernel believes, which is exactly what is in
question.

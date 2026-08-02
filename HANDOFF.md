# Handoff — session of 2026-08-02

Read this first, then `README.md` for the detail. Companion userspace project is
`/mnt/shared/projects/airdrop-mt7921` (FINDINGS §43, §44, §45).

## The question

Make a **single MT7921** do Wi-Fi and AirDrop/AWDL at the same time, with no
second radio and no router configuration. AirDrop must watch a social channel
(6/44/149) chosen by the *phone*, while the station stays associated to an AP on
an unrelated channel.

## What was settled tonight

**Monitor-mode route: closed. Verified, not inferred.**

Three kernel gates block it. Each was found, patched, and confirmed by ftrace to
execute. Each one **fails by succeeding** — returns 0, logs nothing — which is
why this took four rounds of patch-and-measure rather than one reading of the
source.

| # | layer | gate | patch |
|---|---|---|---|
| 1 | cfg80211 | `cfg80211_has_monitors_only()` (`net/wireless/chan.c:1550`) | 0001, `monitor_any_chan` |
| 2 | mac80211 | virtual monitor created only when `open_count == 0` (`net/mac80211/iface.c:1403`) | 0003, `monitor_concurrent` |
| 3 | mt7921 | `mt7921_mcu_config_sniffer()` reachable only from `->change_chanctx`, never for a newly created chanctx | 0002, call it from `->assign_vif_chanctx` |

With all three loaded, ftrace shows the complete chain running down to
`mt7921_mcu_config_sniffer <-mt7921_assign_vif_chanctx`, and
`MCU_UNI_CMD(SNIFFER)` **returns success**.

**The radio does not move.** Associated on ch2 (2417 MHz), monitor requested on
ch149 (5745 MHz): **593 of 593 captured frames were 2417 MHz, zero on 5745**,
association intact at 0% packet loss throughout.

## Why — and this is the useful part

Firmware analysis (`/lib/firmware/mediatek/WIFI_RAM_CODE_MT7961_1.bin.zst`,
792 KB decompressed):

- **Not encrypted.** Debug strings, format strings and MediaTek's internal build
  paths are all readable, e.g.
  `build/csp/7961/asic2.0/projects/wifi_mobile_ram_ccn16/.../hal_cal_flow.c`.
- **It is RAM code, re-uploaded from disk at every boot.** Nothing is flashed,
  so a bad firmware patch **cannot brick the card** — the driver just fails to
  init, and restoring the file fixes it.
- Trailer is `____010000` + build date `20260224110949` + a 4-byte CRC
  (`8a a4 75 57`), matching what the driver prints at probe. A CRC, not
  obviously a cryptographic signature. Whether the ROM enforces a signature is
  **untested**.
- It contains a **channel manager with time-slicing**:
  `CnmFastChReqQuotaInUs`, `CnmGOAbsenceMarginInUs`, `EnCnmDoubleWFDCHtime`,
  `EnCnmSyncTBTT`, `fgCnmForceEarlyAbortCH`. Quota, absence margin, TBTT sync,
  early channel abort. The `GO`/`WFD` naming ties it to P2P Group Owner and
  Wi-Fi Direct — exactly the driver's advertised
  `#{managed} + #{P2P-GO}, #channels <= 2`.
- It contains **zero sniffer strings**.

So the conclusion is sharper than "the chip can't do two channels". **The chip
can — the sniffer just isn't a client of the scheduler that does it.** The
capability exists; monitor mode cannot reach it.

Also present, and worth not misreading: `DBDC band :%d not support in MT7961`.
That rules out two *bands* simultaneously (needs two RF chains). It does not
rule out CNM time-slicing two channels on one chain, which is the thing we want.

## Next thing to try (not started)

Get AWDL onto a vif type **CNM will schedule** — a P2P-GO — rather than a
monitor vif. No firmware work, no reverse engineering.

**Experiment:** bring up a P2P-GO on ch149 while associated on ch36, and confirm
by capture that both channels are genuinely serviced.

- Needs `hostapd`, or a `wpa_supplicant` rebuilt with P2P. **This box's
  `wpa_supplicant` has no P2P compiled in** — `p2p_group_add` is absent from the
  daemon and present only in `wpa_cli`. `xbps-install` is already NOPASSWD here.
- If both channels are serviced, there is a real path. If not, the whole
  approach is closed and firmware editing would not have rescued it either.

**Honest caveat, do not skip:** even if CNM services ch149, OWL still needs raw
injection and reception there, and a monitor vif would still follow the sniffer
channel — which is the thing we just proved is tied to the BSS. Whether that gap
is bridgeable is a *second* unknown. This is maybe-promising, not likely.

I earlier proposed this experiment, then cancelled it on the grounds that the
interface-combination table is not consulted for monitor vifs. That is true but
turned out to be beside the point: it is the *sniffer* that is unwired, not the
combination table that is blocking. The experiment is back on.

## Firmware editing verdict

Possible in principle — unencrypted, analyzable, and not a bricking risk. But it
is months of reverse-engineering a stripped ~792 KB binary for an undocumented
MCU with no symbols. **Wrong target.** The CNM finding above is the cheaper
route to the same goal.

## State of the machine

Left **clean**. Verified at end of session:

- Stock `cfg80211` / `mac80211` / `mt7921e` loaded; patched module parameters
  absent from `/sys/module/*/parameters/`.
- No leftover monitor vifs; only `wlp2s0`, type managed.
- ftrace reset to `nop`, filter cleared, `tracing_on=0`.
- Associated, `192.168.68.62`, 0% packet loss.
- **Nothing was ever written to `/lib/modules`**, so a reboot is a full reset
  regardless.

`tracefs` was mounted at `/sys/kernel/tracing` during the session (it was not
mounted by default on this box; `debugfs` was). Harmless, and gone on reboot.

## Where things live

| what | where |
|---|---|
| Kernel patches, scripts, analysis | `/mnt/shared/projects/mt7921-awdl-kernel` (committed, **no GitHub remote — deliberately local**) |
| Userspace AirDrop stack | `/mnt/shared/projects/airdrop-mt7921` (committed and pushed) |
| Kernel source tree, built modules | `/mnt/shared/kernel/linux-6.18.33` — **2.3 GB**, safe to delete, README documents the rebuild |

`/` is at **95%** (2.6 GB free). Keep all kernel work on `/mnt/shared`.

## Traps already paid for — do not re-learn these

1. **Vermagic matching is necessary, not sufficient.** With `CONFIG_MODVERSIONS`
   off there are no symbol CRCs, and *nothing* checks that your config matches
   the running kernel. Disabling `CONFIG_DEBUG_INFO_BTF_MODULES` removes 4
   fields from `struct module` (`module.h:511`); `init` is at :458 (before the
   block) and `exit` at :572 (after), so `exit`'s relocation lands 24 bytes
   early in a field the loader already wrote →
   `Invalid module format` / `Invalid relocation target ... nonzero for type 1`,
   for **every** module built that way. **Build with `/proc/config.gz`
   verbatim.** `pahole` is installed; module BTF skips itself when `vmlinux` is
   absent.
2. **Test module loading with `crypto/michael_mic.ko`,** not the Wi-Fi stack. It
   reproduces load failures at zero cost instead of dropping your network.
3. **Never build `M=<dir>` twice without `make M=<dir> clean`** — the second
   pass re-links incrementally and double-applies relocations.
4. **The phy renumbers on driver reload** (`phy0` → `phy1`). Always re-read it:
   `PHY=$(iw phy | grep -oP '^Wiphy \K.*' | head -1)`.
5. **`iw dev mon0 info` reports what the kernel believes,** which is precisely
   what is in question. Only a radiotap capture is evidence. Use ftrace to
   confirm a code path actually ran before trusting any "success".
6. The reload scripts were **blocked by the Claude Code permission classifier**
   until the user granted permission explicitly. They all auto-roll-back to the
   stock stack if the link does not return within 45 s.

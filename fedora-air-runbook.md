# fedora-air — Linux enablement runbook

Everything done to get Fedora running on this MacBook Air, why each piece exists, and how to
undo it. Written 2026-09-17, last updated 2026-09-24.

Lives in the `fedora-air` repo alongside every file it describes; see [README.md](README.md)
for the layout and [`install.sh`](install.sh) for putting the files in place.

This machine needs a handful of local, unpackaged workarounds to be usable. None of them are
shipped by any package, so nothing will recreate them after a reinstall and nothing will warn
you if one breaks. That is what this document is for.

**It is written to be handed to a person — or an agent — doing this again on the same hardware
after a fresh Fedora install.** Each section gives the reason the workaround exists, the exact
commands that create it, what correct output looks like, and how to undo it. Nothing here should
need to be inferred.

Suggested order on a fresh install:

1. **§3 Wifi** first — everything else wants the network. Note the `wl` driver's limits before
   choosing an SSID to connect to.
2. **§4 Camera**, which is self-contained and the longest procedure.
3. **§5 Suspend/resume**, in particular `lid-wake-guard` (idle sleep is broken without it) and
   the `facetimehd` sleep hook (install it before trusting suspend).
4. **§7** for the printer and the small stuff, **§6** only if a resume ever hangs.
5. **§9 Health check** to confirm the result, and again after every kernel upgrade.

§11 lists what has never been verified, so nothing in here reads as more settled than it is.

> Sanitized for publication: network names, printer identifiers, usernames and home-directory
> paths are placeholders in angle brackets. The commands for recovering the real values on a
> running system are given where each one appears.

---

## 1. The machine

| | |
|---|---|
| Model | Apple MacBookAir7,2 (13", early 2015), BIOS 489.0.0.0.0 |
| CPU / GPU | Broadwell-U i5 @ 1.6 GHz, HD Graphics 6000 |
| OS | Fedora Linux 44 (KDE Plasma Desktop Edition), installed 2026-09-16 |
| Kernel | 7.2.5-200.fc44.x86_64 (6.19.10-300 also installed) |
| Root | btrfs, subvol=root, on Samsung Apple-slot AHCI SSD |
| Wifi | Internal: Broadcom BCM4360 `14e4:43a0`, proprietary `wl`. Added 2026-09-26: Realtek RTL8821CU USB dongle `0bda:c811`, in-kernel `rtw88_8821cu`, now the primary link |
| Camera | Broadcom 1570 FaceTime HD `14e4:1570` — out-of-tree `facetimehd` |
| Input | USB keyboard/trackpad (`bcm5974` + `hid_apple`), **not** SPI |
| Battery | iFixit replacement, 100% of design (53.2 Wh) |

Two out-of-tree modules are loaded at all times, so the kernel is permanently tainted
`P` (proprietary), `O` (out-of-tree), `E` (unsigned). Expect no upstream sympathy for bug
reports taken from this machine.

---

## 2. Timeline

| When | What | By |
|---|---|---|
| 2026-09-16 17:20 | Fedora 44 KDE installed | user |
| 2026-09-16 20:53 | FaceTime HD firmware extracted to `/lib/firmware/facetimehd/` | user |
| 2026-09-16 21:26 | RPMFusion free + nonfree enabled; `akmod-wl` installed | user |
| 2026-09-16 21:28 | `kmod-wl` force-installed (`--nogpgcheck --disablerepo`) | user |
| 2026-09-17 00:43 | `git gcc make kernel-devel` installed; facetimehd built from source | user |
| 2026-09-17 12:22 | `dkms` installed, facetimehd registered with DKMS | user |
| 2026-09-17 12:26 | `acpica-tools` installed (ACPI/DSDT inspection) | user |
| 2026-09-17 ~15:59 | Three `wl` workarounds installed (sleep hook, profile watcher, PMF default) | agent session |
| 2026-09-17 16:16 | Suspend on lid close — **never finished resuming**, hard power-cycled 20:14 | — |
| 2026-09-17 20:27–20:55 | Resume-hang diagnosis; pm_trace instrumentation; facetimehd sleep hook; applespi blacklist | agent session |
| 2026-09-17 21:01 | Network laser printer added to CUPS as a driverless queue | agent session |
| 2026-09-18 15:45 | Retracted a bogus ~10 mW suspend-drain figure; added `battery-drain-log` to measure it properly | agent session |
| 2026-09-18 19:10 | **pm_trace disarmed** (now toggled by `/etc/pm-trace.enabled`); printer, dock and trackpad notes | agent session |
| 2026-09-24 19:11 | Idle sleep diagnosed as waking itself after 6 s with the lid open; `lid-wake-guard` hook added | agent session |
| 2026-09-24 19:20 | Runbook moved to the desktop user's home dir, sanitized for publication, open threads (§11) collected | agent session |
| 2026-09-24 19:30 | §4 rewritten as a reproducible build/install procedure; intro states the reuse goal | agent session |
| 2026-09-24 19:40 | Runbook and all local files collected into the `fedora-air` git repo with `install.sh` | agent session |
| 2026-09-24 20:27 | `wl-fix-wifi-profiles` verified end to end; printer duplex default set; `battery-drain-log` now labels charging cycles; §3/§7 rewritten as procedures; `check-drift.sh` added | agent session |
| 2026-09-26 11:20 | RTL8821CU USB dongle added: WPA3/SAE profile, power save off, made primary; all wifi profiles bound to their interfaces after they swapped devices across a suspend | agent session |

---

## 3. Wifi — Broadcom BCM4360 (`14e4:43a0`)

The card needs Broadcom's proprietary `wl` driver: unmaintained, hostile to suspend, incapable of
WPA3, and it weakens the kernel's Spectre mitigations. Everything in this section exists to work
around one of those four facts. **Do this first on a fresh install** — the camera build and
everything else wants a network.

What a finished installation looks like:

| Piece | What |
|---|---|
| RPMFusion free + nonfree | the repos `wl` comes from |
| `akmod-wl` + `broadcom-wl` | driver source and the blacklist for the in-tree drivers |
| `kmod-wl-<kernel>` | the built module, from akmods |
| `/lib/modules/<kernel>/extra/wl/wl.ko.xz` | where it lands |
| `wlp3s0` | the interface |
| three local workarounds | sleep hook, profile watcher, PMF default — see below |

### Why three extra workarounds exist

The `wl` driver is unmaintained and has three defects that matter here:

1. **It does not survive S3 suspend.** After resume it associates but authentication times
   out.
2. **It cannot do WPA3/SAE or PMF (802.11w)** at all.
3. **It is incompatible with kernel security mitigations.** The kernel says so on every boot:

   > You are using the Broadcom STA wireless driver, which is not maintained and is
   > incompatible with Linux kernel security mitigations. It is heavily recommended to
   > replace the hardware and remove the driver. Proceed at your own risk!

   and follows it with `WARNING: Unpatched return thunk in use. This should not happen!`
   — the module isn't built with return thunks, which weakens Spectre/retbleed mitigations
   system-wide.

### Prerequisites

```sh
lspci -nn | grep 14e4:43a0        # confirm the card
sudo dnf install -y gcc kernel-devel     # akmods needs these to build the module
```

You need a temporary network to install from: USB tethering from a phone, a USB ethernet adapter,
or a USB wifi adapter. There is no way to install the driver over the wifi it provides.

### Install

**1. Enable RPMFusion** (free and nonfree — `wl` is in nonfree, which depends on free):

```sh
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
```

**2. Install the driver.** `akmod-wl` builds the module locally against the running kernel;
`broadcom-wl` is the common package that ships
`/usr/lib/modprobe.d/broadcom-wl-blacklist.conf`, which blacklists `ssb`, `bcma`, `b43`,
`brcmsmac` and `brcmfmac` so they cannot claim the card first. **Don't remove that file.**

```sh
sudo dnf install -y akmod-wl broadcom-wl
sudo akmods --force            # build now rather than waiting for the next boot
sudo modprobe wl
```

The build produces `kmod-wl-<kernel-version>`, which is what actually provides `wl.ko`. On this
machine that package was force-installed by hand early on
(`dnf install --nogpgcheck --disablerepo=...`) before `akmods` had run; that is a workaround for
an impatient install, not a requirement — `akmods --force` is the normal path.

**3. Install the three local workarounds** — the sleep hook, the profile watcher and the PMF
default, all described below. From the repo: `sudo ./install.sh`.

### Verify

```sh
modinfo wl | grep -E 'filename|license'   # extra/wl/wl.ko.xz, MIXED/Proprietary
lsmod | grep '^wl'
nmcli device                              # expect wlp3s0, wifi, disconnected or connected
rfkill list wifi                          # must not be blocked
nmcli device wifi list | head             # scanning works
```

Expect these in the journal, on every boot, all of them normal for this driver:

```
wl: module license 'MIXED/Proprietary' taints kernel.
Disabling lock debugging due to kernel taint
You are using the Broadcom STA wireless driver, which is not maintained and is
  incompatible with Linux kernel security mitigations. ...
Unpatched return thunk in use. This should not happen!
```

If `nmcli device` shows no wifi device, the usual cause is that an in-tree driver won the race:
check `lsmod | grep -E 'b43|bcma|ssb|brcm'` and confirm the blacklist file is present.

### Connecting

The home network is a WPA2/WPA3 *transition* SSID on 5 GHz, with a separate 2.4 GHz SSID.
Because plasma-nm would have saved it as SAE, the profile was created by hand:

```sh
nmcli connection add type wifi con-name <ssid> ssid <ssid> \
    wifi-sec.key-mgmt wpa-psk wifi-sec.pmf disable wifi-sec.psk '<passphrase>'
```

(`nmcli -f NAME,TYPE connection show` lists what exists now.)

### On kernel upgrades

`akmod-wl` rebuilds `wl` when a new kernel is installed, through `akmods.service`, provided
`gcc` and a matching `kernel-devel` are present. **A kernel that boots fine can have no wifi**, so
verify rather than assume:

```sh
modinfo wl | grep filename       # must name the running kernel's directory
sudo akmods --force              # if it doesn't; then reboot or modprobe wl
journalctl -u akmods -b          # build log when that fails
```

### `/usr/lib/systemd/system-sleep/wl-reload`

Unloads `wl` before suspend, reloads it after, then **restarts `wpa_supplicant`**.

The supplicant restart is the non-obvious part and it is essential. Without it the supplicant
stays bound to the interface that vanished, falls back to the old `wext` driver, and every
scan fails with `ioctl[SIOCSIWSCAN]: Inappropriate ioctl for device` — no networks listed at
all, which looks like a much scarier problem than it is.

Verified working: on a good cycle this completes in ~540 ms (reload → interface rename →
supplicant restart → thaw).

### `/usr/local/sbin/wl-fix-wifi-profiles` + `.path` / `.service` in `/etc/systemd/system/`

plasma-nm saves SAE (WPA3) profiles for WPA2/WPA3 *transition* networks. Those profiles then
never connect, with no useful error. The path unit watches
`/etc/NetworkManager/system-connections` and rewrites any SAE profile to `wpa-psk` with PMF
disabled, then bounces the connection if it's mid-activation.

It deliberately no-ops if any wifi device is present that is **not** on `wl`, so plugging in a
decent adapter doesn't silently strip WPA3 from it.

Enabled via `wl-fix-wifi-profiles.path`. **Verified end to end 2026-09-24:** adding a throwaway
SAE profile triggered the path unit, the service rewrote it to `wpa-psk` with PMF disabled within
a second and logged `switched 'zz-sae-test' from WPA3 (SAE) to WPA2-PSK` via `logger`, and the
real profile and live connection were untouched. To repeat the test:

```sh
sudo nmcli connection add type wifi con-name zz-sae-test ssid ZZ-SAE-TEST \
    wifi-sec.key-mgmt sae wifi-sec.psk 'testtest123' autoconnect no
nmcli -g 802-11-wireless-security.key-mgmt connection show zz-sae-test   # -> wpa-psk
journalctl -t wl-fix-wifi-profiles -n 3
sudo nmcli connection delete zz-sae-test
```

### `/etc/NetworkManager/conf.d/91-wl-no-pmf.conf`

Defaults `wifi-sec.pmf=1` (disable) for `match-device=driver:wl`, so new profiles don't get
created with PMF on in the first place.

### Known limits

A **WPA3-only** network still cannot work on this card. No workaround exists.

### Upgrading to a USB adapter

Everything above exists because the internal card needs `wl`. A USB adapter with an in-kernel
driver removes the reason for all of it: no RPMFusion, no akmods rebuild per kernel, real
WPA3/SAE, and no tainted kernel or mitigation hole. **The internal card cannot be replaced** — it
is an Apple-proprietary module, not M.2 — so a dongle is the only hardware route.

Keep the `wl` setup working anyway. A dongle you forgot to pack is a machine with no network, and
`wl` is the fallback if the adapter dies. This model has no ethernet port to recover through.

**What to buy.** Buy on *chipset*, not model name:

| Chipset | Driver | Notes |
|---|---|---|
| **MediaTek MT7921AU** (`0e8d:7961`) | `mt7921u`, in-kernel since 5.18 | First choice: 2x2 802.11ax, USB 3.0. The Fenvi FU-AX1800 is a known-good example (`morrownr/USB-WiFi` lists it). **Unmeasured here** — see below. |
| **Realtek RTL8821CU** (`0bda:c811`) | `rtw88_8821cu`, in-kernel | In use here since 2026-09-26. Works with zero configuration, does real SAE, survives suspend — but 1x1 802.11ac on USB 2.0, and slower than the internal card. |
| Realtek RTL8852BU | out-of-tree DKMS | **Avoid.** Puts you straight back where `wl` has you. |

That last row is not theoretical: Fenvi ships AX-1800 units with *either* the MT7921AU or the
RTL8852BU under the same model name. Require the listing to name the chipset, and if what arrives
needs a driver disc or a GitHub repo, send it back.

**Measured, RTL8821CU vs the internal card.** Each interface alone (the other disconnected), four
50 MB downloads from the same server, same AP, 5 GHz, after DHCP settled:

| Interface | Signal | PHY rate | Throughput | Latency (avg / jitter) |
|---|---|---|---|---|
| Internal BCM4360, `wl` | −53…−57 dBm | 526 Mbit/s | **~200 Mbit/s** | 17.4 ms / 3.8 ms |
| RTL8821CU dongle | −58 dBm | 390 Mbit/s | **~75 Mbit/s** | 18.5 ms / 1.9 ms *(power save off)* |
| RTL8821CU dongle | −58 dBm | 390 Mbit/s | ~75 Mbit/s | 40.7 ms / 35.3 ms *(power save **on**, the default)* |

Two things follow, and both matter more than the headline number:

1. **Disable power save on the dongle or the link feels bad.** With the default on, latency
   averaged 40 ms with 35 ms of jitter and 104 ms spikes — visible on calls and over SSH. Off, it
   matches the internal card. Set it per-profile: `802-11-wireless.powersave 2`. It costs battery,
   since the radio stops idling.
2. **Throughput is driver-bound, not signal-bound, and cannot be tuned.** 390 Mbit/s of PHY
   delivering 75 Mbit/s is about 20% efficiency where 50–60% is normal. Ruled out on this machine:
   RF (−58 dBm, MCS 9), CPU (16% busy across four cores during a transfer), and the USB bus.
   Neither `iw set power_save off` (55–77 Mbit/s) nor `rtw88_core.disable_lps_deep=1` (52–61) moved
   it. Don't spend an evening on it.

**Would an MT7921AU do better? Probably substantially, but this is inference, not measurement.**
It is 2x2 ax rather than 1x1 ac, a USB 3.0 device rather than 2.0, and `mt76` is the better-regarded
driver — the 20% efficiency above is a `rtw88_usb` characteristic. Against that: this machine's USB 3
ports hang off the same Falcon Ridge complex that already mishandles Thunderbolt power management
(§7), so USB 3 throughput here is not a given.

**Whether ~75 Mbit/s matters** depends on what you do. It saturates 4K streaming several times over
and is invisible for browsing, SSH and normal work. It is noticeable pulling large files off a LAN
server (~9 MB/s instead of ~25) and on multi-hundred-MB `dnf` upgrades.

**Setting one up.** The adapter should appear with no configuration:

```sh
lsusb                                  # find its USB ID
ls -l /sys/class/net/*/device/driver   # which driver bound, per interface
iw phy | grep -i "supports SAE"        # real WPA3 -- wl can never print this
nmcli device status                    # the new interface, 'disconnected'
```

Give it its own profile using SAE rather than the WPA2 downgrade `wl` forces. A lower route metric
makes it the preferred path while both are connected:

```sh
sudo nmcli connection add type wifi con-name '<ssid>-usb' ifname <iface> ssid '<ssid>' \
    wifi-sec.key-mgmt sae wifi-sec.psk '<passphrase>' \
    802-11-wireless.powersave 2 \
    ipv4.route-metric 50 ipv6.route-metric 50
sudo nmcli connection up '<ssid>-usb'
```

> **Bind every wifi profile to its interface, including the old `wl` ones:**
> ```sh
> sudo nmcli connection modify '<ssid>' connection.interface-name <wl-iface>
> ```
> **This is not optional, and the failure is nasty.** A profile created without `ifname` is not
> tied to a device, so when `wl-reload` unloads `wl` during a suspend, NetworkManager re-activates
> that profile on whichever wifi device is still there — the dongle. Observed on the first suspend
> after plugging one in: the dongle came back running the `wl` profile, i.e. **WPA2 with PMF
> disabled instead of WPA3**, at the profile's default route metric, so the deliberate "make the
> dongle primary" setting was silently undone. The internal card meanwhile fell back to the 2.4 GHz
> profile. Binding both sides fixed it, verified across a further suspend.

Verify:

```sh
nmcli -t -f DEVICE,STATE,CONNECTION device status   # each profile on its own device
nmcli -g 802-11-wireless-security.key-mgmt connection show --active '<ssid>-usb'   # sae
iw dev <iface> link                                # SSID, freq, VHT/HE bitrate
iw dev <iface> get power_save                      # off
ip route show default                              # dongle's route has the lower metric
```

> A route metric of `20050` rather than `50` right after activation is NetworkManager's +20000
> penalty for a device whose per-device connectivity check has not passed yet. It clears within
> seconds. Re-check before concluding the metric didn't take.

**Suspend.** `rtw88_8821cu` survives S3 on this machine: across two cycles of 123 s and 92 s the
dongle re-associated on its own with no hook, no module reload and working routing — unlike `wl`,
which needs §3's sleep hook. It is not in any sleep hook and does not appear to need one.

**Retiring `wl` altogether** is the end state a dongle buys: it removes the sleep hook, the profile
watcher, the PMF default and the mitigation hole in one step. Commands are in §10 — read the
warning there first. Without `wl` there is no wifi at all when the dongle is absent.

### Removal

Only after a replacement adapter works — you will otherwise have no network. See §10.

---

## 4. Camera — FaceTime HD (Broadcom 1570)

There is no package for this camera, on any distribution. It needs an out-of-tree driver plus a
firmware blob extracted from Apple's own macOS driver, and both have to be rebuilt or reinstalled
by hand. This section is written so it can be followed start to finish on a fresh install.

What a finished installation looks like:

| Path | What |
|---|---|
| `/usr/src/facetimehd-0.7.0.1/` | driver source DKMS builds from |
| `/lib/modules/<kernel>/extra/facetimehd.ko.xz` | the built module |
| `/lib/firmware/facetimehd/firmware.bin` | 1.4 MB firmware, plus eleven `*_01XX.dat` sensor sets |
| `/etc/modules-load.d/facetimehd.conf` | contains `facetimehd`, loads it at boot |
| `/etc/modprobe.d/bdc_pci.conf` | `blacklist bdc_pci`, written by DKMS from `dkms.conf` |
| `/dev/video0` | the result |

### Upstream

| | |
|---|---|
| Driver | https://github.com/patjak/facetimehd |
| Firmware extractor | https://github.com/patjak/facetimehd-firmware |
| Wiki, incl. installation notes | https://github.com/patjak/bcwc_pcie/wiki |

Checked out here: driver `c5c7fac` (`0.7.2-10`), firmware tooling `60ee212` (`v1.0.0-3`). Both
trees live in the desktop user's home directory (`~/facetimehd`, `~/facetimehd-firmware`); only
the copy under `/usr/src` matters at runtime, so the checkouts can live anywhere.

### Why two repositories

The driver is GPL source that compiles against the running kernel. The firmware is Apple's and
cannot be redistributed, so the second repo fetches it at build time: its `Makefile` issues HTTP
range requests against Apple's CDN for a few slices of a macOS 10.12.6 update image, decompresses
those chunks, cuts `AppleCameraInterface` and `AppleCameraAssistant` out of them, then
`extract-firmware.sh` locates the firmware inside the driver and **verifies it by sha256** against
a table of known-good hashes. Nothing proprietary is committed to the repo; it is downloaded from
Apple each time.

`FW_VER=5.60.0` (macOS 10.12.6) is the default and the one in use here: it also supports the
12-inch MacBook and ships all eleven sensor-set files. `make FW_VER=1.43.0` gets the older OS X
10.11.5 firmware with no sensor sets — no reason to prefer it on this machine.

### Prerequisites

```sh
lspci -nn | grep 14e4:1570      # confirm the hardware: should print the 720p FaceTime HD Camera
sudo dnf install -y dkms gcc make kernel-devel git curl xz
```

`kernel-devel` must match the running kernel; `dnf` keeps matching versions as kernels update,
which is what makes the DKMS rebuild work later. Network access is required for the firmware step.

**Secure Boot:** off on this machine (`mokutil --sb-state` says the system doesn't support it), so
nothing needs signing. With Secure Boot enabled, DKMS signs modules with a key it generates at
`/var/lib/dkms/mok.pub` and that key must be enrolled with `mokutil --import` before the module
will load.

### Build and install

**1. Firmware.** Downloads ~13 MB of ranges from Apple, verifies, installs:

```sh
git clone https://github.com/patjak/facetimehd-firmware.git
cd facetimehd-firmware
make                    # prints the driver it recognised, then extracts firmware.bin
sudo make install       # -> /lib/firmware/facetimehd/
```

`make clean` removes the downloaded blobs and extracted files if you want to start over. The
firmware is not tied to a kernel version, so this step is done once and survives every upgrade.

**2. Driver, registered with DKMS.** The version in the path *must* match `PACKAGE_VERSION` in the
repo's `dkms.conf` (`0.7.0.1` at `c5c7fac`) — check it before copying:

```sh
git clone https://github.com/patjak/facetimehd.git
cd facetimehd
grep PACKAGE_VERSION dkms.conf                                   # -> 0.7.0.1
sudo mkdir -p /usr/src/facetimehd-0.7.0.1
git archive HEAD | sudo tar -x -C /usr/src/facetimehd-0.7.0.1    # source only, no .git, no build junk
sudo dkms add -m facetimehd -v 0.7.0.1
sudo dkms install -m facetimehd -v 0.7.0.1
```

`git archive` rather than `cp -r` on purpose: DKMS copies whatever it is given into its own tree,
and stale `.o`/`.ko` files from an earlier manual build cause confusing rebuild failures.

DKMS prints `Deprecated feature: CLEAN` and `Deprecated feature: MODULES_CONF` — both are the
repo's `dkms.conf`, both are harmless. `MODULES_CONF` is what writes
`/etc/modprobe.d/bdc_pci.conf`; `bdc_pci` is a stub driver that claims the same PCI ID and must
stay blacklisted or it wins the race and the camera never appears.

**3. Load it at boot.** The module is not auto-loaded by any udev rule:

```sh
echo facetimehd | sudo tee /etc/modules-load.d/facetimehd.conf
sudo modprobe facetimehd
```

**4. Take it out of the resume path** — see the sleep hook below. Do this before trusting suspend:
this driver is the most fragile thing in the resume sequence on this machine.

### Verify

```sh
dkms status                                   # facetimehd/0.7.0.1, <kernel>, x86_64: installed
modinfo facetimehd | grep -E 'filename|firmware'
grep -c '^facetimehd ' /proc/modules          # expect: 1
ls -l /dev/video0                             # expect: crw-rw----+ root video
journalctl -k -b | grep -i facetimehd
```

A healthy bring-up logs, in order: `Found FaceTime HD camera with device id: 1570`,
`S2 PCIe link init succeeded`, `PLL reset finished`, `S2 PLL is locked`,
`DDR40 PHY PLL locked`, `STRAP valid`, the DDR40 VDL calibrations, and the firmware load. For an
end-to-end test, open any application that uses `/dev/video0`; `v4l-utils` is not installed here,
but `sudo dnf install v4l-utils` then `v4l2-ctl --list-devices` is the quickest headless check.

### On kernel upgrades

`AUTOINSTALL=yes` plus an installed `kernel-devel` means DKMS rebuilds the module when a new
kernel is installed, via `/usr/lib/kernel/install.d/40-dkms.install`, with `dkms.service` as a
boot-time fallback. **Verify rather than assume** — a kernel that boots fine can have no camera:

```sh
dkms status                                   # expect "installed" for the new kernel
# on failure:
cat /var/lib/dkms/facetimehd/0.7.0.1/<kernel>/x86_64/log/make.log
```

A build that breaks on a big kernel jump is usually a V4L2 API change; the fix is to pull upstream
and reinstall, as below.

### Updating the driver from upstream

```sh
cd ~/facetimehd && git pull
sudo dkms remove facetimehd/0.7.0.1 --all
sudo rm -rf /usr/src/facetimehd-0.7.0.1
sudo mkdir -p /usr/src/facetimehd-<new-version>
git archive HEAD | sudo tar -x -C /usr/src/facetimehd-<new-version>
sudo dkms install -m facetimehd -v <new-version>
```

Use the `PACKAGE_VERSION` from the pulled `dkms.conf` for `<new-version>`; if it hasn't changed,
reuse `0.7.0.1`.

### Quirks, all expected

- **`Direct firmware load for facetimehd/1871_01XX.dat failed with error -2`** on every boot,
  including healthy ones. The driver probes for a sensor set this machine doesn't have. Ignore it.
- **DKMS says `0.7.0.1`, git says `0.7.2-10`.** The repo's `dkms.conf` lags its own tags. Only one
  `.ko` exists on disk and DKMS builds from `/usr/src/facetimehd-0.7.0.1`. Cosmetic.
- **`dkms status` appends `(Original modules exist)`.** The first build here was installed by hand
  into `/lib/modules/<kernel>/updates/` before DKMS existed on the machine; DKMS archived it under
  `/var/lib/dkms/facetimehd/original_module` and would *restore that stale module* if anyone ran
  `dkms remove`. Harmless now, but `sudo rm -rf /var/lib/dkms/facetimehd/original_module` removes
  the trap. Not needed on a clean install that starts with DKMS.
- **Taint messages** — `loading out-of-tree module taints kernel` and `module verification failed`
  are normal for an unsigned out-of-tree module (§1).

### Suspend — `/usr/lib/systemd/system-sleep/facetimehd-reload` *(added 2026-09-17)*

Unloads `facetimehd` before suspend, reloads it after. This driver redoes a **full hardware
bring-up on every resume** — PCIe link init, PLL lock, DDR40 PHY calibration, 1.4 MB firmware
reload, then polls for the ISP to wake — which makes it the most fragile thing in the resume
path. Upstream ships this same workaround in its own installation docs.

Two deliberate design choices, both load-bearing:

- **The reload is detached** via `systemd-run --no-block`. Every post hook runs while
  `user.slice` is still frozen (see §5), and there are reports of `modprobe facetimehd`
  itself wedging machines. Detached, a stuck reload costs you the webcam, not the session.
- **It only reloads what it unloaded**, tracked via `/run/facetimehd-unloaded`. If something
  holds `/dev/video0` the unload fails harmlessly and we leave the module alone.

Verified on a real cycle: 47 ms unload, clean detached reload, `/dev/video0` back.


### Removal

```sh
sudo dkms remove facetimehd/0.7.0.1 --all
sudo rm -rf /usr/src/facetimehd-0.7.0.1 /var/lib/dkms/facetimehd
sudo rm -f /etc/modules-load.d/facetimehd.conf /etc/modprobe.d/bdc_pci.conf
sudo rm -rf /lib/firmware/facetimehd
sudo rm -f /usr/lib/systemd/system-sleep/facetimehd-reload
```

---

## 5. Suspend / resume

### The failure of 2026-09-17

Suspended 16:16:36 on lid close, from a 90-second-old boot sitting at the SDDM greeter. Woken
~20:12: screen lit, greeter visible, **clock frozen at 4:17pm, keyboard and mouse dead**.
Power-cycled at 20:14.

**The kernel never finished resuming.** It was not a frozen desktop. The evidence:

- That boot's journal file's last write is *exactly* the `PM: suspend entry (deep)` timestamp.
- **No file anywhere under `/var` was modified between 20:00 and 20:14:20.**

Since `/var` is btrfs with a 30-second commit interval and ~2 minutes elapsed, any
post-resume logging would have reached disk. journald never ran again. What was on screen was
the pre-suspend framebuffer, put back by i915 early in the resume sequence; nothing could
repaint it and nothing was reading input.

> **Reusable technique.** After any hard power-off, that `/var` mtime sweep answers "did
> userspace actually run?" far more reliably than reading the journal, which simply stops
> with no indication of why:
> ```
> find /var -xdev -newermt "<start>" ! -newermt "<end>" -printf '%T+ %p\n' | sort
> ```

### Why the sleep hooks were the obvious suspect, and why they're innocent

systemd freezes `user.slice` for the **entire** duration of `systemd-suspend.service`,
including the post-resume hooks. From `man systemd-sleep`:

> Note that by default these services freeze user.slice while they run. This prevents the
> execution of any process in any of the user sessions while the system is entering into and
> resuming from sleep.

So a hung post hook produces *exactly* these symptoms — frozen clock, dead input, live
display. It just isn't what happened here: hooks run after `PM: suspend exit` and would have
logged. But **this is why every post hook in this runbook is written to return in
milliseconds**, and why anything slow is detached. Do not add a blocking post hook.

### Resume hang — current status

Intermittent, not deterministic — five cycles succeeded earlier the same day, including one of
7h15m. Prime suspect is `facetimehd`, now removed from the resume path (§4). Not proven.

**Since the facetimehd fix (2026-09-18): no recurrence.** Clean cycles include 7.08 h, 9.46 h,
15.10 h and one of **119 h** (2026-09-19 → 2026-09-24), all far longer than the ~3.9 h suspend
that hung. Encouraging, not proof — five cycles succeeded before the failure too.

**If it recurs, there will be no evidence:** `pm_trace` is disarmed (§6). Re-arm it before a
trip or anything else where a dead machine would matter.

### Idle sleep woke itself after 6 seconds — the lid-open wake trap *(fixed 2026-09-24)*

**Symptom as reported:** "left the machine for a while and it did not sleep, the battery drained
from 74% to 13%." System Settings showed the stock *On Battery → When Inactive: Sleep, 10 min*
(stock is all it can be — there is no `powerdevilrc` at all, the profile has never been edited).

**What was actually happening:** Plasma suspended on schedule. The machine reached S3 and came
back **6–7 seconds later**, every time. That is indistinguishable from "it never slept" — you
return to the lock screen and the battery has drained at ~12 W the whole time. Such cycles also
leave almost no trace: they never reach `/var/log/suspend-drain.log`, which drops anything under
60 s, and `journalctl` shows `PM: suspend entry` and `exit` seconds apart only if you look for it.

**Cause.** `\_SB.LID0._PSW` arms lid wake by setting the EC's `EWLO` ("wake on lid open") bit on
the way down, and Linux calls it whenever LID0 is `*enabled` in `/proc/acpi/wakeup` — regardless
of where the lid actually is. With the lid already open, the wake condition is satisfied
immediately and the EC fires GPE 0x70 a few seconds later. LID0 and the EC **share GPE 0x70**
(both `_PRW` return `0x70`), so the kernel cannot distinguish this from someone opening the lid.
The giveaway in the counters: `/sys/class/wakeup` shows the EC and both `PNP0C0D` (lid) nodes
incrementing while USB `1-5` (keyboard/trackpad) does not move — nothing touched the machine.

Measured 2026-09-24:

| Lid at suspend | LID0 wake | Result |
|---|---|---|
| open (idle, battery) | enabled | woke after 7 s |
| open (idle, battery) | enabled | woke after 6 s |
| open (manual, AC) | enabled | woke after 6 s |
| open (manual, AC) | **disabled** | slept 88 s, until a key was pressed |
| open (manual, AC) | **disabled by the hook** | slept the full 122 s to an RTC alarm |
| closed | enabled | 23 min — and 119 h on 2026-09-19 |

So AC vs battery is irrelevant; lid position combined with LID0 arming is the whole story.

**Fix — `/usr/lib/systemd/system-sleep/lid-wake-guard`.** Pre hook: arm LID0 only when the lid is
genuinely closed, disable it otherwise. Post hook: restore `enabled`. `/proc/acpi/wakeup` is a
*toggle*, not a value, so the script reads the current state and writes only when it differs.

**The trade-off it accepts:** after an idle suspend with the lid open, lid wake is off for that
cycle, so closing the lid and reopening it will *not* wake the machine — press the power button.
Keyboard/trackpad wake (`XHC1`) stays armed, which is the behaviour you want with the lid open.
Lid-close suspends are untouched and still wake on lid open, which is why LID0 must **not** simply
be disabled permanently.

### The other reason it won't sleep: a browser tab playing audio

Chrome takes a PowerDevil inhibition (`/usr/bin/google-chrome-stable`) whenever a tab plays audio
or video. It blocks *sleep* while still allowing dim and screen-off, so the machine sits awake
with a dark screen — same visible outcome as the bug above, entirely different cause. Observed
live on 2026-09-24: the inhibition appeared while a tab played music and vanished when it stopped.

**`systemd-inhibit --list` does not show these** — they are session-level, so ask PowerDevil:

```sh
dbus-send --session --print-reply --dest=org.kde.Solid.PowerManagement.PolicyAgent \
  /org/kde/Solid/PowerManagement/PolicyAgent \
  org.kde.Solid.PowerManagement.PolicyAgent.ListInhibitions
```

Run it in the desktop user's own session. From a root shell, prefix it with
`sudo -u <user> XDG_RUNTIME_DIR=/run/user/$(id -u <user>)`.

Hovering the battery applet in the tray names the blocking application too.

### S3 suspend drain — ~5 mW, measured 2026-09-24

**Status: measured, provisionally ~5 mW.** Three cycles of very different lengths agree — which
is exactly what the discredited method below could never produce:

| Cycle | Slept | Charge lost | Implied |
|---|---|---|---|
| 2026-09-19 | 4.90 h | 4 mAh | 6.5 mW *(upper bound — below gauge resolution)* |
| 2026-09-19 | 15.10 h | 10 mAh | 5.3 mW *(upper bound — below gauge resolution)* |
| 2026-09-24 | **119.04 h** | 75 mAh | **4.7 mW** |

The 119-hour row is the one that counts: 75 mAh is well clear of the gauge's ~1 mAh resolution,
so it is a measurement rather than a bound, and it lands on the same figure as the two short
bounds either side of it. Five days suspended cost 75 mAh of a 7000 mAh pack.

**Unresolved:** Apple's ~30-day standby spec for this model implies ~75 mW, roughly 15× more
than this. Either the platform beats its spec in S3 or the gauge under-counts something. §11.

**Do not try to measure this from upower's history.** It cannot work, and it produces a
plausible-looking wrong answer. Three suspends, lined up against duration:

| Suspend | Gauge delta across upower's gap | Implied |
|---|---|---|
| 23 min | 0.196 pp | 276 mW |
| 7.08 h | 0.140 pp | 10.7 mW |
| 9.46 h | 0.168 pp | 9.6 mW |

**The delta does not scale with duration.** The 9.46-hour suspend lost *less* than the
23-minute one. Real drain over 24× the time would be ~24× the charge. What this actually
measures is a fixed ~0.17 pp offset, and dividing a constant by a growing denominator is the
whole reason the "implied power" slides from 276 mW to 9.6 mW.

The offset's source: chrony steps the clock ~15.6 s after every resume and upower samples every
~30 s, so its first post-resume sample lands **16–45 s after wake** — by which time the machine
has burned 0.08–0.35 pp *awake*. That window alone accounts for the entire delta. Two intervals
"agreeing" on ~10 mW is the artifact being reproducible, not evidence.

> A previous version of this runbook claimed ~10 mW and 225 days of standby from this method,
> and a later session retracted it. **The retraction was right even though the figure was close
> to what proper measurement later gave:** the method measured twenty seconds of wake-up, so its
> near-agreement was luck, not evidence. The per-cycle log below is what earned the number.

### S3 suspend drain — measuring it properly

`/usr/lib/systemd/system-sleep/battery-drain-log` now does this on every cycle, appending to
`/var/log/suspend-drain.log`. It fixes both flaws:

- reads raw `charge_now` (µAh) at the *instants* around the suspend, so the `post` read happens
  before awake drain accrues, rather than on a 30-second poll;
- recovers the suspend duration despite pm_trace having destroyed the RTC — see the comment in
  the script. The trick is that `CLOCK_MONOTONIC` excludes suspend time, so
  `slept = (wall_now - wall_pre) - (mono_now - mono_pre)`, i.e. total elapsed minus awake
  elapsed. That needs a corrected wall clock, so the arithmetic is deferred 90 s via
  `systemd-run --on-active=90` (detached — §5 applies, nothing may delay the thaw).

It flags its own readings: under ~20 mAh the gauge's ~1 mAh resolution and few-mA deadband make
the result an upper bound, not a measurement. Cycles shorter than 60 s are not logged at all —
this machine gets a lot of brief lid-close-and-reopens and they would bury the rows that matter.

**Short cycles say nothing; wait for a long one.** At the measured ~5 mW an hour costs ~1 mAh,
which is pure gauge noise, and a day costs ~15 mAh. The multi-day row that produced the figure
above arrived on 2026-09-24:

```
2026-09-24 15:56:15  slept=119.039h  drain=   75.0mAh (  555.2mWh)       4.7mW
```

**Cycles with the charger connected are now labelled rather than measured** *(fixed
2026-09-24)*: the script samples `/sys/class/power_supply/ADP1/online` at both ends and writes
`(charger connected -- not a drain measurement)` instead of a drain figure. Rows written before
that fix show absurd negatives such as `drain=-2713.0mAh … -26803.9mW`; read those as "it was
charging", not as data. Short cycles at a low state of charge also read high — one 23-minute row
claims 754 mW — and are still logged as-is.

If drain ever does climb into the hundreds of mW, start with
`journalctl -b 0 | grep -i 'PM: '` and the wakeup sources in `/proc/acpi/wakeup`.

Note this says nothing about the Thunderbolt issue below, which costs power only while
*awake*; in S3 the platform cuts the controller's power regardless.

---

## 6. Instrumentation and debugging techniques

The `pm_trace` machinery was installed 2026-09-17 because a resume hang leaves no journal
evidence by definition. See also the `/var` mtime sweep in §5, which establishes whether
userspace ran at all after a hard power-off.

### `/usr/lib/systemd/system-sleep/pm-trace` — **currently DISARMED**

> Armed only when `/etc/pm-trace.enabled` exists.
> `sudo touch /etc/pm-trace.enabled` to arm, `sudo rm -f /etc/pm-trace.enabled` to disarm.
>
> Disarmed 2026-09-18. The cost below is paid on *every* wake; the benefit only on a hang,
> which has not recurred in six cycles since facetimehd left the resume path — two of them
> longer than the ~3.9 h suspend that failed. Re-arm if it hangs again. Note pm_trace is the
> only tool that works for this: there is no pstore backend, a hang raises no panic so pstore
> would not help anyway, and the machine has no serial port.

Arms `/sys/power/pm_trace` and `/sys/power/pm_debug_messages` before each suspend. `pm_trace`
stores a hash of the last device-resume callback **in the RTC**, which survives the hard
power-cycle a hang forces.

It also writes `/var/lib/pm-trace-armed`. **That marker is the essential part.** The kernel
decodes the RTC into a `Magic number` line on *every single boot*, so those dmesg lines are
meaningless noise unless a resume actually failed. The marker is written before the suspend
(the kernel syncs filesystems on the way down, so it reaches disk) and removed on every
successful resume — if it survives to the next boot, the resume never completed.

### After a hang: `pm-trace-result`

```sh
sudo pm-trace-result
```

Reports the trace only when the marker survived. Expect two or three candidate `hash matches`
lines — the hash space is small, so some are false positives. Cross-check PCI addresses with
`lspci -s <addr>`.

### The clock side effect — and the fix that took two tries

`pm_trace` clobbers the RTC — and the RTC is the persistent clock `timekeeping_resume()` reads
to work out how long the machine slept. So **the system clock does not advance across a
suspend at all.** It is not a small error: a 9.46-hour overnight suspend came back with the
clock still reading the moment the lid closed, and chrony had to step it by 34,060 seconds.
The RTC itself was left reading `2004-04-20`.

> **Consequence, and it is a nasty one: journal timestamps across a suspend are unreliable.**
> Everything logged between resume and chrony's step is stamped hours in the past, so a
> 9-hour suspend can look like it lasted 5 seconds. This bit the author of this runbook.
>
> **How to read the journal across a suspend anyway:**
> ```sh
> journalctl -b 0 -o short-monotonic     # monotonic time cannot be distorted
> journalctl -b 0 | grep 'was stepped by'   # chrony's step == true sleep duration
> ```
> Note `CLOCK_MONOTONIC` does not advance during S3 either, so `uptime` reports *awake*
> time only. Use `/proc/uptime`'s second field or `CLOCK_BOOTTIME` for wall time.
>
> This is a real argument for disarming `pm_trace` once the resume hang is understood: it
> degrades exactly the evidence you would want for any *other* incident.

`/etc/chrony.conf` has `makestep 1.0 3`, which stops chronyd stepping after its first three
updates — so it slewed that 131s error at ~600ppm. Days, not minutes.

> **The trap:** a bare `chronyc makestep` in the post hook does **not** fix this. It steps
> using the offset chronyd holds *at that instant*, and at resume there is no network yet
> (`wl` is still reloading), so it is a silent no-op every time.

The hook now uses `chronyc makestep 0.1 5`, which re-arms stepping for the next 5 updates —
those land once wifi is back. It then launches `/usr/local/sbin/pm-trace-rtc-fix` detached,
which waits for the step and runs `hwclock --systohc`. chrony's `rtcsync` would get there
within 11 minutes anyway; this closes the window where a reboot in the meantime boots with a
2004 date (TLS and `dnf` failures until chrony catches up).

No conflict with the trace itself: `pm_trace` writes its hash during *suspend*, so after a
hang you power-cycle long before anything could repair the RTC. The evidence survives exactly
when it's needed.

**Note:** Plasma showing the right time proves nothing here. Plasma displays the *system*
clock, which was only ~2 minutes off. The 2004 date lives in the *RTC*, which nothing displays
while the machine is running and which only matters at boot.

### Reading the EC registers (needed for any lid/AC/battery wake question)

Fedora does not build `CONFIG_ACPI_EC_DEBUGFS`, so there is no `ec_sys` module. Build it out of
tree against the running kernel — it needs only `first_ec`, which is exported:

```sh
cd /tmp/ec && curl -fsSLO "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/acpi/ec_sys.c?h=v$(uname -r | cut -d- -f1)"
# plus internal.h from the same directory, then:
echo 'obj-m := ec_sys.o' > Makefile && make -C /lib/modules/$(uname -r)/build M=$PWD modules
insmod ec_sys.ko          # read-only by default; /sys/kernel/debug/ec/ec0/io
```

Useful offsets on this machine, from the DSDT's `ECOR` field (decode with `acpica-tools`):
`0x60` bit 0 `ELSW` lid open, bit 1 `EACP` AC present; `0x68` bit 0 `EWLO` wake-on-lid-open;
`0x06` `WKRS`. **Unload it when done** — it is a debug module and exposes raw EC access.

### `no_console_suspend`

Added to all three BLS entries and to `/etc/kernel/cmdline`. **Probably inert on this
machine** — during a resume hang the panel keeps showing the stale framebuffer rather than
falling back to fbcon, so there's nowhere for the messages to appear without a serial console.
Kept because it costs nothing.

---

## 7. Other changes

### `/etc/modprobe.d/99-applespi-blacklist.conf`

`applespi` drives the SPI keyboard/trackpad of 2016-and-later MacBooks. This machine's input
is USB, so the driver binds nothing — it logs `USB interface already enabled` and stops.
Blacklisted to keep one more module out of the suspend path. It loads after switch-root, so no
initramfs rebuild was needed.

### Power management — already fine, leave it alone

`tuned` is active on `balanced-battery`, `thermald` is running, `fstrim.timer` is enabled,
zram swap is configured. **Do not install TLP** — it fights tuned.

### Printing — HP LaserJet MFP (M232-M237 series)

Driverless over the network; queue added 2026-09-17 and set as system default. **Do not install
an HP driver for this.** The printer advertises AirPrint and Mopria 2.2 with `URF` and PCLm, so
CUPS' built-in `everywhere` model drives it. `hplip` is installed on this machine but plays no
part in the queue and is not needed to print.

| | |
|---|---|
| Model | HP LaserJet MFP M234sdw (reports as M232-M237), mono, duplex, scanner |
| Address | mDNS name `<printer>.local`, DHCP address |
| Admin UI | `http://<printer>.local/` |

**Adding it.**

```sh
sudo dnf install -y cups avahi           # both are in a stock Fedora KDE install
lpinfo -v | grep -iE 'dnssd|ipp'         # find the printer; copy the URI it prints
sudo lpadmin -p <queue> -E -v '<uri>' -m everywhere -o printer-is-shared=false
sudo lpadmin -d <queue>                  # make it the system default
sudo lpadmin -p <queue> -o Duplex=DuplexNoTumble   # two-sided by default (see below)
```

**Never use a hardcoded `ipp://<ip>/...` URI.** The printer is on DHCP, so an address-based URI
breaks the day its lease changes. Both `dnssd://` and a hostname-based `ipp://<printer>.local:631/`
URI are resolved by mDNS at print time, which means **`avahi-daemon` must stay running** or
printing stops working.

> This queue was created with a `dnssd://…` URI, and CUPS has since rewritten it to
> `ipp://<printer>.local:631/ipp/print`. Both are fine — the name, not an address — so don't
> "fix" it back. Read the live value with `lpstat -v` rather than trusting either this document
> or your memory.

**Duplex, and a trap.**

**`-o sides-default=two-sided-long-edge` silently does nothing on this queue.** It is accepted,
it is not stored, and `lpoptions` keeps reporting one-sided; an earlier version of this runbook
recommended exactly that. The queue has a generated PPD, so the default lives in the PPD's
`Duplex` option instead:

```sh
sudo lpadmin -p <queue> -o Duplex=DuplexNoTumble    # long-edge (portrait)
grep '^\*DefaultDuplex' /etc/cups/ppd/<queue>.ppd  # -> DuplexNoTumble
lpoptions -p <queue> | tr ' ' '\n' | grep sides    # -> sides=two-sided-long-edge
```

Set that way 2026-09-24. `Duplex=None` restores one-sided. Other defaults are Letter and `Gray`.

**Verify.**

```sh
lpstat -t | head -5             # queue idle and enabled, and the default destination
lpstat -v                       # the live device URI
systemctl is-active avahi-daemon cups
echo test | lp                  # prints one page on the default queue
```

**Notes.**

Available to all local users with no extra configuration: the queue lives in the system-wide
cupsd, and the stock `<Limit Create-Job Print-Job …> Order deny,allow` policy in
`/etc/cups/cupsd.conf` permits any local user to submit. `printer-is-shared=false` keeps this
machine from re-advertising a printer that already advertises itself.

`cups-browsed` is disabled and should stay that way; with a permanent queue it would create
duplicate temporary queues in print dialogs.

Remove the queue with `sudo lpadmin -x <queue>`.

### Trackpad — left at libinput defaults, deliberately

Click method is **clickfinger** (right-click = press down with two fingers) and tap-to-click is
**off**. These are the libinput defaults and they match macOS. Tap-to-click and
bottom-right-corner right-click were offered on 2026-09-18 and declined — don't "fix" it.

Only `NaturalScroll=false` is set, in `~/.config/kcminputrc` under `[Libinput][1452][657][bcm5974]`.

### Open issue: Thunderbolt idle power (not locally fixable)

Boot logs `thunderbolt 0000:07:00.0: device link creation from 0000:06:00.0 failed`. Those
device links carry `DL_FLAG_PM_RUNTIME`; without one, the NHI never runtime-suspends —
`runtime_suspended_time` stays 0 across the whole uptime while the downstream bridges suspend
fine. That pins the upstream bridges awake too, which is the ~2 W upstream attributes to an
idle Falcon Ridge controller.

Active upstream work area (device-link patch revisions v6–v10 through 2026, aimed at Ice Lake
and Apple T2). No config knob for this generation. Blacklisting `thunderbolt` would not help —
it stops managing the controller, it doesn't power it down.

To decide whether it's worth caring about, measure real idle draw with the screen dimmed and
nothing running:

```sh
while :; do awk '{printf "%.2f W\n", $1/1e6}' /sys/class/power_supply/BAT0/power_now; sleep 5; done
```

Under ~6 W, nothing to chase. ~8 W or more, the Thunderbolt gap is probably showing.

---

## 8. File manifest

Everything below is local and unpackaged — no package will recreate it. Each linked path is a
copy held in this repo; [`install.sh`](install.sh) puts them all in place, and §9 checks the
result. Unlinked rows are not files, or are created by a package.

| Path | Purpose | §|
|---|---|---|
| [`/usr/lib/systemd/system-sleep/wl-reload`](usr/lib/systemd/system-sleep/wl-reload) | unload/reload `wl`, restart supplicant | 3 |
| [`/usr/local/sbin/wl-fix-wifi-profiles`](usr/local/sbin/wl-fix-wifi-profiles) | rewrite SAE profiles to WPA2-PSK | 3 |
| [`/etc/systemd/system/wl-fix-wifi-profiles.path`](etc/systemd/system/wl-fix-wifi-profiles.path) | triggers the above on profile change | 3 |
| [`/etc/systemd/system/wl-fix-wifi-profiles.service`](etc/systemd/system/wl-fix-wifi-profiles.service) | oneshot invoked by the path unit | 3 |
| [`/etc/NetworkManager/conf.d/91-wl-no-pmf.conf`](etc/NetworkManager/conf.d/91-wl-no-pmf.conf) | default PMF off for `driver:wl` | 3 |
| `/lib/firmware/facetimehd/` | extracted Apple camera firmware + sensor sets | 4 |
| `/usr/src/facetimehd-0.7.0.1/` | camera driver source; DKMS builds from here | 4 |
| [`/etc/modules-load.d/facetimehd.conf`](etc/modules-load.d/facetimehd.conf) | load the camera module at boot | 4 |
| [`/usr/lib/systemd/system-sleep/facetimehd-reload`](usr/lib/systemd/system-sleep/facetimehd-reload) | take camera out of the resume path | 4 |
| [`/usr/lib/systemd/system-sleep/lid-wake-guard`](usr/lib/systemd/system-sleep/lid-wake-guard) | arm lid wake only when the lid is closed, so lid-open sleeps stick | 5 |
| [`/usr/lib/systemd/system-sleep/pm-trace`](usr/lib/systemd/system-sleep/pm-trace) | arm pm_trace; repair clock on resume | 6 |
| [`/usr/lib/systemd/system-sleep/battery-drain-log`](usr/lib/systemd/system-sleep/battery-drain-log) | measure real S3 drain per cycle | 5 |
| [`/usr/local/sbin/pm-trace-result`](usr/local/sbin/pm-trace-result) | read the trace after a hang | 6 |
| [`/usr/local/sbin/pm-trace-rtc-fix`](usr/local/sbin/pm-trace-rtc-fix) | repair the RTC once the clock steps | 6 |
| [`/etc/modprobe.d/99-applespi-blacklist.conf`](etc/modprobe.d/99-applespi-blacklist.conf) | keep idle `applespi` unloaded | 7 |
| `no_console_suspend` on kernel cmdline | (probably inert) | 6 |
| CUPS queue for the network printer | driverless, system default | 7 |

Package-created, don't hand-edit: `/etc/modprobe.d/bdc_pci.conf` (written by DKMS from the
driver's `dkms.conf`) and `/usr/lib/modprobe.d/broadcom-wl-blacklist.conf` (RPMFusion).

> `/usr/local/sbin` is a symlink to `/usr/local/bin` on Fedora 44 (usrmerge). Both paths refer
> to the same files; the repo mirrors the `sbin` spelling.

### SELinux gotcha

Sleep hooks must live in `/usr/lib/systemd/system-sleep/`, **not** `/etc/systemd/system-sleep/`.
SELinux labels the latter `etc_t`, which `systemd_sleep_t` cannot execute. The correct label is
`bin_t`; run `restorecon` after creating one.

---

## 9. Health check

```sh
# all local files present?
for f in /usr/lib/systemd/system-sleep/{wl-reload,facetimehd-reload,pm-trace,lid-wake-guard} \
         /usr/local/sbin/{wl-fix-wifi-profiles,pm-trace-result,pm-trace-rtc-fix} \
         /etc/NetworkManager/conf.d/91-wl-no-pmf.conf \
         /etc/modprobe.d/99-applespi-blacklist.conf; do
  [ -e "$f" ] || echo "MISSING: $f"
done

sudo /path/to/repo/check-drift.sh                  # repo copies still match the system
systemctl is-enabled wl-fix-wifi-profiles.path     # expect: enabled
dkms status                                        # expect: facetimehd ... installed
sudo pm-trace-result                               # expect: "No trace to read" when healthy
lpstat -t | head -5                                # printer queue idle + enabled
tail -5 /var/log/suspend-drain.log                 # real S3 drain, once a long suspend exists
systemctl is-active avahi-daemon                   # required: printer URI is dnssd://
timedatectl | grep -E 'RTC time|synchronized'      # RTC must not be in 2004

grep ^LID0 /proc/acpi/wakeup                       # expect: *enabled while awake

# After a suspend, confirm the full cycle -- and that it lasted minutes, not seconds.
# Entry/exit 6-7s apart with the lid open means lid-wake-guard is missing or not running (§5):
journalctl -b 0 -k | grep -E 'PM: suspend (entry|exit)'
grep -c '^facetimehd ' /proc/modules               # expect: 1
nmcli -t -f DEVICE,STATE dev | grep wlp3s0         # expect: connected
```

### After a kernel upgrade

`akmod-wl` and DKMS rebuild `wl` and `facetimehd` automatically, but **verify before you
trust a suspend**: `modinfo wl facetimehd | grep filename` and check `dkms status`. A kernel
that boots fine can still have no wifi and no camera.

---

## 10. Rollback

Each piece is independent. Delete the file to undo:

```sh
# camera out of resume path
rm /usr/lib/systemd/system-sleep/facetimehd-reload

# suspend drain logging
rm /usr/lib/systemd/system-sleep/battery-drain-log /var/log/suspend-drain.log

# lid-open instant-wake fix (idle sleep will again wake itself after ~6s; §5)
rm /usr/lib/systemd/system-sleep/lid-wake-guard

# pm_trace instrumentation (do all four together)
rm /usr/lib/systemd/system-sleep/pm-trace \
   /usr/local/sbin/pm-trace-result /usr/local/sbin/pm-trace-rtc-fix \
   /var/lib/pm-trace-armed
rm -f /etc/pm-trace.enabled                      # (disarm alone: just this line)
echo 0 | sudo tee /sys/power/pm_trace /sys/power/pm_debug_messages
sudo grubby --update-kernel=ALL --remove-args="no_console_suspend"
sudo sed -i 's/ no_console_suspend//' /etc/kernel/cmdline

# applespi
rm /etc/modprobe.d/99-applespi-blacklist.conf

# wifi workarounds — only after a non-wl adapter is working
systemctl disable --now wl-fix-wifi-profiles.path
rm /usr/lib/systemd/system-sleep/wl-reload /usr/local/sbin/wl-fix-wifi-profiles \
   /etc/systemd/system/wl-fix-wifi-profiles.{path,service} \
   /etc/NetworkManager/conf.d/91-wl-no-pmf.conf
```

Removing `wl` itself: `dnf remove akmod-wl broadcom-wl kmod-wl`. Don't do this until the
replacement adapter is confirmed working — you will have no network.

---

## 11. Open threads

Things this runbook raised and nothing ever came back to. Listed worst-consequence first.

| # | Thread | Where | Status / what would close it |
|---|---|---|---|
| 1 | **Resume hang never root-caused.** `facetimehd` is a suspect on circumstantial evidence only; the hang has not recurred since it left the resume path, which is consistent with a fix *and* with the hang simply being rare. | §5 | **Open, and unresolvable by design** — you cannot prove absence. `pm_trace` is disarmed, so a recurrence yields nothing; re-arm (`sudo touch /etc/pm-trace.enabled`) before trusting the machine somewhere inconvenient. |
| 2 | **The ~5 mW drain figure conflicts with Apple's ~75 mW standby implication** by about 15×, with no explanation for the gap. | §5 | **Open.** Cross-check the gauge against state of charge over a week-long suspend, or against `energy_now` rather than `charge_now`. |
| 3 | **`wl` is still installed and tainting the kernel**, although a working dongle now carries the traffic. Retiring it would close the mitigation hole and three workarounds, at the cost of having no wifi whenever the dongle is absent. | §3, §10 | **Open decision.** Run for a while on the dongle first; the failure mode of getting this wrong is a laptop with no network and no ethernet port. |
| 4 | **The MT7921AU was never measured.** The claim that it would beat the RTL8821CU's ~75 Mbit/s is inference from 2x2 ax + USB 3 + `mt76`, not data, and this machine's USB 3 complex is already known to misbehave for Thunderbolt. | §3 | **Open.** ~$25 settles it. Until then the runbook's recommendation of it over the Realtek rests on reasoning only. |
| 5 | **One suspend woke after 11 seconds** on 2026-09-26, 13 s after a wifi reconfiguration, with no wake source recorded in `/sys/class/wakeup`. The two cycles either side of it slept their full duration and woke on the RTC alarm as expected. | §5 | **Open, unexplained, not reproduced.** Suspect in-flight USB/DHCP activity. If early wakes recur with the dongle plugged in, snapshot `/sys/class/wakeup` before and after and diff — that is what identified the lid-wake bug. |
| 6 | **Thunderbolt idle power was never measured on this machine.** The ~2 W figure is upstream's estimate for an un-suspended Falcon Ridge controller, not an observation here. | §7 | **Open, and it needs the right conditions:** on battery (`power_now` measures the charger otherwise), screen dim, nothing running. Under ~6 W there is nothing to chase. |
| 7 | **`lid-wake-guard`'s lid-closed path has not been exercised on a real cycle.** The logic and a dry run are verified and lid-open sleeps now stick, but no lid-close suspend has happened since it was installed. | §5 | **Open.** Close the lid, wait a minute, open it: it should wake. If it does not, check `grep ^LID0 /proc/acpi/wakeup` during a suspend. |
| 8 | **The chrony/RTC repair path is dead code while `pm_trace` is disarmed.** `makestep 0.1 5` plus `pm-trace-rtc-fix` exist only to undo damage `pm_trace` does, and have not run since 2026-09-18. | §6 | **Open decision, no action needed.** Keep as a matched pair with `pm_trace`, or delete both together — never one alone. |
| 9 | **`no_console_suspend` was never validated** and is believed inert, yet it sits on the cmdline of all three BLS entries. | §6 | **Open decision.** Harmless either way; remove per §10 for a clean cmdline. |
| 10 | **The older 6.19.10 kernel would boot without wifi or camera.** *(Confirmed by inspection 2026-09-24: no `extra/`, empty `updates/`, no `kmod-wl` for it, and DKMS has built `facetimehd` only for 7.2.5.)* | §9 | **Half closed.** What remains is a decision: boot it once and build both modules for it, or remove it (`dnf remove kernel-core-6.19.10-300.fc44`) so a bad boot cannot land on a kernel with no network. |

**Closed 2026-09-26:**

- **A dongle exists and works** — RTL8821CU, in-kernel driver, real WPA3/SAE, survives S3 without
  a sleep hook, now primary. The four-year-old "exit plan" is half executed (§3).
- **Profiles no longer migrate between adapters** — every wifi profile is bound to its interface,
  after the dongle came back from a suspend running `wl`'s WPA2 profile (§3).

**Closed 2026-09-24:**

- **`wl-fix-wifi-profiles` is no longer untested** — a throwaway SAE profile was rewritten to
  `wpa-psk` within a second, logged, with the live connection untouched (§3).
- **`battery-drain-log` no longer writes nonsense for charging cycles** — it samples AC state at
  both ends and labels such rows instead of emitting a plausible -30 W figure (§5).
- **Duplex is the printer's default** — via the PPD's `Duplex` option, because the previously
  documented `sides-default` form is accepted and silently ignored on this queue (§7).
- **S3 drain has a real measurement** — ~5 mW, from a 119-hour suspend corroborated by two
  shorter cycles (§5).
- **Idle sleep sticks** — `lid-wake-guard`, the subject of this evening's diagnosis (§5).

---

## 12. References

- facetimehd driver — https://github.com/patjak/facetimehd
- facetimehd install docs (incl. the suspend script) — https://github.com/patjak/facetimehd/wiki/Installation
- facetimehd firmware extractor — https://github.com/patjak/facetimehd-firmware
- Thunderbolt idle power-down (LKML) — https://lkml.iu.edu/hypermail/linux/kernel/1701.1/05812.html
- Thunderbolt device links patch series — https://ratatoskr.run/linux-usb/2026/08/17485214/t
- `man systemd-sleep`, `man 5 systemd-sleep.conf`
- `Documentation/power/s2ram.rst` in the kernel tree (pm_trace)

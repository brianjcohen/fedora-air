# fedora-air

Fedora 44 on a 2015 MacBook Air (`MacBookAir7,2`): the local workarounds it needs, why each one
exists, and how to undo it.

Apple's 2015 hardware needs a proprietary wifi driver, an out-of-tree camera driver built from
source, and a sleep hook to stop the machine waking itself six seconds after every idle suspend.
None of it is shipped by any package, so nothing recreates it after a reinstall and nothing warns
you when a piece breaks.

**[`fedora-air-runbook.md`](fedora-air-runbook.md) is the document.** It is written to be handed
to a person — or an agent — doing this again on the same hardware: the reason for each workaround,
the commands that create it, what correct output looks like, and how to roll it back. This repo
holds the files it refers to, so nothing has to be retyped from prose.

## Layout

Files mirror their real filesystem paths, so installing is a tree copy:

```
fedora-air-runbook.md                                  the runbook
install.sh                                             copies the files below into place
usr/lib/systemd/system-sleep/
    wl-reload            unload/reload the Broadcom wl driver around suspend
    facetimehd-reload    take the camera driver out of the resume path
    lid-wake-guard       arm lid wake only when the lid is actually closed
    pm-trace             arm pm_trace for the next resume hang (disarmed by default)
    battery-drain-log    measure real S3 drain per cycle
usr/local/sbin/
    wl-fix-wifi-profiles rewrite WPA3/SAE profiles the wl driver cannot use
    pm-trace-result      read the RTC trace after a resume hang
    pm-trace-rtc-fix     repair the RTC that pm_trace clobbers
etc/
    systemd/system/wl-fix-wifi-profiles.{path,service}
    NetworkManager/conf.d/91-wl-no-pmf.conf
    modprobe.d/99-applespi-blacklist.conf
    modules-load.d/facetimehd.conf
```

## Install

```sh
git clone <this-repo> && cd fedora-air
sudo ./install.sh
```

`install.sh` refuses to run on any model other than `MacBookAir7,2` unless forced, is safe to
re-run, and installs **only** these files — it does not install packages, build the camera driver
or touch the kernel command line. It prints what remains to be done by hand.

Then work through the runbook: §3 wifi, §4 camera, §9 health check. Expect roughly half an hour
of building for the camera and a reboot to confirm the result.

## What this does not fix

- **WPA3-only networks.** The `wl` driver cannot do SAE at all; a WPA2/WPA3 transition SSID works,
  WPA3-only does not. The runbook's exit plan is a MediaTek MT7921AU USB adapter, which retires
  four of these workarounds at once.
- **Kernel security mitigations.** `wl` is built without return thunks and weakens Spectre and
  retbleed mitigations system-wide. The kernel says so on every boot.
- **The resume hang.** One suspend in 2026-09-17 never finished resuming. It has not recurred
  since the camera driver left the resume path, but the cause was never proven. §11 of the runbook
  lists that and everything else that was never followed up.

## License

[MIT](LICENSE). The scripts are small and the workarounds they implement are documented in public
bug reports and upstream wikis; use them however you like. The camera driver and firmware
extractor are separate upstream projects with their own licenses.

## Notes

Written against Fedora 44, kernel 7.2.x, KDE Plasma on Wayland. Paths such as
`/usr/lib/systemd/system-sleep` and the SELinux labelling assume a Fedora-like layout. Network
names, printer identifiers and usernames in the runbook are placeholders in angle brackets.

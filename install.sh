#!/bin/bash
# Install the local, unpackaged files this MacBookAir7,2 needs under Fedora.
#
# This script only installs the files in this repo. It deliberately does NOT
# install packages, build the camera driver, or configure wifi/printing --
# those need decisions and network access, and are documented step by step in
# fedora-air-runbook.md. Read that first; this is the mechanical part.
#
# Safe to re-run: it overwrites its own files and nothing else.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO"          # the globs below are repo-relative, so don't inherit the caller's cwd
MODEL_EXPECTED=MacBookAir7,2
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root: sudo $0" >&2
    exit 1
fi

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
if [ "$model" != "$MODEL_EXPECTED" ] && [ "$FORCE" -ne 1 ]; then
    cat >&2 <<EOF
This machine reports '$model', not '$MODEL_EXPECTED'.

Every workaround here is specific to that model: the Broadcom wl wifi driver,
the FaceTime HD camera, the lid-wake quirk, the applespi blacklist. Installing
them elsewhere is at best pointless. Re-run with --force if you are certain.
EOF
    exit 1
fi

install_file() {   # install_file <mode> <path-relative-to-repo>
    local mode=$1 rel=$2 src="$REPO/$2" dst="/$2"
    install -D -m "$mode" "$src" "$dst"
    echo "  $dst"
}

echo "Installing sleep hooks and helpers (mode 755):"
for f in usr/lib/systemd/system-sleep/*; do install_file 755 "$f"; done
for f in usr/local/sbin/*;               do install_file 755 "$f"; done

echo "Installing configuration (mode 644):"
for f in etc/systemd/system/* etc/NetworkManager/conf.d/* \
         etc/modprobe.d/* etc/modules-load.d/*; do
    install_file 644 "$f"
done

# Sleep hooks must be bin_t to be executable by systemd_sleep_t; files created
# under /usr/lib get that from policy, but relabel explicitly in case the repo
# was unpacked somewhere with an odd context.
if command -v restorecon >/dev/null; then
    echo "Relabelling for SELinux:"
    restorecon -F /usr/lib/systemd/system-sleep/* /usr/local/sbin/* \
                  /etc/systemd/system/wl-fix-wifi-profiles.* && echo "  done"
fi

echo "Reloading systemd and enabling the wifi profile watcher:"
systemctl daemon-reload
systemctl enable --now wl-fix-wifi-profiles.path
echo "  wl-fix-wifi-profiles.path enabled"

# pm_trace is left disarmed on purpose: it costs a clobbered RTC on every wake
# and only pays off during a resume hang. See the runbook, section 6.
rm -f /etc/pm-trace.enabled

cat <<'EOF'

Installed. Still to do by hand, in this order (runbook sections in brackets):

  1. Wifi [3]      dnf install akmod-wl broadcom-wl from RPMFusion, then create
                   the profile with wifi-sec.pmf disable. No wifi until this is done.
  2. Camera [4]    build the firmware and the DKMS module -- a long procedure
                   with its own verification steps.
  3. Verify [9]    run the health check; it names anything missing.

Not installed by this script, by design: kernel cmdline changes (no_console_suspend),
the CUPS printer queue, and anything requiring a package.
EOF

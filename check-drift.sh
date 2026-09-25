#!/bin/bash
# Compare every file in this repo against the copy installed on the system.
#
# The repo and the machine drift the moment someone edits one and not the other,
# and nothing else notices: the installed file keeps working, the repo keeps
# looking plausible, and the difference only surfaces when somebody reinstalls
# from it. Run this after changing anything under /usr/lib/systemd/system-sleep,
# /usr/local/sbin or /etc.
#
# Exit status: 0 when everything matches, 1 when anything differs or is missing.
# Needs read access to the installed files, so run it with sudo.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO"
status=0

while IFS= read -r rel; do
    installed="/$rel"
    if [ ! -e "$installed" ]; then
        printf 'MISSING   %s\n' "$installed"
        status=1
    elif ! cmp -s "$rel" "$installed"; then
        printf 'DIFFERS   %s\n' "$installed"
        status=1
    else
        printf 'ok        %s\n' "$installed"
    fi
done < <(find usr etc -type f | sort)

echo
if [ "$status" -eq 0 ]; then
    echo "Repo matches the system."
else
    cat <<'EOF'
Drift found. For each file above, decide which copy is right:

  diff /<path> <path>            # see what changed
  cp /<path> <path>              # the machine is right: update the repo, then commit
  sudo ./install.sh              # the repo is right: reinstall (overwrites the system copy)

MISSING means the repo has a file the system does not -- either it was never
installed here, or something removed it. The runbook's health check (section 9)
covers the reverse case: local files the system needs that are absent.
EOF
fi
exit "$status"

#!/usr/bin/env bash
# Installs the nightly check for the current user on this machine (run it on the test machine, from a
# checkout of the composer placed at ~/sbcomposer):
#   ~/sbcomposer/nightly/setup.sh
# Needs: Docker usable without sudo (user in the "docker" group), git, curl; gh (logged in) for issues.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
[ "$ROOT" = "$HOME/sbcomposer" ] || { echo "Place the composer checkout at ~/sbcomposer (the service runs %h/sbcomposer/nightly/nightly.sh)."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not usable by $(id -un): sudo usermod -aG docker $(id -un), then log in again."; exit 1; }
for c in git curl flock; do command -v $c >/dev/null || { echo "missing: $c"; exit 1; }; done
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || echo "Note: gh is missing or not logged in: no GitHub issue on failure."

mkdir -p ~/.config/systemd/user ~/.config/sbcomposer
chmod 700 ~/.config/sbcomposer
if [ ! -f ~/.config/sbcomposer/nightly.env ]; then
    install -m 600 "$HERE/nightly.env.example" ~/.config/sbcomposer/nightly.env
    echo "Created ~/.config/sbcomposer/nightly.env: fill in ISSUE_REPO and the SMTP settings."
fi
cp "$HERE/sbcomposer-nightly.service" "$HERE/sbcomposer-nightly.timer" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sbcomposer-nightly.timer
# Without lingering, user timers only run while the user is logged in
if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
    loginctl enable-linger "$(id -un)" 2>/dev/null || echo "Run once: sudo loginctl enable-linger $(id -un)   (so the timer runs while logged out)"
fi
systemctl --user list-timers sbcomposer-nightly.timer --no-pager

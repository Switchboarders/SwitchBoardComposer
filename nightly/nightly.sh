#!/usr/bin/env bash
# Nightly check (vieuxpc, 00:00): does a fresh install + update of the latest SwitchBoard and
# SwitchBoardChat still work? Runs tests/run-linux.sh in throwaway Docker-in-Docker machines:
#   1. debian: install at the last commits that passed, then update to main (the real update path);
#      the first night (nothing passed yet): install main, then re-run (update path) on main;
#   2. one more distribution, rotating each night (ubuntu, fedora, arch, alpine): install + update on main;
#   (each test machine: install -> verify --functional -> update -> verify --functional -> tests/suite.sh)
#   3. with LIVE_PREFIX set: the live installation of this machine is updated to main (install.sh) and the
#      complete suite runs against it through its public names (tests/suite.sh --outside local).
# On success the tested commits become the new "last good" ones. On failure: an email and a GitHub issue
# (one open issue, commented on each failure, closed by the next success).
#
# Settings: ~/.config/sbcomposer/nightly.env (see nightly/nightly.env.example).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CONFIG="${SBC_NIGHTLY_CONFIG:-$HOME/.config/sbcomposer/nightly.env}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/sbcomposer"
mkdir -p "$STATE/logs"
LOG="$STATE/logs/$(date +%Y-%m-%d_%H%M).log"
exec 9>"$STATE/lock"
flock -n 9 || { echo "another nightly run is in progress"; exit 0; }
exec > >(tee "$LOG") 2>&1

# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${ROTATE:=ubuntu fedora arch alpine}"
: "${ISSUE_REPO:=}"           # owner/repo for the failure issue (empty: no issue)
: "${MAIL_TO:=}"              # empty: no email
GOOD="$STATE/good-commits"

echo "sbcomposer nightly $(date -Is) on $(hostname)"

# 1. Self-update (the test scripts follow the composer's own main)
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$ROOT" pull -q --ff-only && echo "composer: $(git -C "$ROOT" rev-parse --short HEAD)" \
        || echo "WARNING: could not update the composer checkout; testing $(git -C "$ROOT" rev-parse --short HEAD)"
fi

FROM_SB="" FROM_SBCHAT=""
if [ -f "$GOOD" ]; then
    FROM_SB=$(sed -n 's/^SB=//p' "$GOOD"); FROM_SBCHAT=$(sed -n 's/^SBCHAT=//p' "$GOOD")
fi
set -- $ROTATE
idx=$(( $(date +%j | sed 's/^0*//') % $# + 1 ))
EXTRA=${!idx}

FAILED=0 SUMMARY=""
run() { # title args...
    local title=$1; shift
    echo; echo "################ $title"
    if "$ROOT/tests/run-linux.sh" "$@"; then SUMMARY+="PASS  $title"$'\n'; else SUMMARY+="FAIL  $title"$'\n'; FAILED=1; fi
}
if [ -n "$FROM_SB" ] && [ -n "$FROM_SBCHAT" ]; then
    run "debian: update from last good (SB ${FROM_SB:0:7}, SBChat ${FROM_SBCHAT:0:7}) to main" \
        --distros debian --from-sb "$FROM_SB" --from-sbchat "$FROM_SBCHAT"
else
    run "debian: install + update on main" --distros debian
fi
run "$EXTRA: install + update on main" --distros "$EXTRA"

# 3. The live installation of this machine (LIVE_PREFIX in nightly.env): the real update path on real data,
#    then the complete functional suite against it, through its public names
if [ -n "${LIVE_PREFIX:-}" ]; then
    echo; echo "################ live installation $LIVE_PREFIX: update + full suite"
    if [ "${LIVE_UPDATE:-1}" = 1 ]; then
        if "$ROOT/install.sh" --non-interactive --prefix "$LIVE_PREFIX" > "$STATE/logs/live-update.log" 2>&1; then
            SUMMARY+="PASS  live: update to main + verify"$'\n'
        else
            SUMMARY+="FAIL  live: update or verify (see $STATE/logs/live-update.log)"$'\n'; FAILED=1
            grep -a -E '^FAIL|sbcomposer: ' "$STATE/logs/live-update.log" | tail -n 10
        fi
    fi
    if "$ROOT/tests/suite.sh" --confirm --prefix "$LIVE_PREFIX" --outside "${LIVE_OUTSIDE:-local}" > "$STATE/logs/live-suite.log" 2>&1; then
        SUMMARY+="PASS  live: full suite ($(grep -a '^Suite:' "$STATE/logs/live-suite.log"))"$'\n'
    else
        SUMMARY+="FAIL  live: full suite ($(grep -a '^Suite:' "$STATE/logs/live-suite.log"))"$'\n'; FAILED=1
    fi
    grep -a -E '^FAIL' "$STATE/logs/live-suite.log"
fi

SB_HEAD=$(git ls-remote https://github.com/Switchboarders/SwitchBoard.git refs/heads/main | cut -c1-40)
SBCHAT_HEAD=$(git ls-remote https://github.com/Switchboarders/SwitchBoardChat.git refs/heads/main | cut -c1-40)
# The commits actually tested (main may have moved during the run)
TESTED=$(cat "$ROOT/tests/results/$EXTRA/commits" 2>/dev/null)
T_SB=$(sed -n 1p <<<"$TESTED"); T_SBCHAT=$(sed -n 2p <<<"$TESTED")
COMMITS="SwitchBoard ${T_SB:-$SB_HEAD} · SwitchBoardChat ${T_SBCHAT:-$SBCHAT_HEAD} · composer $(git -C "$ROOT" rev-parse --short HEAD)"

echo; echo "################ Summary"; printf '%s' "$SUMMARY"; echo "$COMMITS"

# Failed checks only (never secrets: the scripts do not print any), for the email and the issue
details() {
    { grep -a -h -E '^FAIL|sbcomposer: ' "$ROOT"/tests/results/*/*.log 2>/dev/null
      [ -z "${LIVE_PREFIX:-}" ] || grep -a -h -E '^FAIL|sbcomposer: ' "$STATE"/logs/live-*.log 2>/dev/null; } | head -n 40
}

send_mail() { # subject body
    [ -n "$MAIL_TO" ] && [ -n "${SMTP_URL:-}" ] || return 0
    local f; f=$(mktemp)
    printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n' \
        "${MAIL_FROM:-$SMTP_USER}" "$MAIL_TO" "$1" "$2" > "$f"
    # credentials through a curl config on stdin (never in the process list)
    printf 'user = "%s:%s"\n' "${SMTP_USER:-}" "${SMTP_PASSWORD:-}" \
        | curl -s --ssl-reqd --max-time 60 -K - --url "$SMTP_URL" --mail-from "${MAIL_FROM:-$SMTP_USER}" \
            --mail-rcpt "$MAIL_TO" --upload-file "$f" && echo "email sent to $MAIL_TO" || echo "WARNING: email not sent"
    rm -f "$f"
}

issue() { # fail|pass body
    [ -n "$ISSUE_REPO" ] && command -v gh >/dev/null || return 0
    local open
    open=$(gh issue list -R "$ISSUE_REPO" --label nightly-failure --state open --json number --jq '.[0].number' 2>/dev/null)
    if [ "$1" = fail ]; then
        if [ -n "$open" ]; then
            gh issue comment "$open" -R "$ISSUE_REPO" --body "$2" >/dev/null && echo "commented on issue #$open"
        else
            gh label create nightly-failure -R "$ISSUE_REPO" --color B60205 --description "sbcomposer nightly install check" >/dev/null 2>&1
            gh issue create -R "$ISSUE_REPO" --label nightly-failure \
                --title "Nightly install check failing since $(date +%Y-%m-%d)" --body "$2" && echo "issue opened"
        fi
    elif [ -n "$open" ]; then
        gh issue close "$open" -R "$ISSUE_REPO" --comment "$2" >/dev/null && echo "issue #$open closed"
    fi
}

if [ "$FAILED" = 0 ]; then
    { echo "SB=${T_SB:-$SB_HEAD}"; echo "SBCHAT=${T_SBCHAT:-$SBCHAT_HEAD}"; echo "DATE=$(date -Is)"; } > "$GOOD"
    issue pass "Passing again on $(date +%Y-%m-%d) ($(hostname)).
$SUMMARY
$COMMITS"
else
    BODY="Nightly install check FAILED on $(date '+%Y-%m-%d %H:%M') ($(hostname)).

$SUMMARY
$COMMITS

Failed checks:
$(details)

Full log on $(hostname): $LOG
Per-distribution logs: $ROOT/tests/results/"
    send_mail "[sbcomposer] nightly install check FAILED $(date +%Y-%m-%d)" "$BODY"
    issue fail "\`\`\`
$BODY
\`\`\`"
fi

# Housekeeping: 30 days of logs; machines are removed by run-linux.sh; keep Docker's disk in check
find "$STATE/logs" -name '*.log' -mtime +30 -delete
docker image prune -f >/dev/null 2>&1
docker builder prune -f --filter until=168h >/dev/null 2>&1
exit "$FAILED"

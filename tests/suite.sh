#!/usr/bin/env bash
# Full functional test suite of an installation made by install.sh. TEST INSTALLATIONS ONLY: it creates
# test accounts and a test call center, points the web chat at it, mutes outgoing SMS and restarts the
# services, then puts the bridge's settings back and deletes the call center.
#
#   tests/suite.sh --confirm [--prefix DIR] [--outside HOST] [--skip restart,outside,...]
#
# Sections (each prints PASS/FAIL lines; the exit code is 0 only if everything passed):
#   health    verify.sh: containers, public addresses, logins, SBChat --check, SwitchBoard wiring
#   setup     test accounts through MAS and through SwitchBoard, call center + respondents through the
#             SBChat API, macros through SwitchBoard, web chat + mute settings on the bridge
#   accounts  account created by SwitchBoard logs in; wrong password refused; respondents log in (E2EE)
#   webchat   visitor -> 2 respondents: room, decryption, welcome macro, !aide, unknown command, #macro,
#             answers from both, history, end closes the room for everyone
#   sms       voip.ms webhook (key checked) -> room, both read it, number hidden, answer queued (muted), !fin
#   server    the muted SMS answer reached the voip.ms queue; Law 25: closed rooms purged from Synapse
#   restart   every service restarted -> a new web chat still works end to end
#   outside   from HOST on another network: DNS, certificates, redirects, discovery, federation, what must
#             NOT be exposed, CORS; then a web chat from there answered by a respondent here
set -uo pipefail
umask 077
COMPOSER_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$COMPOSER_DIR/lib/common.sh"
COMPOSER_DIR=$(winpath "$COMPOSER_DIR")
if [ "$IS_WINDOWS" = 1 ]; then PREFIX="${SBC_PREFIX:-$(winpath "$USERPROFILE")/switchboard}"; else PREFIX="${SBC_PREFIX:-/opt/switchboard}"; fi
OUTSIDE="" OUTSIDE_PORT=22 SKIP="" CONFIRM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=$2; shift 2 ;;
        --outside) OUTSIDE=$2; shift 2 ;;
        --outside-port) OUTSIDE_PORT=$2; shift 2 ;;   # e.g. a reverse tunnel: ssh -A -R 2222:pi:22 server
        --skip) SKIP=",$2,"; shift 2 ;;
        --confirm) CONFIRM=1; shift ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "$EXIT_ARGS" "unknown option: $1" ;;
    esac
done
[ "$CONFIRM" = 1 ] || die "$EXIT_ARGS" "this suite changes the installation for a while (see --help): add --confirm on a test installation"
CONF="$PREFIX/composer.env"
[ -f "$CONF" ] || die "$EXIT_ARGS" "no installation in $PREFIX"
. "$COMPOSER_DIR/lib/matrix.sh"
. "$COMPOSER_DIR/lib/switchboard.sh"
. "$COMPOSER_DIR/lib/sbchat.sh"

MATRIX=$(conf MATRIX_HOST); SB=$(conf SB_HOST); SBCHAT=$(conf SBCHAT_HOST)
D=$(SBCHAT_DIR); ENVF="$D/.env"
ORIGIN=https://site.sbcomposer.invalid
DID=5145550199
WELCOME="Bienvenue sur le clavardage de test sbcomposer, un bénévole va vous répondre."
MERCI="Merci d'avoir écrit au clavardage de test sbcomposer."
RESP_A=sbctest-resp-a RESP_B=sbctest-resp-b SBUSER=sbctest-sbuser
RESP_PW=$(conf TEST_RESPONDENT_PASSWORD); [ -n "$RESP_PW" ] || { RESP_PW=$(rand_password); env_set "$CONF" TEST_RESPONDENT_PASSWORD "$RESP_PW"; }
SBUSER_PW=$(conf TEST_SBUSER_PASSWORD); [ -n "$SBUSER_PW" ] || { SBUSER_PW=$(rand_password); env_set "$CONF" TEST_SBUSER_PASSWORD "$SBUSER_PW"; }
RESULTS="$COMPOSER_DIR/tests/results/suite"; mkdir -p "$RESULTS"
FAILS=0 PASSES=0
pass() { say "PASS  $*"; PASSES=$((PASSES + 1)); }
fail() { say "FAIL  $*"; FAILS=$((FAILS + 1)); }
count() { # reads PASS/FAIL lines from stdin, echoes them, adds them up
    local line
    while IFS= read -r line; do
        say "$line"
        case "$line" in PASS*) PASSES=$((PASSES + 1)) ;; FAIL*) FAILS=$((FAILS + 1)) ;; esac
    done
}
skip() { case "$SKIP" in *",$1,"*) say "(skipped: $1)"; return 0 ;; esac; return 1; }

# How the test containers reach the installation: through the public names (real certificates: Let's Encrypt
# or the upstream proxy), or, on a self-signed test machine, through the front nginx on the "web" network.
NET_ARGS=()
if [ "$(conf TLS_MODE)" = selfsigned ] && [ "$(conf FRONT)" != proxy ]; then
    NET_ARGS=(--network web -v "$D/sbcomposer-ca-bundle.pem:/etc/ssl/certs/ca-certificates.crt:ro" -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt)
    CURL_CA=(-v "$(MATRIX_DIR)/ca/ca.pem:/ca.pem:ro" -e CURL_CA_BUNDLE=/ca.pem)
else
    CURL_CA=()
fi
sbchat_api() { # json [token]
    local token=${2:-$(head -n1 "$D/admin-api-token")}
    printf 'url = "https://%s/sbchat_api"\nheader = %s\nheader = "Content-Type: application/json"\ndata = %s\n' \
        "$SBCHAT" "$(curl_quote "Authorization: Bearer $token")" "$(curl_quote "$1")" \
        | docker run --rm -i "${NET_ARGS[@]:0:2}" "${CURL_CA[@]}" "$(conf CURL_IMAGE)" -s --max-time 60 -K -
}
bridge_ready() {
    local started; started=$(docker inspect -f '{{.State.StartedAt}}' sb-chat 2>/dev/null) || return 1
    docker logs --since "$started" sb-chat 2>&1 | grep -c "The client is ready" >/dev/null
}
restart_bridge() { (cd "$D" && docker compose up -d --force-recreate --no-build sb-chat >/dev/null 2>&1) && wait_for 300 "the bridge" bridge_ready; }
sqlite_bridge() { # SQL -> rows (read-only, the bridge's users.db)
    docker run --rm --volumes-from sb-chat:ro --entrypoint python3 "$(conf SYNAPSE_IMAGE)" -c \
        "import sqlite3,sys; c=sqlite3.connect('file:/app/data/db/users.db?mode=ro', uri=True); [print('|'.join(map(str,r))) for r in c.execute(sys.argv[1])]" "$1"
}
suite_py() { # scenario... (output also kept in $RESULTS/py.log)
    docker run --rm -i "${NET_ARGS[@]}" \
        -e MATRIX_HOST="$MATRIX" -e SB_HOST="$SB" -e SBCHAT_HOST="$SBCHAT" -e ORIGIN="$ORIGIN" \
        -e RESP_A="$RESP_A" -e RESP_B="$RESP_B" -e RESP_PW -e SBUSER="$SBUSER" -e SBUSER_PW \
        -e CC_TOKEN -e DID="$DID" -e WELCOME="$WELCOME" -e MERCI="$MERCI" -e NONCE="${NONCE:-}" \
        sbcomposer-sim python3 - "$@" < "$COMPOSER_DIR/tests/suite.py" 2>&1 | tee -a "$RESULTS/py.log"
}
export RESP_PW SBUSER_PW
: > "$RESULTS/py.log"

# ------------------------------------------------------------------------------------------ health
step "health"
count < <("$COMPOSER_DIR/verify.sh" --prefix "$PREFIX" 2>&1 | grep -E '^(PASS|FAIL)')

# ------------------------------------------------------------------------------------------ setup
step "setup"
docker build -q -t sbcomposer-sim -f "$COMPOSER_DIR/tests/sim.Dockerfile" "$D/tests/e2e" >/dev/null \
    && pass "respondent simulator built (SwitchBoardChat tests/e2e/respondent-sim)" || { fail "respondent simulator build"; exit 1; }
mas_ensure_user "$RESP_A" "$RESP_PW" 0 && mas_ensure_user "$RESP_B" "$RESP_PW" 0 && pass "respondent accounts in MAS"
OUT=$(sb_wire_php "{\"action\":\"mas_user\",\"admin_username\":\"$(conf SB_ADMIN_USER)\",\"username\":\"$SBUSER\",\"password\":\"$SBUSER_PW\"}")
case "$OUT" in *'"ok":true'*) pass "SwitchBoard creates a Matrix account through MAS and sets its password ($OUT)" ;; *) fail "SwitchBoard → MAS account: $OUT" ;; esac

OUT=$(sbchat_api "{\"command\":\"add_new_call_center\",\"voip_ms_username\":\"sbctest@sbcomposer.invalid\",\"voip_ms_api_password\":\"sbctest\",\"call_center_did\":\"$DID\",\"privilege_level\":0,\"renew_api_token\":false}")
CC_TOKEN=$(printf '%s' "$OUT" | sed -n 's/.*"vec_answer":\["\([^"]*\)".*/\1/p'); export CC_TOKEN
[ -n "$CC_TOKEN" ] && pass "test call center created (SBChat API)" || { fail "add_new_call_center: ${OUT:0:200}"; exit 1; }

cleanup() {
    step "cleanup"
    sbchat_api "{\"command\":\"delete_call_center\",\"api_token\":\"$CC_TOKEN\"}" >/dev/null && pass "test call center deleted" || fail "delete_call_center"
    if [ -f "$ENVF.sbcomposer-suite" ]; then
        mv "$ENVF.sbcomposer-suite" "$ENVF"; chmod 600 "$ENVF"
        restart_bridge && pass "bridge back to its own settings" || fail "bridge restart after the suite"
    fi
    say ""
    say "Suite: $PASSES passed, $FAILS failed."
}
trap cleanup EXIT

OUT=$(sbchat_api "{\"command\":\"change_respondents\",\"api_token\":\"$CC_TOKEN\",\"respondent\":[\"@$RESP_A:$MATRIX\",\"$RESP_B\"]}" "$CC_TOKEN")
case "$OUT" in *'"querystatus":"Success'*) pass "respondents assigned (one full id, one short name completed by the bridge)" ;; *) fail "change_respondents: ${OUT:0:200}" ;; esac
for spec in "newcomerweb|$WELCOME|newcomerweb" "merci|$MERCI|"; do
    IFS='|' read -r name text tags <<<"$spec"
    OUT=$(sb_wire_php "$(printf '{"action":"macro","admin_username":"%s","token":"%s","name":"%s","text":"%s","tags":"%s"}' \
        "$(conf SB_ADMIN_USER)" "$CC_TOKEN" "$name" "$(json_escape "$text")" "$tags")")
    case "$OUT" in *'"ok":true'*) pass "macro « $name » saved through SwitchBoard and listed back" ;; *) fail "macro $name through SwitchBoard: $OUT" ;; esac
done
CC_ID=$(sqlite_bridge "SELECT id_call_center FROM call_center WHERE call_center_did=$DID ORDER BY id_call_center DESC LIMIT 1" 2>/dev/null)
[[ "$CC_ID" =~ ^[0-9]+$ ]] || { fail "test call center id not found"; exit 1; }
cp -p "$ENVF" "$ENVF.sbcomposer-suite"
env_set "$ENVF" WEB_ALLOWED_ORIGINS "$ORIGIN"
env_set "$ENVF" WEB_CALL_CENTER_ID "$CC_ID"
env_set "$ENVF" WEB_CHALLENGE off
env_set "$ENVF" MUTE_VOIPMS_REQUEST true
env_set "$ENVF" ROOM_PURGE_DELAY_SECS 20
restart_bridge && pass "bridge restarted: web chat on call center $CC_ID, outgoing SMS muted" || { fail "bridge restart"; exit 1; }
SENT_BEFORE=$(sqlite_bridge "SELECT COUNT(*) FROM to_voipms_queue WHERE processing_level='Test mode'" 2>/dev/null || echo 0)

# ------------------------------------------------------------------------------------------ conversations
step "accounts, webchat, sms"
count < <(suite_py accounts webchat sms | grep -E '^(PASS|FAIL)')

# ------------------------------------------------------------------------------------------ server side
if ! skip server; then
    step "server side"
    SENT_AFTER=$(sqlite_bridge "SELECT COUNT(*) FROM to_voipms_queue WHERE processing_level='Test mode'" 2>/dev/null || echo 0)
    [ "${SENT_AFTER:-0}" -gt "${SENT_BEFORE:-0}" ] && pass "the respondent's SMS answer reached the voip.ms queue (muted: not sent)" \
        || fail "no muted SMS in the voip.ms queue ($SENT_BEFORE -> $SENT_AFTER)"
    # Law 25: a closed room is purged from Synapse (the bridge does it through MAS, ROOM_PURGE_DELAY_SECS)
    TOKEN=$(mas_cli manage issue-compatibility-token "$(conf ADMIN_LOCALPART)" --yes-i-want-to-grant-synapse-admin-privileges 2>/dev/null \
        | grep -o 'mct_[A-Za-z0-9_]*' | head -n1)
    for room in $(sed -n 's/^ROOM \(webchat\|sms\) //p' "$RESULTS/py.log"); do
        gone=0
        for _ in $(seq 1 20); do
            code=$(printf 'url = "http://localhost:8008/_synapse/admin/v1/rooms/%s"\nheader = "Authorization: Bearer %s"\n' "$room" "$TOKEN" \
                | docker exec -i synapse curl -s -o /dev/null -w '%{http_code}' -K -)
            [ "$code" = 404 ] && { gone=1; break; }
            sleep 10
        done
        [ "$gone" = 1 ] && pass "closed room $room purged from Synapse (Law 25)" || fail "room $room still in Synapse after 200 s (HTTP $code)"
    done
fi

# ------------------------------------------------------------------------------------------ restart
if ! skip restart; then
    step "restart: every service"
    docker restart synapse mas masdb synapse-nginx sb_php-fpm sb_web_server sb_mariadb >/dev/null \
        && pass "Synapse, MAS, its database, nginx and SwitchBoard restarted" || fail "docker restart"
    wait_for 300 "Synapse" sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" synapse)" = healthy ]'
    restart_bridge && pass "bridge restarted and ready" || fail "bridge not ready after restart"
    sleep 10
    count < <(suite_py webchat | grep -E '^(PASS|FAIL)' | sed 's/^\(PASS\|FAIL\)  /\1  after restart: /')
fi

# ------------------------------------------------------------------------------------------ outside
if [ -n "$OUTSIDE" ] && ! skip outside; then
    step "outside network: $OUTSIDE"
    OSSH=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RESULTS/known_hosts")
    ssh "${OSSH[@]}" -p "$OUTSIDE_PORT" "$OUTSIDE" 'mkdir -p /tmp/sbcsuite' \
        && scp -q "${OSSH[@]}" -P "$OUTSIDE_PORT" "$COMPOSER_DIR/tests/outside.py" "$D/tests/e2e/lib.py" "$OUTSIDE:/tmp/sbcsuite/" \
        || fail "could not copy the checks to $OUTSIDE"
    remote() { ssh "${OSSH[@]}" -p "$OUTSIDE_PORT" "$OUTSIDE" "cd /tmp/sbcsuite && MATRIX_HOST=$MATRIX SB_HOST=$SB SBCHAT_HOST=$SBCHAT ORIGIN=$ORIGIN NONCE=${NONCE:-} python3 -I outside.py $*"; }
    count < <(remote public 2>&1 | grep -E '^(PASS|FAIL)')
    NONCE=$(rand_hex 4); export NONCE
    suite_py responder > "$RESULTS/responder.log" 2>&1 &
    RPID=$!
    for _ in $(seq 1 60); do grep -q '^READY' "$RESULTS/responder.log" && break; sleep 2; done
    count < <(remote visitor 2>&1 | grep -E '^(PASS|FAIL)')
    wait "$RPID"
    count < <(grep -E '^(PASS|FAIL)' "$RESULTS/responder.log")
    ssh "${OSSH[@]}" -p "$OUTSIDE_PORT" "$OUTSIDE" 'rm -rf /tmp/sbcsuite'
fi
exit $(( FAILS > 0 ))

#!/usr/bin/env bash
# Functional test of an installation (called by verify.sh --functional). TEST MACHINES ONLY:
# creates a test call center + respondent, points the web chat at it (bridge restarted), runs
# tests/roundtrip.py, then deletes the call center and restores the bridge's settings.
set -uo pipefail
umask 077
COMPOSER_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$COMPOSER_DIR/lib/common.sh"
COMPOSER_DIR=$(winpath "$COMPOSER_DIR")
if [ "$IS_WINDOWS" = 1 ]; then PREFIX="${SBC_PREFIX:-$(winpath "$USERPROFILE")/switchboard}"; else PREFIX="${SBC_PREFIX:-/opt/switchboard}"; fi
[ "${1:-}" = --prefix ] && PREFIX=$2
CONF="$PREFIX/composer.env"
. "$COMPOSER_DIR/lib/matrix.sh"
. "$COMPOSER_DIR/lib/switchboard.sh"
. "$COMPOSER_DIR/lib/sbchat.sh"

MATRIX=$(conf MATRIX_HOST); SB=$(conf SB_HOST); SBCHAT=$(conf SBCHAT_HOST)
D=$(SBCHAT_DIR); ENVF="$D/.env"
RESP=sbctest-respondent
RESP_PW=$(env_get "$CONF" TEST_RESPONDENT_PASSWORD)
[ -n "$RESP_PW" ] || { RESP_PW=$(rand_password); env_set "$CONF" TEST_RESPONDENT_PASSWORD "$RESP_PW"; }
ORIGIN=https://site.sbcomposer.invalid
DID=5145550199
CA_ARGS=()
[ "$(conf TLS_MODE)" = selfsigned ] && CA_ARGS=(-v "$(MATRIX_DIR)/ca/ca.pem:/ca.pem:ro" -e CURL_CA_BUNDLE=/ca.pem)
FAILS=0
pass() { say "PASS  $*"; }
fail() { say "FAIL  $*"; FAILS=$((FAILS + 1)); }

# sbchat_api COMMAND-JSON [token]: through https://<sbchat host>/sbchat_api, as SwitchBoard does
sbchat_api() {
    local token=${2:-$(head -n1 "$D/admin-api-token")}
    printf 'url = "https://%s/sbchat_api"\nheader = %s\nheader = "Content-Type: application/json"\ndata = %s\n' \
        "$SBCHAT" "$(curl_quote "Authorization: Bearer $token")" "$(curl_quote "$1")" \
        | docker run --rm -i --network web "${CA_ARGS[@]}" "$(conf CURL_IMAGE)" -s --max-time 60 -K -
}
bridge_ready() {
    local started; started=$(docker inspect -f '{{.State.StartedAt}}' sb-chat 2>/dev/null) || return 1
    docker logs --since "$started" sb-chat 2>&1 | grep -c "The client is ready" >/dev/null
}
restart_bridge() {
    (cd "$D" && docker compose up -d --force-recreate --no-build sb-chat >/dev/null 2>&1) && wait_for 300 "the bridge" bridge_ready
}

# ---------------------------------------------------------------------------------- test image
step "Building the respondent simulator (first time: several minutes)"
if docker build -q -t sbcomposer-sim -f "$COMPOSER_DIR/tests/sim.Dockerfile" "$D/tests/e2e" >/dev/null; then
    pass "respondent-sim built from SwitchBoardChat's tests/e2e"
else
    fail "respondent-sim build"; exit 1
fi

# ---------------------------------------------------------------------------------- setup
mas_ensure_user "$RESP" "$RESP_PW" 0
OUT=$(sbchat_api "{\"command\":\"add_new_call_center\",\"voip_ms_username\":\"sbctest@sbcomposer.invalid\",\"voip_ms_api_password\":\"sbctest\",\"call_center_did\":\"$DID\",\"privilege_level\":0,\"renew_api_token\":false}")
CC_TOKEN=$(printf '%s' "$OUT" | sed -n 's/.*"vec_answer":\["\([^"]*\)".*/\1/p')
if [ -n "$CC_TOKEN" ]; then pass "test call center created through the SBChat API"; else fail "add_new_call_center: ${OUT:0:200}"; exit 1; fi

cleanup() {
    step "Cleanup"
    sbchat_api "{\"command\":\"delete_call_center\",\"api_token\":\"$CC_TOKEN\"}" >/dev/null && pass "test call center deleted" || fail "delete_call_center"
    if [ -f "$ENVF.sbcomposer-test" ]; then
        mv "$ENVF.sbcomposer-test" "$ENVF"; chmod 600 "$ENVF"
        restart_bridge && pass "bridge restored to its settings" || fail "bridge restart after the test"
    fi
}
trap cleanup EXIT

OUT=$(sbchat_api "{\"command\":\"change_respondents\",\"api_token\":\"$CC_TOKEN\",\"respondent\":[\"@$RESP:$MATRIX\"]}" "$CC_TOKEN")
case "$OUT" in *'"querystatus":"Success'*) pass "respondent @$RESP:$MATRIX assigned" ;; *) fail "change_respondents: ${OUT:0:200}" ;; esac

# The web chat goes to one call center (WEB_CALL_CENTER_ID): find the test one's id in the bridge's DB
CC_ID=$(docker run --rm --volumes-from sb-chat:ro --entrypoint python3 "$(conf SYNAPSE_IMAGE)" -c \
    "import sqlite3; print(sqlite3.connect('file:/app/data/db/users.db?mode=ro', uri=True).execute('SELECT id_call_center FROM call_center WHERE call_center_did=$DID ORDER BY id_call_center DESC').fetchone()[0])" 2>/dev/null)
[[ "$CC_ID" =~ ^[0-9]+$ ]] || { fail "could not find the test call center's id"; exit 1; }
cp -p "$ENVF" "$ENVF.sbcomposer-test"
env_set "$ENVF" WEB_ALLOWED_ORIGINS "$ORIGIN"
env_set "$ENVF" WEB_CALL_CENTER_ID "$CC_ID"
env_set "$ENVF" WEB_CHALLENGE off
if restart_bridge; then pass "bridge restarted with the web chat on call center $CC_ID"; else fail "bridge restart"; exit 1; fi

# ---------------------------------------------------------------------------------- the conversation
step "Conversation"
RESPONDENT_PASSWORD="$RESP_PW" docker run --rm -i --network web "${CA_ARGS[@]}" -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    $( [ "$(conf TLS_MODE)" = selfsigned ] && echo "-v $D/sbcomposer-ca-bundle.pem:/etc/ssl/certs/ca-certificates.crt:ro" ) \
    -e SB_HOST="$SB" -e MATRIX_HOST="$MATRIX" -e RESPONDENT="$RESP" -e ORIGIN="$ORIGIN" -e RESPONDENT_PASSWORD \
    sbcomposer-sim python3 - < "$COMPOSER_DIR/tests/roundtrip.py" >&2
RC=$?
[ "$RC" = 0 ] || FAILS=$((FAILS + 1))
exit $(( FAILS > 0 ))

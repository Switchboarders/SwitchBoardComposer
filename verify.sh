#!/usr/bin/env bash
# Checks an installation made by install.sh. Prints one PASS/FAIL line per check, exits 0 if all pass.
#
#   ./verify.sh [--prefix DIR]                 health checks only; changes nothing (safe in production)
#   ./verify.sh [--prefix DIR] --functional    + a real conversation: a website visitor writes, a
#                                              simulated respondent (real end-to-end encrypted Matrix
#                                              client, logged in through MAS) reads and answers.
#                                              Creates and deletes a test call center and restarts the
#                                              bridge twice: for test machines only, never production.
set -uo pipefail
umask 077
COMPOSER_DIR=$(cd "$(dirname "$0")" && pwd)
. "$COMPOSER_DIR/lib/common.sh"
COMPOSER_DIR=$(winpath "$COMPOSER_DIR")
if [ "$IS_WINDOWS" = 1 ]; then PREFIX="${SBC_PREFIX:-$(winpath "$USERPROFILE")/switchboard}"; else PREFIX="${SBC_PREFIX:-/opt/switchboard}"; fi
FUNCTIONAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=$2; shift 2 ;;
        --functional) FUNCTIONAL=1; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "$EXIT_ARGS" "unknown option: $1" ;;
    esac
done
PREFIX=$(winpath "$PREFIX")
CONF="$PREFIX/composer.env"
[ -f "$CONF" ] || die "$EXIT_ARGS" "no installation in $PREFIX ($CONF missing)"
. "$COMPOSER_DIR/lib/matrix.sh"
. "$COMPOSER_DIR/lib/switchboard.sh"
. "$COMPOSER_DIR/lib/sbchat.sh"

FAILS=0
check() { # description command...
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then say "PASS  $d"; else say "FAIL  $d"; FAILS=$((FAILS + 1)); fi
}

MATRIX=$(conf MATRIX_HOST); SB=$(conf SB_HOST); SBCHAT=$(conf SBCHAT_HOST)
# curl in the "web" network with real certificate checks (the local CA in self-signed mode)
CA_ARGS=()
[ "$(conf TLS_MODE)" = selfsigned ] && CA_ARGS=(-v "$(MATRIX_DIR)/ca/ca.pem:/ca.pem:ro" -e CURL_CA_BUNDLE=/ca.pem)
vcurl() { docker run --rm -i --network web "${CA_ARGS[@]}" "$(conf CURL_IMAGE)" -s --max-time 30 "$@"; }
http_code() { vcurl -o /dev/null -w '%{http_code}' "$@"; }
code_is() { [ "$(http_code "${@:2}")" = "$1" ]; }
# reads the whole body first: with pipefail, "curl | grep -q" fails when grep stops early (SIGPIPE)
body_has() { local b; b=$(vcurl "${@:2}") && grep -q -- "$1" <<<"$b"; }

step "Containers"
for c in synapse-nginx synapse mas masdb sb_web_server sb_php-fpm sb_mariadb sb_mail_relay sb-chat; do
    check "$c is running" container_running "$c"
done
check "Synapse is healthy" sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" synapse)" = healthy ]'

step "Public addresses (through the front proxy, certificates checked)"
check "https://$SB SwitchBoard portal answers" code_is 200 "https://$SB$SB_PORTAL"
check "https://$MATRIX Matrix client API answers" body_has '"versions"' "https://$MATRIX/_matrix/client/versions"
check "https://$MATRIX/.well-known/matrix/client points to the homeserver" body_has "https://$MATRIX" "https://$MATRIX/.well-known/matrix/client"
check "MAS discovery at https://$MATRIX/auth/" body_has '"issuer"' "https://$MATRIX/auth/.well-known/openid-configuration"
check "Synapse delegates authentication to MAS" body_has "$MATRIX/auth/" "https://$MATRIX/_matrix/client/v1/auth_metadata"
check "MAS health" vcurl -f http://mas:8081/health
check "https://$SBCHAT bridge answers (SMS webhook refuses a request without key: 403)" code_is 403 "https://$SBCHAT/voip_api"

step "Logins"
sb_login() {
    web_sh <<EOF
U='https://$SB$SB_PORTAL'
curl -sk --max-time 30 -c /tmp/j -b /tmp/j "\$U" > /dev/null
cat > /tmp/cfg <<'CFG'
data-urlencode = "username=$(conf SB_ADMIN_USER)"
data-urlencode = "password=$(conf SB_ADMIN_PASSWORD)"
CFG
curl -sk --max-time 30 -c /tmp/j -b /tmp/j -K /tmp/cfg "\$U" | grep -q 'page=logout'
EOF
}
check "SwitchBoard admin login" sb_login
# Password login through MAS's compatibility layer, then logout (the device is removed again)
matrix_login() {
    local out token
    out=$(printf 'url = "https://%s/_matrix/client/v3/login"\ndata = %s\nheader = "Content-Type: application/json"\n' "$MATRIX" \
        "$(curl_quote "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$(conf ADMIN_LOCALPART)\"},\"password\":\"$(json_escape "$(conf ADMIN_PASSWORD)")\",\"initial_device_display_name\":\"sbcomposer verify\"}")" \
        | vcurl -K -)
    token=$(printf '%s' "$out" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || return 1
    printf 'url = "https://%s/_matrix/client/v3/logout"\nrequest = "POST"\nheader = %s\ndata = "{}"\n' "$MATRIX" \
        "$(curl_quote "Authorization: Bearer $token")" | vcurl -K - >/dev/null
}
check "Matrix password login through MAS (@$(conf ADMIN_LOCALPART):$MATRIX)" matrix_login

step "SwitchBoardChat"
check "scripts/install.sh --check (bridge ready, .env, admin token, port 3443)" "$(SBCHAT_DIR)/scripts/install.sh" --check
check "the bridge logged in as @$(conf BOT_LOCALPART):$MATRIX" sh -c "docker logs sb-chat 2>&1 | grep -q 'The client is ready'"

if [ -n "$(conf WP_HOST)" ]; then
    WPH=$(conf WP_HOST)
    step "WordPress with WP Chat (https://$WPH)"
    check "container sbwp is running" container_running sbwp
    check "https://$WPH answers" code_is 200 "https://$WPH/"
    check "its pages carry the WP Chat widget" body_has 'wp-chat' "https://$WPH/"
    check "the widget points to https://$SBCHAT" body_has "$SBCHAT" "https://$WPH/"
    check "the bridge accepts web chats from https://$WPH (CORS)" sh -c \
        "docker run --rm --network web ${CA_ARGS[*]} $(conf CURL_IMAGE) -s -D - -o /dev/null --max-time 20 -X OPTIONS -H 'Origin: https://$WPH' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' https://$SBCHAT/web/session | grep -qi 'access-control-allow-origin: https://$WPH'"
fi

step "SwitchBoard ↔ SwitchBoardChat ↔ MAS"
STATUS=$(sb_wire_php "{\"action\":\"status\",\"admin_username\":\"$(conf SB_ADMIN_USER)\"}")
check "SwitchBoard's admin account holds the SBChat token" grep -q '"has_token":true' <<<"$STATUS"
check "SwitchBoard calls the SBChat API with it (list_macros)" grep -q '"sbchat_api":true' <<<"$STATUS"
check "SwitchBoard calls the MAS admin API (list users)" grep -q '"mas_api":true' <<<"$STATUS"
check "SwitchBoard finds the Matrix server name ($MATRIX)" grep -q "\"matrix_server_name\":\"$MATRIX\"" <<<"$STATUS"

if [ "$FUNCTIONAL" = 1 ]; then
    step "Functional: a web chat answered by a respondent"
    "$COMPOSER_DIR/tests/roundtrip.sh" --prefix "$PREFIX" || FAILS=$((FAILS + 1))
fi

step "Summary"
if [ "$FAILS" = 0 ]; then say "All checks passed."; exit 0; fi
say "$FAILS check(s) failed."
exit 1

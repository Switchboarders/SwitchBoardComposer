#!/usr/bin/env bash
# Installs or updates, in one run: SwitchBoard, SwitchBoardChat, Synapse and MAS (Matrix Authentication
# Service), wired together. The same command does both: the first run installs, later runs update
# (backup first, then each piece's own updater) and keep every secret.
#
#   ./install.sh --domain example.org --email admin@example.org            (first install)
#   ./install.sh                                                            (update, same machine)
#   ./install.sh --non-interactive --domain test --tls selfsigned           (tests, LAN)
#
# Host names: matrix.<domain> (Synapse, MAS under /auth/), sb.<domain> (SwitchBoard, web chat under
# /web/), sbchat.<domain> (the bridge). Their DNS must point to this machine for Let's Encrypt.
# Exit codes: 0 ok · 2 bad arguments · 3 missing dependency · 4 install/start failed · 5 verification failed
set -euo pipefail
umask 077

COMPOSER_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$COMPOSER_DIR/lib/common.sh"
COMPOSER_DIR=$(winpath "$COMPOSER_DIR")

if [ "$IS_WINDOWS" = 1 ]; then DEFAULT_PREFIX="$(winpath "$USERPROFILE")/switchboard"; else DEFAULT_PREFIX=/opt/switchboard; fi
PREFIX="${SBC_PREFIX:-$DEFAULT_PREFIX}"
OPT_DOMAIN="${SBC_DOMAIN:-}" OPT_MATRIX_HOST="" OPT_SB_HOST="" OPT_SBCHAT_HOST=""
OPT_EMAIL="${SBC_EMAIL:-}" OPT_TZ="${SBC_TZ:-}" OPT_TLS="${SBC_TLS:-}"
OPT_SB_REF="" OPT_SBCHAT_REF="" OPT_SB_REPO="" OPT_SBCHAT_REPO=""
OPT_WEB_ORIGINS="" OPT_WEB_CALL_CENTER="" OPT_HTTP_PORT="" OPT_HTTPS_PORT="" OPT_FRONT=""
INTERACTIVE=1 SKIP_VERIFY=0 NO_BACKUP=0

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options (first install; later runs reuse the saved answers unless given again):
  --prefix DIR             where everything is installed (default /opt/switchboard;
                           Windows: %USERPROFILE%\switchboard)                           [SBC_PREFIX]
  --domain NAME            base domain of the three host names                          [SBC_DOMAIN]
  --matrix-host NAME | --sb-host NAME | --sbchat-host NAME   override one host name
  --email ADDRESS          Let's Encrypt and SwitchBoard contact address                [SBC_EMAIL]
  --tz ZONE                time zone, e.g. America/Toronto (default: this machine's)     [SBC_TZ]
  --tls letsencrypt|selfsigned   certificates (default letsencrypt)                     [SBC_TLS]
  --behind-proxy           another reverse proxy (e.g. Nginx Proxy Manager) owns 80/443 and the
                           public certificates: it forwards the three names to
                           http://synapse-nginx:8080 on the Docker network "web". Implies
                           --tls selfsigned for the internal traffic; nothing is published on 80/443.
  --http-port N / --https-port N  host ports of the front proxy (default 80 / 443)
  --sb-ref REF / --sbchat-ref REF  branch or tag to follow (default main)
  --sb-repo URL / --sbchat-repo URL  git repositories (default: Switchboarders on GitHub)
  --web-origins LIST       websites allowed to embed the web chat (comma-separated)
  --web-call-center ID     call center that receives web chats
  --no-backup              update without the backup step (tests only)
  --no-verify              skip the final verification
  --non-interactive        never prompt (default when stdin is not a terminal)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=${2-}; shift 2 ;;
        --domain) OPT_DOMAIN=${2-}; shift 2 ;;
        --matrix-host) OPT_MATRIX_HOST=${2-}; shift 2 ;;
        --sb-host) OPT_SB_HOST=${2-}; shift 2 ;;
        --sbchat-host) OPT_SBCHAT_HOST=${2-}; shift 2 ;;
        --email) OPT_EMAIL=${2-}; shift 2 ;;
        --tz) OPT_TZ=${2-}; shift 2 ;;
        --tls) OPT_TLS=${2-}; shift 2 ;;
        --behind-proxy) OPT_FRONT=proxy; shift ;;
        --http-port) OPT_HTTP_PORT=${2-}; shift 2 ;;
        --https-port) OPT_HTTPS_PORT=${2-}; shift 2 ;;
        --sb-ref) OPT_SB_REF=${2-}; shift 2 ;;
        --sbchat-ref) OPT_SBCHAT_REF=${2-}; shift 2 ;;
        --sb-repo) OPT_SB_REPO=${2-}; shift 2 ;;
        --sbchat-repo) OPT_SBCHAT_REPO=${2-}; shift 2 ;;
        --web-origins) OPT_WEB_ORIGINS=${2-}; shift 2 ;;
        --web-call-center) OPT_WEB_CALL_CENTER=${2-}; shift 2 ;;
        --no-backup) NO_BACKUP=1; shift ;;
        --no-verify) SKIP_VERIFY=1; shift ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "$EXIT_ARGS" "unknown option: $1" ;;
    esac
done
[ -t 0 ] || INTERACTIVE=0

. "$COMPOSER_DIR/lib/matrix.sh"
. "$COMPOSER_DIR/lib/switchboard.sh"
. "$COMPOSER_DIR/lib/sbchat.sh"

# ---------------------------------------------------------------------------------------- preflight
step "Checking this machine"
need git; need openssl; need curl; need awk; need sed; need gzip
check_docker
mkdir -p "$PREFIX" 2>/dev/null || die "$EXIT_ARGS" "cannot create $PREFIX (use --prefix, or create it and give it to $(id -un))"
[ -w "$PREFIX" ] || die "$EXIT_ARGS" "$PREFIX is not writable by $(id -un)"
PREFIX=$(winpath "$(cd "$PREFIX" && pwd)")
CONF="$PREFIX/composer.env"
UPDATE=0
# composer.env may be pre-seeded (e.g. SB_SMTP_* before the first install): an installation exists
# once the host names are in it
[ -n "$(env_get "$CONF" MATRIX_HOST)" ] && UPDATE=1
say "$( [ "$UPDATE" = 1 ] && echo "Existing installation in $PREFIX: updating" || echo "New installation in $PREFIX")"

# ---------------------------------------------------------------------------------------- settings
ask() { # var text
    [ "$INTERACTIVE" = 1 ] || return 0
    local v; read -r -p "$2: " v; printf -v "$1" '%s' "$v"
}
host_ok() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }

[ -n "$OPT_DOMAIN" ] || [ -n "$(conf MATRIX_HOST)" ] || ask OPT_DOMAIN "Base domain (matrix.<domain>, sb.<domain>, sbchat.<domain>)"
OPT_DOMAIN=$(printf '%s' "$OPT_DOMAIN" | tr 'A-Z' 'a-z')
if [ -n "$OPT_DOMAIN" ]; then
    : "${OPT_MATRIX_HOST:=matrix.$OPT_DOMAIN}" "${OPT_SB_HOST:=sb.$OPT_DOMAIN}" "${OPT_SBCHAT_HOST:=sbchat.$OPT_DOMAIN}"
fi
for pair in MATRIX_HOST:"$OPT_MATRIX_HOST" SB_HOST:"$OPT_SB_HOST" SBCHAT_HOST:"$OPT_SBCHAT_HOST"; do
    key=${pair%%:*}; val=${pair#*:}
    [ -n "$val" ] || val=$(conf "$key")
    [ -n "$val" ] || die "$EXIT_ARGS" "--domain is required on the first install"
    host_ok "$val" || die "$EXIT_ARGS" "$key: « $val » is not a valid host name"
    env_set "$CONF" "$key" "$val"
done

[ -n "$OPT_FRONT" ] || OPT_FRONT=$(conf FRONT)
[ -n "$OPT_FRONT" ] || OPT_FRONT=direct
env_set "$CONF" FRONT "$OPT_FRONT"
if [ "$OPT_FRONT" = proxy ]; then
    # Public TLS is the upstream proxy's job; our own certificates only serve container-to-container traffic
    OPT_TLS=selfsigned
    : "${OPT_HTTP_PORT:=$(conf HTTP_PORT)}" "${OPT_HTTPS_PORT:=$(conf HTTPS_PORT)}"
    [ -n "$OPT_HTTP_PORT" ] && [ "$OPT_HTTP_PORT" != 80 ] || OPT_HTTP_PORT=18480
    [ -n "$OPT_HTTPS_PORT" ] && [ "$OPT_HTTPS_PORT" != 443 ] || OPT_HTTPS_PORT=18443
fi
[ -n "$OPT_TLS" ] || OPT_TLS=$(conf TLS_MODE)
[ -n "$OPT_TLS" ] || OPT_TLS=letsencrypt
case "$OPT_TLS" in letsencrypt|selfsigned) ;; *) die "$EXIT_ARGS" "--tls must be letsencrypt or selfsigned" ;; esac
env_set "$CONF" TLS_MODE "$OPT_TLS"

[ -n "$OPT_EMAIL" ] || OPT_EMAIL=$(conf EMAIL)
[ -n "$OPT_EMAIL" ] || ask OPT_EMAIL "Contact email (Let's Encrypt, SwitchBoard)"
[ -n "$OPT_EMAIL" ] || { [ "$OPT_TLS" = selfsigned ] && OPT_EMAIL="admin@$(conf SB_HOST)"; }
[ -n "$OPT_EMAIL" ] || die "$EXIT_ARGS" "--email is required with Let's Encrypt"
[[ "$OPT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "$EXIT_ARGS" "--email is not an email address"
env_set "$CONF" EMAIL "$OPT_EMAIL"

host_tz() {
    local tz=""
    [ -L /etc/localtime ] && tz=$(readlink /etc/localtime | sed -n 's|.*zoneinfo/||p')
    [ -n "$tz" ] || tz=$(cat /etc/timezone 2>/dev/null || true)
    printf '%s' "${tz:-America/Toronto}"
}
[ -n "$OPT_TZ" ] || OPT_TZ=$(conf TZ)
[ -n "$OPT_TZ" ] || OPT_TZ=$(host_tz)
[[ "$OPT_TZ" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die "$EXIT_ARGS" "--tz must look like America/Toronto"
env_set "$CONF" TZ "$OPT_TZ"

set_or_default() { # key option default
    if [ -n "$2" ]; then env_set "$CONF" "$1" "$2"; else env_default "$CONF" "$1" "$3"; fi
}
set_or_default HTTP_PORT "$OPT_HTTP_PORT" 80
set_or_default HTTPS_PORT "$OPT_HTTPS_PORT" 443
set_or_default SB_REPO "$OPT_SB_REPO" https://github.com/Switchboarders/SwitchBoard.git
set_or_default SB_REF "$OPT_SB_REF" main
set_or_default SBCHAT_REPO "$OPT_SBCHAT_REPO" https://github.com/Switchboarders/SwitchBoardChat.git
set_or_default SBCHAT_REF "$OPT_SBCHAT_REF" main
[ -z "$OPT_WEB_ORIGINS" ] || { safe_value --web-origins "$OPT_WEB_ORIGINS"; env_set "$CONF" WEB_ORIGINS "$OPT_WEB_ORIGINS"; }
[ -z "$OPT_WEB_CALL_CENTER" ] || { [[ "$OPT_WEB_CALL_CENTER" =~ ^[0-9]+$ ]] || die "$EXIT_ARGS" "--web-call-center must be a number"
                                   env_set "$CONF" WEB_CALL_CENTER_ID "$OPT_WEB_CALL_CENTER"; }

# Generated once, never rotated by a re-run (changing them would lock out accounts or break sessions)
env_default "$CONF" BOT_LOCALPART sms
env_default "$CONF" ADMIN_LOCALPART admin
env_default "$CONF" SB_ADMIN_USER admin
env_default "$CONF" BOT_PASSWORD "$(rand_password)"
env_default "$CONF" ADMIN_PASSWORD "$(rand_password)"
env_default "$CONF" SB_ADMIN_PASSWORD "$(rand_password)"
env_default "$CONF" MAS_DB_PASSWORD "$(rand_hex 24)"
env_default "$CONF" MAS_SYNAPSE_SECRET "$(rand_hex 32)"
env_default "$CONF" MAS_ADMIN_CLIENT_ID "$(rand_ulid)"
env_default "$CONF" MAS_ADMIN_CLIENT_SECRET "$(rand_hex 32)"
env_default "$CONF" SYNAPSE_REGISTRATION_SECRET "$(rand_hex 32)"
env_default "$CONF" SYNAPSE_MACAROON_SECRET "$(rand_hex 32)"
env_default "$CONF" SYNAPSE_FORM_SECRET "$(rand_hex 32)"
chmod 600 "$CONF"

# ---------------------------------------------------------------------------------------- backup
if [ "$UPDATE" = 1 ] && [ "$NO_BACKUP" = 0 ]; then
    BACKUP="$PREFIX/backups/$(date +%Y%m%d-%H%M%S)"
    step "Backup before updating: $BACKUP"
    mkdir -p "$BACKUP"; chmod 700 "$PREFIX/backups" "$BACKUP"
    cp -p "$CONF" "$BACKUP/composer.env"
    sb_backup "$BACKUP"
    if container_running masdb; then
        docker exec masdb pg_dump -U mas -d mas | gzip > "$BACKUP/mas-db.sql.gz" || die "$EXIT_START" "MAS database backup failed"
    fi
    if container_running synapse; then
        # sqlite online backup, from inside the container (the files belong to Synapse's uid)
        docker exec synapse python -c "import sqlite3; s=sqlite3.connect('/data/homeserver.db'); d=sqlite3.connect('/data/backup.db'); s.backup(d); d.close()" \
            && docker cp synapse:/data/backup.db - | gzip > "$BACKUP/synapse-db.tar.gz" \
            && docker exec synapse rm -f /data/backup.db || die "$EXIT_START" "Synapse database backup failed"
    fi
    sbchat_backup "$BACKUP"
    say "Backup done"
fi

# ---------------------------------------------------------------------------------------- sources
fetch_repo() { # dir url ref (branch, tag or commit)
    local dir=$1 url=$2 ref=$3
    if [ ! -d "$dir/.git" ]; then
        # public source code: normal permissions (containers read parts of it as non-root users)
        ( umask 022; git clone -q -c core.autocrlf=false -c core.eol=lf "$url" "$dir" ) || die "$EXIT_START" "git clone $url failed"
    elif [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
        die "$EXIT_START" "$dir has local modifications: commit or discard them (git -C $dir status), then re-run"
    fi
    git -C "$dir" fetch -q --tags origin || die "$EXIT_START" "git fetch in $dir failed"
    if git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$ref" >/dev/null; then
        # a branch: follow it (fast-forward only: local commits are never thrown away)
        if git -C "$dir" rev-parse -q --verify "refs/heads/$ref" >/dev/null \
           && ! git -C "$dir" merge-base --is-ancestor "refs/heads/$ref" "origin/$ref"; then
            die "$EXIT_START" "$dir: local branch $ref has commits that are not on origin/$ref"
        fi
        ( umask 022; git -C "$dir" checkout -q -B "$ref" "origin/$ref" ) || die "$EXIT_START" "cannot check out $ref in $dir"
    elif git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
        # a tag or a commit: pinned
        ( umask 022; git -C "$dir" -c advice.detachedHead=false checkout -q "$ref" ) || die "$EXIT_START" "cannot check out $ref in $dir"
    else
        die "$EXIT_ARGS" "$ref is not a branch, tag or commit of $url"
    fi
}
step "Fetching SwitchBoard ($(conf SB_REF)) and SwitchBoardChat ($(conf SBCHAT_REF))"
fetch_repo "$(SB_DIR)" "$(conf SB_REPO)" "$(conf SB_REF)"
fetch_repo "$(SBCHAT_DIR)" "$(conf SBCHAT_REPO)" "$(conf SBCHAT_REF)"

# ---------------------------------------------------------------------------------------- install
docker network inspect web >/dev/null 2>&1 || docker network create web >/dev/null
# Certificates first (self-signed: the CA is handed to SwitchBoard and the bridge)
[ "$(conf TLS_MODE)" = selfsigned ] && { matrix_prepare_dirs; tls_selfsigned; }
switchboard_up
[ "$UPDATE" = 1 ] && switchboard_update_app
matrix_up
sbchat_up
switchboard_first_admin
switchboard_wire

# ---------------------------------------------------------------------------------------- summary
CREDS="$PREFIX/credentials.txt"
( umask 077; cat > "$CREDS" <<EOF
SwitchBoard      https://$(conf SB_HOST)$SB_PORTAL
                 user $(conf SB_ADMIN_USER)   password $(conf SB_ADMIN_PASSWORD)
Matrix (Element) https://$(conf MATRIX_HOST)
                 user @$(conf ADMIN_LOCALPART):$(conf MATRIX_HOST)   password $(conf ADMIN_PASSWORD)
                 (MAS admin; change the password at https://$(conf MATRIX_HOST)/auth/account/)
Bridge bot       @$(conf BOT_LOCALPART):$(conf MATRIX_HOST)  (password in composer.env, do not log in with it)
voip.ms SMS URL  https://$(conf SBCHAT_HOST)/voip_api  (SwitchBoard shows the full URL per call center)
EOF
)

rc=0
if [ "$SKIP_VERIFY" = 0 ]; then
    "$COMPOSER_DIR/verify.sh" --prefix "$PREFIX" || rc=$EXIT_CHECK
fi
step "Done"
say "Installed in $PREFIX. Addresses and first passwords: $CREDS (mode 600)."
if [ "$rc" != 0 ]; then
    say "Verification FAILED (see above)."
    [ -n "${BACKUP:-}" ] && say "The backup taken before this update is in $BACKUP."
fi
exit "$rc"

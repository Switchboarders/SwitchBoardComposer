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
OPT_WP_HOST="" OPT_WP_TITLE="" OPT_WP_PRIVACY="" OPT_WPCHAT_REPO="" OPT_WPCHAT_REF=""
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
  --wordpress-host NAME    also install a WordPress site with the WP Chat widget, connected to this chat
                           (https://github.com/Switchboarders/wp_chat); its address is allowed for web chats
  --wordpress-title TEXT   that site's title (default "Clavardage")
  --privacy-contact TEXT   privacy officer shown by the widget (default: the --email address)
  --wpchat-repo URL / --wpchat-ref REF   where WP Chat comes from (default: Switchboarders on GitHub, main)
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
        --wordpress-host) OPT_WP_HOST=$(printf '%s' "${2-}" | tr 'A-Z' 'a-z'); shift 2 ;;
        --wordpress-title) OPT_WP_TITLE=${2-}; shift 2 ;;
        --privacy-contact) OPT_WP_PRIVACY=${2-}; shift 2 ;;
        --wpchat-repo) OPT_WPCHAT_REPO=${2-}; shift 2 ;;
        --wpchat-ref) OPT_WPCHAT_REF=${2-}; shift 2 ;;
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
. "$COMPOSER_DIR/lib/wordpress.sh"

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

# One run at a time (a second one would rebuild and restart the same containers in the middle of the first)
LOCK="$PREFIX/.install.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    other=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        die "$EXIT_ARGS" "install.sh is already running for $PREFIX (process $other): wait for it to finish"
    fi
    say "Removing the lock of an earlier run that was interrupted"
    rm -rf "$LOCK"; mkdir "$LOCK" || die "$EXIT_ARGS" "cannot create $LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" "${CONF_NEW:-}"' EXIT

# The containers have fixed names: they belong to exactly one installation per Docker host
for c in synapse mas masdb sb-chat sb_php-fpm; do
    dir=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$c" 2>/dev/null || true)
    [ -n "$dir" ] || continue
    case "$(winpath "$dir")/" in
        "$PREFIX"/*) ;;
        *) die "$EXIT_ARGS" "the container $c belongs to another installation ($dir): this Docker host runs one installation; use --prefix ${dir%/*} to update that one" ;;
    esac
done
if [ "$UPDATE" = 0 ]; then
    # composer.env lost while the data still exists: new secrets would lock MAS out of its database and make
    # SwitchBoard's encrypted secrets unreadable
    for d in "$PREFIX/matrix/postgres" "$PREFIX/matrix/synapse" "$PREFIX/switchboard/Docker/db_data" "$PREFIX/switchboardchat/sb-chat"; do
        if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
            die "$EXIT_ARGS" "$PREFIX already holds an installation's data ($d) but $CONF is missing or empty. Restore composer.env from a backup ($PREFIX/backups/*/composer.env) instead of starting over: new secrets would lock you out of the existing data"
        fi
    done
fi

# ---------------------------------------------------------------------------------------- settings
# First install: the answers go to a temporary file that becomes composer.env only once every check has
# passed (a refused option must not leave a half-configured installation behind)
CONF_NEW=""
if [ "$UPDATE" = 0 ]; then
    CONF_FINAL=$CONF; CONF_NEW="$CONF.new"; rm -f "$CONF_NEW"
    [ -f "$CONF" ] && cp -p "$CONF" "$CONF_NEW"   # keeps pre-seeded values (e.g. MAIL_OAUTH_*)
    CONF=$CONF_NEW
fi
ask() { # var text
    [ "$INTERACTIVE" = 1 ] || return 0
    local v; read -r -p "$2: " v; printf -v "$1" '%s' "$v"
}
host_ok() { # a DNS name with at least one dot, not an IP address
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && ! [[ "$1" =~ ^[0-9.]+$ ]]
}

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
for p in "$OPT_HTTP_PORT" "$OPT_HTTPS_PORT"; do
    [ -z "$p" ] || { [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; } || die "$EXIT_ARGS" "--http-port/--https-port: « $p » is not a port number (1-65535)"
done
set_or_default HTTP_PORT "$OPT_HTTP_PORT" 80
set_or_default HTTPS_PORT "$OPT_HTTPS_PORT" 443
[ "$(conf HTTP_PORT)" != "$(conf HTTPS_PORT)" ] || die "$EXIT_ARGS" "--http-port and --https-port must differ"
set_or_default SB_REPO "$OPT_SB_REPO" https://github.com/Switchboarders/SwitchBoard.git
set_or_default SB_REF "$OPT_SB_REF" main
set_or_default SBCHAT_REPO "$OPT_SBCHAT_REPO" https://github.com/Switchboarders/SwitchBoardChat.git
set_or_default SBCHAT_REF "$OPT_SBCHAT_REF" main
[ -z "$OPT_WEB_ORIGINS" ] || { safe_value --web-origins "$OPT_WEB_ORIGINS"; env_set "$CONF" WEB_ORIGINS "$OPT_WEB_ORIGINS"; }
[ -z "$OPT_WEB_CALL_CENTER" ] || { [[ "$OPT_WEB_CALL_CENTER" =~ ^[0-9]+$ ]] || die "$EXIT_ARGS" "--web-call-center must be a number"
                                   env_set "$CONF" WEB_CALL_CENTER_ID "$OPT_WEB_CALL_CENTER"; }

# Optional WordPress site with WP Chat
if [ -n "$OPT_WP_HOST" ]; then
    host_ok "$OPT_WP_HOST" || die "$EXIT_ARGS" "--wordpress-host: « $OPT_WP_HOST » is not a valid host name"
    env_set "$CONF" WP_HOST "$OPT_WP_HOST"
fi
if [ -n "$(conf WP_HOST)" ]; then
    set_or_default WP_TITLE "$OPT_WP_TITLE" "Clavardage"
    set_or_default WP_PRIVACY_OFFICER "$OPT_WP_PRIVACY" "$(conf EMAIL)"
    set_or_default WPCHAT_REPO "$OPT_WPCHAT_REPO" https://github.com/Switchboarders/wp_chat.git
    set_or_default WPCHAT_REF "$OPT_WPCHAT_REF" main
    env_default "$CONF" WP_ADMIN_PASSWORD "$(rand_password)"
    env_default "$CONF" WP_DB_PASSWORD "$(rand_hex 20)"
    env_default "$CONF" WP_DB_ROOT_PASSWORD "$(rand_hex 20)"
    # the site may open web chats: its address joins the allowed origins
    case ",$(conf WEB_ORIGINS)," in
        *",https://$(conf WP_HOST),"*) ;;
        *) env_set "$CONF" WEB_ORIGINS "$(conf WEB_ORIGINS | sed 's/[^,]$/&,/')https://$(conf WP_HOST)" ;;
    esac
fi

# Every name is a different site
names="$(conf MATRIX_HOST) $(conf SB_HOST) $(conf SBCHAT_HOST) $(conf WP_HOST)"
dup=$(printf '%s\n' $names | sort | uniq -d | head -n1)
[ -z "$dup" ] || die "$EXIT_ARGS" "the host name $dup is used twice: Matrix, SwitchBoard, SBChat (and WordPress) need one name each"

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

# Ports of the front proxy: checked before anything is installed or started
ports_free
if [ -n "$CONF_NEW" ]; then
    mv "$CONF_NEW" "$CONF_FINAL"; chmod 600 "$CONF_FINAL"; CONF=$CONF_FINAL; CONF_NEW=""
fi

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
# Fixes the composer needs that are not (yet) in a repository: patches/<repo>/*.patch, applied after
# each checkout and removed before the next update (so the "local modifications" check and the
# fast-forward still see a clean tree). A patch that no longer applies (fixed upstream, or the file
# changed) is skipped with a note.
patches_of() { ls "$COMPOSER_DIR/patches/$1/"*.patch 2>/dev/null || true; }
unapply_patches() { # dir name
    local p
    for p in $(patches_of "$2"); do
        git -C "$1" apply -R --check "$p" 2>/dev/null && git -C "$1" apply -R "$p"
    done
    return 0
}
apply_patches() { # dir name
    local p
    for p in $(patches_of "$2"); do
        if git -C "$1" apply --check "$p" 2>/dev/null; then
            ( umask 022; git -C "$1" apply "$p" ) && say "Applied patch $(basename "$p")"
        elif git -C "$1" apply -R --check "$p" 2>/dev/null; then
            :   # already applied
        else
            say "Note: patch $(basename "$p") no longer applies (fixed upstream?): skipped"
        fi
    done
}

fetch_repo() { # dir url ref (branch, tag or commit) name
    local dir=$1 url=$2 ref=$3
    [ -d "$dir/.git" ] && unapply_patches "$dir" "$4"
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
    apply_patches "$dir" "$4"
}
step "Fetching SwitchBoard ($(conf SB_REF)) and SwitchBoardChat ($(conf SBCHAT_REF))"
fetch_repo "$(SB_DIR)" "$(conf SB_REPO)" "$(conf SB_REF)" switchboard
fetch_repo "$(SBCHAT_DIR)" "$(conf SBCHAT_REPO)" "$(conf SBCHAT_REF)" switchboardchat

# ---------------------------------------------------------------------------------------- install
docker network inspect web >/dev/null 2>&1 || docker network create web >/dev/null
# Certificates first (self-signed: the CA is handed to SwitchBoard and the bridge)
[ "$(conf TLS_MODE)" = selfsigned ] && { matrix_prepare_dirs; tls_selfsigned; }
mail_oauth_migrate
switchboard_up
[ "$UPDATE" = 1 ] && switchboard_update_app
matrix_up
sbchat_up
switchboard_first_admin
switchboard_wire
switchboard_mail_oauth
wordpress_up

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
$( [ -n "$(conf WP_HOST)" ] && printf 'WordPress        https://%s/wp-admin   user admin   password %s\n' "$(conf WP_HOST)" "$(conf WP_ADMIN_PASSWORD)" )
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

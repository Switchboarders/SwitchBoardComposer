# Synapse + MAS + front nginx: configuration, certificates, accounts. Sourced by install.sh.
# Expects: COMPOSER_DIR, PREFIX, CONF (composer.env) and the helpers of lib/common.sh.
# Configs are rendered from composer.env on every run (secrets in composer.env never change), so an
# update re-applies the same settings and a hand edit in $PREFIX/matrix is overwritten: change
# composer.env or the templates instead.

MATRIX_DIR() { printf '%s/matrix' "$PREFIX"; }
mx_compose() { (cd "$(MATRIX_DIR)" && docker compose "$@"); }
conf() { local v; v=$(env_get "$CONF" "$1"); [ -n "$v" ] || v=$(env_get "$COMPOSER_DIR/versions.env" "$1"); printf "%s" "$v"; }

# Write stdin to a file of a bind-mounted directory as root inside a container (the directory may
# belong to another uid, e.g. Synapse's 991), with the given owner and mode.
write_as_root() { # image dir file owner mode
    docker run --rm -i -v "$2:/w" --entrypoint sh "$1" -c "cat > '/w/$3.tmp' && chown $4 '/w/$3.tmp' && chmod $5 '/w/$3.tmp' && mv '/w/$3.tmp' '/w/$3'"
}

matrix_prepare_dirs() {
    local d; d=$(MATRIX_DIR)
    mkdir -p "$d/synapse" "$d/mas" "$d/postgres" "$d/nginx" "$d/letsencrypt" "$d/certbot-www"
    chmod 700 "$d/mas"
    cp "$COMPOSER_DIR/matrix/docker-compose.yml" "$d/docker-compose.yml"
    ( umask 077; cat > "$d/.env" <<EOF
# Written by install.sh from $CONF: do not edit (it is rewritten on every run).
SYNAPSE_IMAGE=$(conf SYNAPSE_IMAGE)
MAS_IMAGE=$(conf MAS_IMAGE)
POSTGRES_IMAGE=$(conf POSTGRES_IMAGE)
NGINX_IMAGE=$(conf NGINX_IMAGE)
CERTBOT_IMAGE=$(conf CERTBOT_IMAGE)
MAS_DB_PASSWORD=$(conf MAS_DB_PASSWORD)
MATRIX_HOST=$(conf MATRIX_HOST)
SB_HOST=$(conf SB_HOST)
SBCHAT_HOST=$(conf SBCHAT_HOST)
HTTP_PORT=$(conf HTTP_PORT)
HTTPS_PORT=$(conf HTTPS_PORT)
COMPOSE_PROFILES=$( [ "$(conf TLS_MODE)" = letsencrypt ] && echo letsencrypt )
EOF
    )
}

# ------------------------------------------------------------------------------------------ Synapse
synapse_render() {
    local d host image
    d=$(MATRIX_DIR)/synapse; host=$(conf MATRIX_HOST); image=$(conf SYNAPSE_IMAGE)
    if [ ! -f "$d/$host.signing.key" ]; then
        say "Generating Synapse's signing key and log configuration"
        docker run --rm -v "$d:/data" -e SYNAPSE_SERVER_NAME="$host" -e SYNAPSE_REPORT_STATS=no \
            "$image" generate >/dev/null
    fi
    write_as_root "$image" "$d" homeserver.yaml 991:991 600 <<EOF
# Rendered by sbcomposer install.sh: edits are overwritten. Settings follow SwitchBoardChat's
# docs/homeserver.md.
server_name: "$host"
public_baseurl: "https://$host/"
pid_file: /data/homeserver.pid
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false
database:
  name: sqlite3
  args:
    database: /data/homeserver.db
log_config: "/data/$host.log.config"
media_store_path: /data/media_store
signing_key_path: "/data/$host.signing.key"
report_stats: false
registration_shared_secret: "$(conf SYNAPSE_REGISTRATION_SECRET)"
macaroon_secret_key: "$(conf SYNAPSE_MACAROON_SECRET)"
form_secret: "$(conf SYNAPSE_FORM_SECRET)"
trusted_key_servers:
  - server_name: "matrix.org"
suppress_key_server_warning: true

# Authentication is MAS's job
matrix_authentication_service:
  enabled: true
  endpoint: http://mas:8080/
  secret: "$(conf MAS_SYNAPSE_SECRET)"

# Respondents are invited to every new room and join at once (local users only)
auto_accept_invites:
  enabled: true
  only_for_direct_messages: false
  only_from_local_users: true

# Respondents look each other up; nobody else should be on this server
user_directory:
  search_all_users: false
EOF
}

# ------------------------------------------------------------------------------------------ MAS
mas_render() {
    local d host image
    d=$(MATRIX_DIR)/mas; host=$(conf MATRIX_HOST); image=$(conf MAS_IMAGE)
    if [ ! -s "$d/secrets.yaml" ]; then
        say "Generating MAS's signing keys"
        # Only the "secrets:" block of a generated config is kept (encryption key + signing keys)
        ( umask 077; docker run --rm "$image" config generate 2>/dev/null \
            | awk '/^secrets:/ { on = 1; print; next } on && /^[^ ]/ { exit } on { print }' > "$d/secrets.yaml.tmp" )
        grep -q '^  encryption:' "$d/secrets.yaml.tmp" || die "$EXIT_START" "mas-cli config generate gave no secrets block"
        mv "$d/secrets.yaml.tmp" "$d/secrets.yaml"
    fi
    chmod 644 "$d/secrets.yaml"   # read by MAS's non-root user; $d itself is 0700
    local email recovery=true
    email=$(mas_email_block)
    if [ -z "$email" ]; then
        recovery=false   # no mail account in SwitchBoard: MAS cannot send recovery emails
        email=$(printf 'email:\n  from: %s\n  reply_to: %s\n  transport: blackhole\n' \
            "'\"Authentication Service\" <noreply@$host>'" "'\"Authentication Service\" <noreply@$host>'")
    fi
    ( umask 077; cat > "$d/config.yaml.tmp" <<EOF
# Rendered by sbcomposer install.sh: edits are overwritten. Signing keys are in secrets.yaml.
http:
  public_base: https://$host/auth/
  issuer: https://$host/auth/
  trusted_proxies: ['192.168.0.0/16', '172.16.0.0/12', '10.0.0.0/8', '127.0.0.0/8', 'fd00::/8', '::1/128']
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
        # Admin API (SwitchBoard manages Matrix accounts with it, through https://<matrix host>/auth/).
        # It only answers tokens with the urn:mas:admin scope, which MAS grants to admin clients.
        - name: adminapi
      binds:
        - address: '[::]:8080'
    - name: internal
      resources:
        - name: health
      binds:
        - address: '[::]:8081'
database:
  uri: postgresql://mas:$(conf MAS_DB_PASSWORD)@masdb/mas
matrix:
  kind: synapse
  homeserver: $host
  secret: "$(conf MAS_SYNAPSE_SECRET)"
  endpoint: http://synapse:8008/
clients:
  - client_id: $(conf MAS_ADMIN_CLIENT_ID)
    client_auth_method: client_secret_basic
    client_secret: "$(conf MAS_ADMIN_CLIENT_SECRET)"
policy:
  data:
    admin_clients:
      - $(conf MAS_ADMIN_CLIENT_ID)
passwords:
  enabled: true
  minimum_complexity: 3
  schemes:
    - version: 1
      algorithm: argon2id
account:
  password_registration_enabled: false
  password_change_allowed: true
  password_recovery_enabled: $recovery
  email_change_allowed: true
  displayname_change_allowed: true
  account_deactivation_allowed: false
  login_with_email_allowed: false
$email
EOF
    )
    chmod 644 "$d/config.yaml.tmp"
    mv "$d/config.yaml.tmp" "$d/config.yaml"
    docker run --rm -v "$d/config.yaml:/config/config.yaml:ro" -v "$d/secrets.yaml:/config/secrets.yaml:ro" -e MAS_CONFIG=/config/config.yaml:/config/secrets.yaml "$image" config check >/dev/null 2>&1 \
        || { docker run --rm -v "$d/config.yaml:/config/config.yaml:ro" -v "$d/secrets.yaml:/config/secrets.yaml:ro" -e MAS_CONFIG=/config/config.yaml:/config/secrets.yaml "$image" config check 2>&1 | tail -n 5 >&2
             die "$EXIT_START" "MAS refused its configuration"; }
}

# MAS sends its mail through SwitchBoard's relay (same logic as SwitchBoard's utils/connect-mas-mail.sh),
# when SwitchBoard has a mail account configured. Prints nothing otherwise.
mas_email_block() {
    container_running sb_mail_relay || return 0
    local from
    from=$(docker exec sb_mail_relay awk '$1=="from"{print $2}' /etc/msmtprc 2>/dev/null || true)
    [ -n "$from" ] || return 0
    printf 'email:\n  from: '"'"'"Authentication Service" <%s>'"'"'\n  reply_to: '"'"'"Authentication Service" <%s>'"'"'\n  transport: smtp\n  mode: plain\n  hostname: sb_mail_relay\n  port: 2525\n' "$from" "$from"
}

mas_cli() { docker exec mas mas-cli "$@"; }   # MAS_CONFIG is set in the container

# curl inside the "web" network, options (credentials, body) read from stdin as a curl config file, so
# no secret ever appears in a process list. Usage: printf 'url = "..."\n...' | web_curl [args]
web_curl() { docker run --rm -i --network web "$(conf CURL_IMAGE)" -s --max-time 30 -K - "$@"; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
curl_quote() { printf '"%s"' "$(json_escape "$1")"; }

# Access token for MAS's admin API (client credentials of the composer's admin client)
mas_admin_token() {
    printf 'url = "http://mas:8080/oauth2/token"\nuser = %s\ndata = "grant_type=client_credentials&scope=urn:mas:admin"\n' \
        "$(curl_quote "$(conf MAS_ADMIN_CLIENT_ID):$(conf MAS_ADMIN_CLIENT_SECRET)")" \
        | web_curl | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}
# mas_api TOKEN METHOD PATH [JSON]: prints the body, then the HTTP code on the last line
mas_api() {
    { printf 'url = "http://mas:8080/api/admin/v1/%s"\nrequest = "%s"\nheader = %s\nheader = "Content-Type: application/json"\n' \
          "$3" "$2" "$(curl_quote "Authorization: Bearer $1")"
      [ -z "${4:-}" ] || printf 'data = %s\n' "$(curl_quote "$4")"
    } | web_curl -w '\n%{http_code}'
}
mas_user_id() { # token localpart -> MAS user id (ULID), empty if absent
    mas_api "$1" GET "users/by-username/$2" | sed -n 's/.*"data":{"type":"user","id":"\([0-9A-Z]*\)".*/\1/p'
}

# Creates the user if missing (password set on creation only, never reset) and makes it an admin.
mas_ensure_user() { # localpart password admin(0|1)
    local user=$1 pass=$2 admin=$3 token id out
    token=$(mas_admin_token)
    [ -n "$token" ] || die "$EXIT_START" "could not get a MAS admin token (admin client misconfigured?)"
    id=$(mas_user_id "$token" "$user")
    if [ -n "$id" ]; then
        say "MAS user $user already exists"
    else
        out=$(mas_api "$token" POST users "{\"username\":\"$user\"}")
        [ "$(tail -n1 <<<"$out")" = 201 ] || die "$EXIT_START" "could not create the MAS user $user (HTTP $(tail -n1 <<<"$out"))"
        id=$(mas_user_id "$token" "$user")
        out=$(mas_api "$token" POST "users/$id/set-password" "{\"password\":\"$(json_escape "$pass")\",\"skip_password_check\":true}")
        [ "$(tail -n1 <<<"$out")" = 204 ] || die "$EXIT_START" "could not set the password of $user (HTTP $(tail -n1 <<<"$out"))"
        say "Created MAS user $user"
    fi
    if [ "$admin" = 1 ]; then
        out=$(mas_api "$token" POST "users/$id/set-admin" '{"admin":true}')
        [ "$(tail -n1 <<<"$out")" = 200 ] || die "$EXIT_START" "could not make $user an admin (HTTP $(tail -n1 <<<"$out"))"
    fi
}

# ------------------------------------------------------------------------------------------ TLS
# Self-signed mode: a local CA (kept, so clients that trust it keep working) and one certificate for
# the three host names, written where certbot would put it.
tls_selfsigned() {
    local d live ca host sb sbchat
    d=$(MATRIX_DIR); host=$(conf MATRIX_HOST); sb=$(conf SB_HOST); sbchat=$(conf SBCHAT_HOST)
    ca="$d/ca"; live="$d/letsencrypt/live/$host"
    mkdir -p "$ca" "$live"; chmod 700 "$ca"
    if [ ! -f "$ca/ca.pem" ]; then
        openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -subj "/CN=SwitchBoard local CA" \
            -keyout "$ca/ca.key" -out "$ca/ca.pem" 2>/dev/null
        chmod 600 "$ca/ca.key"
    fi
    chmod 644 "$ca/ca.pem"   # public; read by non-root users in the curl and SwitchBoard containers
    if [ ! -f "$live/fullchain.pem" ] || ! openssl x509 -checkend 2592000 -noout -in "$live/fullchain.pem" >/dev/null 2>&1 \
       || ! openssl x509 -noout -ext subjectAltName -in "$live/fullchain.pem" 2>/dev/null | grep -q "DNS:$sbchat"; then
        openssl req -newkey rsa:2048 -nodes -subj "/CN=$host" -keyout "$live/privkey.pem" -out "$ca/leaf.csr" 2>/dev/null
        printf 'subjectAltName=DNS:%s,DNS:%s,DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" "$sb" "$sbchat" > "$ca/leaf.ext"
        openssl x509 -req -in "$ca/leaf.csr" -CA "$ca/ca.pem" -CAkey "$ca/ca.key" -CAcreateserial -days 825 -sha256 \
            -extfile "$ca/leaf.ext" -out "$live/cert.pem" 2>/dev/null
        cat "$live/cert.pem" "$ca/ca.pem" > "$live/fullchain.pem"
        chmod 644 "$live/privkey.pem"   # read by nginx in its container; $d/letsencrypt is not world-browsable
        say "Self-signed certificate for $host, $sb, $sbchat (CA: $ca/ca.pem)"
    fi
}

nginx_render() { # [primer]
    local d; d=$(MATRIX_DIR)
    if [ "${1:-}" = primer ]; then
        # Port 80 only, for the first Let's Encrypt challenge (no certificate exists yet)
        cat > "$d/nginx/default.conf" <<EOF
server {
    listen 80;
    server_name $(conf MATRIX_HOST) $(conf SB_HOST) $(conf SBCHAT_HOST);
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 503; }
}
EOF
    else
        sed -e "s/@MATRIX_HOST@/$(conf MATRIX_HOST)/g" -e "s/@SB_HOST@/$(conf SB_HOST)/g" \
            -e "s/@SBCHAT_HOST@/$(conf SBCHAT_HOST)/g" -e "s/@CERT@/$(conf MATRIX_HOST)/g" \
            "$COMPOSER_DIR/matrix/nginx.conf.tmpl" > "$d/nginx/default.conf"
    fi
}

tls_letsencrypt() {
    local d host; d=$(MATRIX_DIR); host=$(conf MATRIX_HOST)
    if [ ! -f "$d/letsencrypt/live/$host/fullchain.pem" ]; then
        say "Requesting a Let's Encrypt certificate (port 80 must reach this machine)"
        nginx_render primer
        mx_compose up -d nginx >&2
        docker run --rm -v "$d/letsencrypt:/etc/letsencrypt" -v "$d/certbot-www:/var/www/certbot" "$(conf CERTBOT_IMAGE)" \
            certonly --webroot -w /var/www/certbot --email "$(conf EMAIL)" --agree-tos --non-interactive \
            --keep-until-expiring --expand --cert-name "$host" -d "$host" -d "$(conf SB_HOST)" -d "$(conf SBCHAT_HOST)" >&2 \
            || die "$EXIT_START" "Let's Encrypt refused the certificate (DNS of the three names must point here)"
    fi
}

matrix_up() {
    step "Matrix: Synapse $(conf SYNAPSE_IMAGE | sed 's/.*://'), MAS $(conf MAS_IMAGE | sed 's/.*://')"
    matrix_prepare_dirs
    case "$(conf TLS_MODE)" in
        letsencrypt) tls_letsencrypt ;;
        *) tls_selfsigned ;;
    esac
    synapse_render
    mas_render
    nginx_render
    mx_compose pull -q >&2 2>/dev/null || true
    mx_compose up -d --remove-orphans >&2 || die "$EXIT_START" "docker compose up (matrix) failed"
    # nginx re-reads its configuration (it may have been running with the primer or an older one)
    docker exec synapse-nginx nginx -s reload >/dev/null 2>&1 || true
    wait_for 300 "Synapse" sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" synapse)" = healthy ]' \
        || die "$EXIT_START" "Synapse did not become healthy: docker logs synapse"
    wait_for 180 "MAS" docker run --rm --network web "$(conf CURL_IMAGE)" -fs --max-time 5 http://mas:8081/health \
        || die "$EXIT_START" "MAS did not become healthy: docker logs mas"
    mas_ensure_user "$(conf BOT_LOCALPART)" "$(conf BOT_PASSWORD)" 1
    mas_ensure_user "$(conf ADMIN_LOCALPART)" "$(conf ADMIN_PASSWORD)" 1
}

# SwitchBoard: install/update with its own Docker/up.sh (reverse-proxy mode, like production), first
# admin account, SBChat/MAS wiring. Sourced by install.sh and verify.sh.

SB_DIR() { printf '%s/switchboard' "$PREFIX"; }
SB_PORTAL=/SwitchBoard/SwitchBoard/src/managementportal.php
SB_SRC=/var/www/html/SwitchBoard/SwitchBoard/src

# sh script (stdin) run in a curl container on the "web" network: talks to the public host names
# through the front nginx (network aliases), so it works the same with Let's Encrypt or self-signed.
web_sh() { docker run --rm -i --network web --entrypoint sh "$(conf CURL_IMAGE)" -s; }

switchboard_up() {
    step "SwitchBoard ($(git -C "$(SB_DIR)" rev-parse --short HEAD))"
    local d; d="$(SB_DIR)/Docker"
    # The CA of self-signed mode is trusted by SwitchBoard for SBChat and MAS (SB_SBCHAT_CA_BUNDLE)
    if [ "$(conf TLS_MODE)" = selfsigned ] && [ -f "$(MATRIX_DIR)/ca/ca.pem" ]; then
        cp "$(MATRIX_DIR)/ca/ca.pem" "$d/certs/sbcomposer-ca.pem"
        chmod 644 "$d/certs/sbcomposer-ca.pem"
        [ -f "$d/.env" ] && env_set "$d/.env" SB_SBCHAT_CA_BUNDLE /etc/ssl/sbchat/sbcomposer-ca.pem
    fi
    (cd "$d" && SB_TZ="$(conf TZ)" ./up.sh --non-interactive --mode=reverse-proxy --host="$(conf SB_HOST)" \
        --email="$(conf EMAIL)" --tz="$(conf TZ)") >&2 || die "$EXIT_START" "SwitchBoard's up.sh failed"
    if [ "$(conf TLS_MODE)" = selfsigned ] && [ -f "$(MATRIX_DIR)/ca/ca.pem" ] \
       && [ "$(env_get "$d/.env" SB_SBCHAT_CA_BUNDLE)" != /etc/ssl/sbchat/sbcomposer-ca.pem ]; then
        # First install: .env did not exist before up.sh; set the CA and recreate php once
        env_set "$d/.env" SB_SBCHAT_CA_BUNDLE /etc/ssl/sbchat/sbcomposer-ca.pem
        (cd "$d" && docker compose up -d >&2)
    fi
}

# Updates SwitchBoard's application code with its own engine (src/miseajour.php: backup, migrations, swap)
switchboard_update_app() {
    step "SwitchBoard application update (src/miseajour.php)"
    docker exec -u www-data sb_php-fpm php "$SB_SRC/miseajour.php" >&2 \
        || die "$EXIT_START" "SwitchBoard's update failed (see above); the previous code is still running"
}

sb_portal_ready() {
    printf 'curl -sk --max-time 20 -o /dev/null -w "%%{http_code}" "https://%s%s"\n' "$(conf SB_HOST)" "$SB_PORTAL" \
        | web_sh | grep -qx 200
}

# Creates the first admin account through the form, as a person would (only when no account exists).
switchboard_first_admin() {
    wait_for 300 "SwitchBoard's portal" sb_portal_ready || die "$EXIT_START" "SwitchBoard's portal does not answer"
    local result
    result=$(web_sh <<EOF
U='https://$(conf SB_HOST)$SB_PORTAL'
curl -sk --max-time 30 -c /tmp/j -b /tmp/j "\$U" > /tmp/form.html
if ! grep -q createormodifyusername /tmp/form.html; then echo exists; exit 0; fi
CSRF=\$(grep -o "name='csrf_token' value='[^']*'" /tmp/form.html | head -n 1 | sed "s/.*value='//; s/'\$//")
cat > /tmp/cfg <<'CFG'
data-urlencode = "createormodifyusername=$(conf SB_ADMIN_USER)"
data-urlencode = "createormodifypassword=$(conf SB_ADMIN_PASSWORD)"
data-urlencode = "createormodifypasswordverification=$(conf SB_ADMIN_PASSWORD)"
CFG
curl -sk --max-time 30 -c /tmp/j -b /tmp/j -K /tmp/cfg --data-urlencode "csrf_token=\$CSRF" "\$U" > /tmp/after.html
grep -q 'page=logout' /tmp/after.html && echo created || echo failed
EOF
)
    case "$result" in
        created) say "Created SwitchBoard's first admin account ($(conf SB_ADMIN_USER))" ;;
        exists)  say "SwitchBoard already has its admin account" ;;
        *) die "$EXIT_START" "could not create SwitchBoard's first admin account" ;;
    esac
}

# sb_wire_php ACTION [json fields...]: runs lib/sb-wire.php in sb_php-fpm; prints its SBWIRE JSON line
sb_wire_php() {
    local payload
    payload=$(printf '%s' "$1" | base64 | tr -d '\n')
    { printf "<?php \$cfg = json_decode(base64_decode('%s'), true); ?>" "$payload"; cat "$COMPOSER_DIR/lib/sb-wire.php"; } \
        | docker exec -i -u www-data sb_php-fpm php 2>/dev/null | sed -n 's/^SBWIRE //p'
}

switchboard_wire() {
    step "Wiring SwitchBoard to SwitchBoardChat and MAS"
    local token json out
    token=$(head -n1 "$(SBCHAT_DIR)/admin-api-token")
    json=$(printf '{"action":"wire","admin_username":"%s","sbchat_url":"https://%s","sbchat_token":"%s","mas_url":"https://%s/auth","mas_client_id":"%s","mas_secret":"%s"}' \
        "$(conf SB_ADMIN_USER)" "$(conf SBCHAT_HOST)" "$token" "$(conf MATRIX_HOST)" "$(conf MAS_ADMIN_CLIENT_ID)" "$(conf MAS_ADMIN_CLIENT_SECRET)")
    out=$(sb_wire_php "$json")
    case "$out" in
        *'"ok":true'*) say "SwitchBoard's admin account now holds the SBChat token and the MAS client" ;;
        *) die "$EXIT_START" "could not store the SBChat/MAS settings in SwitchBoard: ${out:-no answer}" ;;
    esac
}

sb_backup() { # dir
    local pw; pw=$(env_get "$(SB_DIR)/Docker/.env" MYSQL_ROOT_PASSWORD)
    container_running sb_mariadb || return 0
    docker exec -i sb_mariadb sh -c 'exec mariadb-dump --all-databases --single-transaction -uroot -p"$(cat)"' <<<"$pw" \
        | gzip > "$1/switchboard-db.sql.gz" || die "$EXIT_START" "SwitchBoard database backup failed"
}

# SwitchBoardChat: install/update with its own scripts/install.sh (the "larger installer" contract of
# its docs/install.md). Sourced by install.sh and verify.sh.

SBCHAT_DIR() { printf '%s/switchboardchat' "$PREFIX"; }

# Self-signed mode: the bridge must trust the local CA to reach https://<matrix host> (login through MAS,
# the MAS admin API). A compose override (git-untracked, read automatically by docker compose) mounts a
# bundle = public roots + that CA over the system bundle.
sbchat_trust_ca() {
    local d override bundle
    d=$(SBCHAT_DIR); override="$d/docker-compose.override.yml"; bundle="$d/sbcomposer-ca-bundle.pem"
    if [ "$(conf TLS_MODE)" != selfsigned ]; then
        rm -f "$override" "$bundle"
        return 0
    fi
    { docker run --rm --entrypoint cat "$(conf CURL_IMAGE)" /etc/ssl/certs/ca-certificates.crt; cat "$(MATRIX_DIR)/ca/ca.pem"; } > "$bundle"
    chmod 644 "$bundle"
    cat > "$override" <<'EOF'
# Written by sbcomposer install.sh (self-signed mode): trust the local CA of the front proxy.
services:
  sb-chat:
    environment:
      SSL_CERT_FILE: /etc/ssl/certs/ca-certificates.crt
    volumes:
      - ./sbcomposer-ca-bundle.pem:/etc/ssl/certs/ca-certificates.crt:ro
EOF
}

sbchat_up() {
    step "SwitchBoardChat ($(git -C "$(SBCHAT_DIR)" rev-parse --short HEAD))"
    local d tmp subnet rc=0
    d=$(SBCHAT_DIR)
    sbchat_trust_ca
    tmp=$(mktemp -d); chmod 700 "$tmp"
    printf '%s\n' "$(conf BOT_PASSWORD)" > "$tmp/bot"
    printf '%s\n' "$(conf MAS_ADMIN_CLIENT_SECRET)" > "$tmp/mas"
    subnet=$(docker network inspect web -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | awk '{print $1}')
    local args=(--non-interactive
        --homeserver-url "https://$(conf MATRIX_HOST)"
        --bot-user "@$(conf BOT_LOCALPART):$(conf MATRIX_HOST)"
        --bot-password-file "$tmp/bot"
        --virtual-host "$(conf SBCHAT_HOST)"
        --mas-admin-client-id "$(conf MAS_ADMIN_CLIENT_ID)"
        --mas-admin-client-secret-file "$tmp/mas"
        --docker-network web
        --trusted-proxies "$subnet"
        --output-json "$tmp/result.json")
    [ -z "$(conf WEB_ORIGINS)" ] || args+=(--web-origins "$(conf WEB_ORIGINS)")
    [ -z "$(conf WEB_CALL_CENTER_ID)" ] || args+=(--web-call-center "$(conf WEB_CALL_CENTER_ID)")
    "$d/scripts/install.sh" "${args[@]}" </dev/null >&2 || rc=$?
    [ -f "$tmp/result.json" ] && cp "$tmp/result.json" "$PREFIX/sbchat-install.json"
    rm -rf "$tmp"
    [ "$rc" = 0 ] || die "$EXIT_START" "SwitchBoardChat's scripts/install.sh failed (exit $rc): docker logs sb-chat"
}

sbchat_backup() { # dir
    local d; d=$(SBCHAT_DIR)
    container_running sb-chat || return 0
    # The bridge's own backup (session + crypto store from the same moment, bridge briefly stopped)
    (cd "$d" && sh scripts/backup-data.sh . sb-chat) >&2 || die "$EXIT_START" "SwitchBoardChat backup failed"
    printf '%s\n' "$(ls -d "$d"/sb-chat/backup-* 2>/dev/null | tail -n1)" > "$1/sbchat-backup-location"
}

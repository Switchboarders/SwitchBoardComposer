# SwitchBoardChat: install/update with its own scripts/install.sh (the "larger installer" contract of
# its docs/install.md). Sourced by install.sh and verify.sh.

SBCHAT_DIR() { printf '%s/switchboardchat' "$PREFIX"; }

# docker-compose.override.yml (git-untracked, read automatically by docker compose) for:
#  - self-signed mode: the bridge must trust the local CA to reach https://<matrix host> (login through MAS,
#    the MAS admin API): a bundle = public roots + that CA, mounted over the system bundle;
#  - Windows: the bridge's data (sqlite databases, crypto store) in a Docker volume, not on NTFS.
sbchat_override() {
    local d override bundle
    d=$(SBCHAT_DIR); override="$d/docker-compose.override.yml"; bundle="$d/sbcomposer-ca-bundle.pem"
    rm -f "$override"
    if [ "$(conf TLS_MODE)" = selfsigned ]; then
        { docker run --rm --entrypoint cat "$(conf CURL_IMAGE)" /etc/ssl/certs/ca-certificates.crt; cat "$(MATRIX_DIR)/ca/ca.pem"; } > "$bundle"
        chmod 644 "$bundle"
    else
        rm -f "$bundle"
    fi
    [ "$(conf TLS_MODE)" = selfsigned ] || [ "$IS_WINDOWS" = 1 ] || return 0
    {
        echo "# Written by sbcomposer install.sh: do not edit (rewritten on every run)."
        echo "services:"
        echo "  sb-chat:"
        [ "$(conf TLS_MODE)" = selfsigned ] && printf '    environment:\n      SSL_CERT_FILE: /etc/ssl/certs/ca-certificates.crt\n'
        echo "    volumes:"
        [ "$(conf TLS_MODE)" = selfsigned ] && echo "      - ./sbcomposer-ca-bundle.pem:/etc/ssl/certs/ca-certificates.crt:ro"
        [ "$IS_WINDOWS" = 1 ] && echo "      - sbchat-data:/app/data"
        [ "$IS_WINDOWS" = 1 ] && printf 'volumes:\n  sbchat-data:\n    name: sbchat-data\n'
        true
    } > "$override"
}

sbchat_up() {
    step "SwitchBoardChat ($(git -C "$(SBCHAT_DIR)" rev-parse --short HEAD))"
    local d tmp subnet rc=0
    d=$(SBCHAT_DIR)
    sbchat_override
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
    # newer SBChat: the public web chat address goes into the string SwitchBoard shows ("Link a website")
    grep -q -- '--web-public-url' "$d/scripts/install.sh" && args+=(--web-public-url "https://$(conf SBCHAT_HOST)")
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
    if [ "$IS_WINDOWS" = 1 ]; then
        # Data in a volume: same rule as scripts/backup-data.sh (bridge stopped, session + db together)
        (cd "$d" && docker compose stop sb-chat >&2) || die "$EXIT_START" "could not stop the bridge for the backup"
        docker cp sb-chat:/app/data - | gzip > "$1/sbchat-data.tar.gz" || die "$EXIT_START" "SwitchBoardChat backup failed"
        (cd "$d" && docker compose start sb-chat >&2)
        return 0
    fi
    # The bridge's own backup (session + crypto store from the same moment, bridge briefly stopped)
    (cd "$d" && sh scripts/backup-data.sh . sb-chat) >&2 || die "$EXIT_START" "SwitchBoardChat backup failed"
}

# Optional WordPress site with the WP Chat widget (https://github.com/Switchboarders/wp_chat), installed
# next to the rest with install.sh --wordpress-host NAME. Sourced by install.sh and verify.sh.
# The site is created once (title, French (Canada), home and privacy pages); later runs only update
# WordPress's image, the plugin (from its repository) and the plugin's connection settings.

WP_DIR() { printf '%s/wordpress' "$PREFIX"; }
WPPLUGIN_DIR() { printf '%s/wp_chat' "$PREFIX"; }
wp_cli() { # wp-cli as www-data, in the WordPress container's files, on its private network
    docker run --rm -i --user 33:33 --volumes-from sbwp --network sbwp_internal \
        -e WORDPRESS_DB_HOST=sbwp-db -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_NAME=wordpress \
        -e WORDPRESS_DB_PASSWORD="$(conf WP_DB_PASSWORD)" "$(conf WORDPRESS_CLI_IMAGE)" wp "$@" 2> >(grep -v -E '^Warning: ' >&2)
}

wordpress_up() {
    [ -n "$(conf WP_HOST)" ] || return 0
    step "WordPress with WP Chat: https://$(conf WP_HOST)"
    local d; d=$(WP_DIR)
    mkdir -p "$d"
    cp "$COMPOSER_DIR/wordpress/docker-compose.yml" "$d/docker-compose.yml"
    ( umask 077; cat > "$d/.env" <<EOF
# Written by install.sh from $CONF: do not edit (it is rewritten on every run).
WORDPRESS_IMAGE=$(conf WORDPRESS_IMAGE)
WP_DB_IMAGE=$(conf WP_DB_IMAGE)
WP_DB_PASSWORD=$(conf WP_DB_PASSWORD)
WP_DB_ROOT_PASSWORD=$(conf WP_DB_ROOT_PASSWORD)
$( [ "$IS_WINDOWS" = 1 ] && printf 'WP_FILES=wp-files\nWP_DB_DATA=wp-db\n' )
EOF
    )
    (cd "$d" && docker compose up -d --remove-orphans >&2) || die "$EXIT_START" "docker compose up (WordPress) failed"
    wait_for 180 "WordPress's database" wp_cli db check || die "$EXIT_START" "WordPress cannot reach its database: docker logs sbwp-db"

    if ! wp_cli core is-installed >/dev/null 2>&1; then
        wp_cli core install --url="https://$(conf WP_HOST)" --title="$(conf WP_TITLE)" --admin_user=admin \
            --admin_password="$(conf WP_ADMIN_PASSWORD)" --admin_email="$(conf EMAIL)" --skip-email >&2 \
            || die "$EXIT_START" "WordPress installation failed"
        wp_cli language core install fr_CA --activate >/dev/null 2>&1 || true
        local home privacy
        home=$(wp_cli post create --post_type=page --post_status=publish --post_title="Accueil" --porcelain \
            --post_content="<p>Besoin de parler? Cliquez sur la bulle de clavardage en bas à droite : un bénévole vous répondra, de façon anonyme et confidentielle.</p>")
        privacy=$(wp_cli post create --post_type=page --post_status=publish --post_title="Confidentialité" --post_name=confidentialite --porcelain \
            --post_content="<p>Le clavardage ne conserve aucune conversation sur ce site. Les messages sont supprimés à la fin du clavardage ou après 48 heures d’inactivité.</p><p>Responsable de la protection des renseignements personnels : $(conf WP_PRIVACY_OFFICER)</p>")
        wp_cli option update show_on_front page >/dev/null
        wp_cli option update page_on_front "$home" >/dev/null
        wp_cli option update wp_page_for_privacy_policy "$privacy" >/dev/null
        wp_cli rewrite structure "/%postname%/" >/dev/null
        say "WordPress installed (admin: see credentials.txt)"
    fi

    # Self-signed mode: WordPress checks certificates with its own list; give it the local CA too, so the plugin
    # can call the chat server (linking with a code from SwitchBoard)
    if [ "$(conf TLS_MODE)" = selfsigned ] && [ -f "$(SBCHAT_DIR)/sbcomposer-ca-bundle.pem" ]; then
        docker exec -u 33:33 sbwp mkdir -p /var/www/html/wp-content/mu-plugins
        docker cp "$(SBCHAT_DIR)/sbcomposer-ca-bundle.pem" sbwp:/var/www/html/wp-content/mu-plugins/sbcomposer-ca-bundle.pem
        printf '%s\n' '<?php' '// sbcomposer (self-signed mode): trust the local CA of this installation for outgoing HTTPS' \
            "add_filter( 'http_request_args', function ( \$a ) { \$a['sslcertificates'] = __DIR__ . '/sbcomposer-ca-bundle.pem'; return \$a; } );" \
            | docker exec -i -u 33:33 sbwp sh -c 'cat > /var/www/html/wp-content/mu-plugins/sbcomposer-ca.php'
    fi

    # The plugin, from its repository (public, GPL-2.0-or-later), refreshed on every run
    if [ -d "$(WPPLUGIN_DIR)/.git" ]; then
        git -C "$(WPPLUGIN_DIR)" fetch -q origin "$(conf WPCHAT_REF)" && git -C "$(WPPLUGIN_DIR)" checkout -q -B "$(conf WPCHAT_REF)" FETCH_HEAD \
            || die "$EXIT_START" "could not update wp_chat"
    else
        ( umask 022; git clone -q -c core.autocrlf=false --branch "$(conf WPCHAT_REF)" "$(conf WPCHAT_REPO)" "$(WPPLUGIN_DIR)" ) \
            || die "$EXIT_START" "could not clone $(conf WPCHAT_REPO)"
    fi
    tar -C "$(WPPLUGIN_DIR)" -cf - wp-chat | docker exec -i -u 33:33 sbwp sh -c 'rm -rf /var/www/html/wp-content/plugins/wp-chat && tar -xf - -C /var/www/html/wp-content/plugins/' \
        || die "$EXIT_START" "could not copy the WP Chat plugin into WordPress"
    wp_cli plugin activate wp-chat >/dev/null || die "$EXIT_START" "could not activate the WP Chat plugin"
    # Connection settings follow the installation; the rest (name, colour, pages...) stays as set in WordPress
    docker run --rm --user 33:33 --volumes-from sbwp --network sbwp_internal \
        -e WORDPRESS_DB_HOST=sbwp-db -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_NAME=wordpress \
        -e WORDPRESS_DB_PASSWORD="$(conf WP_DB_PASSWORD)" -e SBC_BACKEND="https://$(conf SBCHAT_HOST)" \
        -e SBC_PRIVACY_URL="https://$(conf WP_HOST)/confidentialite/" -e SBC_PRIVACY_OFFICER="$(conf WP_PRIVACY_OFFICER)" \
        "$(conf WORDPRESS_CLI_IMAGE)" wp eval '
        $o = get_option("wp_chat_options", array());
        $o["backend_url"] = getenv("SBC_BACKEND");
        if (empty($o["privacy_url"]))     { $o["privacy_url"] = getenv("SBC_PRIVACY_URL"); }
        if (empty($o["privacy_officer"])) { $o["privacy_officer"] = getenv("SBC_PRIVACY_OFFICER"); }
        if (empty($o["agent_name"]) || $o["agent_name"] === "Respondent") { $o["agent_name"] = "Bénévole"; }
        update_option("wp_chat_options", $o);' 2>/dev/null \
        || die "$EXIT_START" "could not configure the WP Chat plugin"
    say "WP Chat $(git -C "$(WPPLUGIN_DIR)" rev-parse --short HEAD) active, connected to https://$(conf SBCHAT_HOST)"
}

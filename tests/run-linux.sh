#!/usr/bin/env bash
# Installs the whole stack in throwaway Linux "machines" (one Docker-in-Docker container per distribution,
# Docker installed the way an admin would on it), then checks it really works, then updates it.
# Nothing touches the containers of the machine running the tests.
#
#   tests/run-linux.sh [--distros "debian ubuntu fedora arch alpine"] [--keep] [--errors]
#                      [--from-sb REF --from-sbchat REF]   update test starting from these refs
#                      [--sb-ref REF --sbchat-ref REF]     refs to install/update to (default main)
#
# For each distribution: install.sh (fresh, self-signed) -> verify.sh --functional -> install.sh again
# (update path: backups, nothing regenerated) -> secrets unchanged -> verify.sh --functional -> tests/suite.sh.
# With --from-*: the fresh install uses those refs and the update goes to --sb-ref/--sbchat-ref.
# Logs: tests/results/<distribution>/. Exit 0 when every check passed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DISTROS="debian"
KEEP=0
FROM_SB="" FROM_SBCHAT="" TO_SB=main TO_SBCHAT=main ERRORS=0 LOCAL_REPOS="" QUICK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --distros) DISTROS=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --errors) ERRORS=1; shift ;;   # user-error scenario instead of the install/update cycle
        --local-repos) LOCAL_REPOS=$(cd "$2" && pwd); shift 2 ;;   # DIR/{sb,sbchat,wp_chat}: test unpushed changes
        --quick) QUICK=1; shift ;;     # install + verify + suite only (no update step)
        --from-sb) FROM_SB=$2; shift 2 ;;
        --from-sbchat) FROM_SBCHAT=$2; shift 2 ;;
        --sb-ref) TO_SB=$2; shift 2 ;;
        --sbchat-ref) TO_SBCHAT=$2; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done
NET=sbctest-lan
MIRROR=sbctest-mirror
RESULTS="$HERE/results"
DOMAIN=sbc.test
PREFIX=/opt/switchboard
TOTAL_FAIL=0

say() { printf '%s\n' "$*"; }
pass() { say "PASS  [$DISTRO] $*"; }
fail() { say "FAIL  [$DISTRO] $*"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }

# ------------------------------------------------------------------------------ machine images
# Same recipes as SwitchBoard's Docker/tests/install/run-linux.sh, plus git (install.sh clones the repos).
dockerfile() {
    case "$1" in
        debian) cat <<'EOF'
FROM debian:12
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git iproute2 openssl \
 && curl -fsSL https://get.docker.com | sh && rm -rf /var/lib/apt/lists/*
EOF
        ;;
        ubuntu) cat <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git openssl docker.io docker-compose-v2 docker-buildx \
 && rm -rf /var/lib/apt/lists/*
EOF
        ;;
        fedora) cat <<'EOF'
FROM fedora:42
RUN dnf -y install dnf-plugins-core findutils procps-ng iproute git openssl gzip \
 && dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
 && dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin iptables-nft && dnf clean all \
 && (alternatives --set iptables /usr/sbin/iptables-nft; alternatives --set ip6tables /usr/sbin/ip6tables-nft; true)
EOF
        ;;
        alpine) cat <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache bash curl git openssl docker docker-cli-compose docker-cli-buildx
EOF
        ;;
        arch) cat <<'EOF'
FROM archlinux:latest
RUN pacman -Syu --noconfirm docker docker-compose docker-buildx git openssl && pacman -Scc --noconfirm
EOF
        ;;
        *) return 1 ;;
    esac
    cat <<'EOF'
RUN printf '%s\n' '#!/bin/sh' \
 'if [ -f /sys/fs/cgroup/cgroup.controllers ]; then' \
 '  mkdir -p /sys/fs/cgroup/init' \
 '  xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :' \
 '  sed -e "s/ / +/g" -e "s/^/+/" < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || :' \
 'fi' \
 'dockerd --registry-mirror "$SBCTEST_MIRROR" > /var/log/dockerd.log 2>&1 &' \
 'exec sleep infinity' > /sbctest-start && chmod +x /sbctest-start
CMD ["/sbctest-start"]
EOF
}

infra() {
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
    if ! docker ps --format '{{.Names}}' | grep -qx "$MIRROR"; then
        docker rm -f "$MIRROR" >/dev/null 2>&1
        docker run -d --name "$MIRROR" --network "$NET" --restart unless-stopped \
            -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
            -v sbctest-mirror-data:/var/lib/registry registry:2 >/dev/null
    fi
}

m() { docker exec "$MACHINE" "$@"; }
msh() { docker exec "$MACHINE" bash -c "$*"; }

# The composer as a fresh clone would give it (tracked + new files, nothing ignored)
copy_composer() {
    msh "rm -rf /opt/sbcomposer && mkdir -p /opt/sbcomposer"
    (cd "$ROOT" && git ls-files -co --exclude-standard | grep -v '^tests/results/' | tar -cf - -T -) \
        | docker exec -i "$MACHINE" tar -xf - -C /opt/sbcomposer
}

secrets_fingerprint() {
    msh "{ grep -E '^(BOT_PASSWORD|ADMIN_PASSWORD|SB_ADMIN_PASSWORD|MAS_[A-Z_]*|SYNAPSE_[A-Z_]*SECRET)=' $PREFIX/composer.env | sort
           grep -E '^(PHONE_HASH_SECRET|PHONE_ENC_KEY)=' $PREFIX/switchboardchat/.env | sort
           grep -E '^(APP_ENCRYPTION_KEY|MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD)=' $PREFIX/switchboard/Docker/.env | sort
           cat $PREFIX/switchboardchat/admin-api-token $PREFIX/matrix/mas/secrets.yaml; } | sha256sum"
}

# ------------------------------------------------------------------------------ user errors
# expect CODE REGEX DESCRIPTION COMMAND: the command (bash, in the machine) must exit with CODE and print REGEX
expect() {
    local code=$1 re=$2 what=$3 out rc; shift 3
    out=$(msh "$*" 2>&1); rc=$?
    if [ "$rc" = "$code" ] && grep -qE -- "$re" <<<"$out"; then pass "$what"
    else fail "$what (exit $rc, expected $code / « $re »): $(tail -n 2 <<<"$out" | tr '\n' ' ' | cut -c1-200)"; fi
}
no_state() { # nothing was installed: no containers of ours and no configured composer.env
    if msh "! docker ps -a --format '{{.Names}}' | grep -qE '^(synapse|mas|masdb|sb_php-fpm|sb-chat|synapse-nginx)$' && ! grep -qs '^MATRIX_HOST=' $1/composer.env"; then
        pass "  … and nothing was installed or half-installed"
    else fail "  … but something was left installed or configured"; fi
}

scenario_errors() {
    local I="cd /opt/sbcomposer && ./install.sh --non-interactive"
    local P=/opt/err
    # --- arguments (nothing must be created)
    expect 2 'unknown option' "unknown option refused" "$I --prefix $P --bogus"
    expect 2 'domain is required' "first install without --domain refused" "$I --prefix $P"
    no_state $P
    expect 2 'not a valid host name' "domain with a space refused" "$I --prefix $P --domain 'exa mple.org' --tls selfsigned"
    expect 2 'not a valid host name' "host name starting with a dash refused" "$I --prefix $P --domain -bad.org --tls selfsigned"
    expect 2 'not a valid host name' "IP address as a domain refused" "$I --prefix $P --matrix-host 1.2.3.4 --domain ok.test --tls selfsigned"
    expect 2 'not an email' "invalid email refused" "$I --prefix $P --domain ok.test --email nobody"
    expect 2 'letsencrypt or selfsigned' "unknown --tls refused" "$I --prefix $P --domain ok.test --tls maybe"
    expect 2 'America/Toronto' "malformed time zone refused" "$I --prefix $P --domain ok.test --tls selfsigned --tz '../../etc/passwd'"
    expect 2 'not a port number' "non-numeric port refused" "$I --prefix $P --domain ok.test --tls selfsigned --http-port eighty"
    expect 2 'must differ' "same HTTP and HTTPS port refused" "$I --prefix $P --domain ok.test --tls selfsigned --http-port 8443 --https-port 8443"
    expect 2 'used twice' "WordPress on the SwitchBoard name refused" "$I --prefix $P --domain ok.test --tls selfsigned --wordpress-host sb.ok.test"
    expect 2 'must be a number' "non-numeric call center refused" "$I --prefix $P --domain ok.test --tls selfsigned --web-call-center two"
    expect 2 'not a branch, tag or commit' "unknown --sb-ref refused" "$I --prefix $P --domain ok.test --tls selfsigned --sb-ref no-such-branch-xyz"
    msh "rm -rf $P"
    no_state $P
    # --- the machine
    msh "useradd -m tester 2>/dev/null; usermod -aG docker tester; mkdir -p /opt/locked; chmod 755 /opt/locked; chmod -R a+rX /opt/sbcomposer"
    expect 2 'cannot create|not writable' "an install folder the user cannot write to is explained" \
        "su tester -c 'cd /opt/sbcomposer && ./install.sh --non-interactive --prefix /opt/locked/x --domain ok.test --tls selfsigned'"
    msh "useradd -m outsider 2>/dev/null; true"
    expect 3 'usermod -aG docker' "a user outside the docker group is told how to fix it" \
        "su outsider -c 'cd /opt/sbcomposer && ./install.sh --non-interactive --prefix /tmp/x --domain ok.test --tls selfsigned'"
    msh "mv /usr/bin/git /usr/bin/git.hidden"
    expect 3 'missing dependency: git' "missing git is explained" "$I --prefix $P --domain ok.test --tls selfsigned"
    msh "mv /usr/bin/git.hidden /usr/bin/git"
    # Docker stopped: the installer sees the same thing when its socket does not answer
    expect 3 'Docker daemon' "a stopped Docker service is explained" "cd /opt/sbcomposer && DOCKER_HOST=unix:///run/no-docker.sock ./install.sh --non-interactive --prefix $P --domain ok.test --tls selfsigned"
    msh "docker run -d --name blocker -p 80:80 $(grep '^NGINX_IMAGE=' "$ROOT/versions.env" | cut -d= -f2) >/dev/null"
    expect 4 'port 80 is already used' "a busy port 80 is explained before anything starts" "$I --prefix $P --domain ok.test --tls selfsigned"
    no_state $P
    msh "docker rm -f blocker >/dev/null; rm -rf $P"

    # --- a real installation, then mistakes around it
    if msh "$I --prefix $P --domain ok.test --tls selfsigned --no-verify" > "$RESULTS/$DISTRO/errors-install.log" 2>&1; then
        pass "installation for the next cases"
    else fail "installation for the next cases (see errors-install.log)"; return; fi
    expect 2 'already running' "a second install.sh while one runs is refused" \
        "sleep 300 & mkdir -p $P/.install.lock && echo \$! > $P/.install.lock/pid && $I --prefix $P; rc=\$?; kill %1; rm -rf $P/.install.lock; exit \$rc"
    expect 2 'belongs to another installation' "a second installation in another folder is refused" \
        "$I --prefix /opt/second --domain two.test --tls selfsigned"
    msh "echo '# local edit' >> $P/switchboardchat/scripts/install.sh"
    expect 4 'local modifications' "local changes in a checkout stop the update (nothing lost)" "$I --prefix $P --no-verify"
    msh "git -C $P/switchboardchat checkout -- scripts/install.sh"
    msh "mv $P/composer.env $P/composer.env.away"
    expect 2 'Restore composer.env' "a lost composer.env is explained (no new secrets over old data)" "$I --prefix $P --domain ok.test --tls selfsigned"
    msh "mv $P/composer.env.away $P/composer.env"
    local before after
    before=$(msh "grep -E '^(BOT_PASSWORD|MAS_[A-Z_]*|SYNAPSE_[A-Z_]*SECRET)=' $P/composer.env | sort | sha256sum")
    msh "sed -i 's/\$/\r/' $P/composer.env && sed -i '1s/^/\xef\xbb\xbf/' $P/composer.env && sed -i 's/^EMAIL=\(.*\)\r\$/EMAIL = \"\1\"\r/' $P/composer.env"
    if msh "$I --prefix $P" > "$RESULTS/$DISTRO/errors-notepad.log" 2>&1; then
        pass "a composer.env saved by Notepad (BOM, CRLF, quotes, spaces) still works (update + verify)"
    else fail "update with a Notepad-edited composer.env (see errors-notepad.log)"; fi
    after=$(msh "grep -E '^(BOT_PASSWORD|MAS_[A-Z_]*|SYNAPSE_[A-Z_]*SECRET)=' $P/composer.env | sort | sha256sum")
    [ "$before" = "$after" ] && pass "  … with the same secrets" || fail "  … but a secret changed"
    # interrupted update (Ctrl-C half-way), then the same command again
    docker exec -d "$MACHINE" sh -c "cd /opt/sbcomposer && ./install.sh --non-interactive --prefix $P --no-verify > /tmp/int.log 2>&1"
    # Ctrl-C reaches the whole process group (install.sh and the docker build it is waiting for); then wait for it
    msh "sleep 45; pid=\$(pgrep -o -f 'install.sh --non-interactive --prefix $P'); [ -n \"\$pid\" ] && kill -INT -- -\$(ps -o pgid= \$pid | tr -d ' ') 2>/dev/null; for i in \$(seq 1 300); do pgrep -f 'install.sh --non-interactive --prefix $P' >/dev/null || break; sleep 2; done; true"
    if msh "$I --prefix $P" > "$RESULTS/$DISTRO/errors-resume.log" 2>&1; then
        pass "after an interrupted update, running it again completes (verify passes)"
    else fail "re-run after an interrupted update (see errors-resume.log)"; fi
}

run_distro() {
    DISTRO=$1
    MACHINE="sbctest-$DISTRO"
    local logs="$RESULTS/$DISTRO"
    rm -rf "$logs"; mkdir -p "$logs"
    say ""; say "======== $DISTRO"
    if ! dockerfile "$DISTRO" | docker build -q -t "sbctest-machine-$DISTRO" - > "$logs/machine-build.log" 2>&1; then
        fail "machine image build (see $logs/machine-build.log)"; return
    fi
    docker rm -f -v "$MACHINE" >/dev/null 2>&1
    docker run -d --privileged --name "$MACHINE" --hostname "$MACHINE" --network "$NET" \
        -e SBCTEST_MIRROR="http://$MIRROR:5000" -v /var/lib/docker "sbctest-machine-$DISTRO" >/dev/null
    local i
    for i in $(seq 1 60); do m docker info >/dev/null 2>&1 && break; sleep 2; done
    m docker info >/dev/null 2>&1 && pass "Docker runs in the machine" || { fail "dockerd did not start"; return; }
    copy_composer
    if [ "$ERRORS" = 1 ]; then
        scenario_errors
        [ "$KEEP" = 1 ] || docker rm -f -v "$MACHINE" >/dev/null 2>&1
        return
    fi

    local repo_args=""
    if [ -n "$LOCAL_REPOS" ]; then
        # unpushed changes: the three repositories as they are here (committed), cloned from inside the machine
        msh "rm -rf /opt/repos && mkdir -p /opt/repos"
        local r
        for r in sb sbchat wp_chat; do
            tar -C "$LOCAL_REPOS" -cf - "$r" | docker exec -i "$MACHINE" tar -xf - -C /opt/repos
        done
        msh "chown -R root:root /opt/repos"   # else git refuses them ("dubious ownership")
        repo_args="--sb-repo /opt/repos/sb --sbchat-repo /opt/repos/sbchat --wpchat-repo /opt/repos/wp_chat"
    fi
    local from_args="" to_args="--sb-ref $TO_SB --sbchat-ref $TO_SBCHAT"
    [ -n "$FROM_SB" ] && from_args+=" --sb-ref $FROM_SB"
    [ -n "$FROM_SBCHAT" ] && from_args+=" --sbchat-ref $FROM_SBCHAT"
    [ -n "$from_args" ] || from_args=$to_args

    # --- fresh install
    local t0=$SECONDS
    if msh "cd /opt/sbcomposer && ./install.sh --non-interactive --domain $DOMAIN --tls selfsigned --prefix $PREFIX --wordpress-host wp.$DOMAIN $repo_args $from_args" \
        > "$logs/install.log" 2>&1; then
        pass "fresh install ($((SECONDS - t0)) s)"
    else
        fail "fresh install (see $logs/install.log)"; tail -n 40 "$logs/install.log"; return
    fi
    if [ -n "$LOCAL_REPOS" ]; then
        # SwitchBoard's container clones its application from GitHub itself: put the local code in its place
        msh "docker cp /opt/repos/sb/SwitchBoard/src/. sb_php-fpm:/var/www/html/SwitchBoard/SwitchBoard/src/ && docker exec sb_php-fpm chown -R www-data:www-data /var/www/html/SwitchBoard/SwitchBoard/src" \
            && pass "local SwitchBoard application code in place" || fail "could not copy the local SwitchBoard code"
    fi
    if msh "cd /opt/sbcomposer && ./verify.sh --prefix $PREFIX --functional" > "$logs/verify-1.log" 2>&1; then
        pass "verify --functional after install"
    else
        fail "verify --functional after install (see $logs/verify-1.log)"; grep -E '^FAIL' "$logs/verify-1.log"
    fi
    if [ "$QUICK" = 1 ]; then
        if msh "cd /opt/sbcomposer && tests/suite.sh --confirm --prefix $PREFIX --skip outside" > "$logs/suite.log" 2>&1; then
            pass "full suite ($(grep -a -c '^PASS' "$logs/suite.log") checks)"
        else
            fail "full suite: $(grep -a -c '^FAIL' "$logs/suite.log") failed (see $logs/suite.log)"; grep -a -E '^FAIL' "$logs/suite.log"
        fi
        [ "$KEEP" = 1 ] || docker rm -f -v "$MACHINE" >/dev/null 2>&1
        return
    fi
    local before; before=$(secrets_fingerprint)

    # --- update (same command again)
    t0=$SECONDS
    if msh "cd /opt/sbcomposer && ./install.sh --non-interactive --prefix $PREFIX $to_args" > "$logs/update.log" 2>&1; then
        pass "update ($((SECONDS - t0)) s)"
    else
        fail "update (see $logs/update.log)"; tail -n 40 "$logs/update.log"; return
    fi
    [ "$(secrets_fingerprint)" = "$before" ] && pass "secrets unchanged by the update" || fail "a secret changed during the update"
    msh "ls $PREFIX/backups/*/switchboard-db.sql.gz $PREFIX/backups/*/mas-db.sql.gz $PREFIX/backups/*/synapse-db.tar.gz" >/dev/null 2>&1 \
        && pass "backups taken before the update" || fail "backups missing"
    if msh "cd /opt/sbcomposer && ./verify.sh --prefix $PREFIX --functional" > "$logs/verify-2.log" 2>&1; then
        pass "verify --functional after update"
    else
        fail "verify --functional after update (see $logs/verify-2.log)"; grep -E '^FAIL' "$logs/verify-2.log"
    fi
    # The full functional suite (test accounts, web chat with two respondents, SMS, Law 25 purge, restarts)
    if msh "cd /opt/sbcomposer && tests/suite.sh --confirm --prefix $PREFIX --skip outside" > "$logs/suite.log" 2>&1; then
        pass "full suite ($(grep -a -c '^PASS' "$logs/suite.log") checks)"
    else
        fail "full suite: $(grep -a -c '^FAIL' "$logs/suite.log") failed (see $logs/suite.log)"; grep -a -E '^FAIL' "$logs/suite.log"
    fi
    msh "git -C $PREFIX/switchboard rev-parse HEAD; git -C $PREFIX/switchboardchat rev-parse HEAD" > "$logs/commits" 2>/dev/null
    [ "$KEEP" = 1 ] || docker rm -f -v "$MACHINE" >/dev/null 2>&1
}

infra
for d in $DISTROS; do run_distro "$d"; done
say ""
if [ "$TOTAL_FAIL" = 0 ]; then say "ALL PASSED ($DISTROS)"; exit 0; fi
say "$TOTAL_FAIL FAILURE(S)"
exit 1

#!/usr/bin/env bash
# Installs the whole stack in throwaway Linux "machines" (one Docker-in-Docker container per distribution,
# Docker installed the way an admin would on it), then checks it really works, then updates it.
# Nothing touches the containers of the machine running the tests.
#
#   tests/run-linux.sh [--distros "debian ubuntu fedora arch alpine"] [--keep]
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
FROM_SB="" FROM_SBCHAT="" TO_SB=main TO_SBCHAT=main
while [ $# -gt 0 ]; do
    case "$1" in
        --distros) DISTROS=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
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

    local from_args="" to_args="--sb-ref $TO_SB --sbchat-ref $TO_SBCHAT"
    [ -n "$FROM_SB" ] && from_args+=" --sb-ref $FROM_SB"
    [ -n "$FROM_SBCHAT" ] && from_args+=" --sbchat-ref $FROM_SBCHAT"
    [ -n "$from_args" ] || from_args=$to_args

    # --- fresh install
    local t0=$SECONDS
    if msh "cd /opt/sbcomposer && ./install.sh --non-interactive --domain $DOMAIN --tls selfsigned --prefix $PREFIX --wordpress-host wp.$DOMAIN $from_args" \
        > "$logs/install.log" 2>&1; then
        pass "fresh install ($((SECONDS - t0)) s)"
    else
        fail "fresh install (see $logs/install.log)"; tail -n 40 "$logs/install.log"; return
    fi
    if msh "cd /opt/sbcomposer && ./verify.sh --prefix $PREFIX --functional" > "$logs/verify-1.log" 2>&1; then
        pass "verify --functional after install"
    else
        fail "verify --functional after install (see $logs/verify-1.log)"; grep -E '^FAIL' "$logs/verify-1.log"
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

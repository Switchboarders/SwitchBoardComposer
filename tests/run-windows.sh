#!/usr/bin/env bash
# Same cycle as run-linux.sh on a real Windows PC with Docker Desktop and Git for Windows, by SSH
# (default: vieuxpcwindows reached through arch-desktop, like SwitchBoard's own Windows test):
#   install.ps1 (fresh, self-signed, ports 18080/18443) -> verify --functional -> install.ps1 again
#   (update) -> secrets unchanged -> verify --functional
#
#   tests/run-windows.sh [--pc vieuxpcwindows] [--relay arch-desktop|""] [--keep]
# Without --keep, everything the test created on the PC (containers, volumes, folders) is removed first.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PC=vieuxpcwindows RELAY=arch-desktop KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --pc) PC=$2; shift 2 ;;
        --relay) RELAY=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done
RESULTS="$HERE/results/windows"
mkdir -p "$RESULTS"
FAILS=0
pass() { echo "PASS  [windows] $*"; }
fail() { echo "FAIL  [windows] $*"; FAILS=$((FAILS + 1)); }
noise='post-quantum|store now|may need to be upgraded|pq.html|^#< CLIXML|^<Objs'

# ssh/scp to the PC, through the relay if any
pc_ssh() {
    if [ -n "$RELAY" ]; then ssh -o BatchMode=yes -o ServerAliveInterval=30 "$RELAY" "ssh -o BatchMode=yes -o ServerAliveInterval=30 $PC $(printf '%q' "$1")"
    else ssh -o BatchMode=yes -o ServerAliveInterval=30 "$PC" "$1"; fi
}
pc_put() { # local-file remote-name (in the PC user's home)
    if [ -n "$RELAY" ]; then
        scp -q -o BatchMode=yes "$1" "$RELAY:/tmp/$2" && ssh -o BatchMode=yes "$RELAY" "scp -q -o BatchMode=yes /tmp/$2 $PC:$2 && rm -f /tmp/$2"
    else scp -q -o BatchMode=yes "$1" "$PC:$2"; fi
}
# PowerShell script (stdin) on the PC
ps() {
    local f="sbctest-$$-$RANDOM.ps1" tmp; tmp=$(mktemp)
    cat > "$tmp"; pc_put "$tmp" "$f"; rm -f "$tmp"
    pc_ssh "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f; \$c=\$LASTEXITCODE; Remove-Item $f; exit \$c" 2>&1 \
        | tr -d '\r' | grep -v -E "$noise"
    return "${PIPESTATUS[0]}"
}

# Runs a composer script on the PC in the background (survives a dropped SSH session), waits for it,
# copies its log to $RESULTS/<name>.log; returns its exit code.
run_on_pc() { # name script args...
    local name=$1 script=$2; shift 2
    ps <<EOF >/dev/null
\$log = "\$env:USERPROFILE\\sbctest-$name.log"
Remove-Item -ErrorAction SilentlyContinue \$log, "\$log.rc"
\$cmd = "& '\$env:USERPROFILE\\sbcomposer\\install.ps1' -Script $script $* > '\$log' 2>&1; Set-Content -Path '\$log.rc' -Value \$LASTEXITCODE"
Start-Process -WindowStyle Hidden powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',\$cmd
EOF
    local rc=""
    for _ in $(seq 1 240); do   # up to 2 h
        sleep 30
        rc=$(ps <<EOF
\$f = "\$env:USERPROFILE\\sbctest-$name.log.rc"; if (Test-Path \$f) { (Get-Content \$f).Trim() }
EOF
)
        [ -n "$rc" ] && break
    done
    ps <<EOF > "$RESULTS/$name.log"
Get-Content "\$env:USERPROFILE\\sbctest-$name.log"
EOF
    [ -n "$rc" ] || { echo "timed out"; return 124; }
    return "$rc"
}

fingerprint() {
    ps <<'EOF'
$p = "$env:USERPROFILE\switchboard"
$t = (Select-String -Path "$p\composer.env" -Pattern '^(BOT_PASSWORD|ADMIN_PASSWORD|SB_ADMIN_PASSWORD|MAS_[A-Z_]*|SYNAPSE_[A-Z_]*SECRET)=' | ForEach-Object Line | Sort-Object) -join "`n"
$t += (Select-String -Path "$p\switchboardchat\.env" -Pattern '^(PHONE_HASH_SECRET|PHONE_ENC_KEY)=' | ForEach-Object Line | Sort-Object) -join "`n"
$t += Get-Content -Raw "$p\switchboardchat\admin-api-token"
$t += Get-Content -Raw "$p\matrix\mas\secrets.yaml"
$h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t))
-join ($h | ForEach-Object { $_.ToString('x2') })
EOF
}

echo "======== windows ($PC${RELAY:+ via $RELAY})"
ps <<'EOF' | sed 's/^/    /'
"Windows " + [Environment]::OSVersion.Version + ", PowerShell " + $PSVersionTable.PSVersion + ", Docker " + (docker version --format "{{.Server.Version}}")
EOF

if [ "$KEEP" = 0 ]; then
    ps <<'EOF' >/dev/null
$ErrorActionPreference = 'Continue'
$names = 'synapse-nginx','synapse','mas','masdb','certbot','sb-chat','sb_web_server','sb_php-fpm','sb_mariadb','sb_mail_relay','sb_nginx-proxy','sb_letsencrypt','sb_web'
docker rm -f -v @names 2>&1 | Out-Null
docker volume rm sbmatrix-synapse sbmatrix-postgres sbchat-data 2>&1 | Out-Null
docker volume ls -q | Where-Object { $_ -like 'switchboarddocker*' -or $_ -like 'docker_sb_*' -or $_ -like '*_sb_db' -or $_ -like '*_sb_web' } | ForEach-Object { docker volume rm $_ 2>&1 | Out-Null }
docker network rm web 2>&1 | Out-Null
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:USERPROFILE\switchboard", "$env:USERPROFILE\sbcomposer"
EOF
    pass "previous test installation removed"
fi

# The composer as a fresh clone would give it, in ~/sbcomposer on the PC
ARCHIVE=$(mktemp --suffix=.tar)
(cd "$ROOT" && git ls-files -co --exclude-standard | grep -v '^tests/results/' | tar -cf "$ARCHIVE" -T -)
pc_put "$ARCHIVE" sbcomposer.tar; rm -f "$ARCHIVE"
ps <<'EOF' >/dev/null
New-Item -ItemType Directory -Force "$env:USERPROFILE\sbcomposer" | Out-Null
tar -xf "$env:USERPROFILE\sbcomposer.tar" -C "$env:USERPROFILE\sbcomposer"; Remove-Item "$env:USERPROFILE\sbcomposer.tar"
EOF

t0=$SECONDS
if run_on_pc install install.sh --non-interactive --domain sbc.test --tls selfsigned --http-port 18080 --https-port 18443; then
    pass "fresh install ($((SECONDS - t0)) s)"
    if run_on_pc verify1 verify.sh --functional; then pass "verify --functional after install"
    else fail "verify --functional after install"; grep -E '^FAIL' "$RESULTS/verify1.log"; fi
    before=$(fingerprint)
    t0=$SECONDS
    if run_on_pc update install.sh --non-interactive; then
        pass "update ($((SECONDS - t0)) s)"
        [ "$(fingerprint)" = "$before" ] && pass "secrets unchanged by the update" || fail "a secret changed during the update"
        if run_on_pc verify2 verify.sh --functional; then pass "verify --functional after update"
        else fail "verify --functional after update"; grep -E '^FAIL' "$RESULTS/verify2.log"; fi
    else
        fail "update (see $RESULTS/update.log)"; tail -n 30 "$RESULTS/update.log"
    fi
else
    fail "fresh install (see $RESULTS/install.log)"; tail -n 40 "$RESULTS/install.log"
fi

echo
if [ "$FAILS" = 0 ]; then echo "ALL PASSED (windows)"; exit 0; fi
echo "$FAILS FAILURE(S)"; exit 1

# Shared helpers for install.sh, verify.sh and the tests. Sourced, never executed.
# Logging goes to stderr; nothing here ever prints a secret.

# shellcheck disable=SC2034
readonly EXIT_OK=0 EXIT_ARGS=2 EXIT_DEPS=3 EXIT_START=4 EXIT_CHECK=5

# Windows (Git Bash, called by install.ps1): Docker Desktop's Linux engine does the work. Git Bash must
# not rewrite paths given to docker.exe/git.exe, and every path we build is a "C:/..." (mixed) path,
# which bash, git and docker all understand.
IS_WINDOWS=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; esac
if [ "$IS_WINDOWS" = 1 ]; then
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
fi
winpath() { if [ "$IS_WINDOWS" = 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
die()  { local code=$1; shift; printf 'sbcomposer: %s\n' "$*" >&2; exit "$code"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$EXIT_DEPS" "missing dependency: $1"; }

# ------------------------------------------------------------------------------------------ env files
# Same semantics as SwitchBoardChat's scripts/install.sh: KEY=VALUE lines, first match wins.
env_get() { # file key
    [ -f "$1" ] || return 0
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}
env_set() { # file key value
    local file=$1 key=$2 value=$3 tmp
    [ -f "$file" ] || { ( umask 077; : > "$file" ); }
    tmp=$(mktemp "$file.XXXXXX")
    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        !done && index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}
env_unset() { # file key: removes KEY= lines
    [ -f "$1" ] || return 0
    local tmp; tmp=$(mktemp "$1.XXXXXX")
    awk -v k="$2" 'index($0, k "=") != 1' "$1" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$1"
}
# Sets KEY only when it is empty (generated secrets are created once and never rotated)
env_default() { # file key value
    [ -n "$(env_get "$1" "$2")" ] || env_set "$1" "$2" "$3"
}
safe_value() { # name value: refuse what a line-based .env or YAML template could misread
    case "$2" in
        *$'\n'*|*$'\r'*|*'$'*|*'"'*|*"'"*|*'`'*|*'\'*|*' '*|*'#'*)
            die "$EXIT_ARGS" "$1 contains a character that is not allowed (space, quote, \$, #, backslash or newline)" ;;
    esac
}

# ------------------------------------------------------------------------------------------ secrets
rand_hex() { openssl rand -hex "${1:-32}"; }
# Password with letters, digits and a symbol (MAS minimum_complexity 3 and SB's checks are satisfied)
rand_password() { printf '%s-%s-%s' "$(openssl rand -hex 6)" "$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 12)" "Q7"; }
# ULID-shaped id (MAS client ids must be ULIDs): 26 Crockford base32 characters, first one 0-7
rand_ulid() {
    local alphabet=0123456789ABCDEFGHJKMNPQRSTVWXYZ out=0 i byte
    for byte in $(openssl rand 25 | od -An -tu1); do
        out+=${alphabet:$((byte % 32)):1}
    done
    printf '%s' "${out:0:26}"
}

# ------------------------------------------------------------------------------------------ docker
check_docker() {
    need docker
    docker compose version >/dev/null 2>&1 || die "$EXIT_DEPS" "missing dependency: docker compose (v2 plugin)"
    local err
    if ! err=$(docker info 2>&1 >/dev/null); then
        case "$err" in
            *ermission*) die "$EXIT_DEPS" "Docker refuses user $(id -un): sudo usermod -aG docker $(id -un), then log in again" ;;
            *) die "$EXIT_DEPS" "cannot talk to the Docker daemon (is it running?)" ;;
        esac
    fi
    local v major minor
    v=$(docker compose version --short 2>/dev/null | sed 's/^v//')
    major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
    if [ -n "$v" ] && { [ "${major:-0}" -lt 2 ] || { [ "$major" = 2 ] && [ "${minor:-0}" -lt 17 ]; }; }; then
        die "$EXIT_DEPS" "Docker Compose $v is too old: 2.17 or newer is needed"
    fi
    case "$(docker version --format '{{.Server.Arch}}' 2>/dev/null)" in
        arm|armhf|armel|386) die "$EXIT_DEPS" "a 64-bit system is needed (MariaDB has no 32-bit image)" ;;
    esac
}

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# wait_for SECONDS DESCRIPTION COMMAND...: retries COMMAND every 3 s
wait_for() {
    local timeout=$1 what=$2; shift 2
    local deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        [ $SECONDS -lt "$deadline" ] || { say "timed out after ${timeout}s waiting for $what"; return 1; }
        sleep 3
    done
}

#!/usr/bin/env bash
# =============================================================================
#  RUST CROSS-COMPILER ULTIMATE v7 — MORON-PROOF EDITION
# =============================================================================
#  Guarantees:
#    - Works inside Docker/Podman containers AND native hosts
#    - Survives missing tools, broken rustup, no internet, full disks
#    - Self-detects filename (not hardcoded) for container re-exec
#    - Atomic lockfile prevents concurrent runs
#    - All network ops have timeouts & retry with resume
#    - Cleans up temp files even on SIGTERM/SIGINT
#    - Validates environment BEFORE doing anything destructive
# =============================================================================

# ═════════════════════════════════════════════════════════════════════════════
#  0. HARD FAIL GUARDS (these exit immediately, no logging yet)
# ═════════════════════════════════════════════════════════════════════════════

# Bash version check — nameref (local -n) needs 4.3+
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
   [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3 ]]; then
    echo "FATAL: Bash 4.3+ required (you have ${BASH_VERSION:-unknown})" >&2
    exit 1
fi

# Prevent running via sh/dash — bashisms will silently fail otherwise
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "FATAL: This script must be run with bash, not sh/dash" >&2
    exit 1
fi

# Detect if we're in a container (affects systemd, user groups, apt behavior)
_IN_CONTAINER=0
if [[ -f /.dockerenv ]] || grep -qE '(/docker/|/lxc/|/podman/|/kubepods/)' /proc/1/cgroup 2>/dev/null; then
    _IN_CONTAINER=1
fi

# ═════════════════════════════════════════════════════════════════════════════
#  1. STRICT MODE (with guards)
# ═════════════════════════════════════════════════════════════════════════════

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true
IFS=$'\n\t'

# ═════════════════════════════════════════════════════════════════════════════
#  2. SCRIPT SELF-AWARENESS
# ═════════════════════════════════════════════════════════════════════════════

# Resolve script path safely — handles symlinks, spaces, relative paths
_SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_SOURCE" ]]; do
    _SCRIPT_DIR_LINK="$(cd "$(dirname "$_SCRIPT_SOURCE")" && pwd)"
    _SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$_SCRIPT_SOURCE")"
    [[ "$_SCRIPT_SOURCE" != /* ]] && _SCRIPT_SOURCE="$_SCRIPT_DIR_LINK/$_SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_SOURCE")" && pwd)"
SCRIPT_NAME="$(basename "$_SCRIPT_SOURCE")"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

# ═════════════════════════════════════════════════════════════════════════════
#  3. PROJECT VALIDATION
# ═════════════════════════════════════════════════════════════════════════════

PROJ_DIR="$(pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-${PROJ_DIR}/deploy}"

# NOTE: Cargo.toml validation is done in main() so --help works from anywhere

# ═════════════════════════════════════════════════════════════════════════════
#  4. GLOBALS (with safe defaults)
# ═════════════════════════════════════════════════════════════════════════════

FORCE_BUILD="${FORCE_BUILD:-0}"
STRIP_BIN="${STRIP_BIN:-1}"
CHECKSUMS="${CHECKSUMS:-1}"
USE_DOCKER="${USE_DOCKER:-auto}"
DOCKER_IMAGE="${DOCKER_IMAGE:-rust-cross-ultimate:v7}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE="${LOG_FILE:-}"
LOCK_FILE="${LOCK_FILE:-${PROJ_DIR}/.rust-cross-build.lock}"

# CPU count with fallbacks for macOS, containers, bare metal
JOBS="${JOBS:-$(nproc 2>/dev/null || \
    sysctl -n hw.ncpu 2>/dev/null || \
    getconf _NPROCESSORS_ONLN 2>/dev/null || \
    grep -c '^processor' /proc/cpuinfo 2>/dev/null || \
    echo 2)}"
# Sanity cap
[[ "$JOBS" =~ ^[0-9]+$ ]] || JOBS=2
(( JOBS < 2 )) && JOBS=2 || true
(( JOBS > 32 )) && JOBS=32 || true

CONTAINER_CMD=""
FILTER_TARGET=""
FILTER_BIN=""
SHOW_MENU=0

# ═════════════════════════════════════════════════════════════════════════════
#  5. COLOR SUPPORT DETECTION
# ═════════════════════════════════════════════════════════════════════════════

if [[ -t 2 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'
    C='\033[0;36m'; D='\033[0;90m'; NC='\033[0m'; BD='\033[1m'
else
    R=''; G=''; Y=''; B=''; C=''; D=''; NC=''; BD=''
fi

# ═════════════════════════════════════════════════════════════════════════════
#  6. ATOMIC LOCKFILE (prevents concurrent builds)
# ═════════════════════════════════════════════════════════════════════════════

_acquire_lock() {
    local _lock_fd=200
    eval "exec $_lock_fd>\"$LOCK_FILE\"" 2>/dev/null || {
        echo "WARN: Cannot create lock file at $LOCK_FILE — continuing unlocked" >&2
        return 0
    }
    if ! flock -n $_lock_fd 2>/dev/null; then
        echo "FATAL: Another build is already running (lock: $LOCK_FILE)" >&2
        echo "       If you're sure no build is running, delete the lock file." >&2
        exit 1
    fi
    # Write PID into lock for debugging
    echo "$$" >&$_lock_fd 2>/dev/null || true
}
_release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════════
#  7. LOGGING (no process substitution = no zombie processes)
# ═════════════════════════════════════════════════════════════════════════════

_log() {
    local lvl="$1"; shift
    local ts; ts=$(date '+%H:%M:%S' 2>/dev/null || echo "??????")
    local color="${D}"
    case "$lvl" in
        DEBUG) color="${D}" ;; INFO)  color="${B}" ;; OK)    color="${G}" ;;
        WARN)  color="${Y}" ;; ERROR) color="${R}" ;; STEP)  color="${C}" ;;
        EXEC)  color="${D}" ;; FATAL) color="${R}${BD}" ;;
    esac
    printf "${color}[%-5s]${NC} ${D}%s${NC} %b\n" "$lvl" "$ts" "$*" >&2
}
log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && _log "DEBUG" "$@"; return 0; }
log_info()  { _log "INFO" "$@"; }
log_ok()    { _log "OK" "$@"; }
log_warn()  { _log "WARN" "$@"; }
log_error() { _log "ERROR" "$@"; }
log_step()  { echo "" >&2; _log "STEP" "═══ $* ═══"; }
log_exec()  { _log "EXEC" "$@"; }
log_fatal() { _log "FATAL" "$@"; _release_lock; exit 1; }

# ═════════════════════════════════════════════════════════════════════════════
#  8. CLEANUP (comprehensive, handles child processes)
# ═════════════════════════════════════════════════════════════════════════════

TEMP_DIRS=()
PIDS_TO_KILL=()
_cleanup() {
    local code=${1:-$?}
    log_debug "Cleanup triggered (exit code: $code)"

    # Kill child processes we spawned
    for _pid in "${PIDS_TO_KILL[@]}"; do
        kill "$_pid" 2>/dev/null || true
        wait "$_pid" 2>/dev/null || true
    done

    # Remove temp directories
    for _d in "${TEMP_DIRS[@]+${TEMP_DIRS[@]}}"; do
        [[ -n "$_d" && "$_d" != "/" && -d "$_d" ]] && rm -rf "$_d" 2>/dev/null || true
    done

    _release_lock

    # Restore terminal on interrupt
    [[ -t 2 ]] && stty sane 2>/dev/null || true

    exit "$code"
}
trap '_cleanup $?' EXIT INT TERM HUP

_mktemp_dir() {
    local _d
    _d=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/rcf.XXXXXX")
    if [[ "$_d" == *"XXXXXX" ]]; then
        # Very old system — use manual fallback
        _d="${TMPDIR:-/tmp}/rcf.$$.$RANDOM.$(date +%s)"
        mkdir -p "$_d" || { log_fatal "Cannot create temp directory"; }
    fi
    if [[ -z "$_d" || "$_d" == "/" ]]; then
        log_fatal "Refusing to use unsafe temp directory: '$_d'"
    fi
    TEMP_DIRS+=("$_d")
    printf '%s' "$_d"
}

# ═════════════════════════════════════════════════════════════════════════════
#  9. SAFE RM (never rm -rf a variable that could be empty)
# ═════════════════════════════════════════════════════════════════════════════

_safe_rm_rf() {
    local _path="$1"
    [[ -z "$_path" ]] && return 0
    [[ "$_path" == "/" ]] && { log_warn "Refusing to rm -rf /"; return 1; }
    [[ "$_path" == "$HOME" ]] && { log_warn "Refusing to rm -rf \$HOME"; return 1; }
    [[ -e "$_path" ]] && rm -rf "$_path" 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════════
#  10. COMMAND EXECUTORS (with logging & error capture)
# ═════════════════════════════════════════════════════════════════════════════

_run_cmd() {
    log_exec "$*"
    "$@"
}

_run_cmd_logged() {
    log_exec "$*"
    if ! "$@"; then
        local code=$?
        log_error "Command exited with code $code: $*"
        return "$code"
    fi
    return 0
}

_run_cmd_quiet() {
    log_debug "(quiet) $*"
    "$@" >/dev/null 2>&1
}

# Run with timeout (uses timeout command if available, else falls through)
_run_cmd_timeout() {
    local _secs="${1:-300}"; shift
    if _run_cmd_quiet command -v timeout; then
        timeout "$_secs" "$@"
    elif _run_cmd_quiet command -v gtimeout; then
        gtimeout "$_secs" "$@"
    else
        log_debug "timeout(1) not available — running without timeout"
        "$@"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  11. RETRY WITH EXPONENTIAL BACKOFF
# ═════════════════════════════════════════════════════════════════════════════

_retry() {
    local n=1 max=5 delay=3
    while true; do
        log_exec "$*"
        if "$@"; then
            return 0
        fi
        local code=$?
        if (( n == max )); then
            log_warn "Max retries reached (exit $code): $*"
            return "$code"
        fi
        log_warn "Retry $n/$max in ${delay}s... (exit: $code)"
        sleep "$delay"
        n=$((n+1)); delay=$((delay*2))
        # Cap delay at 60s
        (( delay > 60 )) && delay=60 || true
    done
}

# Retry with curl/wget resume support
_download_retry() {
    local _url="$1" _dest="$2"
    local n=1 max=5 delay=5
    mkdir -p "$(dirname "$_dest")" 2>/dev/null || true

    while true; do
        (( n <= max )) || break
        log_info "Download attempt $n/$max: $_url"

        if _run_cmd_quiet command -v curl; then
            # curl with resume (-C -), follow redirects (-L), fail on HTTP error (-f)
            if curl -fsSL -C - --max-time 300 --retry 0 \
                -o "$_dest" "$@" "$_url" 2>/dev/null; then
                return 0
            fi
        elif _run_cmd_quiet command -v wget; then
            # wget with continue (-c)
            if wget -q --show-progress -c -t 1 --timeout=300 \
                -O "$_dest" "$_url" 2>/dev/null; then
                return 0
            fi
        else
            log_fatal "Neither curl nor wget available — cannot download"
        fi

        log_warn "Download failed, waiting ${delay}s..."
        sleep "$delay"
        n=$((n+1)); delay=$((delay*2))
        (( delay > 60 )) && delay=60 || true
    done

    log_error "Download failed after $max attempts: $_url"
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  12. NETWORK CONNECTIVITY CHECK
# ═════════════════════════════════════════════════════════════════════════════

_check_network() {
    local _test_urls=(
        "https://github.com"
        "https://crates.io"
        "https://sh.rustup.rs"
    )
    for _url in "${_test_urls[@]}"; do
        if curl -fsSL -o /dev/null --max-time 10 "$_url" 2>/dev/null; then
            log_debug "Network OK ($_url)"
            return 0
        fi
    done
    log_warn "No internet connectivity detected — network features will fail"
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  13. DISK SPACE CHECK
# ═════════════════════════════════════════════════════════════════════════════

_check_disk_space() {
    local _dir="${1:-$PROJ_DIR}"
    local _needed_mb="${2:-2048}"
    local _avail_mb

    if _run_cmd_quiet command -v df; then
        _avail_mb=$(df -mP "$PROJ_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    fi
    [[ -z "$_avail_mb" || ! "$_avail_mb" =~ ^[0-9]+$ ]] && return 0  # Can't determine, press on

    if (( _avail_mb < _needed_mb )); then
        log_warn "Low disk space: ${_avail_mb}MB free (recommend ${_needed_mb}MB+)"
        return 1
    fi
    log_debug "Disk space OK: ${_avail_mb}MB free"
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  14. DISTRO DETECTION (robust)
# ═════════════════════════════════════════════════════════════════════════════

_get_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf 'unknown'
    fi
}

_get_distro_like() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        printf '%s' "${ID_LIKE:-${ID:-unknown}}"
    else
        printf 'unknown'
    fi
}

_get_distro_codename() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
    else
        printf 'unknown'
    fi
}

_get_distro_version_id() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        printf '%s' "${VERSION_ID:-unknown}"
    else
        printf 'unknown'
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  15. PACKAGE MANAGEMENT (with container awareness)
# ═════════════════════════════════════════════════════════════════════════════

_ensure_apt() {
    local pkgs=("$@")
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1

    # In containers, don't try to start services
    if [[ "$_IN_CONTAINER" -eq 1 ]]; then
        mkdir -p /etc/apt/apt.conf.d 2>/dev/null || true
        printf 'APT::Get::Assume-Yes "true";\nDPkg::Options {"--force-confold"};\n' \
            > /etc/apt/apt.conf.d/99failsafe 2>/dev/null || true
    fi

    # Check if apt-get is available
    if ! _run_cmd_quiet command -v apt-get; then
        log_warn "apt-get not found"
        return 1
    fi

    # In read-only containers, apt update will fail — handle gracefully
    log_exec "apt-get update"
    apt-get update -qq 2>/dev/null || {
        log_warn "apt-get update failed (read-only FS or no network?)"
        # Still try install in case index is stale but sufficient
    }

    log_exec "apt-get install -y --no-install-recommends ${pkgs[*]}"
    apt-get install -y --no-install-recommends "${pkgs[@]}" || return 1
    return 0
}

_ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    _run_cmd_quiet command -v "$cmd" && return 0
    log_warn "'$cmd' not found, installing '$pkg'..."
    local distro
    distro=$(_get_distro)
    case "$distro" in
        ubuntu|debian)
            _ensure_apt "$pkg" || return 1 ;;
        fedora|rhel|centos|rocky|almalinux)
            _run_cmd_logged dnf install -y "$pkg" || return 1 ;;
        arch|manjaro)
            _run_cmd_logged pacman -Sy --noconfirm "$pkg" || return 1 ;;
        alpine)
            _run_cmd_logged apk add --no-cache "$pkg" || return 1 ;;
        *)
            log_warn "Unknown distro '$distro', cannot install '$pkg'"
            return 1 ;;
    esac
    _run_cmd_quiet command -v "$cmd"
}

# ═════════════════════════════════════════════════════════════════════════════
#  16. PROJECT DETECTION (improved parsing)
# ═════════════════════════════════════════════════════════════════════════════

_get_bins() {
    local -a bins=()
    local in_bin=0 line_trimmed

    if [[ ! -f "${PROJ_DIR}/Cargo.toml" ]]; then
        printf ''
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$line_trimmed" == "[[bin]]" ]] && { in_bin=1; continue; }
        [[ "$line_trimmed" == \[* ]] && { in_bin=0; continue; }
        if [[ $in_bin -eq 1 && "$line_trimmed" == name* ]]; then
            local bn
            bn=$(printf '%s' "$line_trimmed" | sed -E "s/^name[[:space:]]*=[[:space:]]*['\"]?([^[:space:]'\"]+)['\"]?.*/\\1/")
            [[ -n "$bn" && "$bn" != "$line_trimmed" ]] && bins+=("$bn")
            in_bin=0
        fi
    done < "${PROJ_DIR}/Cargo.toml"

    # Fallback to package name
    if [[ ${#bins[@]} -eq 0 ]]; then
        local pkg
        pkg=$(grep -m1 '^name\s*=' "${PROJ_DIR}/Cargo.toml" 2>/dev/null | \
              sed -E "s/^name\s*=\s*['\"]?([^'\"]+)['\"]?.*/\\1/" | tr -d ' ')
        [[ -z "$pkg" ]] && pkg=$(basename "$PROJ_DIR")
        bins=("$pkg")
    fi

    printf '%s\n' "${bins[@]}"
}

_should_build() {
    local needle="$1" haystack="$2"
    [[ -z "$haystack" ]] && return 0
    local found=0
    local IFS_saved; IFS_saved="$IFS"
    IFS=','
    for item in $haystack; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ "$item" == "$needle" ]] && found=1
    done
    IFS="$IFS_saved"
    [[ $found -eq 1 ]]
}

# ═════════════════════════════════════════════════════════════════════════════
#  17. CLI / HELP / MENU
# ═════════════════════════════════════════════════════════════════════════════

_show_help() {
    local _sn="${SCRIPT_NAME:-autobuild.sh}"
    cat <<HELP
Usage: ${_sn} [OPTIONS]

OPTIONS:
  -h, --help              Show help
  --menu                  Interactive configuration menu
  --target <t>            Build only specific target(s), comma-separated
  --bin <name>            Build only specific binary(s), comma-separated
  --no-strip              Disable stripping
  --no-checksum           Disable SHA256 checksums
  -f, --force             Force rebuild
  --debug                 Debug logging
  --native                Force native (no container)
  --docker                Force container engine (installs if missing)
  --log-file <path>       Write ALL output to log file
  --lock-file <path>      Override default lock file location

ENV:
  DEPLOY_DIR, FORCE_BUILD, STRIP_BIN, CHECKSUMS, USE_DOCKER,
  LOG_LEVEL, LOG_FILE, JOBS, LOCK_FILE, DOCKER_IMAGE

EXAMPLES:
  ./${_sn} --native --target x86_64-unknown-linux-gnu
  ./${_sn} --docker --log-file build.log
  FORCE_BUILD=1 ./${_sn} --native
HELP
}

_menu_header() {
    echo "" >&2
    echo -e "${C}${BD}═══════════════════════════════════════════════════════════════${NC}" >&2
    echo -e "${C}${BD}  $1${NC}" >&2
    echo -e "${C}${BD}═══════════════════════════════════════════════════════════════${NC}" >&2
    echo "" >&2
}

_menu_yn() {
    local prompt="$1" default="${2:-y}"
    local val
    while true; do
        printf "${BD}%s${NC} [%s]: " "$prompt" "$default" >&2
        # Handle non-interactive (CI/container) gracefully
        if [[ ! -t 0 ]]; then
            echo "$default" >&2
            [[ "$default" == [Yy]* ]] && return 0 || return 1
        fi
        read -r val
        [[ -z "$val" ]] && val="$default"
        case "$val" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
        echo "  Please answer y or n." >&2
    done
}

_show_menu() {
    local val tmp
    local -a BINS
    mapfile -t BINS < <(_get_bins)

    _menu_header "Rust Cross-Compiler — Interactive Setup"
    echo "Configure your cross-compilation build." >&2

    if [[ -t 0 ]]; then
        printf "${BD}Press Enter to continue...${NC} " >&2; read -r
    fi

    _menu_header "1. Build Mode"
    echo "  1) auto   — Auto-detect (container preferred)" >&2
    echo "  2) native — No container (host toolchain)" >&2
    echo "  3) docker — Force container (installs if missing)" >&2
    printf "${BD}Select [1]:${NC} " >&2; read -r val
    case "$val" in 2) USE_DOCKER="no" ;; 3) USE_DOCKER="yes" ;; *) USE_DOCKER="auto" ;; esac
    echo "  -> $USE_DOCKER" >&2

    _menu_header "2. Targets"
    echo "  1) x86_64-unknown-linux-gnu      Linux x86-64" >&2
    echo "  2) x86_64-pc-windows-gnu         Windows x86-64 (MinGW)" >&2
    echo "  3) i686-pc-windows-gnu           Windows x86 (MinGW)" >&2
    echo "  4) x86_64-pc-windows-msvc        Windows x86-64 (MSVC)" >&2
    echo "  5) aarch64-pc-windows-msvc       Windows ARM64 (MSVC)" >&2
    echo "  6) aarch64-unknown-linux-gnu     Linux ARM64" >&2
    echo "  7) armv7-unknown-linux-gnueabihf Linux ARMv7" >&2
    echo "  8) riscv64gc-unknown-linux-gnu   Linux RISC-V" >&2
    echo "  9) x86_64-apple-darwin           macOS x86-64" >&2
    echo " 10) aarch64-apple-darwin          macOS ARM64" >&2
    printf "${BD}Select [all]:${NC} " >&2; read -r val
    val="${val// /}"
    if [[ -z "$val" || "$val" == "all" ]]; then
        FILTER_TARGET="x86_64-unknown-linux-gnu,x86_64-pc-windows-gnu,i686-pc-windows-gnu,x86_64-pc-windows-msvc,aarch64-pc-windows-msvc,aarch64-unknown-linux-gnu,armv7-unknown-linux-gnueabihf,riscv64gc-unknown-linux-gnu,x86_64-apple-darwin,aarch64-apple-darwin"
    else
        tmp=""
        local IFS_saved; IFS_saved="$IFS"
        IFS=','
        for n in $val; do
            case "$n" in
                1) tmp="${tmp},x86_64-unknown-linux-gnu" ;;
                2) tmp="${tmp},x86_64-pc-windows-gnu" ;;
                3) tmp="${tmp},i686-pc-windows-gnu" ;;
                4) tmp="${tmp},x86_64-pc-windows-msvc" ;;
                5) tmp="${tmp},aarch64-pc-windows-msvc" ;;
                6) tmp="${tmp},aarch64-unknown-linux-gnu" ;;
                7) tmp="${tmp},armv7-unknown-linux-gnueabihf" ;;
                8) tmp="${tmp},riscv64gc-unknown-linux-gnu" ;;
                9) tmp="${tmp},x86_64-apple-darwin" ;;
                10) tmp="${tmp},aarch64-apple-darwin" ;;
            esac
        done
        IFS="$IFS_saved"
        FILTER_TARGET="${tmp#,}"
    fi
    echo "  -> ${FILTER_TARGET//,/ }" >&2

    _menu_header "3. Binaries"
    local i=1
    for b in "${BINS[@]}"; do
        echo "  $i) $b" >&2
        i=$((i+1))
    done
    printf "${BD}Select [all]:${NC} " >&2; read -r val
    val="${val// /}"
    if [[ -z "$val" || "$val" == "all" ]]; then
        FILTER_BIN=""
    else
        tmp=""
        local IFS_saved; IFS_saved="$IFS"
        IFS=','
        for n in $val; do
            local idx=$((n-1))
            [[ $idx -ge 0 && $idx -lt ${#BINS[@]} ]] && tmp="${tmp},${BINS[$idx]}"
        done
        IFS="$IFS_saved"
        FILTER_BIN="${tmp#,}"
    fi
    echo "  -> ${FILTER_BIN:-all}" >&2

    _menu_header "4. Options"
    _menu_yn "Strip binaries?" "y" && STRIP_BIN=1 || STRIP_BIN=0
    _menu_yn "Generate checksums?" "y" && CHECKSUMS=1 || CHECKSUMS=0
    _menu_yn "Force rebuild?" "n" && FORCE_BUILD=1 || FORCE_BUILD=0

    _menu_header "5. Summary"
    echo "  Mode:     $USE_DOCKER" >&2
    echo "  Targets:  ${FILTER_TARGET//,/ }" >&2
    echo "  Binaries: ${FILTER_BIN:-all}" >&2
    echo "  Strip:    $([[ $STRIP_BIN -eq 1 ]] && echo yes || echo no)" >&2
    echo "  Checksum: $([[ $CHECKSUMS -eq 1 ]] && echo yes || echo no)" >&2
    echo "  Force:    $([[ $FORCE_BUILD -eq 1 ]] && echo yes || echo no)" >&2
    echo "  Log file: ${LOG_FILE:-(none)}" >&2
    if _menu_yn "Start build?" "y"; then
        echo -e "${G}Starting build...${NC}" >&2; sleep 1
    else
        echo -e "${Y}Cancelled.${NC}" >&2; exit 0
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  18. CONTAINER ENGINE (robust detection + install)
# ═════════════════════════════════════════════════════════════════════════════

_detect_container() {
    if _run_cmd_quiet command -v docker; then
        # Check if docker daemon is reachable
        if docker info >/dev/null 2>&1; then
            CONTAINER_CMD="docker"
            log_ok "Docker detected and running"
            return 0
        elif docker ps >/dev/null 2>&1; then
            CONTAINER_CMD="docker"
            log_ok "Docker detected (rootless/privileged)"
            return 0
        fi
        log_warn "Docker installed but daemon not running"
    fi
    if _run_cmd_quiet command -v podman; then
        if podman info >/dev/null 2>&1; then
            CONTAINER_CMD="podman"
            log_ok "Podman detected and running"
            return 0
        fi
        log_warn "Podman installed but not functional"
    fi
    if _run_cmd_quiet command -v nerdctl; then
        if nerdctl info >/dev/null 2>&1; then
            CONTAINER_CMD="nerdctl"
            log_ok "nerdctl detected and running"
            return 0
        fi
    fi
    return 1
}

_install_docker() {
    log_step "Installing Docker Engine"

    # Can't install Docker in a container (no kernel access, no systemd)
    if [[ "$_IN_CONTAINER" -eq 1 ]]; then
        log_warn "Running inside a container — cannot install Docker daemon"
        return 1
    fi

    # Need root for Docker install
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_warn "Docker install requires root. Try: sudo $SCRIPT_NAME --docker"
        return 1
    fi

    local distro; distro=$(_get_distro)
    local codename; codename=$(_get_distro_codename)
    local like; like=$(_get_distro_like)

    log_info "Distro: $distro (like: $like), codename: $codename"

    # Validate we can determine architecture
    if ! _run_cmd_quiet command -v dpkg; then
        log_warn "dpkg not found — cannot determine architecture for Docker repo"
        return 1
    fi

    local arch
    arch=$(dpkg --print-architecture)

    # Determine correct Docker repo
    local docker_repo="ubuntu"
    if [[ "$distro" == "debian" || "$like" == *"debian"* ]]; then
        docker_repo="debian"
    elif [[ "$distro" == "ubuntu" || "$like" == *"ubuntu"* ]]; then
        docker_repo="ubuntu"
    fi

    # Map codename for edge cases
    if [[ "$codename" == "trixie" && "$docker_repo" == "ubuntu" ]]; then
        docker_repo="debian"
        codename="trixie"
    fi

    # Fallback for unknown codename on Debian -> use stable
    if [[ "$docker_repo" == "debian" && ( "$codename" == "unknown" || -z "$codename" ) ]]; then
        codename="bookworm"
        log_warn "Unknown Debian codename — using '$codename' as fallback"
    fi

    log_info "Using Docker repo: $docker_repo, codename: $codename, arch: $arch"

    # Install prerequisites
    _ensure_apt ca-certificates curl gnupg lsb-release || return 1

    # Add Docker GPG key (with temp dir for safety)
    local _keyring_tmp
    _keyring_tmp=$(_mktemp_dir)
    install -m 0755 -d /etc/apt/keyrings 2>/dev/null || mkdir -p /etc/apt/keyrings

    if ! curl -fsSL --max-time 30 "https://download.docker.com/linux/${docker_repo}/gpg" \
         -o "${_keyring_tmp}/docker.gpg.raw" 2>/dev/null; then
        log_warn "Failed to download Docker GPG key"
        return 1
    fi
    gpg --dearmor < "${_keyring_tmp}/docker.gpg.raw" > /etc/apt/keyrings/docker.gpg 2>/dev/null || {
        log_warn "Failed to dearmor Docker GPG key"
        return 1
    }
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$arch" "$docker_repo" "$codename" > /etc/apt/sources.list.d/docker.list

    # Install Docker
    apt-get update -qq || true
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
        log_warn "Docker package install failed"
        return 1
    }

    # Start and enable (but not in containers)
    if [[ "$_IN_CONTAINER" -eq 0 ]]; then
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || {
            log_warn "Could not start docker service"
        }
        systemctl enable docker 2>/dev/null || true

        # Add user to docker group
        local _current_user
        _current_user="${SUDO_USER:-${USER:-$(whoami)}}"
        if [[ -n "$_current_user" && "$_current_user" != "root" ]]; then
            usermod -aG docker "$_current_user" 2>/dev/null || true
            log_info "Added '$_current_user' to docker group (re-login required)"
        fi
    fi

    # Verify
    if _run_cmd_quiet command -v docker && docker info >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        log_ok "Docker installed and running"
        return 0
    fi

    return 1
}

_install_podman() {
    log_step "Installing Podman"
    local distro; distro=$(_get_distro)
    case "$distro" in
        ubuntu|debian)
            _ensure_apt podman ;;
        fedora|rhel|centos|rocky|almalinux)
            dnf install -y podman ;;
        arch|manjaro)
            pacman -Sy --noconfirm podman ;;
        alpine)
            apk add --no-cache podman ;;
        *)
            log_warn "Cannot auto-install podman on $distro"
            return 1 ;;
    esac

    if _run_cmd_quiet command -v podman && podman info >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        log_ok "Podman installed and running"
        return 0
    fi
    return 1
}

_ensure_container() {
    [[ "$USE_DOCKER" == "no" ]] && { log_info "Container mode disabled"; return 1; }
    [[ -n "$CONTAINER_CMD" ]] && return 0

    if _detect_container; then
        return 0
    fi

    if [[ "$USE_DOCKER" == "yes" || "$USE_DOCKER" == "auto" ]]; then
        log_info "No container engine found. Attempting auto-install..."

        if _install_docker; then
            return 0
        fi

        log_warn "Docker install failed, trying Podman..."
        if _install_podman; then
            return 0
        fi

        log_warn "Could not install any container engine"
    fi

    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  19. CONTAINER IMAGE BUILD (re-entrant, handles partial builds)
# ═════════════════════════════════════════════════════════════════════════════

_build_container_image() {
    log_step "Building Container Image ($DOCKER_IMAGE)"

    # Check if image already exists and we're not forcing rebuild
    if $CONTAINER_CMD image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 && \
       [[ "$FORCE_BUILD" != "1" ]]; then
        log_ok "Container image exists"
        return 0
    fi

    # Also check if a build is currently in progress (Docker's own lock)
    # by checking for dangling build containers

    local tmpdir
    tmpdir=$(_mktemp_dir)

    # Write Containerfile with embedded version marker for cache invalidation
    cat > "$tmpdir/Containerfile" <<CONTAINER_EOF
FROM ubuntu:24.04
LABEL rust-cross.version="7"
ENV DEBIAN_FRONTEND=noninteractive \\
    NONINTERACTIVE=1 \\
    RUSTUP_HOME=/usr/local/rustup \\
    CARGO_HOME=/usr/local/cargo \\
    CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \\
    PATH=/usr/local/cargo/bin:/opt/llvm-mingw/bin:/opt/osxcross/target/bin:/root/.local/bin:\$PATH

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \\
    ca-certificates curl wget git build-essential cmake pkg-config \\
    tar xz-utils unzip libxml2-dev zlib1g-dev bison flex \\
    libssl-dev mingw-w64 clang lld llvm \\
    gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu gcc-arm-linux-gnueabihf \\
    jq file python3 \\
    && rm -rf /var/lib/apt/lists/*

# Install Rust (with retry)
RUN curl --proto '=https' --tlsv1.2 -fsSL --max-time 120 https://sh.rustup.rs \\
    | sh -s -- -y --default-toolchain stable --no-modify-path \\
    && chmod -R a+w \$RUSTUP_HOME \$CARGO_HOME

# Install all cross-compilation targets
RUN rustup target add \\
    x86_64-unknown-linux-gnu \\
    x86_64-pc-windows-gnu \\
    i686-pc-windows-gnu \\
    x86_64-pc-windows-msvc \\
    aarch64-pc-windows-msvc \\
    aarch64-unknown-linux-gnu \\
    armv7-unknown-linux-gnueabihf \\
    riscv64gc-unknown-linux-gnu \\
    x86_64-apple-darwin \\
    aarch64-apple-darwin

# Install llvm-mingw
RUN mkdir -p /opt/llvm-mingw \\
    && curl -fsSL --max-time 300 "https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz" \\
    -o /tmp/llvm-mingw.tar.xz \\
    && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt/llvm-mingw --strip-components=1 \\
    && rm -f /tmp/llvm-mingw.tar.xz

# Install osxcross
RUN git clone --depth=1 https://github.com/tpoechtrager/osxcross /opt/osxcross \\
    && wget -q --timeout=60 "https://github.com/joseluisq/macosx-sdks/releases/download/11.3/MacOSX11.3.sdk.tar.xz" -P /opt/osxcross/tarballs/ \\
    && cd /opt/osxcross && UNATTENDED=yes OSX_VERSION_MIN=10.13 ./build.sh \\
    && cd / && rm -rf /opt/osxcross/.git

# Install cargo tools
RUN cargo install xwin cargo-xwin \\
    && mkdir -p /xwin \\
    && xwin --accept-license --arch x86_64 --arch aarch64 splat --output /xwin \\
    && rm -rf .xwin-cache

RUN cargo install cargo-zigbuild cross

# Symlink toolchain aliases
RUN mkdir -p /root/.local/bin \\
    && ln -sf \$(command -v ld.lld 2>/dev/null) /root/.local/bin/lld-link 2>/dev/null || true \\
    && ln -sf \$(command -v llvm-ar 2>/dev/null) /root/.local/bin/llvm-lib 2>/dev/null || true \\
    && ln -sf \$(command -v clang 2>/dev/null) /root/.local/bin/clang-cl 2>/dev/null || true

# Cargo config
RUN mkdir -p \$CARGO_HOME && cat > \$CARGO_HOME/config.toml <<'CARGO_EOF'
[registries.crates-io]
protocol = "sparse"

[target.x86_64-pc-windows-gnu]
linker = "x86_64-w64-mingw32-gcc"

[target.i686-pc-windows-gnu]
linker = "i686-w64-mingw32-gcc"

[target.x86_64-pc-windows-msvc]
linker = "lld-link"
ar = "llvm-lib"

[target.aarch64-pc-windows-msvc]
linker = "lld-link"
ar = "llvm-lib"

[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"

[target.armv7-unknown-linux-gnueabihf]
linker = "arm-linux-gnueabihf-gcc"

[target.riscv64gc-unknown-linux-gnu]
linker = "riscv64-linux-gnu-gcc"

[target.x86_64-apple-darwin]
linker = "x86_64-apple-darwin20.4-clang"

[target.aarch64-apple-darwin]
linker = "aarch64-apple-darwin20.4-clang"
CARGO_EOF

WORKDIR /workspace
CONTAINER_EOF

    log_info "Building image (this takes 10-20 min first time)..."
    log_info "Build log: $tmpdir/build.log"

    # Build with timeout and log capture
    if _run_cmd_timeout 1800 "$CONTAINER_CMD" build -t "$DOCKER_IMAGE" \
         -f "$tmpdir/Containerfile" "$tmpdir" >"$tmpdir/build.log" 2>&1; then
        log_ok "Container image built"
        return 0
    else
        log_error "Container image build failed"
        if [[ -f "$tmpdir/build.log" ]]; then
            log_info "Last 50 lines of build log:"
            tail -n 50 "$tmpdir/build.log" | sed 's/^/  [build] /' >&2
        fi
        return 1
    fi
}

_run_container_build() {
    log_step "Running build in container"
    mkdir -p "$DEPLOY_DIR"

    local -a inner_args=("--native")
    [[ -n "$FILTER_TARGET" ]] && inner_args+=("--target" "$FILTER_TARGET")
    [[ -n "$FILTER_BIN" ]] && inner_args+=("--bin" "$FILTER_BIN")
    [[ "$STRIP_BIN" == "0" ]] && inner_args+=("--no-strip")
    [[ "$CHECKSUMS" == "0" ]] && inner_args+=("--no-checksum")
    [[ "$FORCE_BUILD" == "1" ]] && inner_args+=("--force")
    [[ "$LOG_LEVEL" == "DEBUG" ]] && inner_args+=("--debug")

    local -a extra_args=()
    [[ "$CONTAINER_CMD" == "podman" ]] && extra_args+=("--userns=keep-id")

    # In Docker Desktop / rootless, we need to handle user mapping
    # Use the actual script name, not hardcoded
    local script_in_container="/workspace/$SCRIPT_NAME"

    log_exec "$CONTAINER_CMD run --rm ${extra_args[*]} -v ${PROJ_DIR}:/workspace ..."

    $CONTAINER_CMD run --rm \
        "${extra_args[@]}" \
        -v "${PROJ_DIR}:/workspace" \
        -v "rust-cross-registry:/usr/local/cargo/registry" \
        -v "rust-cross-git:/usr/local/cargo/git" \
        -e "FORCE_BUILD=$FORCE_BUILD" \
        -e "STRIP_BIN=$STRIP_BIN" \
        -e "CHECKSUMS=$CHECKSUMS" \
        -e "LOG_LEVEL=$LOG_LEVEL" \
        -e "DEPLOY_DIR=/workspace/deploy" \
        "$DOCKER_IMAGE" \
        bash -lc "cd /workspace && bash $script_in_container ${inner_args[*]}"
}

# ═════════════════════════════════════════════════════════════════════════════
#  20. RUST TOOLCHAIN (with aggressive auto-repair)
# ═════════════════════════════════════════════════════════════════════════════

_repair_rustup() {
    log_warn "rustup toolchain appears broken. Attempting repair..."

    # Method 1: Remove and reinstall stable
    log_info "Removing broken stable toolchain..."
    rustup toolchain uninstall stable 2>/dev/null || true

    log_info "Reinstalling stable toolchain..."
    if rustup toolchain install stable; then
        rustup default stable
        log_ok "rustup repaired successfully"
        return 0
    fi

    # Method 2: Full rustup reinstall
    log_warn "Toolchain reinstall failed. Trying full rustup reinstall..."
    rustup self uninstall -y 2>/dev/null || true

    # Fresh install
    local _rustup_tmp
    _rustup_tmp=$(_mktemp_dir)
    if _download_retry "https://sh.rustup.rs" "${_rustup_tmp}/rustup.sh"; then
        bash "${_rustup_tmp}/rustup.sh" -y --default-toolchain stable 2>/dev/null
    fi

    # Source cargo env with fallbacks
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi
    export PATH="$HOME/.cargo/bin:$PATH"

    if rustup default stable >/dev/null 2>&1; then
        log_ok "rustup fully reinstalled"
        return 0
    fi

    log_error "Could not repair rustup"
    return 1
}

_verify_rustup() {
    log_step "Verifying Rust Toolchain"
    export PATH="$HOME/.cargo/bin:$PATH"

    if ! _run_cmd_quiet command -v rustup; then
        log_warn "rustup not found, installing..."

        local _rustup_tmp
        _rustup_tmp=$(_mktemp_dir)
        if ! _download_retry "https://sh.rustup.rs" "${_rustup_tmp}/rustup.sh"; then
            log_fatal "Cannot download rustup installer — check network connectivity"
        fi

        if ! bash "${_rustup_tmp}/rustup.sh" -y --default-toolchain stable; then
            log_fatal "rustup installation failed"
        fi

        if [[ -f "$HOME/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "$HOME/.cargo/env"
        fi
        export PATH="$HOME/.cargo/bin:$PATH"
    fi

    # Check if toolchain is broken (Missing manifest, etc.)
    if ! rustc --version >/dev/null 2>&1; then
        log_warn "rustc not working — toolchain may be broken"
        _repair_rustup || return 1
    fi

    # Check manifest explicitly
    if ! rustup component list >/dev/null 2>&1; then
        log_warn "rustup component list failed — toolchain broken"
        _repair_rustup || return 1
    fi

    local _rustc_ver _cargo_ver
    _rustc_ver=$(rustc --version 2>/dev/null || echo "unknown")
    _cargo_ver=$(cargo --version 2>/dev/null || echo "unknown")
    log_ok "Rust ready: $_rustc_ver"
    log_ok "Cargo ready: $_cargo_ver"
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  21. XWIN / MSVC SETUP (with retry + cache + validation)
# ═════════════════════════════════════════════════════════════════════════════

_setup_xwin_msvc() {
    log_step "Setting up MSVC SDK (xwin)"

    # Check if cargo-xwin available
    if _run_cmd_quiet command -v cargo-xwin; then
        if cargo xwin --help >/dev/null 2>&1; then
            log_ok "cargo-xwin available"
            return 0
        fi
    fi

    # Install xwin if needed
    if ! _run_cmd_quiet command -v xwin; then
        log_info "Installing xwin..."
        if ! _run_cmd_logged cargo install xwin; then
            log_warn "xwin installation failed"
            return 1
        fi
    fi

    local xwin_out
    xwin_out="${XWIN_PATH:-$HOME/.xwin}"

    # Check if already present and valid
    if [[ -f "$xwin_out/sdk/lib/um/x86_64/kernel32.lib" && \
          -f "$xwin_out/sdk/lib/um/aarch64/kernel32.lib" ]]; then
        log_ok "xwin SDK already present"
        export XWIN_PATH="$xwin_out"
        return 0
    fi

    # Clean partial downloads
    _safe_rm_rf "$HOME/.xwin-cache"
    _safe_rm_rf "$xwin_out"
    mkdir -p "$xwin_out"

    # Download with retry (using our robust downloader for xwin itself)
    local attempt=1
    local max_attempts=3
    while true; do
        (( attempt <= max_attempts )) || break
        log_info "Download attempt $attempt/$max_attempts..."

        if (cd "$HOME" && xwin --accept-license \
            --cache-dir "$xwin_out/.cache" \
            --arch x86_64 --arch aarch64 \
            splat --output "$xwin_out"); then
            break
        fi

        log_warn "xwin download failed, waiting before retry..."
        _safe_rm_rf "$HOME/.xwin-cache"
        sleep 10
        attempt=$((attempt+1))
    done

    if (( attempt > max_attempts )); then
        log_warn "xwin download failed after $max_attempts attempts"
        return 1
    fi

    # Verify artifacts
    local _missing=0
    if [[ ! -f "$xwin_out/sdk/lib/um/x86_64/kernel32.lib" ]]; then
        log_warn "xwin x86_64 libs missing after download"
        _missing=1
    fi
    if [[ ! -f "$xwin_out/sdk/lib/um/aarch64/kernel32.lib" ]]; then
        log_warn "xwin aarch64 libs missing after download"
        _missing=1
    fi

    if [[ "$_missing" -eq 1 ]]; then
        return 1
    fi

    log_ok "xwin SDK ready at $xwin_out"
    export XWIN_PATH="$xwin_out"
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  22. SYSTEM DEPS (per-distro, with graceful degradation)
# ═════════════════════════════════════════════════════════════════════════════

_install_system_deps() {
    log_step "Installing System Dependencies"

    # Check if we even have a package manager
    if ! _run_cmd_quiet command -v apt-get && \
       ! _run_cmd_quiet command -v dnf && \
       ! _run_cmd_quiet command -v pacman && \
       ! _run_cmd_quiet command -v apk; then
        log_warn "No supported package manager found — assuming deps are pre-installed"
        return 0
    fi

    local distro; distro=$(_get_distro)

    case "$distro" in
        ubuntu|debian)
            _ensure_apt curl git cmake make xz-utils clang lld llvm \
                mingw-w64 gcc-mingw-w64 \
                gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu gcc-arm-linux-gnueabihf \
                libssl-dev zlib1g-dev pkg-config jq file \
                || log_warn "Some packages could not be installed (continuing anyway)"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            dnf install -y curl git cmake make clang lld llvm \
                mingw64-gcc mingw32-gcc \
                gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu gcc-arm-linux-gnu \
                openssl-devel zlib-devel \
                || log_warn "Some packages could not be installed (continuing anyway)"
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm curl git cmake make clang lld llvm \
                mingw-w64 gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu \
                gcc-arm-linux-gnueabihf openssl zlib pkg-config jq file \
                || log_warn "Some packages could not be installed (continuing anyway)"
            ;;
        alpine)
            # Alpine uses musl — many cross-compilers aren't available
            log_warn "Alpine Linux detected — cross-compilation support is limited"
            apk add --no-cache curl git cmake make clang lld llvm \
                mingw-w64 gcc-aarch64-linux-gnu pkg-config jq file \
                || log_warn "Some packages could not be installed"
            ;;
        *)
            log_warn "Unknown distro '$distro' — cannot auto-install system deps"
            ;;
    esac

    # Individual tool checks (best-effort)
    _ensure_cmd curl curl || true
    _ensure_cmd git git || true
    _ensure_cmd cmake cmake || true
    _ensure_cmd xz xz-utils || true
    _ensure_cmd jq jq || true
}

# ═════════════════════════════════════════════════════════════════════════════
#  23. LLVM-MINGW (with validation)
# ═════════════════════════════════════════════════════════════════════════════

_setup_llvm_mingw() {
    local LLVM_MINGW_HOME
    LLVM_MINGW_HOME="${LLVM_MINGW_HOME:-$HOME/.local/llvm-mingw}"

    if [[ -d "$LLVM_MINGW_HOME/bin" ]]; then
        export PATH="$LLVM_MINGW_HOME/bin:$PATH"
        # Validate binaries actually work
        if "$LLVM_MINGW_HOME/bin/x86_64-w64-mingw32-gcc" --version >/dev/null 2>&1; then
            log_debug "llvm-mingw already installed and valid"
            return 0
        fi
        log_warn "llvm-mingw exists but binaries are broken — reinstalling"
        _safe_rm_rf "$LLVM_MINGW_HOME"
    fi

    log_warn "Installing llvm-mingw..."
    mkdir -p "$LLVM_MINGW_HOME"

    local _llvm_tmp
    _llvm_tmp=$(_mktemp_dir)
    local _llvm_url
    _llvm_url="https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64.tar.xz"

    if _download_retry "$_llvm_url" "${_llvm_tmp}/llvm-mingw.tar.xz"; then
        if tar -xJf "${_llvm_tmp}/llvm-mingw.tar.xz" -C "$LLVM_MINGW_HOME" --strip-components=1; then
            export PATH="$LLVM_MINGW_HOME/bin:$PATH"
            if "$LLVM_MINGW_HOME/bin/x86_64-w64-mingw32-gcc" --version >/dev/null 2>&1; then
                log_ok "llvm-mingw installed"
            else
                log_warn "llvm-mingw extracted but binaries don't work"
            fi
        else
            log_warn "Failed to extract llvm-mingw"
            _safe_rm_rf "$LLVM_MINGW_HOME"
        fi
    else
        log_warn "llvm-mingw download failed"
        _safe_rm_rf "$LLVM_MINGW_HOME"
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  24. OSXCross (with cache + validation)
# ═════════════════════════════════════════════════════════════════════════════

_setup_osxcross() {
    local OSXCROSS_HOME
    OSXCROSS_HOME="${OSXCROSS_HOME:-$HOME/.local/osxcross}"

    if [[ -d "$OSXCROSS_HOME/target/bin" ]]; then
        export PATH="$OSXCROSS_HOME/target/bin:$PATH"
        if "$OSXCROSS_HOME/target/bin/x86_64-apple-darwin20.4-clang" --version >/dev/null 2>&1; then
            log_debug "osxcross already installed and valid"
            return 0
        fi
        log_warn "osxcross exists but broken — rebuilding"
        _safe_rm_rf "$OSXCROSS_HOME"
    fi

    log_warn "Building osxcross (takes a while)..."
    local osx_tmp
    osx_tmp=$(_mktemp_dir)
    local ok=0

    if _retry git clone --depth=1 https://github.com/tpoechtrager/osxcross "$osx_tmp"; then
        if _download_retry \
            "https://github.com/joseluisq/macosx-sdks/releases/download/11.3/MacOSX11.3.sdk.tar.xz" \
            "$osx_tmp/tarballs/MacOSX11.3.sdk.tar.xz"; then
            if (cd "$osx_tmp" && UNATTENDED=yes OSX_VERSION_MIN=10.13 ./build.sh); then
                mv "$osx_tmp" "$OSXCROSS_HOME"
                export PATH="$OSXCROSS_HOME/target/bin:$PATH"
                if "$OSXCROSS_HOME/target/bin/x86_64-apple-darwin20.4-clang" --version >/dev/null 2>&1; then
                    log_ok "osxcross built and validated"
                    ok=1
                else
                    log_warn "osxcross built but compiler doesn't work"
                fi
            else
                log_warn "osxcross build failed"
            fi
        else
            log_warn "macOS SDK download failed"
        fi
    fi

    if [[ "$ok" -eq 0 ]]; then
        _safe_rm_rf "$osx_tmp"
        _safe_rm_rf "$OSXCROSS_HOME"
        return 1
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  25. ZIGBUILD / CROSS (optional, non-fatal)
# ═════════════════════════════════════════════════════════════════════════════

_setup_zigbuild() {
    _run_cmd_quiet command -v cargo-zigbuild && { log_ok "cargo-zigbuild available"; return 0; }
    log_warn "Installing cargo-zigbuild..."
    if _run_cmd_timeout 300 cargo install cargo-zigbuild; then
        log_ok "cargo-zigbuild installed"
    else
        log_warn "cargo-zigbuild installation failed (will use plain cargo)"
    fi
    return 0
}

_setup_cross() {
    _run_cmd_quiet command -v cross && { log_ok "cross available"; return 0; }
    log_warn "Installing cross..."
    if _run_cmd_timeout 300 cargo install cross; then
        log_ok "cross installed"
    else
        log_warn "cross installation failed (will use plain cargo)"
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  26. CARGO CONFIG (with backup restore)
# ═════════════════════════════════════════════════════════════════════════════

_write_cargo_config() {
    local cfg_dir
    cfg_dir="${PROJ_DIR}/.cargo"
    mkdir -p "$cfg_dir"

    if [[ -f "$cfg_dir/config.toml" && ! -f "$cfg_dir/config.toml.backup" ]]; then
        cp "$cfg_dir/config.toml" "$cfg_dir/config.toml.backup"
        log_debug "Existing config.toml backed up"
    fi

    cat > "$cfg_dir/config.toml" <<'BASE_CFG'
[registries.crates-io]
protocol = "sparse"

[target.x86_64-pc-windows-gnu]
linker = "x86_64-w64-mingw32-gcc"

[target.i686-pc-windows-gnu]
linker = "i686-w64-mingw32-gcc"

[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"

[target.armv7-unknown-linux-gnueabihf]
linker = "arm-linux-gnueabihf-gcc"

[target.riscv64gc-unknown-linux-gnu]
linker = "riscv64-linux-gnu-gcc"

[target.x86_64-apple-darwin]
linker = "x86_64-apple-darwin20.4-clang"

[target.aarch64-apple-darwin]
linker = "aarch64-apple-darwin20.4-clang"
BASE_CFG

    log_ok "Cargo config written to ${cfg_dir}/config.toml"
}

# ═════════════════════════════════════════════════════════════════════════════
#  27. LINKER CHECK
# ═════════════════════════════════════════════════════════════════════════════

_check_linker() {
    local target="$1"
    case "$target" in
        x86_64-pc-windows-gnu)
            _run_cmd_quiet command -v x86_64-w64-mingw32-gcc || return 1 ;;
        i686-pc-windows-gnu)
            _run_cmd_quiet command -v i686-w64-mingw32-gcc || return 1 ;;
        x86_64-pc-windows-msvc)
            _run_cmd_quiet command -v lld-link || return 1 ;;
        aarch64-pc-windows-msvc)
            _run_cmd_quiet command -v lld-link || return 1 ;;
        aarch64-unknown-linux-gnu)
            _run_cmd_quiet command -v aarch64-linux-gnu-gcc || return 1 ;;
        armv7-unknown-linux-gnueabihf)
            _run_cmd_quiet command -v arm-linux-gnueabihf-gcc || return 1 ;;
        riscv64gc-unknown-linux-gnu)
            _run_cmd_quiet command -v riscv64-linux-gnu-gcc || return 1 ;;
        x86_64-apple-darwin)
            _run_cmd_quiet command -v x86_64-apple-darwin20.4-clang || return 1 ;;
        aarch64-apple-darwin)
            _run_cmd_quiet command -v aarch64-apple-darwin20.4-clang || return 1 ;;
    esac
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  28. SINGLE TARGET BUILD (with 4 fallback strategies)
# ═════════════════════════════════════════════════════════════════════════════

_build_target() {
    local target="$1"
    local os="$2"
    local arch="$3"
    local msvc="${4:-}"
    local -n _bins_ref=$5

    local ext=""
    [[ "$os" == "windows" ]] && ext=".exe"
    local msvc_suffix=""
    [[ "$msvc" == "msvc" ]] && msvc_suffix="_msvc"

    echo ""
    log_info "+-- ${BD}${target}${NC}"

    # Install rust target
    if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
        log_info "|   Installing Rust target..."
        if ! _run_cmd rustup target add "$target"; then
            log_warn "|   Target installation failed, skipping"
            return 1
        fi
    fi

    # Check linker (non-MSVC only — MSVC uses lld-link from our symlinks)
    if [[ "$msvc" != "msvc" ]]; then
        if ! _check_linker "$target"; then
            log_warn "|   Linker missing, skipping"
            return 1
        fi
    fi

    log_info "|   Building..."
    local build_ok=0
    local -a env_vars=()

    # MSVC: set library paths
    if [[ "$msvc" == "msvc" ]]; then
        local xwin_out
        xwin_out="${XWIN_PATH:-$HOME/.xwin}"
        if [[ "$target" == "aarch64-pc-windows-msvc" ]]; then
            env_vars=("RUSTFLAGS=-Lnative=${xwin_out}/crt/lib/aarch64 -Lnative=${xwin_out}/sdk/lib/um/aarch64 -Lnative=${xwin_out}/sdk/lib/ucrt/aarch64")
        else
            env_vars=("RUSTFLAGS=-Lnative=${xwin_out}/crt/lib/x86_64 -Lnative=${xwin_out}/sdk/lib/um/x86_64 -Lnative=${xwin_out}/sdk/lib/ucrt/x86_64")
        fi
    fi

    # Strategy 1: cargo-xwin for MSVC targets
    if [[ "$msvc" == "msvc" ]]; then
        log_exec "|   cargo xwin build --release --target $target -j $JOBS"
        if env "${env_vars[@]}" cargo xwin build --release --target "$target" -j "$JOBS"; then
            build_ok=1
            log_info "|   ${G}OK${NC} cargo-xwin succeeded"
        else
            log_warn "|   cargo-xwin failed"
        fi
    fi

    # Strategy 2: cargo-zigbuild for non-MSVC
    if [[ "$build_ok" -eq 0 && "$msvc" != "msvc" ]]; then
        log_exec "|   cargo zigbuild --release --target $target -j $JOBS"
        if env "${env_vars[@]}" cargo zigbuild --release --target "$target" -j "$JOBS"; then
            build_ok=1
            log_info "|   ${G}OK${NC} cargo-zigbuild succeeded"
        else
            log_warn "|   cargo-zigbuild failed"
        fi
    fi

    # Strategy 3: plain cargo build
    if [[ "$build_ok" -eq 0 ]]; then
        log_exec "|   cargo build --release --target $target -j $JOBS"
        if env "${env_vars[@]}" cargo build --release --target "$target" -j "$JOBS"; then
            build_ok=1
            log_info "|   ${G}OK${NC} cargo build succeeded"
        else
            log_warn "|   cargo build failed, trying cross..."
        fi
    fi

    # Strategy 4: cross build
    if [[ "$build_ok" -eq 0 ]]; then
        log_exec "|   cross build --release --target $target"
        if _run_cmd_quiet command -v cross && \
           env "${env_vars[@]}" cross build --release --target "$target"; then
            build_ok=1
            log_info "|   ${G}OK${NC} cross succeeded"
        else
            log_error "|   ${R}FAIL${NC} All build methods failed"
            return 1
        fi
    fi

    # ─── Copy & post-process binaries ──────────────────────────────────
    local copied=0 missing=0
    for bin_name in "${_bins_ref[@]}"; do
        if ! _should_build "$bin_name" "$FILTER_BIN"; then continue; fi

        local src out
        src="${PROJ_DIR}/target/${target}/release/${bin_name}${ext}"
        out="${DEPLOY_DIR}/${bin_name}_${os}_${arch}${msvc_suffix}${ext}"

        if [[ -f "$out" && "$FORCE_BUILD" != "1" ]]; then
            log_info "|   ${Y}SKIP${NC} $(basename "$out") already exists"
            continue
        fi

        if [[ ! -f "$src" ]]; then
            log_error "|   ${R}FAIL${NC} $(basename "$src") not found"
            ((missing++)) || true
            continue
        fi

        cp "$src" "$out"
        ((copied++)) || true

        # Strip binaries (not Windows)
        if [[ "$STRIP_BIN" == "1" && "$os" != "windows" ]]; then
            case "$os" in
                linux) strip "$out" 2>/dev/null || true ;;
                macos)
                    x86_64-apple-darwin20.4-strip "$out" 2>/dev/null || \
                    aarch64-apple-darwin20.4-strip "$out" 2>/dev/null || \
                    strip "$out" 2>/dev/null || true ;;
            esac
        fi

        # Checksums (sha256sum or shasum for macOS)
        if [[ "$CHECKSUMS" == "1" ]]; then
            if _run_cmd_quiet command -v sha256sum; then
                sha256sum "$out" | awk '{print $1}' > "${out}.sha256" 2>/dev/null || true
            elif _run_cmd_quiet command -v shasum; then
                shasum -a 256 "$out" | awk '{print $1}' > "${out}.sha256" 2>/dev/null || true
            fi
        fi

        local fsize
        fsize=$(du -h "$out" 2>/dev/null | cut -f1)
        log_ok "|   ${G}SUCCESS${NC} $(basename "$out") (${fsize})"
    done

    if [[ $copied -eq 0 && $missing -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  29. NATIVE BUILD (orchestrator)
# ═════════════════════════════════════════════════════════════════════════════

_native_build() {
    log_step "NATIVE BUILD MODE"

    if [[ ! -f "${PROJ_DIR}/Cargo.toml" ]]; then
        log_fatal "No Cargo.toml found! Please run from project root."
    fi

    local PROJ
    PROJ=$(grep -m1 '^name\s*=' "${PROJ_DIR}/Cargo.toml" 2>/dev/null | \
           sed -E "s/^name\s*=\s*['\"]?([^'\"]+)['\"]?.*/\\1/" | tr -d ' ')
    [[ -z "$PROJ" ]] && PROJ=$(basename "$PROJ_DIR")

    local -a BINS
    mapfile -t BINS < <(_get_bins)
    [[ ${#BINS[@]} -eq 0 ]] && log_fatal "No binaries detected in Cargo.toml"

    log_info "Project: ${BD}${PROJ}${NC}"
    log_info "Binaries: ${BD}${BINS[*]}${NC}"
    [[ -n "$FILTER_TARGET" ]] && log_info "Filter: ${BD}${FILTER_TARGET}${NC}"

    mkdir -p "$DEPLOY_DIR"

    # Pre-flight checks
    _check_disk_space "$PROJ_DIR" 512 || log_warn "Low disk space — build may fail"
    _check_network || log_warn "No network — cached builds only"

    # System deps
    _install_system_deps

    # Rust toolchain
    _verify_rustup || log_fatal "Could not set up Rust toolchain"

    # Symlink toolchain aliases
    mkdir -p "$HOME/.local/bin"
    if ! _run_cmd_quiet command -v lld-link; then
        if _run_cmd_quiet command -v ld.lld; then
            ln -sf "$(command -v ld.lld)" "$HOME/.local/bin/lld-link" 2>/dev/null || true
        elif _run_cmd_quiet command -v lld; then
            ln -sf "$(command -v lld)" "$HOME/.local/bin/lld-link" 2>/dev/null || true
        fi
    fi
    if ! _run_cmd_quiet command -v llvm-lib && _run_cmd_quiet command -v llvm-ar; then
        ln -sf "$(command -v llvm-ar)" "$HOME/.local/bin/llvm-lib" 2>/dev/null || true
    fi
    if ! _run_cmd_quiet command -v clang-cl && _run_cmd_quiet command -v clang; then
        ln -sf "$(command -v clang)" "$HOME/.local/bin/clang-cl" 2>/dev/null || true
    fi
    export PATH="$HOME/.local/bin:$PATH"

    # llvm-mingw
    _setup_llvm_mingw

    # osxcross
    local osx_ok=0
    _setup_osxcross && osx_ok=1

    # xwin / MSVC
    local msvc_ok=0
    _setup_xwin_msvc && msvc_ok=1

    # zig & cross (optional)
    _setup_zigbuild
    _setup_cross

    # Cargo config
    _write_cargo_config

    # Build loop
    log_step "Starting Cross-Compilation"

    local -a TARGETS=(
        "x86_64-unknown-linux-gnu:linux:x86-64"
        "x86_64-pc-windows-gnu:windows:x86-64"
        "i686-pc-windows-gnu:windows:x86"
        "x86_64-pc-windows-msvc:windows:x86_64:msvc"
        "aarch64-pc-windows-msvc:windows:ARM64:msvc"
        "aarch64-unknown-linux-gnu:linux:ARM64"
        "armv7-unknown-linux-gnueabihf:linux:ARMv7"
        "riscv64gc-unknown-linux-gnu:linux:RISC64"
        "x86_64-apple-darwin:macos:x86_64"
        "aarch64-apple-darwin:macos:ARM64"
    )

    local success=0 skipped=0 fail=0

    for entry in "${TARGETS[@]}"; do
        local target os arch msvc
        IFS=':' read -r target os arch msvc <<< "$entry"

        if ! _should_build "$target" "$FILTER_TARGET"; then
            log_debug "Skipping ${target} (filtered)"
            continue
        fi

        # macOS requires osxcross
        if [[ "$os" == "macos" && "$osx_ok" -eq 0 ]]; then
            log_warn "+-- ${BD}${target}${NC}"
            log_warn "|   osxcross not available, skipping"
            ((fail++)) || true
            continue
        fi

        # MSVC requires xwin
        if [[ "${msvc:-}" == "msvc" && "$msvc_ok" -eq 0 ]]; then
            log_warn "+-- ${BD}${target}${NC}"
            log_warn "|   MSVC SDK not available, skipping"
            ((fail++)) || true
            continue
        fi

        if _build_target "$target" "$os" "$arch" "$msvc" BINS; then
            ((success++)) || true
        else
            ((fail++)) || true
        fi
    done

    # Summary
    echo ""
    log_step "BUILD SUMMARY"
    printf "  ${G}OK:${NC}      %d\n" "$success" >&2
    printf "  ${Y}SKIP:${NC}    %d\n" "$skipped" >&2
    printf "  ${R}FAIL:${NC}    %d\n" "$fail" >&2
    echo "" >&2

    if [[ $((success + skipped)) -gt 0 ]]; then
        log_info "Deploy directory:"
        ls -lh "${DEPLOY_DIR}/" 2>/dev/null || true
    fi

    if [[ $fail -gt 0 ]]; then
        log_warn "Some targets failed! Check logs above for details."
    fi

    # Return non-zero only if ALL failed and none succeeded
    if [[ $success -eq 0 && $fail -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
#  30. MAIN (argument parsing + dispatch)
# ═════════════════════════════════════════════════════════════════════════════

main() {
    # Parse --log-file and --lock-file FIRST (before banner noise)
    local -a original_args=("$@")
    local i=0 _orig_len=${#original_args[@]}
    while true; do
        (( i < _orig_len )) || break
        case "${original_args[$i]}" in
            --log-file)
                LOG_FILE="${original_args[$((i+1))]:-}"
                i=$((i+2))
                ;;
            --lock-file)
                LOCK_FILE="${original_args[$((i+1))]:-}"
                i=$((i+2))
                ;;
            *) i=$((i+1)) ;;
        esac
    done

    # Setup logging (file-based, no process substitution zombies)
    if [[ -n "$LOG_FILE" ]]; then
        local _log_dir
        _log_dir=$(dirname "$LOG_FILE")
        [[ -n "$_log_dir" && "$_log_dir" != "." ]] && mkdir -p "$_log_dir" 2>/dev/null || true
        # Redirect both stdout and stderr to tee
        exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
        log_info "Logging all output to: $LOG_FILE"
    fi

    # Acquire lock
    _acquire_lock

    # Pre-flight environment info
    log_debug "Bash: ${BASH_VERSION}"
    log_debug "Script: $SCRIPT_PATH"
    log_debug "Project: $PROJ_DIR"
    log_debug "In container: $([[ "$_IN_CONTAINER" -eq 1 ]] && echo yes || echo no)"
    log_debug "JOBS: $JOBS"

    # Banner
    echo -e "${C}${BD}" >&2
    cat <<'BANNER' >&2
 _         _        _           _ _     _
/ \  _   _| |_ ___ | |__  _   _(_) | __| |
/ _ \| | | | __/ _ \| '_ \| | | | | |/ _` |
/ ___ \ |_| | || (_) | |_) | |_| | | | (_| |
/_/   \_\__,_|\__\___/|_.__/ \__,_|_|_|\__,_|
FAILSAFE CROSS-COMPILER   v7
BANNER
    echo -e "${NC}" >&2

    # Parse remaining args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) _show_help; exit 0 ;;
            --menu) SHOW_MENU=1; shift ;;
            --target) FILTER_TARGET="${2:-}"; shift 2 ;;
            --bin) FILTER_BIN="${2:-}"; shift 2 ;;
            --no-strip) STRIP_BIN=0; shift ;;
            --no-checksum) CHECKSUMS=0; shift ;;
            -f|--force) FORCE_BUILD=1; shift ;;
            --debug) LOG_LEVEL="DEBUG"; shift ;;
            --native) USE_DOCKER="no"; shift ;;
            --docker) USE_DOCKER="yes"; shift ;;
            --log-file) LOG_FILE="${2:-}"; shift 2 ;;
            --lock-file) LOCK_FILE="${2:-}"; shift 2 ;;
            *) log_warn "Unknown option: $1"; shift ;;
        esac
    done

    # Validate project (deferred from top-level so --help works from anywhere)
    if [[ ! -f "${PROJ_DIR}/Cargo.toml" ]]; then
        log_fatal "No Cargo.toml in current directory (${PROJ_DIR})\n       Run this script from your Rust project root."
    fi
    if ! grep -q '\[package\]' "${PROJ_DIR}/Cargo.toml" 2>/dev/null; then
        log_warn "Cargo.toml may be missing [package] section — continuing anyway"
    fi

    # Show interactive menu if requested
    [[ $SHOW_MENU -eq 1 ]] && _show_menu

    log_info "Mode: ${BD}${USE_DOCKER}${NC} | Log: ${LOG_LEVEL} | Jobs: ${JOBS}"

    # ═══════════════════════════════════════════════════════════════
    #  CONTAINER PATH (preferred)
    # ═══════════════════════════════════════════════════════════════
    if [[ "$USE_DOCKER" != "no" ]]; then
        if _ensure_container; then
            log_info "Container engine: ${BD}${CONTAINER_CMD}${NC}"
            if _build_container_image; then
                _run_container_build
                exit $?
            else
                log_warn "Container image build failed"
                if [[ "$USE_DOCKER" == "yes" ]]; then
                    log_fatal "Container mode forced but image build failed"
                fi
                log_warn "Falling back to native..."
            fi
        else
            if [[ "$USE_DOCKER" == "yes" ]]; then
                log_fatal "Container mode forced but no engine available"
            fi
            log_warn "No container engine available, falling back to native..."
        fi
    fi

    # ═══════════════════════════════════════════════════════════════
    #  NATIVE FALLBACK
    # ═══════════════════════════════════════════════════════════════
    _native_build
}

# ═════════════════════════════════════════════════════════════════════════════
#  ENTRYPOINT
# ═════════════════════════════════════════════════════════════════════════════

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

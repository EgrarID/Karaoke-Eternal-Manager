#!/usr/bin/env bash
# Karaoke Eternal Docker installer and management menu for Ubuntu Server.
# Official server docs: https://www.karaoke-eternal.com/docs/karaoke-eternal-server/
# Official image:       https://hub.docker.com/r/radrootllc/karaoke-eternal
# Docker on Ubuntu:     https://docs.docker.com/engine/install/ubuntu/

set -uo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_VERSION="5.10.1"
APP_NAME="Karaoke Eternal"
APP_DIR="/data/karaoke-eternal"
CONFIG_DIR="$APP_DIR/config"
DEFAULT_MEDIA_DIR="$APP_DIR/media"
DEFAULT_BACKUP_DIR="$APP_DIR/backups"
ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/compose.yaml"
CONTAINER_NAME="karaoke-eternal"
DEFAULT_IMAGE="radrootllc/karaoke-eternal:2"
DEFAULT_PORT="8080"
DEFAULT_BIND_ADDRESS="0.0.0.0"
DEFAULT_TZ="America/New_York"
DEFAULT_BACKUP_RETENTION="10"
REPORT_DIR="$APP_DIR/reports"
ZIP_QUARANTINE_DIR="/data/karaoke-eternal-quarantine"
MANAGER_PATH="/usr/local/sbin/karaoke-eternal-manager"
MANAGER_TMUX_SESSION="karaoke-eternal-manager"
MANAGER_TMUX_ENV_FLAG="KARAOKE_MANAGER_INSIDE_TMUX"
SAMBA_CONFIG_FILE="/etc/samba/smb.conf"
SAMBA_STATE_FILE="$APP_DIR/samba.env"
SAMBA_BLOCK_BEGIN="# BEGIN KARAOKE ETERNAL MANAGER MEDIA SHARE"
SAMBA_BLOCK_END="# END KARAOKE ETERNAL MANAGER MEDIA SHARE"
DEFAULT_SAMBA_SHARE="KaraokeMedia"
DEFAULT_ZIP_TEST_TIMEOUT="300"
ZIP_ACTION_LOG="$REPORT_DIR/zip-error-actions.log"
ZIP_RESTORE_LOG="$REPORT_DIR/zip-restore-actions.log"
RESTORED_MEDIA_DIR="$APP_DIR/restored-media"
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04" "25.10" "26.04")
MIN_DOCKER_FREE_BYTES=$((1024 * 1024 * 1024))
MIN_APP_FREE_BYTES=$((512 * 1024 * 1024))

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[1;31m'
    C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'
    C_CYAN=$'\033[1;36m'
else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

info()    { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
success() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
error()   { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

pause_screen() {
    [[ -t 0 ]] || return 0
    printf '\nPress Enter to return to the menu...'
    read -r _
}

terminal_rows() {
    local rows=""
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        rows="$(tput lines 2>/dev/null || true)"
    fi
    if [[ ! "$rows" =~ ^[0-9]+$ ]] || (( 10#$rows < 10 )); then
        rows="24"
    fi
    printf '%s\n' "$rows"
}

show_file_scrollable() {
    local file="${1:-}"
    local label="${2:-output}"
    local line_count rows threshold

    if [[ -z "$file" || ! -r "$file" ]]; then
        error "Cannot read $label: ${file:-missing path}"
        return 1
    fi

    line_count="$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]')"
    [[ "$line_count" =~ ^[0-9]+$ ]] || line_count="0"
    rows="$(terminal_rows)"
    threshold=$((10#$rows - 4))
    (( threshold < 10 )) && threshold=10

    if [[ -t 0 && -t 1 && "$line_count" =~ ^[0-9]+$ ]] && (( 10#$line_count > threshold )) && command -v less >/dev/null 2>&1; then
        printf '\n%sLong %s detected (%s lines). Opening scrollable viewer.%s\n' "$C_CYAN" "$label" "$line_count" "$C_RESET"
        printf 'Use Arrow keys/PageUp/PageDown/Home/End to scroll. Press q to return to the manager.\n\n'
        LESS='-R -S -X' less -- "$file"
    else
        cat -- "$file"
    fi
}

show_text_scrollable() {
    local label="${1:-output}"
    local tmp
    tmp="$(mktemp)" || return 1
    cat > "$tmp"
    show_file_scrollable "$tmp" "$label"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

confirm() {
    local prompt="$1"
    local default="${2:-no}"
    local suffix='[y/N]'
    [[ "$default" == "yes" ]] && suffix='[Y/n]'
    local answer=""
    if ! read -r -p "$prompt $suffix: " answer; then
        printf '
'
        return 1
    fi
    if [[ -z "$answer" ]]; then
        [[ "$default" == "yes" ]]
    else
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

require_root() {
    if (( EUID != 0 )); then
        if ! command -v sudo >/dev/null 2>&1; then
            error "This script requires root privileges and sudo is not installed."
            exit 1
        fi
        info "Requesting administrator privileges..."
        exec sudo --preserve-env=TERM bash "$(readlink -f "$0")" "$@"
    fi
}

find_service_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
        printf '%s\n' "$SUDO_USER"
        return
    fi

    local console_user=""
    console_user="$(logname 2>/dev/null || true)"
    if [[ -n "$console_user" && "$console_user" != "root" ]] && id "$console_user" >/dev/null 2>&1; then
        printf '%s\n' "$console_user"
        return
    fi

    local normal_user=""
    normal_user="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1; exit}' /etc/passwd)"
    printf '%s\n' "${normal_user:-root}"
}

SERVICE_USER=""
SERVICE_UID=""
SERVICE_GID=""

initialize_identity() {
    SERVICE_USER="$(find_service_user)"
    SERVICE_UID="$(id -u "$SERVICE_USER")"
    SERVICE_GID="$(id -g "$SERVICE_USER")"
}

load_os_release() {
    if [[ ! -r /etc/os-release ]]; then
        error "Unable to identify the operating system."
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
}

host_architecture() {
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --print-architecture
        return
    fi
    case "$(uname -m)" in
        x86_64) printf 'amd64\n' ;;
        aarch64) printf 'arm64\n' ;;
        *) uname -m ;;
    esac
}

check_supported_host() {
    load_os_release || return 1

    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "This manager supports Ubuntu Server only. Detected: ${PRETTY_NAME:-unknown}."
        return 1
    fi

    local supported=0 version
    for version in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
        if [[ "${VERSION_ID:-}" == "$version" ]]; then
            supported=1
            break
        fi
    done
    if (( supported == 0 )); then
        error "Ubuntu ${VERSION_ID:-unknown} is not in Docker's currently supported Ubuntu list."
        error "Supported by this script: ${SUPPORTED_UBUNTU_VERSIONS[*]}"
        return 1
    fi

    local arch
    arch="$(host_architecture)"
    case "$arch" in
        amd64|arm64) ;;
        *)
            error "The Karaoke Eternal image supports amd64 and arm64. Detected: ${arch:-unknown}."
            return 1
            ;;
    esac

    if [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" != "systemd" ]]; then
        error "This manager requires an Ubuntu Server host using systemd."
        return 1
    fi

    return 0
}

human_bytes() {
    local bytes="${1:-0}"
    python3 - "$bytes" <<'PY'
import sys
n = int(sys.argv[1])
for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
    if n < 1024 or unit == "TiB":
        print(f"{n:.1f} {unit}" if isinstance(n, float) else f"{n} {unit}")
        break
    n = n / 1024
PY
}

available_bytes() {
    local path="$1"
    df -P -B1 "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

ensure_free_space() {
    local path="$1"
    local required="$2"
    local label="$3"
    local available=""
    available="$(available_bytes "$path" || true)"
    if [[ ! "$available" =~ ^[0-9]+$ ]]; then
        error "Unable to determine free space for $label at $path."
        return 1
    fi
    if (( available < required )); then
        error "$label has only $(human_bytes "$available") free; at least $(human_bytes "$required") is required."
        return 1
    fi
    success "$label free space: $(human_bytes "$available")"
}

check_inodes() {
    local path="$1"
    local available=""
    available="$(df -Pi "$path" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ "$available" =~ ^[0-9]+$ ]] && (( available < 1000 )); then
        warn "Only $available free inodes remain on the filesystem containing $path."
        return 1
    fi
    return 0
}

check_dns_and_https() {
    if ! getent ahosts download.docker.com >/dev/null 2>&1; then
        error "DNS lookup for download.docker.com failed."
        return 1
    fi
    if ! curl -fsSIL --max-time 15 https://download.docker.com/ >/dev/null 2>&1; then
        error "HTTPS connectivity to download.docker.com failed."
        return 1
    fi
    if ! getent ahosts registry-1.docker.io >/dev/null 2>&1; then
        error "DNS lookup for registry-1.docker.io failed."
        return 1
    fi
    local registry_code=""
    registry_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 https://registry-1.docker.io/v2/ 2>/dev/null || true)"
    if [[ ! "$registry_code" =~ ^[1-5][0-9][0-9]$ || "$registry_code" == "000" ]]; then
        error "HTTPS connectivity to Docker Hub registry failed."
        return 1
    fi
    return 0
}

MANAGER_REQUIRED_COMMANDS=(
    curl
    python3
    ip
    ss
    findmnt
    mountpoint
    tar
    gzip
    realpath
    runuser
    getent
    timeout
    base64
    find
    less
    unzip
    tmux
)

install_host_prerequisites() {
    check_supported_host || return 1
    export DEBIAN_FRONTEND=noninteractive
    info "Installing Ubuntu Server prerequisites, including tmux, less, and unzip..."
    apt-get update || return 1
    apt-get install -y \
        ca-certificates \
        curl \
        python3 \
        iproute2 \
        util-linux \
        tar \
        gzip \
        coreutils \
        findutils \
        procps \
        less \
        unzip \
        tmux || return 1
    success "Ubuntu Server prerequisites are installed."
}

host_prerequisites_ready() {
    local command
    for command in "${MANAGER_REQUIRED_COMMANDS[@]}"; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
    [[ -r /etc/ssl/certs/ca-certificates.crt ]]
}

show_host_prerequisite_status() {
    printf '\n%sManager prerequisite utilities%s\n' "$C_CYAN" "$C_RESET"
    local command missing=0
    for command in "${MANAGER_REQUIRED_COMMANDS[@]}"; do
        if command -v "$command" >/dev/null 2>&1; then
            printf '  [OK]      %-12s %s\n' "$command" "$(command -v "$command")"
        else
            printf '  [MISSING] %-12s install/repair prerequisites to add it\n' "$command"
            missing=1
        fi
    done

    if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        printf '  [OK]      %-12s %s\n' "CA certs" "/etc/ssl/certs/ca-certificates.crt"
    else
        printf '  [MISSING] %-12s install/repair prerequisites to add CA certificates\n' "CA certs"
        missing=1
    fi

    if command -v tmux >/dev/null 2>&1; then
        printf '  tmux version: %s\n' "$(tmux -V 2>/dev/null || echo unknown)"
    fi
    if command -v unzip >/dev/null 2>&1; then
        printf '  unzip version: %s\n' "$(unzip -v 2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}')"
    fi

    if (( missing == 0 )); then
        success "All manager prerequisite utilities are present."
    else
        warn "One or more manager prerequisite utilities are missing."
        return 1
    fi
}

ensure_host_prerequisites() {
    check_supported_host || return 1
    if host_prerequisites_ready; then
        return 0
    fi
    warn "One or more required Ubuntu utilities are missing."
    install_host_prerequisites
}

repair_host_prerequisites() {
    show_host_prerequisite_status || true
    if host_prerequisites_ready; then
        success "No prerequisite repair is needed."
        return 0
    fi
    if [[ -t 0 ]]; then
        confirm "Install/repair missing prerequisite packages now" "yes" || return 0
    fi
    install_host_prerequisites
    show_host_prerequisite_status
}

docker_is_ready() {
    command -v docker >/dev/null 2>&1 \
        && docker info >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1
}

setup_docker_repository() {
    install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc || return 1

    load_os_release || return 1
    cat > /etc/apt/sources.list.d/docker.sources <<EOF_DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(host_architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER_REPO
}

remove_conflicting_docker_packages() {
    local conflicts=()
    local package
    for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            conflicts+=("$package")
        fi
    done

    if (( ${#conflicts[@]} > 0 )); then
        warn "Replacing conflicting distribution packages with Docker CE: ${conflicts[*]}"
        apt-get remove -y "${conflicts[@]}" || return 1
    fi
}

verify_docker_installation() {
    systemctl enable --now containerd.service docker.service || return 1

    if ! docker info >/dev/null 2>&1; then
        error "Docker is installed, but the daemon is not responding."
        systemctl status docker --no-pager -l || true
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        error "The Docker Compose plugin is unavailable."
        return 1
    fi

    info "Running Docker's hello-world verification container..."
    if ! docker run --rm hello-world >/dev/null; then
        error "Docker hello-world verification failed."
        return 1
    fi
    docker image rm hello-world >/dev/null 2>&1 || true

    success "Docker Engine: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    success "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"
}

install_or_update_docker() {
    check_supported_host || return 1
    install_host_prerequisites || return 1
    check_dns_and_https || return 1
    ensure_free_space /var/lib "$MIN_DOCKER_FREE_BYTES" "Docker storage filesystem" || return 1

    export DEBIAN_FRONTEND=noninteractive
    remove_conflicting_docker_packages || return 1
    setup_docker_repository || return 1
    apt-get update || return 1

    info "Installing or updating Docker Engine, containerd, Buildx, and Compose..."
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin || return 1

    verify_docker_installation || return 1
    success "Docker installation/update completed."
}

ensure_docker() {
    ensure_host_prerequisites || return 1
    if docker_is_ready; then
        systemctl enable --now containerd.service docker.service >/dev/null 2>&1 || true
        return 0
    fi
    warn "Docker Engine or Docker Compose is not ready."
    install_or_update_docker
}

rollback_docker_daemon_config() {
    local daemon_file="$1"
    local backup_file="$2"
    local had_original="$3"

    if [[ "$had_original" == "yes" && -n "$backup_file" && -f "$backup_file" ]]; then
        cp -a "$backup_file" "$daemon_file" || return 1
    else
        rm -f "$daemon_file"
    fi
    systemctl restart docker.service >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1
}

merge_docker_daemon_settings() {
    local enable_live_restore="$1"
    local set_default_local_logs="$2"
    local daemon_dir="/etc/docker"
    local daemon_file="$daemon_dir/daemon.json"
    local temp_file=""
    local backup_file=""
    local had_original="no"

    install -d -m 0755 "$daemon_dir" || return 1
    temp_file="$(mktemp "$daemon_dir/daemon.json.tmp.XXXXXX")" || return 1

    if [[ -s "$daemon_file" ]]; then
        had_original="yes"
        backup_file="$daemon_file.backup-$(date +'%Y%m%d-%H%M%S')"
        cp -a "$daemon_file" "$backup_file" || {
            rm -f "$temp_file"
            return 1
        }
    fi

    if ! python3 - "$daemon_file" "$temp_file" "$enable_live_restore" "$set_default_local_logs" <<'PY'
import json
import os
import sys

source, destination, live_restore, local_logs = sys.argv[1:]
data = {}
if os.path.exists(source) and os.path.getsize(source):
    with open(source, "r", encoding="utf-8") as f:
        data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("daemon.json must contain a JSON object")
if live_restore == "yes":
    data["live-restore"] = True
if local_logs == "yes":
    data["log-driver"] = "local"
    data["log-opts"] = {"max-size": "10m", "max-file": "3"}
with open(destination, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
    then
        error "Unable to merge Docker daemon settings. Existing daemon.json was not changed."
        rm -f "$temp_file"
        return 1
    fi

    if command -v dockerd >/dev/null 2>&1; then
        if ! dockerd --validate --config-file "$temp_file" >/dev/null 2>&1; then
            error "The proposed Docker daemon configuration did not pass dockerd validation."
            rm -f "$temp_file"
            return 1
        fi
    fi

    install -m 0644 "$temp_file" "$daemon_file" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    if systemctl reload docker.service >/dev/null 2>&1; then
        success "Docker daemon configuration reloaded."
    else
        warn "Docker does not support reload on this host; restarting the daemon."
        if ! systemctl restart docker.service; then
            error "Docker failed to restart with the proposed configuration. Rolling back."
            if rollback_docker_daemon_config "$daemon_file" "$backup_file" "$had_original"; then
                warn "The previous Docker daemon configuration was restored."
            else
                error "Automatic rollback also failed. Inspect $daemon_file and the Docker journal immediately."
            fi
            return 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        error "Docker is not responding after the daemon configuration change. Rolling back."
        if rollback_docker_daemon_config "$daemon_file" "$backup_file" "$had_original"; then
            warn "The previous Docker daemon configuration was restored."
        else
            error "Automatic rollback also failed. Inspect $daemon_file and the Docker journal immediately."
        fi
        return 1
    fi

    [[ -n "$backup_file" ]] && info "Previous daemon configuration saved as: $backup_file"
}

optimize_docker() {
    ensure_docker || return 1

    local live_restore="no"
    local local_logs="no"
    if confirm "Enable Docker live-restore to reduce downtime during daemon outages?" yes; then
        live_restore="yes"
    fi
    if confirm "Set Docker's default logging driver to rotated local logs for newly created containers?" no; then
        local_logs="yes"
        warn "This changes the default for newly created containers. Existing containers are unaffected."
    fi

    if [[ "$live_restore" == "no" && "$local_logs" == "no" ]]; then
        info "No Docker daemon settings were changed."
        return 0
    fi

    merge_docker_daemon_settings "$live_restore" "$local_logs" || return 1
    success "Safe Docker optimizations applied."
}

configuration_exists() {
    [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]]
}

require_configuration() {
    if ! configuration_exists; then
        error "$APP_NAME is not configured. Choose Install / Reconfigure first."
        return 1
    fi
}

env_get() {
    local key="$1"
    local fallback="${2:-}"
    local value=""
    if [[ -f "$ENV_FILE" ]]; then
        value="$(grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    fi
    printf '%s\n' "${value:-$fallback}"
}

safe_env_value() {
    local value="$1"
    [[ -n "$value" ]] \
        && [[ "$value" != *$'\n'* ]] \
        && [[ "$value" != *$'\r'* ]] \
        && [[ "$value" != *'$'* ]] \
        && [[ "$value" != *'#'* ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_ipv4() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
}

validate_bind_address() {
    validate_ipv4 "$1"
}

bind_address_is_present() {
    local address="$1"
    [[ "$address" == "0.0.0.0" || "$address" == "127.0.0.1" ]] && return 0
    ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$address"
}

validate_timezone() {
    [[ -n "$1" && "$1" != *$'\n'* && -e "/usr/share/zoneinfo/$1" ]]
}

validate_image() {
    [[ "$1" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]]
}

validate_retention() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 999 ))
}

validate_absolute_path() {
    local path="$1"
    [[ "$path" == /* ]] && safe_env_value "$path"
}

canonical_path() {
    realpath -m -- "$1"
}

path_is_within() {
    local child parent
    child="$(canonical_path "$1")"
    parent="$(canonical_path "$2")"
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

prompt_value() {
    local prompt="$1"
    local default="$2"
    local result=""
    read -r -p "$prompt [$default]: " result
    printf '%s\n' "${result:-$default}"
}

prompt_optional_value() {
    local prompt="$1"
    local default="$2"
    local display_default="${default:-none}"
    local result=""
    read -r -p "$prompt [$display_default]: " result
    if [[ -z "$result" ]]; then
        printf '%s\n' "$default"
    elif [[ "$result" == "none" || "$result" == "NONE" || "$result" == "-" ]]; then
        printf '\n'
    else
        printf '%s\n' "$result"
    fi
}

run_as_service_user() {
    if [[ "$SERVICE_USER" == "root" ]]; then
        "$@"
    else
        runuser -u "$SERVICE_USER" -- "$@"
    fi
}


script_self_path() {
    local resolved=""
    resolved="$(readlink -f "$0" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
    else
        printf '%s\n' "$0"
    fi
}

manager_tmux_session_exists() {
    local session="${1:-$MANAGER_TMUX_SESSION}"
    command -v tmux >/dev/null 2>&1 || return 1
    tmux has-session -t "$session" >/dev/null 2>&1
}

manager_tmux_session_attached_count() {
    local session="${1:-$MANAGER_TMUX_SESSION}"
    tmux display-message -p -t "$session" '#{session_attached}' 2>/dev/null || printf '0\n'
}

manager_tmux_start_attached() {
    local session="${1:-$MANAGER_TMUX_SESSION}"
    local script_path="${2:-}"
    if [[ -z "$script_path" ]]; then
        script_path="$(script_self_path)"
    fi

    local quoted_script=""
    printf -v quoted_script '%q' "$script_path"
    local tmux_command="env $MANAGER_TMUX_ENV_FLAG=1 bash $quoted_script"

    info "Starting tmux session: $session"
    info "Detach without stopping the manager: Ctrl-b then d"
    info "Reconnect later: sudo karaoke-eternal-manager"
    exec tmux new-session -s "$session" "$tmux_command"
}

manager_tmux_attach() {
    local session="${1:-$MANAGER_TMUX_SESSION}"
    info "Attaching to tmux session: $session"
    info "Detach without stopping the manager: Ctrl-b then d"
    exec tmux attach-session -t "$session"
}

manager_tmux_install_if_requested() {
    if command -v tmux >/dev/null 2>&1; then
        return 0
    fi

    warn "tmux is not installed, so the manager cannot offer reconnectable SSH sessions yet."
    if [[ ! -t 0 ]]; then
        return 1
    fi

    if ! confirm "Install tmux now with apt-get" "yes"; then
        warn "Continuing without tmux. A dropped SSH connection may leave an unreconnectable manager process."
        return 1
    fi

    check_supported_host || return 1
    if ! command -v apt-get >/dev/null 2>&1; then
        error "apt-get was not found. Install tmux manually, then run the manager again."
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get install -y tmux || return 1
    command -v tmux >/dev/null 2>&1
}

show_manager_tmux_status() {
    if ! command -v tmux >/dev/null 2>&1; then
        warn "tmux is not installed."
        return 1
    fi

    local sessions=""
    sessions="$(tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_windows}\t#{session_created_string}' 2>/dev/null | grep -E "^${MANAGER_TMUX_SESSION}([[:space:]-]|$)" || true)"
    if [[ -z "$sessions" ]]; then
        info "No Karaoke Eternal Manager tmux sessions were found."
        return 0
    fi

    printf 'Manager tmux sessions:\n'
    printf '%s\n' "$sessions" | awk -F '\t' '{printf "  %s  attached_clients=%s  windows=%s  created=%s\n", $1, $2, $3, $4}'
}

safe_manager_launcher() {
    local first_arg="${1:-}"

    [[ -z "$first_arg" ]] || return 0
    [[ "${!MANAGER_TMUX_ENV_FLAG:-}" != "1" ]] || return 0
    [[ -z "${TMUX:-}" ]] || return 0
    [[ -t 0 && -t 1 ]] || return 0

    manager_tmux_install_if_requested || return 0

    local session="$MANAGER_TMUX_SESSION"
    local script_path=""
    script_path="$(script_self_path)"

    if ! manager_tmux_session_exists "$session"; then
        manager_tmux_start_attached "$session" "$script_path"
    fi

    while true; do
        local attached_count="0"
        attached_count="$(manager_tmux_session_attached_count "$session")"
        printf '\nExisting Karaoke Eternal Manager tmux session found.\n'
        printf 'Session: %s\n' "$session"
        printf 'Attached clients: %s\n\n' "$attached_count"
        cat <<'TMUX_MENU'
  1) Reconnect to existing manager session
  2) Start a new separate manager session
  3) Kill the existing session, then start a new one
  4) Run once in this SSH session without tmux
  0) Exit
TMUX_MENU
        printf '\n'
        local choice=""
        if ! read -r -p "Choose an option: " choice; then
            printf '\n'
            return 1
        fi
        case "$choice" in
            1|"") manager_tmux_attach "$session" ;;
            2)
                warn "Starting more than one manager can be unsafe if both are changing files or services."
                if confirm "Start a separate manager session anyway" "no"; then
                    local new_session=""
                    new_session="${MANAGER_TMUX_SESSION}-$(date +%Y%m%d-%H%M%S)"
                    manager_tmux_start_attached "$new_session" "$script_path"
                fi
                ;;
            3)
                warn "This will terminate the existing interactive manager session."
                if confirm "Kill tmux session '$session' and start a new one" "no"; then
                    tmux kill-session -t "$session"
                    manager_tmux_start_attached "$session" "$script_path"
                fi
                ;;
            4)
                warn "Running outside tmux means a dropped SSH connection may leave this menu unreconnectable."
                return 0
                ;;
            0) exit 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

check_expected_mount() {
    local data_path="${1:-}"
    local mode="${2:-local}"
    local expected_mount="${3:-}"
    local label="${4:-storage}"

    if [[ -z "$data_path" ]]; then
        error "Cannot verify $label mount: data path is empty."
        return 1
    fi

    if [[ "$mode" != "mounted" ]]; then
        return 0
    fi

    if [[ -z "$expected_mount" ]]; then
        error "$label is configured as mounted storage, but no expected mount point is recorded."
        return 1
    fi
    if [[ ! -d "$expected_mount" ]]; then
        error "Expected $label mount point does not exist: $expected_mount"
        return 1
    fi
    if ! mountpoint -q "$expected_mount"; then
        error "Expected $label filesystem is not mounted: $expected_mount"
        return 1
    fi
    if ! path_is_within "$data_path" "$expected_mount"; then
        error "$label path $data_path is not located under expected mount $expected_mount."
        return 1
    fi

    local actual_target=""
    actual_target="$(findmnt -T "$data_path" -n -o TARGET 2>/dev/null || true)"
    if [[ -z "$actual_target" ]]; then
        error "Unable to resolve the mounted filesystem for $label path: $data_path"
        return 1
    fi

    success "$label mount verified: $expected_mount"
}

check_media_path() {
    require_configuration || return 1
    initialize_identity

    local media_path mode expected_mount
    media_path="$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")"
    mode="$(env_get KES_MEDIA_PATH_MODE local)"
    expected_mount="$(env_get KES_EXPECTED_MOUNT '')"

    if [[ ! -d "$media_path" ]]; then
        error "Media directory is missing: $media_path"
        return 1
    fi
    check_expected_mount "$media_path" "$mode" "$expected_mount" "media" || return 1

    if ! run_as_service_user test -r "$media_path"; then
        error "Service account $SERVICE_USER cannot read the media path: $media_path"
        return 1
    fi
    if ! run_as_service_user test -x "$media_path"; then
        error "Service account $SERVICE_USER cannot traverse the media path: $media_path"
        return 1
    fi

    success "Media path exists and is readable by $SERVICE_USER: $media_path"
    local sample=""
    sample="$(run_as_service_user find "$media_path" -maxdepth 2 -type f -print -quit 2>/dev/null || true)"
    if [[ -n "$sample" ]]; then
        info "Readable media sample: $sample"
    else
        warn "No readable media file was found within two directory levels. The folder may be empty."
    fi
}

backup_path_settings() {
    local backup_path backup_mode backup_mount
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    backup_mode="$(env_get KES_BACKUP_PATH_MODE local)"
    backup_mount="$(env_get KES_BACKUP_EXPECTED_MOUNT '')"
    printf '%s\n%s\n%s\n' "$backup_path" "$backup_mode" "$backup_mount"
}

check_backup_path() {
    require_configuration || return 1
    initialize_identity

    local backup_path backup_mode backup_mount
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    backup_mode="$(env_get KES_BACKUP_PATH_MODE local)"
    backup_mount="$(env_get KES_BACKUP_EXPECTED_MOUNT '')"

    if [[ ! -d "$backup_path" ]]; then
        error "Backup directory is missing: $backup_path"
        return 1
    fi
    check_expected_mount "$backup_path" "$backup_mode" "$backup_mount" "backup" || return 1

    if path_is_within "$backup_path" "$CONFIG_DIR"; then
        error "Backup directory must not be inside the live config directory: $CONFIG_DIR"
        return 1
    fi
    if [[ ! -w "$backup_path" ]]; then
        error "The root-managed backup process cannot write to: $backup_path"
        return 1
    fi
    if ! run_as_service_user test -w "$backup_path"; then
        warn "Service account $SERVICE_USER cannot write to the backup path; root can still create backups there."
    fi

    success "Backup path exists and is writable by the manager: $backup_path"
}

container_mapping_matches() {
    local address="$1"
    local port="$2"
    docker inspect -f '{{range $containerPort, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{println .HostIp .HostPort}}{{end}}{{end}}' \
        "$CONTAINER_NAME" 2>/dev/null \
        | awk -v address="$address" -v port="$port" '
            $2 == port && ($1 == address || ($1 == "" && address == "0.0.0.0")) {found=1}
            END {exit(found ? 0 : 1)}'
}

container_owns_host_port() {
    local port="$1"
    docker inspect -f '{{range $containerPort, $bindings := .HostConfig.PortBindings}}{{range $bindings}}{{println .HostPort}}{{end}}{{end}}' \
        "$CONTAINER_NAME" 2>/dev/null \
        | grep -Fxq "$port"
}

port_has_listener() {
    local port="$1"
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
}

check_port_available() {
    local address="$1"
    local port="$2"

    if ! bind_address_is_present "$address"; then
        error "Bind address is not assigned to this server: $address"
        return 1
    fi

    if port_has_listener "$port"; then
        if container_owns_host_port "$port"; then
            success "TCP port $port is currently owned by the existing $CONTAINER_NAME container and can be reused during recreation."
            return 0
        fi
        error "TCP port $port is already in use by another listener."
        ss -ltnp "sport = :$port" 2>/dev/null || true
        return 1
    fi

    success "TCP port $address:$port is available."
}

write_env_file() {
    local port="$1"
    local bind_address="$2"
    local media_path="$3"
    local media_mode="$4"
    local expected_mount="$5"
    local backup_path="$6"
    local backup_mode="$7"
    local backup_mount="$8"
    local retention="$9"
    local timezone="${10}"
    local image="${11}"

    cat > "$ENV_FILE" <<EOF_ENV
PUID=$SERVICE_UID
PGID=$SERVICE_GID
TZ=$timezone
KES_BIND_ADDRESS=$bind_address
KES_HOST_PORT=$port
KES_MEDIA_PATH=$media_path
KES_MEDIA_PATH_MODE=$media_mode
KES_EXPECTED_MOUNT=$expected_mount
KES_BACKUP_PATH=$backup_path
KES_BACKUP_PATH_MODE=$backup_mode
KES_BACKUP_EXPECTED_MOUNT=$backup_mount
KES_BACKUP_RETENTION=$retention
KES_IMAGE=$image
EOF_ENV
}

write_compose_file() {
    cat > "$COMPOSE_FILE" <<'YAML'
services:
  karaoke-eternal:
    image: "${KES_IMAGE}"
    container_name: karaoke-eternal
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: "${TZ}"
    volumes:
      - type: bind
        source: ./config
        target: /config
        bind:
          create_host_path: false
      - type: bind
        source: "${KES_MEDIA_PATH}"
        target: /mnt/karaoke
        read_only: true
        bind:
          create_host_path: false
    ports:
      - "${KES_BIND_ADDRESS}:${KES_HOST_PORT}:8080/tcp"
    restart: unless-stopped
    stop_grace_period: 30s
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
YAML
}

compose() {
    docker compose \
        --project-directory "$APP_DIR" \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" "$@"
}

install_manager_command() {
    local source_script
    source_script="$(readlink -f "$0")"
    if [[ "$source_script" != "$MANAGER_PATH" ]]; then
        install -m 0755 "$source_script" "$MANAGER_PATH"
    else
        chmod 0755 "$MANAGER_PATH"
    fi
}

prompt_storage_mode() {
    local label="$1"
    local default="$2"
    local mode=""
    while true; do
        mode="$(prompt_value "$label storage mode (local or mounted)" "$default")"
        case "$mode" in
            local|mounted)
                printf '%s\n' "$mode"
                return 0
                ;;
            *) warn "Enter local or mounted." ;;
        esac
    done
}

suggest_mount_for_path() {
    local path="$1"
    local target=""
    target="$(findmnt -T "$path" -n -o TARGET 2>/dev/null || true)"
    if [[ "$target" == "/" || -z "$target" ]]; then
        printf '\n'
    else
        printf '%s\n' "$target"
    fi
}

prepare_storage_path() {
    local path="$1"
    local mode="$2"
    local expected_mount="$3"
    local label="$4"
    local created_var="$5"

    printf -v "$created_var" '%s' 0

    if [[ "$mode" == "mounted" ]]; then
        if [[ -z "$expected_mount" ]]; then
            error "$label storage mode is mounted, but no mount point was provided."
            return 1
        fi
        if [[ ! -d "$expected_mount" ]] || ! mountpoint -q "$expected_mount"; then
            error "$label mount must be active before configuration: $expected_mount"
            return 1
        fi
        if ! path_is_within "$path" "$expected_mount"; then
            error "$label path must be located under its expected mount point."
            return 1
        fi
        if [[ ! -d "$path" ]]; then
            mkdir -p "$path" || return 1
            printf -v "$created_var" '%s' 1
        fi
    else
        if [[ ! -d "$path" ]]; then
            if ! confirm "$label directory does not exist. Create it now at $path?" yes; then
                error "$label directory is required."
                return 1
            fi
            mkdir -p "$path" || return 1
            printf -v "$created_var" '%s' 1
        fi
    fi

    return 0
}

show_access_information() {
    local port bind_address
    port="$(env_get KES_HOST_PORT "$DEFAULT_PORT")"
    bind_address="$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")"

    printf '\n%sAccess URLs%s\n' "$C_CYAN" "$C_RESET"
    if [[ "$bind_address" == "0.0.0.0" || "$bind_address" == "127.0.0.1" ]]; then
        printf '  Local server: http://127.0.0.1:%s\n' "$port"
    fi
    if [[ "$bind_address" != "0.0.0.0" && "$bind_address" != "127.0.0.1" ]]; then
        printf '  Bound address: http://%s:%s\n' "$bind_address" "$port"
    elif [[ "$bind_address" == "0.0.0.0" ]]; then
        local addresses=""
        addresses="$(hostname -I 2>/dev/null | xargs || true)"
        local -a address_list=()
        local address
        IFS=' ' read -r -a address_list <<< "$addresses"
        for address in "${address_list[@]}"; do
            [[ "$address" == *:* ]] && continue
            printf '  Network:      http://%s:%s\n' "$address" "$port"
        done
    fi
    printf '  Container media folder: /mnt/karaoke\n'
}

rollback_reconfiguration() {
    local backup_dir="$1"
    local had_previous="$2"

    if [[ "$had_previous" == "yes" ]]; then
        cp -a "$backup_dir/.env" "$ENV_FILE" 2>/dev/null || true
        cp -a "$backup_dir/compose.yaml" "$COMPOSE_FILE" 2>/dev/null || true
        warn "Previous manager configuration restored."
        if docker_is_ready; then
            compose up -d --remove-orphans >/dev/null 2>&1 \
                || warn "The previous container configuration could not be restarted automatically."
        fi
    else
        rm -f "$ENV_FILE" "$COMPOSE_FILE"
        warn "Generated manager configuration files were removed because deployment did not complete."
    fi
    rm -rf "$backup_dir"
}

configure_application() {
    initialize_identity
    check_supported_host || return 1
    ensure_docker || return 1

    local current_port current_bind current_media current_media_mode current_media_mount
    local current_backup current_backup_mode current_backup_mount current_retention current_tz current_image
    current_port="$(env_get KES_HOST_PORT "$DEFAULT_PORT")"
    current_bind="$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")"
    current_media="$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")"
    current_media_mode="$(env_get KES_MEDIA_PATH_MODE local)"
    current_media_mount="$(env_get KES_EXPECTED_MOUNT '')"
    current_backup="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    current_backup_mode="$(env_get KES_BACKUP_PATH_MODE local)"
    current_backup_mount="$(env_get KES_BACKUP_EXPECTED_MOUNT '')"
    current_retention="$(env_get KES_BACKUP_RETENTION "$DEFAULT_BACKUP_RETENTION")"
    current_tz="$(env_get TZ "$DEFAULT_TZ")"
    current_image="$(env_get KES_IMAGE "$DEFAULT_IMAGE")"

    printf '\n%sKaraoke Eternal optimized configuration%s\n' "$C_CYAN" "$C_RESET"
    printf 'Press Enter to accept each current/default value.\n\n'

    local bind_address port media_path media_mode media_mount
    local backup_path backup_mode backup_mount retention timezone image

    while true; do
        bind_address="$(prompt_value "IPv4 bind address (0.0.0.0 = all interfaces)" "$current_bind")"
        if validate_bind_address "$bind_address" && bind_address_is_present "$bind_address"; then
            break
        fi
        warn "Enter an IPv4 address assigned to this server, 127.0.0.1, or 0.0.0.0."
    done

    while true; do
        port="$(prompt_value "Web interface TCP port" "$current_port")"
        validate_port "$port" || {
            warn "Enter a TCP port from 1 through 65535."
            continue
        }
        check_port_available "$bind_address" "$port" && break
    done
    (( 10#$port < 1024 )) && warn "Port $port is privileged; root-managed Docker can publish it, but a port above 1023 is normally simpler."

    while true; do
        media_path="$(prompt_value "Absolute host path containing karaoke songs" "$current_media")"
        validate_absolute_path "$media_path" && break
        warn "Use an absolute path without $, #, or control characters."
    done
    media_path="$(canonical_path "$media_path")"
    media_mode="$(prompt_storage_mode "Media" "$current_media_mode")"
    media_mount=""
    if [[ "$media_mode" == "mounted" ]]; then
        local media_mount_default="$current_media_mount"
        [[ -z "$media_mount_default" ]] && media_mount_default="$(suggest_mount_for_path "$media_path")"
        while true; do
            media_mount="$(prompt_optional_value "Expected active media mount point" "$media_mount_default")"
            if validate_absolute_path "$media_mount" && [[ -d "$media_mount" ]] && mountpoint -q "$media_mount"; then
                break
            fi
            warn "Enter an active mount point, such as /mnt/storage."
        done
        media_mount="$(canonical_path "$media_mount")"
    fi

    while true; do
        backup_path="$(prompt_value "Backup destination" "$current_backup")"
        validate_absolute_path "$backup_path" && break
        warn "Use an absolute path without $, #, or control characters."
    done
    backup_path="$(canonical_path "$backup_path")"
    backup_mode="$(prompt_storage_mode "Backup" "$current_backup_mode")"
    backup_mount=""
    if [[ "$backup_mode" == "mounted" ]]; then
        local backup_mount_default="$current_backup_mount"
        [[ -z "$backup_mount_default" ]] && backup_mount_default="$(suggest_mount_for_path "$backup_path")"
        while true; do
            backup_mount="$(prompt_optional_value "Expected active backup mount point" "$backup_mount_default")"
            if validate_absolute_path "$backup_mount" && [[ -d "$backup_mount" ]] && mountpoint -q "$backup_mount"; then
                break
            fi
            warn "Enter an active mount point for the backup destination."
        done
        backup_mount="$(canonical_path "$backup_mount")"
    fi

    while true; do
        retention="$(prompt_value "Number of automatic backups to retain" "$current_retention")"
        validate_retention "$retention" && break
        warn "Enter a whole number from 1 through 999."
    done

    while true; do
        timezone="$(prompt_value "Timezone" "$current_tz")"
        validate_timezone "$timezone" && break
        warn "Timezone not found under /usr/share/zoneinfo (example: America/New_York)."
    done

    while true; do
        image="$(prompt_value "Docker image" "$current_image")"
        validate_image "$image" && break
        warn "Enter a valid Docker image reference."
    done

    if path_is_within "$backup_path" "$CONFIG_DIR"; then
        error "The backup path cannot be inside the live config directory."
        return 1
    fi

    local media_created=0 backup_created=0
    prepare_storage_path "$media_path" "$media_mode" "$media_mount" "Media" media_created || return 1
    prepare_storage_path "$backup_path" "$backup_mode" "$backup_mount" "Backup" backup_created || return 1

    mkdir -p "$APP_DIR" "$CONFIG_DIR" || return 1
    ensure_free_space "$APP_DIR" "$MIN_APP_FREE_BYTES" "Application filesystem" || return 1
    check_inodes "$APP_DIR" || true

    local reconfigure_backup=""
    local had_previous="no"
    reconfigure_backup="$(mktemp -d "$APP_DIR/.reconfigure-backup.XXXXXX")" || return 1
    if [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]]; then
        had_previous="yes"
        cp -a "$ENV_FILE" "$reconfigure_backup/.env" || {
            rm -rf "$reconfigure_backup"
            return 1
        }
        cp -a "$COMPOSE_FILE" "$reconfigure_backup/compose.yaml" || {
            rm -rf "$reconfigure_backup"
            return 1
        }
    fi

    if ! write_env_file "$port" "$bind_address" "$media_path" "$media_mode" "$media_mount" \
        "$backup_path" "$backup_mode" "$backup_mount" "$retention" "$timezone" "$image" \
        || ! write_compose_file; then
        rollback_reconfiguration "$reconfigure_backup" "$had_previous"
        return 1
    fi

    chown -R "$SERVICE_UID:$SERVICE_GID" "$CONFIG_DIR"
    chown "$SERVICE_UID:$SERVICE_GID" "$APP_DIR" "$ENV_FILE" "$COMPOSE_FILE"
    if (( media_created == 1 )); then
        chown "$SERVICE_UID:$SERVICE_GID" "$media_path"
    fi
    if (( backup_created == 1 )); then
        chown "$SERVICE_UID:$SERVICE_GID" "$backup_path"
    fi
    chmod 0755 "$APP_DIR" "$CONFIG_DIR"
    chmod 0640 "$ENV_FILE"
    chmod 0644 "$COMPOSE_FILE"

    install_manager_command

    if ! check_media_path || ! check_backup_path; then
        rollback_reconfiguration "$reconfigure_backup" "$had_previous"
        return 1
    fi

    info "Validating Docker Compose configuration..."
    if ! compose config --quiet; then
        error "The generated Docker Compose configuration is invalid."
        rollback_reconfiguration "$reconfigure_backup" "$had_previous"
        return 1
    fi

    local docker_root="/var/lib/docker"
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
    if ! ensure_free_space "$docker_root" "$MIN_DOCKER_FREE_BYTES" "Docker data filesystem" \
        || ! check_dns_and_https; then
        rollback_reconfiguration "$reconfigure_backup" "$had_previous"
        return 1
    fi

    info "Pulling the configured Karaoke Eternal image..."
    if ! compose pull; then
        rollback_reconfiguration "$reconfigure_backup" "$had_previous"
        return 1
    fi

    info "Starting Karaoke Eternal..."
    if ! compose up -d --remove-orphans; then
        rollback_reconfiguration "$reconfigure_backup" "$had_previous"
        return 1
    fi

    rm -rf "$reconfigure_backup"
    success "$APP_NAME is installed and running."
    if [[ -f "$SAMBA_STATE_FILE" ]]         && [[ "$(samba_state_get SAMBA_MEDIA_PATH '')" != "$media_path" ]]; then
        warn "The media path changed. Reconfigure the Samba media share from the manager menu."
    fi
    show_access_information
    test_http_service || true
    printf '\nRun this manager later with: sudo %s\n' "$MANAGER_PATH"
}

preflight_application() {
    require_configuration || return 1
    ensure_docker || return 1
    compose config --quiet || {
        error "Docker Compose configuration validation failed."
        return 1
    }
    check_media_path || return 1

    local bind_address port
    bind_address="$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")"
    port="$(env_get KES_HOST_PORT "$DEFAULT_PORT")"
    check_port_available "$bind_address" "$port" || return 1
    return 0
}

start_application() {
    preflight_application || return 1
    compose up -d || return 1
    success "$APP_NAME started."
    show_access_information
    test_http_service || true
}

validate_kes_scan_target() {
    local scan_target="${1:-}"
    if [[ -z "$scan_target" ]]; then
        error "KES_SCAN value cannot be empty. Use 'all' or a comma-separated list of Karaoke Eternal pathIds."
        return 1
    fi
    if [[ "$scan_target" == "all" ]]; then
        return 0
    fi
    if [[ "$scan_target" =~ ^[A-Za-z0-9_.:-]+(,[A-Za-z0-9_.:-]+)*$ ]]; then
        return 0
    fi
    error "Invalid KES_SCAN value: $scan_target"
    printf 'Use all, or a comma-separated list of pathIds such as 1,2 or abc123,def456.
'
    return 1
}

compose_up_with_scan_override() {
    local scan_target="$1"
    local override_file=""

    validate_kes_scan_target "$scan_target" || return 1
    install -d -m 0755 "$APP_DIR" || return 1
    override_file="$(mktemp "$APP_DIR/.kes-scan-override.XXXXXX.yaml")" || return 1

    cat > "$override_file" <<YAML
services:
  karaoke-eternal:
    environment:
      KES_SCAN: "$scan_target"
YAML

    docker compose         --project-directory "$APP_DIR"         --env-file "$ENV_FILE"         -f "$COMPOSE_FILE"         -f "$override_file"         up -d --force-recreate --remove-orphans
    local rc=$?
    rm -f "$override_file"
    return "$rc"
}

start_application_with_media_scan() {
    local scan_target="${1:-all}"
    preflight_application || return 1
    validate_kes_scan_target "$scan_target" || return 1

    info "Starting/recreating $APP_NAME with media scanner enabled at startup."
    info "KES_SCAN=$scan_target"
    compose_up_with_scan_override "$scan_target" || return 1

    success "$APP_NAME started with startup media scan requested."
    warn "The running container was created with KES_SCAN=$scan_target. A normal restart/recreate removes this temporary scan override."
    show_access_information
    test_http_service || true
    printf '
Scanner output is written to Docker logs for Docker installs.
'
    printf 'View live logs with: sudo karaoke-eternal-manager --logs
'
}

start_application_menu() {
    while true; do
        print_header
        cat <<'MENU'
Start Karaoke Eternal

  1) Start normally
  2) Start/recreate with media scan on startup (KES_SCAN=all)
  3) Start/recreate with custom KES_SCAN pathIds
  4) View live logs
  0) Return
MENU
        printf '
'
        local choice=""
        read -r -p "Choose an option: " choice || return 0
        printf '
'
        case "$choice" in
            1) start_application; pause_screen ;;
            2) start_application_with_media_scan all; pause_screen ;;
            3)
                local scan_target=""
                scan_target="$(prompt_value "KES_SCAN value (all or comma-separated pathIds)" "all")"
                start_application_with_media_scan "$scan_target"
                pause_screen
                ;;
            4) show_logs ;;
            0) return 0 ;;
            *) warn "Invalid selection."; pause_screen ;;
        esac
    done
}

stop_application() {
    require_configuration || return 1
    ensure_docker || return 1
    compose stop || return 1
    success "$APP_NAME stopped."
}

restart_application() {
    preflight_application || return 1
    compose up -d --force-recreate --remove-orphans || return 1
    success "$APP_NAME force-recreated/restarted with the saved configuration."
    show_access_information
    test_http_service || true
}

container_is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" == "true" ]]
}

http_test_address() {
    local bind_address
    bind_address="$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")"
    if [[ "$bind_address" == "0.0.0.0" ]]; then
        printf '127.0.0.1\n'
    else
        printf '%s\n' "$bind_address"
    fi
}

test_http_service() {
    require_configuration || return 1
    local address port url code=""
    address="$(http_test_address)"
    port="$(env_get KES_HOST_PORT "$DEFAULT_PORT")"
    url="http://$address:$port/"

    info "Testing the web service at $url ..."
    local attempt
    for attempt in {1..20}; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
        if [[ "$code" =~ ^[1-5][0-9][0-9]$ && "$code" != "000" ]]; then
            success "Web service responded with HTTP $code."
            return 0
        fi
        sleep 1
    done

    warn "The web service did not answer within 20 seconds. Review container logs."
    return 1
}

show_status() {
    require_configuration || return 1
    ensure_docker || return 1

    printf '\n%sContainer status%s\n' "$C_CYAN" "$C_RESET"
    compose ps || true
    show_access_information

    printf '\n%sStorage use%s\n' "$C_CYAN" "$C_RESET"
    du -sh "$CONFIG_DIR" 2>/dev/null || true
    du -sh "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")" 2>/dev/null || true
    du -sh "$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")" 2>/dev/null || true

    printf '\n%sPath checks%s\n' "$C_CYAN" "$C_RESET"
    check_media_path || true
    check_backup_path || true

    printf '\n%sWeb test%s\n' "$C_CYAN" "$C_RESET"
    if container_is_running; then
        test_http_service || true
    else
        warn "Container is not running."
    fi
}

show_logs() {
    require_configuration || return 1
    ensure_docker || return 1
    info "Showing the latest logs. Press Ctrl+C to return to the menu."
    compose logs -f --tail=200 || true
}

ensure_unzip_tool() {
    if command -v unzip >/dev/null 2>&1; then
        return 0
    fi

    info "Installing the unzip package required for ZIP integrity testing..."
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip || return 1

    if ! command -v unzip >/dev/null 2>&1; then
        error "The unzip command is still unavailable after package installation."
        return 1
    fi
}

container_media_source() {
    command -v docker >/dev/null 2>&1 || return 0
    docker inspect "$CONTAINER_NAME" \
        --format '{{range .Mounts}}{{if eq .Destination "/mnt/karaoke"}}{{println .Source}}{{end}}{{end}}' \
        2>/dev/null | sed -n '1{s/[[:space:]]*$//;p;}'
}

resolve_zip_test_path() {
    local requested="${1:-}"
    local path=""
    local configured=""
    local mounted=""

    if [[ -n "$requested" ]]; then
        validate_absolute_path "$requested" || {
            error "ZIP test path must be a safe absolute path."
            return 1
        }
        path="$(canonical_path "$requested")"
    else
        # No-argument ZIP tests always use the canonical media directory.
        # This keeps menu item 15 and --verify-zips predictable.
        path="$(canonical_path "$DEFAULT_MEDIA_DIR")"

        if configuration_exists; then
            configured="$(canonical_path "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")")"
            mounted="$(container_media_source || true)"
            [[ -n "$mounted" ]] && mounted="$(canonical_path "$mounted")"

            if [[ "$configured" != "$path" ]]; then
                printf '%s[WARN]%s Saved KES_MEDIA_PATH differs from the ZIP-scan default.\n' \
                    "$C_YELLOW" "$C_RESET" >&2
                printf '       ZIP default: %s\n       Saved:       %s\n' \
                    "$path" "$configured" >&2
            fi
            if [[ -n "$mounted" && "$mounted" != "$path" ]]; then
                printf '%s[WARN]%s Docker /mnt/karaoke source differs from the ZIP-scan default.\n' \
                    "$C_YELLOW" "$C_RESET" >&2
                printf '       ZIP default: %s\n       Mounted:     %s\n' \
                    "$path" "$mounted" >&2
            fi
        fi
    fi

    if [[ ! -d "$path" ]]; then
        error "ZIP test directory does not exist: $path"
        return 1
    fi
    if [[ ! -r "$path" || ! -x "$path" ]]; then
        error "ZIP test directory is not readable/traversable: $path"
        return 1
    fi

    if configuration_exists; then
        configured="$(canonical_path "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")")"
        local expected_mode expected_mount
        expected_mode="$(env_get KES_MEDIA_PATH_MODE local)"
        expected_mount="$(env_get KES_EXPECTED_MOUNT '')"

        if [[ "$path" == "$configured" ]]; then
            check_expected_mount "$path" "$expected_mode" "$expected_mount" "media" || return 1
        elif [[ "$expected_mode" == "mounted" && -n "$expected_mount" ]] \
            && path_is_within "$path" "$expected_mount"; then
            check_expected_mount "$path" "$expected_mode" "$expected_mount" "media" || return 1
        fi
    fi

    printf '%s\n' "$path"
}

count_zip_files_under() {
    local folder="${1:-}"
    local count="0"

    if [[ -z "$folder" || ! -d "$folder" ]]; then
        printf '0\n'
        return 0
    fi

    count="$(find "$folder" -type f -iname '*.zip' -printf x 2>/dev/null | wc -c | tr -d '[:space:]')"
    printf '%s\n' "${count:-0}"
}

select_zip_media_subfolder() {
    local root="${1:-$DEFAULT_MEDIA_DIR}"
    local out_var="${2:-}"

    if [[ -z "$out_var" ]]; then
        error "Internal error: missing output variable for folder selection."
        return 1
    fi

    root="$(resolve_zip_test_path "$root")" || return 1

    local filter=""
    printf '\n%sMedia subfolder ZIP scan%s\n' "$C_CYAN" "$C_RESET"
    printf 'Root: %s\n' "$root"
    if ! read -r -p "Optional folder-name filter, blank to list all immediate subfolders: " filter; then
        printf '
'
        return 1
    fi

    local -a folders=()
    local -a counts=()
    local dir base count base_lower filter_lower
    filter_lower="${filter,,}"

    while IFS= read -r -d '' dir; do
        base="$(basename -- "$dir")"
        base_lower="${base,,}"
        if [[ -n "$filter_lower" && "$base_lower" != *"$filter_lower"* ]]; then
            continue
        fi
        count="$(count_zip_files_under "$dir")"
        if [[ "$count" =~ ^[0-9]+$ ]] && (( 10#$count > 0 )); then
            folders+=("$dir")
            counts+=("$count")
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    if (( ${#folders[@]} == 0 )); then
        if [[ -n "$filter" ]]; then
            info "No immediate subfolders matching '$filter' contain ZIP files."
        else
            info "No immediate subfolders under $root contain ZIP files."
        fi
        return 1
    fi

    local list_file
    list_file="$(mktemp)" || return 1
    {
        printf 'Choose one folder to scan recursively:\n\n'
        local i
        for i in "${!folders[@]}"; do
            printf ' %3d) [%s ZIPs] %s\n' "$((i + 1))" "${counts[$i]}" "${folders[$i]}"
        done
        printf '   0) Cancel\n'
        printf '   v) View this list again\n'
    } > "$list_file"

    local selection=""
    while true; do
        show_file_scrollable "$list_file" "media folder list"
        printf '\n'
        if ! read -r -p "Select media folder, v to view list again, or 0 to cancel: " selection; then
            printf '
'
            rm -f "$list_file"
            return 1
        fi
        [[ "$selection" == "0" ]] && { rm -f "$list_file"; return 1; }
        [[ "$selection" =~ ^[Vv]$ ]] && continue
        [[ "$selection" =~ ^[0-9]+$ ]] || { error "Enter a valid number."; continue; }
        (( 10#$selection >= 1 && 10#$selection <= ${#folders[@]} )) || { error "Selection is out of range."; continue; }
        break
    done
    rm -f "$list_file"

    printf -v "$out_var" '%s' "${folders[$((10#$selection - 1))]}"
}

zip_scan_then_optional_exit_review() {
    local selected="${1:-}"
    local timeout_seconds="${2:-$DEFAULT_ZIP_TEST_TIMEOUT}"
    local rc=0 index="" code=""

    zip_integrity_scan "$selected" "$timeout_seconds"
    rc=$?

    if (( rc == 2 )); then
        index="$(latest_zip_error_index)"
        if [[ -n "$index" && -f "$index" ]]; then
            printf '\n'
            zip_exit_code_summary "$index" "$selected" || true
            printf '\n'
            if confirm "Filter this scan by one exit code and choose keep/quarantine/delete now?" yes; then
                if ! read -r -p "Exact exit code to review: " code; then
                    printf '
'
                    return "$rc"
                fi
                validate_zip_exit_code_filter "$code" || return "$rc"
                review_zip_error_log "$index" "$code" "$selected"
            fi
        fi
    fi

    return "$rc"
}

zip_fast_scan_workflow() {
    require_configuration || return 1

    local requested="${1:-}"
    local timeout_seconds="${2:-$DEFAULT_ZIP_TEST_TIMEOUT}"
    local default_path configured mounted selected choice custom code index rc

    default_path="$(canonical_path "$DEFAULT_MEDIA_DIR")"
    configured="$(canonical_path "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")")"
    mounted="$(container_media_source || true)"
    [[ -n "$mounted" ]] && mounted="$(canonical_path "$mounted")"

    printf '\n%sFast ZIP scan%s\n' "$C_CYAN" "$C_RESET"
    printf 'Workflow: choose folder -> scan recursively -> show exit-code summary -> review one exit code\n\n'

    if [[ -n "$requested" ]]; then
        selected="$(resolve_zip_test_path "$requested")" || return 1
    else
        printf '  Default ZIP media root: %s\n' "$default_path"
        printf '  Saved KES_MEDIA_PATH:   %s\n' "$configured"
        if [[ -n "$mounted" ]]; then
            printf '  Docker /mnt/karaoke:    %s\n' "$mounted"
        else
            printf '  Docker /mnt/karaoke:    container not created or unavailable\n'
        fi

        cat <<'MENU'

  1) Fast scan /data/karaoke-eternal/media recursively
  2) Fast scan one immediate subfolder under the default ZIP media root
  3) Fast scan the saved KES_MEDIA_PATH
  4) Fast scan the active Docker /mnt/karaoke source
  5) Fast scan another absolute media folder
  0) Cancel
MENU
        choice=""
        if ! read -r -p "Choose the Fast Scan folder [2]: " choice; then
            printf '
'
            return 1
        fi
        choice="${choice:-2}"

        case "$choice" in
            1) selected="$default_path" ;;
            2) select_zip_media_subfolder "$default_path" selected || return 0 ;;
            3) selected="$configured" ;;
            4)
                if [[ -z "$mounted" ]]; then
                    error "The Karaoke Eternal container has no detectable /mnt/karaoke source."
                    return 1
                fi
                selected="$mounted"
                ;;
            5)
                custom=""
                if ! read -r -p "Absolute media folder: " custom; then
                    printf '
'
                    return 1
                fi
                validate_absolute_path "$custom" || {
                    error "Enter a safe absolute path."
                    return 1
                }
                selected="$(canonical_path "$custom")"
                ;;
            0) return 0 ;;
            *) error "Invalid selection."; return 1 ;;
        esac
    fi

    selected="$(resolve_zip_test_path "$selected")" || return 1

    printf '\nFast Scan root: %s\n' "$selected"
    confirm "Run Fast Scan on this folder now?" yes || return 0

    zip_integrity_scan "$selected" "$timeout_seconds"
    rc=$?

    if (( rc == 0 )); then
        success "Fast Scan finished with no ZIP errors to review."
        return 0
    fi
    if (( rc != 2 )); then
        return "$rc"
    fi

    index="$(latest_zip_error_index)"
    if [[ -z "$index" || ! -f "$index" ]]; then
        error "Fast Scan found errors, but the ZIP error index could not be found."
        return 1
    fi

    printf '\n'
    zip_exit_code_summary "$index" "$selected" || return 1

    while true; do
        printf '\n'
        code=""
        if ! read -r -p "Exact exit code to review now, blank to skip review: " code; then
            printf '
'
            return "$rc"
        fi
        if [[ -z "$code" ]]; then
            info "Skipped filtered review. The report remains available from menu item 16."
            return "$rc"
        fi
        if validate_zip_exit_code_filter "$code"; then
            code="$((10#$code))"
            break
        fi
    done

    review_zip_error_log "$index" "$code" "$selected"
    return "$rc"
}

zip_integrity_scan_menu() {
    require_configuration || return 1

    local requested_root="${1:-$DEFAULT_MEDIA_DIR}"
    local timeout_seconds="${2:-$DEFAULT_ZIP_TEST_TIMEOUT}"
    local default_path configured mounted selected choice custom
    default_path="$(canonical_path "$requested_root")"
    configured="$(canonical_path "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")")"
    mounted="$(container_media_source || true)"
    [[ -n "$mounted" ]] && mounted="$(canonical_path "$mounted")"

    printf '\n%sZIP media-folder selection%s\n' "$C_CYAN" "$C_RESET"
    printf '  Default ZIP media root: %s\n' "$default_path"
    printf '  Saved KES_MEDIA_PATH:   %s\n' "$configured"
    if [[ -n "$mounted" ]]; then
        printf '  Docker /mnt/karaoke:    %s\n' "$mounted"
    else
        printf '  Docker /mnt/karaoke:    container not created or unavailable\n'
    fi

    cat <<'MENU'

  1) Scan /data/karaoke-eternal/media recursively (default)
  2) Select an immediate subfolder under the default ZIP media root
  3) Scan the saved KES_MEDIA_PATH
  4) Scan the active Docker /mnt/karaoke source
  5) Enter another absolute media folder
  6) Fast Scan: choose folder -> scan -> summarize -> review one exit code
  0) Cancel
MENU
    if ! read -r -p "Choose the ZIP scan option [1]: " choice; then
        printf '
'
        return 1
    fi
    choice="${choice:-1}"

    case "$choice" in
        1) selected="$default_path" ;;
        2) select_zip_media_subfolder "$default_path" selected || return 0 ;;
        3) selected="$configured" ;;
        4)
            if [[ -z "$mounted" ]]; then
                error "The Karaoke Eternal container has no detectable /mnt/karaoke source."
                return 1
            fi
            selected="$mounted"
            ;;
        5)
            if ! read -r -p "Absolute media folder: " custom; then
                printf '
'
                return 1
            fi
            validate_absolute_path "$custom" || {
                error "Enter a safe absolute path."
                return 1
            }
            selected="$(canonical_path "$custom")"
            ;;
        6) zip_fast_scan_workflow "" "$timeout_seconds"; return $? ;;
        0) return 0 ;;
        *) error "Invalid selection."; return 1 ;;
    esac

    printf '
ZIP scan root: %s
' "$selected"
    confirm "Recursively test ZIP files in this folder?" yes || return 0
    zip_scan_then_optional_exit_review "$selected" "$timeout_seconds"
}

zip_integrity_scan_by_folder_workflow() {
    require_configuration || return 1
    local root="${1:-$DEFAULT_MEDIA_DIR}"
    local timeout_seconds="${2:-$DEFAULT_ZIP_TEST_TIMEOUT}"
    local selected=""

    select_zip_media_subfolder "$root" selected || return 1
    printf '
ZIP scan root: %s
' "$selected"
    confirm "Recursively test ZIP files in this folder?" yes || return 0
    zip_scan_then_optional_exit_review "$selected" "$timeout_seconds"
}

b64_encode_text() {
    printf '%s' "$1" | base64 -w 0
}

b64_decode_text() {
    printf '%s' "$1" | base64 -d
}

latest_zip_error_index() {
    local latest_link="$REPORT_DIR/zip-errors-latest.tsv"
    if [[ -e "$latest_link" || -L "$latest_link" ]]; then
        readlink -f -- "$latest_link" 2>/dev/null || true
        return
    fi
    find "$REPORT_DIR" -maxdepth 1 -type f -name 'zip-errors-*.tsv' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-
}

latest_zip_human_log() {
    local latest_link="$REPORT_DIR/zip-test-latest.log"
    if [[ -e "$latest_link" || -L "$latest_link" ]]; then
        readlink -f -- "$latest_link" 2>/dev/null || true
        return
    fi
    find "$REPORT_DIR" -maxdepth 1 -type f -name 'zip-test-*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-
}

zip_integrity_scan() {
    local requested="${1:-}"
    local timeout_seconds="${2:-$DEFAULT_ZIP_TEST_TIMEOUT}"
    local media_path=""

    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( 10#$timeout_seconds >= 10 && 10#$timeout_seconds <= 3600 )) || {
        error "ZIP timeout must be an integer from 10 to 3600 seconds."
        return 1
    }

    ensure_unzip_tool || return 1
    media_path="$(resolve_zip_test_path "$requested")" || return 1
    [[ -n "$SERVICE_USER" ]] || initialize_identity

    mkdir -p "$REPORT_DIR"
    local stamp human_log error_index details_dir find_errors
    stamp="$(date +%Y%m%d-%H%M%S)-$$"
    human_log="$REPORT_DIR/zip-test-$stamp.log"
    error_index="$REPORT_DIR/zip-errors-$stamp.tsv"
    details_dir="$REPORT_DIR/zip-test-details-$stamp"
    find_errors="$details_dir/find-errors.log"
    mkdir -p "$details_dir"

    printf '# Karaoke Eternal ZIP integrity test\n' > "$human_log"
    printf 'Started: %s\nRoot: %s\nCommand: unzip -tqq -P <empty>\nPer-file timeout: %ss\n\n' \
        "$(date --iso-8601=seconds)" "$media_path" "$timeout_seconds" >> "$human_log"
    printf '#KARAOKE_ETERNAL_ZIP_ERRORS_V1\n' > "$error_index"
    printf '#root_b64\tpath_b64\tstatus\texit_code\tdetail_b64\n' >> "$error_index"

    local total tested=0 passed=0 failed=0
    total="$(find "$media_path" -type f -iname '*.zip' -printf x 2>"$find_errors" | wc -c | tr -d ' ')"
    total="${total:-0}"

    printf '\n%sRecursive ZIP integrity test%s\n' "$C_CYAN" "$C_RESET"
    printf '  Media folder: %s\n' "$media_path"
    printf '  ZIP files:    %s\n' "$total"
    printf '  Error log:    %s\n\n' "$human_log"

    while IFS= read -r -d '' zip_file; do
        tested=$((tested + 1))
        printf '[%d/%d] %s\n' "$tested" "$total" "$zip_file"

        local temp_output rc status detail_file
        temp_output="$(mktemp "$details_dir/.zip-test.XXXXXX")"
        rc=0
        status="ERROR"

        if [[ ! -r "$zip_file" ]]; then
            rc=126
            status="UNREADABLE"
            printf 'File is not readable by root: %s\n' "$zip_file" > "$temp_output"
        elif ! run_as_service_user test -r "$zip_file"; then
            rc=126
            status="UNREADABLE"
            printf 'File is not readable by service account %s: %s\n' "$SERVICE_USER" "$zip_file" > "$temp_output"
        else
            timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" \
                unzip -tqq -P '' "$zip_file" > "$temp_output" 2>&1
            rc=$?
            if (( rc == 0 )); then
                passed=$((passed + 1))
                rm -f -- "$temp_output"
                continue
            elif (( rc == 124 || rc == 137 )); then
                status="TIMEOUT"
                printf '\nZIP test exceeded %s seconds.\n' "$timeout_seconds" >> "$temp_output"
            fi
            if [[ ! -s "$temp_output" ]]; then
                printf 'unzip failed with exit status %s. The archive may be encrypted or unreadable.\n' "$rc" > "$temp_output"
            fi
        fi

        failed=$((failed + 1))
        detail_file="$details_dir/error-$(printf '%06d' "$failed").log"
        mv -- "$temp_output" "$detail_file"

        printf 'ERROR [%s] exit=%s: %s\n' "$status" "$rc" "$zip_file" >> "$human_log"
        sed 's/^/    /' "$detail_file" >> "$human_log"
        printf '\n' >> "$human_log"

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(b64_encode_text "$media_path")" \
            "$(b64_encode_text "$zip_file")" \
            "$status" "$rc" \
            "$(b64_encode_text "$detail_file")" >> "$error_index"
    done < <(find "$media_path" -type f -iname '*.zip' -print0 2>>"$find_errors")

    local find_had_warnings=0
    if [[ -s "$find_errors" ]]; then
        find_had_warnings=1
        warn "Directory traversal produced warnings. See: $find_errors"
        printf 'DIRECTORY TRAVERSAL WARNINGS:\n' >> "$human_log"
        sed 's/^/    /' "$find_errors" >> "$human_log"
        printf '\n' >> "$human_log"
    else
        rm -f -- "$find_errors"
    fi

    {
        printf 'Completed: %s\n' "$(date --iso-8601=seconds)"
        printf 'ZIP files discovered: %d\n' "$total"
        printf 'ZIP files tested:     %d\n' "$tested"
        printf 'Passed:               %d\n' "$passed"
        printf 'Errors:               %d\n' "$failed"
        printf 'Traversal warnings:   %d\n' "$find_had_warnings"
    } >> "$human_log"

    ln -sfn "$(basename "$human_log")" "$REPORT_DIR/zip-test-latest.log"
    ln -sfn "$(basename "$error_index")" "$REPORT_DIR/zip-errors-latest.tsv"

    printf '\n'
    printf 'Tested: %d  Passed: %d  Errors: %d\n' "$tested" "$passed" "$failed"
    printf 'Readable report: %s\n' "$human_log"
    printf 'Error index:     %s\n' "$error_index"

    if (( failed > 0 )); then
        warn "$failed ZIP file(s) failed integrity testing. Use menu item 16 or --review-zip-errors."
        if (( find_had_warnings > 0 )); then
            warn "Directory traversal warnings also occurred; some folders may not have been scanned."
        fi
        return 2
    fi

    if (( find_had_warnings > 0 )); then
        warn "ZIP tests found no bad archives, but directory traversal warnings occurred. Some folders may not have been scanned."
        return 3
    fi

    success "All discovered ZIP files passed unzip integrity testing."
    return 0
}

show_latest_zip_error_log() {
    local human_log index
    human_log="$(latest_zip_human_log)"
    index="$(latest_zip_error_index)"

    if [[ -z "$human_log" || ! -f "$human_log" ]]; then
        info "No ZIP integrity-test report exists yet."
        return 1
    fi

    printf '\n%sLatest ZIP integrity report%s\n' "$C_CYAN" "$C_RESET"
    show_file_scrollable "$human_log" "ZIP integrity report"
    printf '\nMachine-readable error index: %s\n' "${index:-not found}"
}

log_zip_error_action() {
    local action="$1" file="$2" destination="${3:-}"
    mkdir -p "$REPORT_DIR"
    printf '%s\taction=%s\tfile=%q\tdestination=%q\n' \
        "$(date --iso-8601=seconds)" "$action" "$file" "$destination" >> "$ZIP_ACTION_LOG"
}

validate_zip_review_path() {
    local root="${1:-}" file="${2:-}"

    [[ -n "$root" && -n "$file" ]] || {
        error "Missing ZIP review path information."
        return 1
    }
    validate_absolute_path "$root" || {
        error "Scanned media root is not a safe absolute path: $root"
        return 1
    }
    validate_absolute_path "$file" || {
        error "Selected ZIP path is not a safe absolute path: $file"
        return 1
    }
    if ! path_is_within "$file" "$root"; then
        error "Refusing to act outside the scanned media directory."
        return 1
    fi
    case "${file,,}" in
        *.zip) ;;
        *)
            error "The selected path is not a ZIP file."
            return 1
            ;;
    esac
}

create_unresolved_zip_review_index() {
    local source_index="${1:-}"
    local output_file="${2:-}"
    local exit_code_filter="${3:-}"
    local folder_filter="${4:-}"

    [[ -n "$source_index" && -f "$source_index" ]] || { error "Source ZIP error index is missing."; return 1; }
    [[ -n "$output_file" ]] || { error "Missing unresolved ZIP review output file."; return 1; }

    python3 - "$source_index" "$ZIP_ACTION_LOG" "$output_file" "$exit_code_filter" "$folder_filter" <<'PYREVIEW'
import base64
import codecs
import os
import shlex
import sys

source_index, action_log, output_file, exit_code_filter, folder_filter = sys.argv[1:6]
folder_filter = os.path.realpath(folder_filter) if folder_filter else ""
handled_actions = {"KEPT", "QUARANTINED", "DELETED", "RESTORED"}
latest_action = {}

def b64decode(value: str) -> str:
    return base64.b64decode(value.encode("ascii")).decode("utf-8", "surrogateescape")

def decode_bash_percent_q(value: str) -> str:
    value = value.strip()
    if value == "''":
        return ""
    if value.startswith("$'") and value.endswith("'"):
        body = value[2:-1]
        try:
            return codecs.decode(body, "unicode_escape")
        except Exception:
            return ""
    try:
        parsed = shlex.split(value, posix=True)
        return parsed[0] if parsed else ""
    except Exception:
        return ""

def is_within(child: str, parent: str) -> bool:
    child = os.path.realpath(child)
    parent = os.path.realpath(parent)
    return child == parent or child.startswith(parent + os.sep)

if os.path.exists(action_log):
    with open(action_log, "r", encoding="utf-8", errors="surrogateescape") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            values = {}
            for part in parts[1:]:
                if "=" not in part:
                    continue
                key, val = part.split("=", 1)
                values[key] = val
            action = values.get("action", "")
            file_path = decode_bash_percent_q(values.get("file", ""))
            if action and file_path:
                latest_action[os.path.realpath(file_path)] = action

with open(output_file, "w", encoding="utf-8", errors="surrogateescape") as out:
    out.write("#KARAOKE_ETERNAL_UNRESOLVED_ZIP_ERRORS_V1\n")
    out.write("#source_index=" + source_index + "\n")
    out.write("#root_b64\tpath_b64\tstatus\texit_code\tdetail_b64\n")
    with open(source_index, "r", encoding="utf-8", errors="surrogateescape") as fh:
        for line in fh:
            raw = line.rstrip("\n")
            if not raw or raw.startswith("#"):
                continue
            parts = raw.split("\t")
            if len(parts) < 5:
                continue
            root_b64, path_b64, status, rc, detail_b64 = parts[:5]
            if exit_code_filter and rc != exit_code_filter:
                continue
            try:
                decoded_path = b64decode(path_b64)
            except Exception:
                continue
            if folder_filter and not is_within(decoded_path, folder_filter):
                continue
            if latest_action.get(os.path.realpath(decoded_path)) in handled_actions:
                continue
            out.write("\t".join([root_b64, path_b64, status, rc, detail_b64]) + "\n")
PYREVIEW
}

parse_zip_review_selection() {
    local selection="${1:-}"
    local max="${2:-0}"
    local out_var="${3:-}"

    [[ -n "$out_var" ]] || { error "Internal error: missing selection output variable."; return 1; }
    [[ "$max" =~ ^[0-9]+$ ]] && (( 10#$max > 0 )) || { error "No selectable rows are available."; return 1; }

    selection="${selection//[[:space:]]/}"
    [[ -n "$selection" ]] || { warn "Enter one number, a comma list, or a range such as 1-5."; return 1; }

    local -a parts=()
    local old_ifs="$IFS"
    IFS=',' read -r -a parts <<< "$selection"
    IFS="$old_ifs"

    local -A seen=()
    local -a selected=()
    local part start end n idx
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || { warn "Empty selection item found."; return 1; }
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            (( 10#$start >= 1 && 10#$end >= 1 )) || { warn "Range values must be at least 1."; return 1; }
            (( 10#$start <= 10#$end )) || { warn "Use ascending ranges like 1-5, not 5-1."; return 1; }
            (( 10#$end <= 10#$max )) || { warn "Selection range exceeds the list size."; return 1; }
            for (( n=10#$start; n<=10#$end; n++ )); do
                idx=$((n - 1))
                if [[ -z "${seen[$idx]:-}" ]]; then
                    seen[$idx]=1
                    selected+=("$idx")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            (( 10#$part >= 1 && 10#$part <= 10#$max )) || { warn "Selection is out of range: $part"; return 1; }
            idx=$((10#$part - 1))
            if [[ -z "${seen[$idx]:-}" ]]; then
                seen[$idx]=1
                selected+=("$idx")
            fi
        else
            warn "Invalid selection item: $part"
            return 1
        fi
    done

    local selected_join="" selected_idx
    for selected_idx in "${selected[@]}"; do
        selected_join+="${selected_join:+ }$selected_idx"
    done
    printf -v "$out_var" '%s' "$selected_join"
}

remove_review_rows_by_indices() {
    local indices="${1:-}"
    local -n review_rows=rows
    local -A remove=()
    local idx i
    for idx in $indices; do
        remove[$idx]=1
    done

    local -a kept=()
    for i in "${!review_rows[@]}"; do
        [[ -n "${remove[$i]:-}" ]] && continue
        kept+=("${review_rows[$i]}")
    done
    review_rows=("${kept[@]}")
}

quarantine_zip_action_target() {
    local root="${1:-}" file="${2:-}" quarantine_root="${3:-}"
    local relative destination

    validate_zip_action_target "$root" "$file" || return 1
    [[ -n "$quarantine_root" ]] || { error "Missing quarantine batch folder."; return 1; }
    validate_absolute_path "$quarantine_root" || { error "Unsafe quarantine batch folder: $quarantine_root"; return 1; }
    path_is_within "$quarantine_root" "$ZIP_QUARANTINE_DIR" || {
        error "Refusing to quarantine outside: $ZIP_QUARANTINE_DIR"
        return 1
    }

    relative="${file#"$root"/}"
    if [[ "$relative" == "$file" || "$relative" == ../* || "$relative" == /* || "$relative" == *'/../'* ]]; then
        error "Unable to derive a safe relative path for quarantine."
        return 1
    fi

    destination="$quarantine_root/$relative"
    if [[ -e "$destination" || -L "$destination" ]]; then
        error "Quarantine destination already exists, refusing overwrite: $destination"
        return 1
    fi
    mkdir -p "$(dirname "$destination")" || return 1
    if mv -- "$file" "$destination"; then
        log_zip_error_action QUARANTINED "$file" "$destination"
        success "Moved to quarantine: $destination"
        return 0
    fi
    error "Unable to move the file to quarantine: $file"
    return 1
}

validate_zip_action_target() {
    local root="${1:-}" file="${2:-}"

    validate_zip_review_path "$root" "$file" || return 1
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        error "The selected file no longer exists: $file"
        return 1
    fi
    if [[ -d "$file" ]]; then
        error "Refusing to act on a directory."
        return 1
    fi
}

zip_exit_code_summary() {
    local index="${1:-}"
    local folder_filter="${2:-}"
    if [[ -z "$index" ]]; then
        index="$(latest_zip_error_index)"
    fi
    if [[ -z "$index" || ! -f "$index" ]]; then
        error "No ZIP error index was found. Run the recursive ZIP test first."
        return 1
    fi

    if [[ -n "$folder_filter" ]]; then
        validate_absolute_path "$folder_filter" || {
            error "Folder filter must be a safe absolute path."
            return 1
        }
        folder_filter="$(canonical_path "$folder_filter")"
        if [[ ! -d "$folder_filter" ]]; then
            error "Folder filter does not exist: $folder_filter"
            return 1
        fi
    fi

    local summary_index
    summary_index="$(mktemp)" || return 1
    create_unresolved_zip_review_index "$index" "$summary_index" "" "$folder_filter" || {
        rm -f "$summary_index"
        return 1
    }

    local line root_b64 path_b64 status rc detail_b64
    local -A counts=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$line"
        [[ "$rc" =~ ^[0-9]+$ ]] || continue
        counts[$rc]=$(( ${counts[$rc]:-0} + 1 ))
    done < "$summary_index"
    rm -f "$summary_index"

    if (( ${#counts[@]} == 0 )); then
        if [[ -n "$folder_filter" ]]; then
            success "The selected folder has no unresolved ZIP errors in this report."
        else
            success "The selected ZIP test contains no unresolved file errors."
        fi
        return 0
    fi

    printf '\n%sUnresolved ZIP errors by unzip exit code%s\n' "$C_CYAN" "$C_RESET"
    printf 'Report: %s\n' "$index"
    if [[ -n "$folder_filter" ]]; then
        printf 'Folder filter: %s\n' "$folder_filter"
    fi
    printf '\n'
    printf '  Exit code   Files\n'
    printf '  ---------   -----\n'
    local summary_code
    while IFS= read -r summary_code; do
        [[ -n "$summary_code" ]] || continue
        printf '  %-11s %s\n' "$summary_code" "${counts[$summary_code]}"
    done < <(printf '%s\n' "${!counts[@]}" | sort -n)
}

validate_zip_exit_code_filter() {
    local code="${1:-}"
    if [[ ! "$code" =~ ^[0-9]+$ ]]; then
        error "Exit-code filter must be a non-negative integer."
        return 1
    fi

    local normalized="$code"
    while [[ ${#normalized} -gt 1 && "${normalized:0:1}" == "0" ]]; do
        normalized="${normalized:1}"
    done
    if (( ${#normalized} > 3 )) || (( 10#$normalized > 255 )); then
        error "Exit-code filter must be between 0 and 255."
        return 1
    fi
}

review_zip_errors_by_exit_code() {
    local code="${1:-}"
    local index="${2:-}"

    if [[ -z "$index" ]]; then
        index="$(latest_zip_error_index)"
    fi
    if [[ -z "$index" || ! -f "$index" ]]; then
        error "No ZIP error index was found. Run the recursive ZIP test first."
        return 1
    fi

    zip_exit_code_summary "$index" || return 1

    if [[ -z "$code" ]]; then
        printf '\n'
        if ! read -r -p "Enter the exact exit code to review: " code; then
            printf '
'
            return 1
        fi
    fi
    validate_zip_exit_code_filter "$code" || return 1
    code="$((10#$code))"

    review_zip_error_log "$index" "$code"
}

review_zip_errors_by_folder_and_exit_code() {
    local folder="${1:-}"
    local code="${2:-}"
    local index="${3:-}"

    if [[ -z "$index" ]]; then
        index="$(latest_zip_error_index)"
    fi
    if [[ -z "$index" || ! -f "$index" ]]; then
        error "No ZIP error index was found. Run the recursive ZIP test first."
        return 1
    fi

    if [[ -z "$folder" ]]; then
        select_zip_media_subfolder "$DEFAULT_MEDIA_DIR" folder || return 1
    else
        validate_absolute_path "$folder" || {
            error "Folder filter must be a safe absolute path."
            return 1
        }
        folder="$(canonical_path "$folder")"
        if [[ ! -d "$folder" ]]; then
            error "Folder filter does not exist: $folder"
            return 1
        fi
    fi

    zip_exit_code_summary "$index" "$folder" || return 1

    if [[ -z "$code" ]]; then
        printf '
'
        if ! read -r -p "Enter the exact exit code to review in this folder: " code; then
            printf '
'
            return 1
        fi
    fi
    validate_zip_exit_code_filter "$code" || return 1
    code="$((10#$code))"

    review_zip_error_log "$index" "$code" "$folder"
}

review_zip_error_log() {
    local index="${1:-}"
    local exit_code_filter="${2:-}"
    local folder_filter="${3:-}"
    if [[ -z "$index" ]]; then
        index="$(latest_zip_error_index)"
    fi
    if [[ -z "$index" || ! -f "$index" ]]; then
        error "No ZIP error index was found. Run the recursive ZIP test first."
        return 1
    fi

    if [[ -n "$exit_code_filter" ]]; then
        validate_zip_exit_code_filter "$exit_code_filter" || return 1
        exit_code_filter="$((10#$exit_code_filter))"
    fi
    if [[ -n "$folder_filter" ]]; then
        validate_absolute_path "$folder_filter" || {
            error "Folder filter must be a safe absolute path."
            return 1
        }
        folder_filter="$(canonical_path "$folder_filter")"
        if [[ ! -d "$folder_filter" ]]; then
            error "Folder filter does not exist: $folder_filter"
            return 1
        fi
    fi

    local unresolved_index
    unresolved_index="$(mktemp)" || return 1
    create_unresolved_zip_review_index "$index" "$unresolved_index" "$exit_code_filter" "$folder_filter" || {
        rm -f "$unresolved_index"
        return 1
    }

    local -a rows=()
    local candidate_line candidate_root_b64 candidate_path_b64 candidate_status candidate_rc candidate_detail_b64
    while IFS= read -r candidate_line || [[ -n "$candidate_line" ]]; do
        [[ -z "$candidate_line" || "$candidate_line" == \#* ]] && continue
        IFS=$'\t' read -r candidate_root_b64 candidate_path_b64 candidate_status candidate_rc candidate_detail_b64 <<< "$candidate_line"
        [[ -n "${candidate_path_b64:-}" && -n "${candidate_rc:-}" ]] || continue
        rows+=("$candidate_line")
    done < "$unresolved_index"
    rm -f "$unresolved_index"

    if (( ${#rows[@]} == 0 )); then
        if [[ -n "$exit_code_filter" && -n "$folder_filter" ]]; then
            info "No unresolved ZIP errors with exit code $exit_code_filter were found under $folder_filter."
        elif [[ -n "$exit_code_filter" ]]; then
            info "No unresolved ZIP errors with exit code $exit_code_filter were found in this report."
        elif [[ -n "$folder_filter" ]]; then
            info "No unresolved ZIP errors were found under $folder_filter in this report."
        else
            success "The selected ZIP test contains no unresolved file errors."
        fi
        return 0
    fi

    while true; do
        if (( ${#rows[@]} == 0 )); then
            success "No unresolved entries remain in this review session."
            return 0
        fi
        local list_file
        list_file="$(mktemp)" || return 1
        {
            printf 'Unresolved ZIP files recorded with errors\n'
            printf 'Report: %s\n' "$index"
            if [[ -n "$exit_code_filter" ]]; then
                printf 'Filter: exact exit code %s\n' "$exit_code_filter"
            fi
            if [[ -n "$folder_filter" ]]; then
                printf 'Folder filter: %s\n' "$folder_filter"
            fi
            printf 'Entries: %s\n' "${#rows[@]}"
            printf '\n'
            local i row root_b64 path_b64 status rc detail_b64 display_path
            for i in "${!rows[@]}"; do
                row="${rows[$i]}"
                IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$row"
                display_path="$(b64_decode_text "$path_b64" 2>/dev/null || printf '<invalid path encoding>')"
                printf ' %3d) [%s, exit %s] %s\n' "$((i + 1))" "$status" "$rc" "$display_path"
            done
            printf '   0) Return\n'
            printf '   v) View this list again\n'
            printf '\nSelection examples: 1    1-5    1,2,3,10    1-5,8,12\n'
        } > "$list_file"
        printf '\n%sUnresolved ZIP files recorded with errors%s\n' "$C_CYAN" "$C_RESET"
        show_file_scrollable "$list_file" "ZIP error selection list"
        rm -f "$list_file"
        printf '\n'

        local selection="" selected_indices=""
        if ! read -r -p "Select one or more entries, v to view list again, or 0 to return: " selection; then
            printf '\n'
            return 0
        fi
        [[ "$selection" == "0" ]] && return 0
        [[ "$selection" =~ ^[Vv]$ ]] && continue
        parse_zip_review_selection "$selection" "${#rows[@]}" selected_indices || continue

        local -a selected_array=()
        local old_ifs_for_selection="$IFS"
        IFS=' ' read -r -a selected_array <<< "$selected_indices"
        IFS="$old_ifs_for_selection"
        local selected_count="${#selected_array[@]}"
        (( selected_count > 0 )) || { warn "No entries selected."; continue; }

        printf '\n%sSelected ZIP error entries%s\n' "$C_CYAN" "$C_RESET"
        local idx row root_b64 path_b64 status rc detail_b64 root file detail display_number
        for idx in "${selected_array[@]}"; do
            row="${rows[$idx]}"
            IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$row"
            file="$(b64_decode_text "$path_b64")"
            display_number=$((idx + 1))
            printf '  %3d) [%s, exit %s] %s\n' "$display_number" "$status" "$rc" "$file"
        done

        if (( selected_count == 1 )); then
            idx="${selected_array[0]}"
            row="${rows[$idx]}"
            IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$row"
            root="$(b64_decode_text "$root_b64")"
            file="$(b64_decode_text "$path_b64")"
            detail="$(b64_decode_text "$detail_b64")"

            printf '\n%sSelected ZIP error%s\n' "$C_CYAN" "$C_RESET"
            printf '  File:   %s\n' "$file"
            printf '  Status: %s\n' "$status"
            printf '  Exit:   %s\n' "$rc"
            if [[ -f "$detail" ]]; then
                printf '\n%sunzip output%s\n' "$C_CYAN" "$C_RESET"
                show_file_scrollable "$detail" "unzip error details"
            fi
        else
            printf '\nBulk selection count: %s\n' "$selected_count"
        fi

        while true; do
            if (( selected_count == 1 )); then
                cat <<'ACTIONS'

  1) Keep / mark this file resolved
  2) Move this file to quarantine
  3) Permanently delete this file
  4) Show unzip error details again
  0) Return to the error list
ACTIONS
            else
                cat <<'ACTIONS'

  1) Keep / mark selected files resolved
  2) Move selected files to quarantine
  3) Permanently delete selected files
  0) Return to the error list
ACTIONS
            fi
            local action=""
            if ! read -r -p "Choose an action: " action; then
                printf '\n'
                return 0
            fi

            local successful_indices="" successful_count=0 failed_count=0 quarantine_root typed=""
            case "$action" in
                1)
                    if (( selected_count > 1 )); then
                        confirm "Mark $selected_count selected ZIP entries as kept/resolved without moving files" no || break
                    fi
                    for idx in "${selected_array[@]}"; do
                        row="${rows[$idx]}"
                        IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$row"
                        root="$(b64_decode_text "$root_b64")"
                        file="$(b64_decode_text "$path_b64")"
                        if validate_zip_review_path "$root" "$file"; then
                            log_zip_error_action KEPT "$file"
                            successful_indices+=" $idx"
                            successful_count=$((successful_count + 1))
                        else
                            failed_count=$((failed_count + 1))
                        fi
                    done
                    success "Marked kept/resolved: $successful_count  Failed/skipped: $failed_count"
                    if [[ -n "$successful_indices" ]]; then
                        remove_review_rows_by_indices "$successful_indices"
                        review_zip_error_log "$index" "$exit_code_filter" "$folder_filter"
                        return $?
                    fi
                    break
                    ;;
                2)
                    if (( selected_count > 1 )); then
                        confirm "Move $selected_count selected ZIP files to quarantine" no || break
                    fi
                    quarantine_root="$ZIP_QUARANTINE_DIR/$(date +%Y%m%d-%H%M%S)-$$"
                    for idx in "${selected_array[@]}"; do
                        row="${rows[$idx]}"
                        IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$row"
                        root="$(b64_decode_text "$root_b64")"
                        file="$(b64_decode_text "$path_b64")"
                        if quarantine_zip_action_target "$root" "$file" "$quarantine_root"; then
                            successful_indices+=" $idx"
                            successful_count=$((successful_count + 1))
                        else
                            failed_count=$((failed_count + 1))
                        fi
                    done
                    success "Quarantine complete. Moved: $successful_count  Failed/skipped: $failed_count"
                    if [[ -n "$successful_indices" ]]; then
                        remove_review_rows_by_indices "$successful_indices"
                        review_zip_error_log "$index" "$exit_code_filter" "$folder_filter"
                        return $?
                    fi
                    break
                    ;;
                3)
                    printf 'Permanent deletion cannot be undone. Quarantine is safer when you are unsure.\n'
                    if (( selected_count == 1 )); then
                        if ! read -r -p "Type DELETE to remove this exact file: " typed; then
                            printf '\n'
                            warn "Deletion canceled."
                            continue
                        fi
                        [[ "$typed" == "DELETE" ]] || { warn "Deletion canceled."; continue; }
                    else
                        printf 'Selected file count: %s\n' "$selected_count"
                        printf 'To reduce accidental mass deletion, type exactly: DELETE %s FILES\n' "$selected_count"
                        if ! read -r -p "Confirmation: " typed; then
                            printf '\n'
                            warn "Deletion canceled."
                            continue
                        fi
                        [[ "$typed" == "DELETE $selected_count FILES" ]] || { warn "Deletion canceled."; continue; }
                    fi
                    for idx in "${selected_array[@]}"; do
                        row="${rows[$idx]}"
                        IFS=$'\t' read -r root_b64 path_b64 status rc detail_b64 <<< "$row"
                        root="$(b64_decode_text "$root_b64")"
                        file="$(b64_decode_text "$path_b64")"
                        if validate_zip_action_target "$root" "$file" && rm -- "$file"; then
                            log_zip_error_action DELETED "$file"
                            success "Deleted: $file"
                            successful_indices+=" $idx"
                            successful_count=$((successful_count + 1))
                        else
                            error "Unable to delete: $file"
                            failed_count=$((failed_count + 1))
                        fi
                    done
                    success "Deletion complete. Deleted: $successful_count  Failed/skipped: $failed_count"
                    if [[ -n "$successful_indices" ]]; then
                        remove_review_rows_by_indices "$successful_indices"
                        review_zip_error_log "$index" "$exit_code_filter" "$folder_filter"
                        return $?
                    fi
                    break
                    ;;
                4)
                    if (( selected_count == 1 )); then
                        [[ -f "$detail" ]] && show_file_scrollable "$detail" "unzip error details" || warn "Detail file is unavailable."
                    else
                        warn "Detail replay is available only for a single selected entry."
                    fi
                    ;;
                0) break ;;
                *) warn "Invalid selection." ;;
            esac
        done
    done
}

create_quarantine_restore_index() {
    local action_log="${1:-$ZIP_ACTION_LOG}"
    local output_file="${2:-}"
    local configured_media="$DEFAULT_MEDIA_DIR"
    [[ -n "$output_file" ]] || { error "Missing output file for quarantine restore index."; return 1; }

    if configuration_exists; then
        configured_media="$(canonical_path "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")")"
    fi

    mkdir -p "$REPORT_DIR"
    python3 - "$action_log" "$output_file" "$DEFAULT_MEDIA_DIR" "$configured_media" "$ZIP_QUARANTINE_DIR" <<'PYRESTORE'
import base64
import codecs
import os
import shlex
import sys

log_path, output_path, default_media, configured_media, quarantine_root = sys.argv[1:6]
default_media = os.path.realpath(default_media)
configured_media = os.path.realpath(configured_media)
quarantine_root = os.path.realpath(quarantine_root)
media_roots = []
for candidate in (default_media, configured_media):
    if candidate and candidate not in media_roots:
        media_roots.append(candidate)

def b64(value: str) -> str:
    return base64.b64encode(value.encode("utf-8", "surrogateescape")).decode("ascii")

def decode_bash_percent_q(value: str) -> str:
    value = value.strip()
    if value == "''":
        return ""
    if value.startswith("$'") and value.endswith("'"):
        body = value[2:-1]
        try:
            return codecs.decode(body, "unicode_escape")
        except Exception:
            return ""
    try:
        parsed = shlex.split(value, posix=True)
        return parsed[0] if parsed else ""
    except Exception:
        return ""

def is_within(child: str, parent: str) -> bool:
    child = os.path.realpath(child)
    parent = os.path.realpath(parent)
    return child == parent or child.startswith(parent + os.sep)

records = []
if os.path.exists(log_path):
    with open(log_path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            timestamp = parts[0]
            values = {}
            for part in parts[1:]:
                if "=" not in part:
                    continue
                key, val = part.split("=", 1)
                values[key] = val
            if values.get("action") != "QUARANTINED":
                continue
            original = decode_bash_percent_q(values.get("file", ""))
            destination = decode_bash_percent_q(values.get("destination", ""))
            if not original or not destination:
                continue
            destination_real = os.path.realpath(destination)

            safety = "OK"
            if not os.path.isabs(original) or not os.path.isabs(destination):
                safety = "UNSAFE_RELATIVE_PATH"
            elif not any(is_within(original, media_root) for media_root in media_roots):
                safety = "UNSAFE_ORIGINAL_OUTSIDE_MEDIA"
            elif not is_within(destination, quarantine_root):
                safety = "UNSAFE_QUARANTINE_OUTSIDE_ROOT"
            elif os.path.isdir(destination):
                safety = "UNSAFE_DESTINATION_IS_DIRECTORY"
            elif not original.lower().endswith(".zip") or not destination.lower().endswith(".zip"):
                safety = "UNSAFE_NOT_ZIP"

            if safety != "OK":
                state = safety
            elif not os.path.exists(destination):
                state = "MISSING_QUARANTINE_FILE"
            elif os.path.exists(original):
                state = "CONFLICT_ORIGINAL_EXISTS"
            else:
                state = "AVAILABLE"

            rel_batch = ""
            if is_within(destination, quarantine_root):
                rel = os.path.relpath(destination_real, quarantine_root)
                rel_batch = rel.split(os.sep, 1)[0] if rel and rel != "." else ""
            records.append((timestamp, original, destination, rel_batch, state))

with open(output_path, "w", encoding="utf-8", errors="surrogateescape") as out:
    out.write("#KARAOKE_ETERNAL_QUARANTINE_RESTORE_V1\n")
    out.write("#timestamp_b64\toriginal_b64\tquarantine_b64\tbatch_b64\tstate\n")
    for rec in records:
        out.write("\t".join([b64(rec[0]), b64(rec[1]), b64(rec[2]), b64(rec[3]), rec[4]]) + "\n")
PYRESTORE
}

quarantine_restore_index_latest() {
    local tmp
    tmp="$(mktemp)" || return 1
    create_quarantine_restore_index "$ZIP_ACTION_LOG" "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$tmp"
}

render_quarantine_restore_list() {
    local index="${1:-}"
    local output_file="${2:-}"
    local state_filter="${3:-}"
    local folder_filter="${4:-}"
    local batch_filter="${5:-}"

    [[ -n "$index" && -f "$index" && -n "$output_file" ]] || return 1

    if [[ -n "$folder_filter" ]]; then
        validate_absolute_path "$folder_filter" || { error "Folder filter must be a safe absolute path."; return 1; }
        folder_filter="$(canonical_path "$folder_filter")"
    fi

    {
        printf 'Quarantined ZIP media files\n'
        printf 'Action log: %s\n' "$ZIP_ACTION_LOG"
        [[ -n "$state_filter" ]] && printf 'State filter: %s\n' "$state_filter"
        [[ -n "$folder_filter" ]] && printf 'Original-folder filter: %s\n' "$folder_filter"
        [[ -n "$batch_filter" ]] && printf 'Quarantine-batch filter: %s\n' "$batch_filter"
        printf '\n'
        printf 'State meanings:\n'
        printf '  AVAILABLE                 Can be restored now.\n'
        printf '  CONFLICT_ORIGINAL_EXISTS  Original path already has a file; no overwrite is allowed.\n'
        printf '  MISSING_QUARANTINE_FILE   File is no longer in quarantine, possibly already restored/moved.\n'
        printf '  UNSAFE_*                  Record failed path-safety checks and will not be restored.\n'
        printf '\n'
        printf 'Entries:\n'

        local line timestamp_b64 original_b64 quarantine_b64 batch_b64 state original quarantine batch i=0 shown=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            IFS=$'\t' read -r timestamp_b64 original_b64 quarantine_b64 batch_b64 state <<< "$line"
            original="$(b64_decode_text "$original_b64" 2>/dev/null || true)"
            quarantine="$(b64_decode_text "$quarantine_b64" 2>/dev/null || true)"
            batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
            [[ -n "$original" && -n "$quarantine" ]] || continue
            if [[ -n "$state_filter" && "$state" != "$state_filter" ]]; then
                continue
            fi
            if [[ -n "$folder_filter" ]] && ! path_is_within "$original" "$folder_filter"; then
                continue
            fi
            if [[ -n "$batch_filter" && "$batch" != "$batch_filter" ]]; then
                continue
            fi
            i=$((i + 1))
            shown=$((shown + 1))
            printf ' %3d) [%s] batch=%s\n' "$i" "$state" "${batch:-unknown}"
            printf '      Original:   %s\n' "$original"
            printf '      Quarantine: %s\n' "$quarantine"
        done < "$index"
        if (( shown == 0 )); then
            printf '  No matching quarantine entries found.\n'
        fi
    } > "$output_file"
}

select_quarantine_restore_record() {
    local index="${1:-}"
    local state_filter="${2:-AVAILABLE}"
    local folder_filter="${3:-}"
    local batch_filter="${4:-}"
    local __orig_var="${5:-}"
    local __dest_var="${6:-}"
    local __batch_var="${7:-}"

    [[ -n "$index" && -f "$index" ]] || return 1

    if [[ -n "$folder_filter" ]]; then
        validate_absolute_path "$folder_filter" || { error "Folder filter must be a safe absolute path."; return 1; }
        folder_filter="$(canonical_path "$folder_filter")"
    fi

    local -a rows=()
    local line timestamp_b64 original_b64 quarantine_b64 batch_b64 state rec_original rec_batch
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r timestamp_b64 original_b64 quarantine_b64 batch_b64 state <<< "$line"
        rec_original="$(b64_decode_text "$original_b64" 2>/dev/null || true)"
        rec_batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
        [[ -n "$rec_original" ]] || continue
        if [[ -n "$state_filter" && "$state" != "$state_filter" ]]; then
            continue
        fi
        if [[ -n "$folder_filter" ]] && ! path_is_within "$rec_original" "$folder_filter"; then
            continue
        fi
        if [[ -n "$batch_filter" && "$rec_batch" != "$batch_filter" ]]; then
            continue
        fi
        rows+=("$line")
    done < "$index"

    if (( ${#rows[@]} == 0 )); then
        warn "No available quarantined files match the selected filter."
        return 1
    fi

    while true; do
        local list_file
        list_file="$(mktemp)" || return 1
        render_quarantine_restore_list "$index" "$list_file" "$state_filter" "$folder_filter" "$batch_filter"
        show_file_scrollable "$list_file" "quarantine restore list"
        rm -f "$list_file"
        printf '\n'
        local selection=""
        if ! read -r -p "Select a quarantined file to restore, v to view list again, or 0 to return: " selection; then
            printf '\n'
            return 1
        fi
        [[ "$selection" == "0" ]] && return 1
        [[ "$selection" =~ ^[Vv]$ ]] && continue
        [[ "$selection" =~ ^[0-9]+$ ]] || { warn "Enter a valid number."; continue; }
        (( 10#$selection >= 1 && 10#$selection <= ${#rows[@]} )) || { warn "Selection is out of range."; continue; }

        line="${rows[$((10#$selection - 1))]}"
        IFS=$'\t' read -r timestamp_b64 original_b64 quarantine_b64 batch_b64 state <<< "$line"
        local chosen_original chosen_quarantine chosen_batch
        chosen_original="$(b64_decode_text "$original_b64")"
        chosen_quarantine="$(b64_decode_text "$quarantine_b64")"
        chosen_batch="$(b64_decode_text "$batch_b64")"
        printf -v "$__orig_var" '%s' "$chosen_original"
        printf -v "$__dest_var" '%s' "$chosen_quarantine"
        printf -v "$__batch_var" '%s' "$chosen_batch"
        return 0
    done
}

validate_quarantine_restore_target() {
    local original="${1:-}"
    local quarantine="${2:-}"
    local default_media configured_media
    default_media="$(canonical_path "$DEFAULT_MEDIA_DIR")"
    configured_media="$(canonical_path "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")")"

    [[ -n "$original" && -n "$quarantine" ]] || { error "Missing restore paths."; return 1; }
    validate_absolute_path "$original" || { error "Original restore path is not a safe absolute path: $original"; return 1; }
    validate_absolute_path "$quarantine" || { error "Quarantine path is not a safe absolute path: $quarantine"; return 1; }
    original="$(canonical_path "$original")"
    quarantine="$(canonical_path "$quarantine")"

    if ! path_is_within "$original" "$default_media" && ! path_is_within "$original" "$configured_media"; then
        error "Refusing to restore outside the known media folders."
        printf '  Original:         %s\n' "$original"
        printf '  Default media:    %s\n' "$default_media"
        printf '  Configured media: %s\n' "$configured_media"
        return 1
    fi
    if ! path_is_within "$quarantine" "$ZIP_QUARANTINE_DIR"; then
        error "Refusing to restore from outside the quarantine root: $ZIP_QUARANTINE_DIR"
        return 1
    fi
    if [[ -d "$quarantine" ]]; then
        error "Refusing to restore a directory: $quarantine"
        return 1
    fi
    if [[ ! -f "$quarantine" ]]; then
        error "Quarantined file is missing: $quarantine"
        return 1
    fi
    if [[ -e "$original" || -L "$original" ]]; then
        error "Original path already exists; refusing to overwrite: $original"
        return 1
    fi
    case "${original,,}:${quarantine,,}" in
        *.zip:*.zip) ;;
        *) error "Restore routine only restores .zip media files."; return 1 ;;
    esac
}

restore_one_quarantined_zip() {
    local original="${1:-}"
    local quarantine="${2:-}"
    local batch="${3:-}"

    validate_quarantine_restore_target "$original" "$quarantine" || return 1

    printf '\n%sRestore quarantined ZIP%s\n' "$C_CYAN" "$C_RESET"
    printf '  From quarantine: %s\n' "$quarantine"
    printf '  Restore to:      %s\n' "$original"
    [[ -n "$batch" ]] && printf '  Batch:           %s\n' "$batch"
    confirm "Restore this ZIP back to the media folder?" yes || return 0

    mkdir -p "$(dirname "$original")"
    if mv -- "$quarantine" "$original"; then
        log_zip_error_action RESTORED "$original" "$quarantine"
        mkdir -p "$REPORT_DIR"
        printf '%s\tRESTORED\toriginal=%q\tquarantine=%q\n' \
            "$(date --iso-8601=seconds)" "$original" "$quarantine" >> "$ZIP_RESTORE_LOG"
        success "Restored: $original"
        return 0
    fi

    error "Restore failed. The quarantined file was not moved."
    return 1
}

list_quarantined_zip_files() {
    local index list_file
    index="$(quarantine_restore_index_latest)" || return 1
    list_file="$(mktemp)" || { rm -f "$index"; return 1; }
    render_quarantine_restore_list "$index" "$list_file"
    show_file_scrollable "$list_file" "quarantine restore list"
    rm -f "$list_file" "$index"
}

restore_single_quarantined_zip_interactive() {
    local index original quarantine batch
    index="$(quarantine_restore_index_latest)" || return 1
    select_quarantine_restore_record "$index" "AVAILABLE" "" "" original quarantine batch || { rm -f "$index"; return 1; }
    restore_one_quarantined_zip "$original" "$quarantine" "$batch"
    local rc=$?
    rm -f "$index"
    return "$rc"
}

restore_quarantined_zips_by_batch() {
    local index batch
    index="$(quarantine_restore_index_latest)" || return 1

    local -a batches=()
    local line timestamp_b64 original_b64 quarantine_b64 batch_b64 state decoded_batch
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r timestamp_b64 original_b64 quarantine_b64 batch_b64 state <<< "$line"
        [[ "$state" == "AVAILABLE" ]] || continue
        decoded_batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
        [[ -n "$decoded_batch" ]] || continue
        case " ${batches[*]:-} " in
            *" $decoded_batch "*) ;;
            *) batches+=("$decoded_batch") ;;
        esac
    done < "$index"

    if (( ${#batches[@]} == 0 )); then
        warn "No available quarantine batches were found."
        rm -f "$index"
        return 1
    fi

    printf '\n%sAvailable quarantine batches%s\n' "$C_CYAN" "$C_RESET"
    local i
    for i in "${!batches[@]}"; do
        printf ' %3d) %s\n' "$((i + 1))" "${batches[$i]}"
    done
    printf '   0) Return\n\n'
    local choice=""
    if ! read -r -p "Choose a quarantine batch to restore: " choice; then
        printf '\n'
        rm -f "$index"
        return 1
    fi
    [[ "$choice" == "0" ]] && { rm -f "$index"; return 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid selection."; rm -f "$index"; return 1; }
    (( 10#$choice >= 1 && 10#$choice <= ${#batches[@]} )) || { warn "Selection out of range."; rm -f "$index"; return 1; }
    batch="${batches[$((10#$choice - 1))]}"

    local list_file
    list_file="$(mktemp)" || { rm -f "$index"; return 1; }
    render_quarantine_restore_list "$index" "$list_file" "AVAILABLE" "" "$batch"
    show_file_scrollable "$list_file" "quarantine batch restore list"
    rm -f "$list_file"
    confirm "Restore all AVAILABLE files from batch $batch without overwriting existing files?" no || { rm -f "$index"; return 0; }

    local restored=0 skipped=0 original quarantine
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r timestamp_b64 original_b64 quarantine_b64 batch_b64 state <<< "$line"
        [[ "$state" == "AVAILABLE" ]] || continue
        decoded_batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
        [[ "$decoded_batch" == "$batch" ]] || continue
        original="$(b64_decode_text "$original_b64")"
        quarantine="$(b64_decode_text "$quarantine_b64")"
        if validate_quarantine_restore_target "$original" "$quarantine"; then
            mkdir -p "$(dirname "$original")"
            if mv -- "$quarantine" "$original"; then
                log_zip_error_action RESTORED "$original" "$quarantine"
                printf '%s\tRESTORED\toriginal=%q\tquarantine=%q\n' \
                    "$(date --iso-8601=seconds)" "$original" "$quarantine" >> "$ZIP_RESTORE_LOG"
                restored=$((restored + 1))
            else
                skipped=$((skipped + 1))
            fi
        else
            skipped=$((skipped + 1))
        fi
    done < "$index"
    rm -f "$index"
    success "Batch restore complete. Restored: $restored  Skipped: $skipped"
}

restore_quarantined_zips_by_original_folder() {
    local folder="${1:-}"
    if [[ -z "$folder" ]]; then
        select_zip_media_subfolder "$DEFAULT_MEDIA_DIR" folder || return 1
    else
        validate_absolute_path "$folder" || { error "Folder must be a safe absolute path."; return 1; }
        folder="$(canonical_path "$folder")"
        [[ -d "$folder" ]] || { error "Folder does not exist: $folder"; return 1; }
    fi

    local index list_file
    index="$(quarantine_restore_index_latest)" || return 1
    list_file="$(mktemp)" || { rm -f "$index"; return 1; }
    render_quarantine_restore_list "$index" "$list_file" "AVAILABLE" "$folder"
    show_file_scrollable "$list_file" "quarantine folder restore list"
    rm -f "$list_file"

    local original quarantine batch
    select_quarantine_restore_record "$index" "AVAILABLE" "$folder" "" original quarantine batch || { rm -f "$index"; return 1; }
    restore_one_quarantined_zip "$original" "$quarantine" "$batch"
    local rc=$?
    rm -f "$index"
    return "$rc"
}

show_quarantine_restore_history() {
    if [[ -f "$ZIP_RESTORE_LOG" ]]; then
        show_file_scrollable "$ZIP_RESTORE_LOG" "quarantine restore history"
    else
        info "No quarantine restore actions have been recorded yet."
    fi
    if [[ -f "$ZIP_ACTION_LOG" ]]; then
        printf '\n%sCombined ZIP action history%s\n' "$C_CYAN" "$C_RESET"
        show_file_scrollable "$ZIP_ACTION_LOG" "ZIP action history"
    fi
}


create_orphan_quarantine_index() {
    local output_file="${1:-}"
    [[ -n "$output_file" ]] || { error "Missing output file for orphan quarantine index."; return 1; }

    mkdir -p "$REPORT_DIR"
    python3 - "$ZIP_ACTION_LOG" "$output_file" "$ZIP_QUARANTINE_DIR" "$RESTORED_MEDIA_DIR" <<'PYORPHAN'
import base64
import codecs
import os
import shlex
import sys

action_log, output_path, quarantine_root, restored_media_root = sys.argv[1:5]
quarantine_root = os.path.realpath(quarantine_root)
restored_media_root = os.path.realpath(restored_media_root)

def b64(value: str) -> str:
    return base64.b64encode(value.encode("utf-8", "surrogateescape")).decode("ascii")

def decode_bash_percent_q(value: str) -> str:
    value = value.strip()
    if value == "''":
        return ""
    if value.startswith("$'") and value.endswith("'"):
        body = value[2:-1]
        try:
            return codecs.decode(body, "unicode_escape")
        except Exception:
            return ""
    try:
        parsed = shlex.split(value, posix=True)
        return parsed[0] if parsed else ""
    except Exception:
        return ""

def is_within(child: str, parent: str) -> bool:
    child = os.path.realpath(child)
    parent = os.path.realpath(parent)
    return child == parent or child.startswith(parent + os.sep)

known_quarantine_paths = set()
if os.path.exists(action_log):
    with open(action_log, "r", encoding="utf-8", errors="surrogateescape") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            values = {}
            for part in parts[1:]:
                if "=" not in part:
                    continue
                key, val = part.split("=", 1)
                values[key] = val
            action = values.get("action", "")
            destination = decode_bash_percent_q(values.get("destination", ""))
            if action in {"QUARANTINED", "RESTORED", "ORPHAN_RECOVERED"} and destination:
                known_quarantine_paths.add(os.path.realpath(destination))

records = []
if os.path.isdir(quarantine_root):
    for root, dirs, files in os.walk(quarantine_root):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        for name in files:
            if not name.lower().endswith(".zip"):
                continue
            source = os.path.realpath(os.path.join(root, name))
            if source in known_quarantine_paths:
                continue
            if not is_within(source, quarantine_root):
                state = "UNSAFE_SOURCE_OUTSIDE_QUARANTINE"
            elif not os.path.isfile(source):
                state = "MISSING_OR_NOT_FILE"
            else:
                state = "AVAILABLE"
            rel = os.path.relpath(source, quarantine_root)
            if rel == "." or rel.startswith(".." + os.sep) or os.path.isabs(rel):
                state = "UNSAFE_RELATIVE_PATH"
                rel = os.path.basename(source)
            target = os.path.realpath(os.path.join(restored_media_root, rel))
            if not is_within(target, restored_media_root):
                state = "UNSAFE_RESTORED_TARGET"
            elif os.path.exists(target):
                state = "CONFLICT_RESTORED_TARGET_EXISTS"
            batch = rel.split(os.sep, 1)[0] if rel and rel != "." else "loose-files"
            records.append((source, rel, batch, target, state))

with open(output_path, "w", encoding="utf-8", errors="surrogateescape") as out:
    out.write("#KARAOKE_ETERNAL_ORPHAN_QUARANTINE_V1\n")
    out.write("#source_b64\trelative_b64\tbatch_b64\trestored_target_b64\tstate\n")
    for rec in records:
        out.write("\t".join([b64(rec[0]), b64(rec[1]), b64(rec[2]), b64(rec[3]), rec[4]]) + "\n")
PYORPHAN
}

orphan_quarantine_index_latest() {
    local tmp
    tmp="$(mktemp)" || return 1
    create_orphan_quarantine_index "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$tmp"
}

render_orphan_quarantine_list() {
    local index="${1:-}"
    local output_file="${2:-}"
    local state_filter="${3:-}"
    local batch_filter="${4:-}"

    [[ -n "$index" && -f "$index" && -n "$output_file" ]] || return 1

    {
        printf 'Orphaned quarantined ZIP media files\n'
        printf 'Quarantine root:       %s\n' "$ZIP_QUARANTINE_DIR"
        printf 'Restored media folder: %s\n' "$RESTORED_MEDIA_DIR"
        [[ -n "$state_filter" ]] && printf 'State filter:          %s\n' "$state_filter"
        [[ -n "$batch_filter" ]] && printf 'Quarantine-batch filter: %s\n' "$batch_filter"
        printf '\n'
        printf 'This list is for ZIPs physically found under the quarantine folder that are not usable through the normal action-log restore index.\n'
        printf 'Recovering them moves them into the restored media folder, not directly into the live Karaoke Eternal media tree.\n'
        printf '\n'
        printf 'State meanings:\n'
        printf '  AVAILABLE                       Can be moved into the restored media folder now.\n'
        printf '  CONFLICT_RESTORED_TARGET_EXISTS A file already exists at the restored-media destination; no overwrite is allowed.\n'
        printf '  UNSAFE_*                        Path failed safety checks and will not be recovered.\n'
        printf '\n'
        printf 'Entries:\n'

        local line source_b64 rel_b64 batch_b64 target_b64 state source rel batch target i=0 shown=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            IFS=$'\t' read -r source_b64 rel_b64 batch_b64 target_b64 state <<< "$line"
            source="$(b64_decode_text "$source_b64" 2>/dev/null || true)"
            rel="$(b64_decode_text "$rel_b64" 2>/dev/null || true)"
            batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
            target="$(b64_decode_text "$target_b64" 2>/dev/null || true)"
            [[ -n "$source" && -n "$target" ]] || continue
            if [[ -n "$state_filter" && "$state" != "$state_filter" ]]; then
                continue
            fi
            if [[ -n "$batch_filter" && "$batch" != "$batch_filter" ]]; then
                continue
            fi
            i=$((i + 1))
            shown=$((shown + 1))
            printf '\n[%d] %s\n' "$i" "$state"
            printf '  Quarantine file: %s\n' "$source"
            printf '  Relative path:   %s\n' "$rel"
            printf '  Batch/folder:    %s\n' "${batch:-unknown}"
            printf '  Recover to:      %s\n' "$target"
        done < "$index"
        (( shown > 0 )) || printf '  No matching orphaned quarantine ZIPs found.\n'
    } > "$output_file"
}

list_orphan_quarantined_zip_files() {
    local index list_file
    index="$(orphan_quarantine_index_latest)" || return 1
    list_file="$(mktemp)" || { rm -f "$index"; return 1; }
    render_orphan_quarantine_list "$index" "$list_file"
    show_file_scrollable "$list_file" "orphaned quarantine list"
    rm -f "$list_file" "$index"
}

validate_orphan_recovery_target() {
    local source="${1:-}"
    local target="${2:-}"
    [[ -n "$source" && -n "$target" ]] || { error "Missing orphan recovery paths."; return 1; }
    validate_absolute_path "$source" || { error "Orphan source path is not a safe absolute path: $source"; return 1; }
    validate_absolute_path "$target" || { error "Restored-media target is not a safe absolute path: $target"; return 1; }
    source="$(canonical_path "$source")"
    target="$(canonical_path "$target")"
    if ! path_is_within "$source" "$ZIP_QUARANTINE_DIR"; then
        error "Refusing to recover from outside the quarantine root: $ZIP_QUARANTINE_DIR"
        return 1
    fi
    if ! path_is_within "$target" "$RESTORED_MEDIA_DIR"; then
        error "Refusing to recover outside the restored media folder: $RESTORED_MEDIA_DIR"
        return 1
    fi
    [[ -f "$source" ]] || { error "Orphaned quarantined file is missing: $source"; return 1; }
    [[ ! -d "$source" ]] || { error "Refusing to recover a directory: $source"; return 1; }
    [[ ! -e "$target" && ! -L "$target" ]] || { error "Restored-media target already exists; refusing to overwrite: $target"; return 1; }
    case "${source,,}:${target,,}" in
        *.zip:*.zip) ;;
        *) error "Orphan recovery only moves .zip media files."; return 1 ;;
    esac
}

recover_orphan_quarantined_zips_to_restored_media() {
    local batch_filter="${1:-}"
    local index list_file
    index="$(orphan_quarantine_index_latest)" || return 1
    list_file="$(mktemp)" || { rm -f "$index"; return 1; }
    render_orphan_quarantine_list "$index" "$list_file" "AVAILABLE" "$batch_filter"
    show_file_scrollable "$list_file" "orphaned quarantine recovery list"
    rm -f "$list_file"

    local line source_b64 rel_b64 batch_b64 target_b64 state source target batch count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r source_b64 rel_b64 batch_b64 target_b64 state <<< "$line"
        [[ "$state" == "AVAILABLE" ]] || continue
        batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
        [[ -z "$batch_filter" || "$batch" == "$batch_filter" ]] || continue
        count=$((count + 1))
    done < "$index"

    if (( count == 0 )); then
        warn "No AVAILABLE orphaned quarantined ZIPs were found."
        rm -f "$index"
        return 1
    fi

    printf '\nRecovery target folder:\n  %s\n' "$RESTORED_MEDIA_DIR"
    printf 'Files to recover: %s\n' "$count"
    warn "Recovered files are moved outside the live media tree for inspection; Karaoke Eternal will not scan them unless you later move or configure them."

    local typed=""
    if (( count == 1 )); then
        confirm "Move this orphaned ZIP into the restored media folder?" no || { rm -f "$index"; return 0; }
    else
        printf 'To reduce accidental bulk moves, type exactly: RECOVER %s FILES\n' "$count"
        if ! read -r -p "Confirmation: " typed; then
            printf '\n'
            warn "Recovery canceled."
            rm -f "$index"
            return 1
        fi
        [[ "$typed" == "RECOVER $count FILES" ]] || { warn "Recovery canceled."; rm -f "$index"; return 1; }
    fi

    local recovered=0 skipped=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r source_b64 rel_b64 batch_b64 target_b64 state <<< "$line"
        [[ "$state" == "AVAILABLE" ]] || continue
        batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
        [[ -z "$batch_filter" || "$batch" == "$batch_filter" ]] || continue
        source="$(b64_decode_text "$source_b64")"
        target="$(b64_decode_text "$target_b64")"
        if validate_orphan_recovery_target "$source" "$target"; then
            mkdir -p "$(dirname "$target")"
            if mv -- "$source" "$target"; then
                log_zip_error_action ORPHAN_RECOVERED "$target" "$source"
                mkdir -p "$REPORT_DIR"
                printf '%s\tORPHAN_RECOVERED\trestored_media=%q\tquarantine=%q\n' \
                    "$(date --iso-8601=seconds)" "$target" "$source" >> "$ZIP_RESTORE_LOG"
                success "Recovered to restored media: $target"
                recovered=$((recovered + 1))
            else
                error "Unable to recover: $source"
                skipped=$((skipped + 1))
            fi
        else
            skipped=$((skipped + 1))
        fi
    done < "$index"
    rm -f "$index"
    success "Orphan recovery complete. Recovered: $recovered  Skipped: $skipped"
}

recover_orphan_quarantined_zips_by_batch() {
    local index
    index="$(orphan_quarantine_index_latest)" || return 1

    local -a batches=()
    local line source_b64 rel_b64 batch_b64 target_b64 state decoded_batch
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=$'\t' read -r source_b64 rel_b64 batch_b64 target_b64 state <<< "$line"
        [[ "$state" == "AVAILABLE" ]] || continue
        decoded_batch="$(b64_decode_text "$batch_b64" 2>/dev/null || true)"
        [[ -n "$decoded_batch" ]] || decoded_batch="loose-files"
        case " ${batches[*]:-} " in
            *" $decoded_batch "*) ;;
            *) batches+=("$decoded_batch") ;;
        esac
    done < "$index"
    rm -f "$index"

    if (( ${#batches[@]} == 0 )); then
        warn "No available orphaned quarantine batches were found."
        return 1
    fi

    printf '\n%sAvailable orphaned quarantine batches%s\n' "$C_CYAN" "$C_RESET"
    local i
    for i in "${!batches[@]}"; do
        printf ' %3d) %s\n' "$((i + 1))" "${batches[$i]}"
    done
    printf '   0) Return\n\n'
    local choice=""
    if ! read -r -p "Choose an orphaned quarantine batch to recover: " choice; then
        printf '\n'
        return 1
    fi
    [[ "$choice" == "0" ]] && return 0
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid selection."; return 1; }
    (( 10#$choice >= 1 && 10#$choice <= ${#batches[@]} )) || { warn "Selection out of range."; return 1; }
    recover_orphan_quarantined_zips_to_restored_media "${batches[$((10#$choice - 1))]}"
}

zip_quarantine_restore_menu() {
    while true; do
        printf '\n%sRestore quarantined ZIP media files%s\n' "$C_CYAN" "$C_RESET"
        cat <<'MENU'
  1) List quarantined ZIP files recorded in the action log
  2) Restore one available logged quarantined ZIP
  3) Restore all available logged ZIPs from one quarantine batch
  4) Restore one available logged ZIP by original media folder
  5) List orphaned ZIPs physically found in the quarantine folder
  6) Recover all orphaned ZIPs into the restored media folder
  7) Recover orphaned ZIPs from one quarantine batch/folder into the restored media folder
  8) Show restore/action history
  0) Return
MENU
        printf '\n'
        local choice=""
        if ! read -r -p "Choose an option: " choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1) list_quarantined_zip_files; pause_screen ;;
            2) restore_single_quarantined_zip_interactive; pause_screen ;;
            3) restore_quarantined_zips_by_batch; pause_screen ;;
            4) restore_quarantined_zips_by_original_folder; pause_screen ;;
            5) list_orphan_quarantined_zip_files; pause_screen ;;
            6) recover_orphan_quarantined_zips_to_restored_media; pause_screen ;;
            7) recover_orphan_quarantined_zips_by_batch; pause_screen ;;
            8) show_quarantine_restore_history; pause_screen ;;
            0) return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

zip_error_review_menu() {
    while true; do
        printf '\n%sZIP integrity error log%s\n' "$C_CYAN" "$C_RESET"
        cat <<'MENU'
  1) Show the latest ZIP test report
  2) Show error counts grouped by exit code
  3) Review all files recorded with errors
  4) Filter by one exit code, then keep/quarantine/delete
  5) Filter by media folder and exit code, then keep/quarantine/delete
  6) Run a new recursive ZIP integrity test
  7) Restore quarantined media files
  8) Show keep/quarantine/delete/restore action history
  0) Return
MENU
        printf '\n'
        local choice=""
        if ! read -r -p "Choose an option: " choice; then
            printf '
'
            return 0
        fi
        case "$choice" in
            1) show_latest_zip_error_log; pause_screen ;;
            2) zip_exit_code_summary; pause_screen ;;
            3) review_zip_error_log; pause_screen ;;
            4) review_zip_errors_by_exit_code; pause_screen ;;
            5) review_zip_errors_by_folder_and_exit_code; pause_screen ;;
            6) zip_integrity_scan_menu; pause_screen ;;
            7) zip_quarantine_restore_menu ;;
            8)
                if [[ -f "$ZIP_ACTION_LOG" ]]; then
                    show_file_scrollable "$ZIP_ACTION_LOG" "ZIP action history"
                else
                    info "No ZIP-file actions have been recorded."
                fi
                if [[ -f "$ZIP_RESTORE_LOG" ]]; then
                    printf '
%sRestore history%s
' "$C_CYAN" "$C_RESET"
                    show_file_scrollable "$ZIP_RESTORE_LOG" "quarantine restore history"
                fi
                pause_screen
                ;;
            0) return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

archive_is_safe() {
    local archive="$1"
    python3 - "$archive" <<'PY'
import os
import posixpath
import sys
import tarfile

archive = sys.argv[1]
allowed_roots = {"config", "compose.yaml", ".env"}
required = {"compose.yaml", ".env"}
seen = set()

try:
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        if not members:
            raise ValueError("archive is empty")
        for member in members:
            name = member.name.replace("\\", "/")
            normalized = posixpath.normpath(name)
            if name.startswith("/") or normalized == ".." or normalized.startswith("../"):
                raise ValueError(f"unsafe path: {name}")
            root = normalized.split("/", 1)[0]
            if root not in allowed_roots:
                raise ValueError(f"unexpected top-level entry: {root}")
            if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                raise ValueError(f"unsupported archive member type: {name}")
            seen.add(normalized)
        missing = required - seen
        if missing:
            raise ValueError(f"missing required files: {', '.join(sorted(missing))}")
        if not any(name == "config" or name.startswith("config/") for name in seen):
            raise ValueError("missing config directory")
except Exception as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)
PY
}

safe_extract_archive() {
    local archive="$1"
    local destination="$2"
    python3 - "$archive" "$destination" <<'PY'
import os
import posixpath
import shutil
import sys
import tarfile

archive, destination = sys.argv[1:]
os.makedirs(destination, exist_ok=True)
base = os.path.realpath(destination)
with tarfile.open(archive, "r:gz") as tf:
    for member in tf.getmembers():
        name = member.name.replace("\\", "/")
        normalized = posixpath.normpath(name)
        target = os.path.realpath(os.path.join(base, normalized))
        if not (target == base or target.startswith(base + os.sep)):
            raise SystemExit(f"unsafe extraction target: {name}")
        if member.isdir():
            os.makedirs(target, exist_ok=True)
            continue
        if not member.isfile():
            raise SystemExit(f"unsupported member: {name}")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        source = tf.extractfile(member)
        if source is None:
            raise SystemExit(f"unable to read member: {name}")
        with source, open(target, "wb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(target, member.mode & 0o777)
PY
}

prune_backups() {
    local backup_path retention
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    retention="$(env_get KES_BACKUP_RETENTION "$DEFAULT_BACKUP_RETENTION")"

    mapfile -t old_backups < <(
        find "$backup_path" -maxdepth 1 -type f -name 'karaoke-eternal_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | awk -v keep="$retention" 'NR > keep {$1=""; sub(/^ /, ""); print}'
    )

    local file
    for file in "${old_backups[@]:-}"; do
        [[ -n "$file" ]] || continue
        rm -f -- "$file" && info "Pruned old backup: $(basename "$file")"
    done
}

create_backup() {
    require_configuration || return 1
    ensure_docker || return 1
    initialize_identity
    check_backup_path || return 1

    local backup_path
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"

    local config_bytes required_bytes
    config_bytes="$(du -sb "$CONFIG_DIR" "$COMPOSE_FILE" "$ENV_FILE" 2>/dev/null | awk '{sum += $1} END {print sum+0}')"
    required_bytes=$((config_bytes * 2 + 100 * 1024 * 1024))
    ensure_free_space "$backup_path" "$required_bytes" "Backup filesystem" || return 1
    check_inodes "$backup_path" || true

    local was_running=0
    if container_is_running; then
        was_running=1
        info "Briefly stopping the container for a consistent database backup..."
        compose stop || return 1
    fi

    local timestamp backup_file temp_file backup_ok=0
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
    backup_file="$backup_path/karaoke-eternal_$timestamp.tar.gz"
    temp_file="$backup_file.partial"

    if tar -czf "$temp_file" -C "$APP_DIR" config compose.yaml .env \
        && archive_is_safe "$temp_file"; then
        mv "$temp_file" "$backup_file"
        chown "$SERVICE_UID:$SERVICE_GID" "$backup_file" 2>/dev/null || true
        chmod 0640 "$backup_file" 2>/dev/null || true
        backup_ok=1
    else
        error "Backup creation or verification failed."
        rm -f "$temp_file"
    fi

    if (( was_running == 1 )); then
        compose start || warn "Backup finished, but the container could not be restarted automatically."
    fi

    if (( backup_ok == 1 )); then
        success "Verified backup created: $backup_file"
        info "Song/media files are not included."
        prune_backups
    else
        return 1
    fi
}

list_backups() {
    local backup_path
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    find "$backup_path" -maxdepth 1 -type f -name 'karaoke-eternal_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | cut -d' ' -f2-
}

restore_backup() {
    require_configuration || return 1
    ensure_docker || return 1
    initialize_identity
    check_backup_path || return 1

    mapfile -t backups < <(list_backups)
    if (( ${#backups[@]} == 0 )); then
        warn "No backups were found in $(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")."
        return 0
    fi

    local list_file
    list_file="$(mktemp)" || return 1
    {
        printf 'Available verified-backup candidates\n\n'
        local i
        for i in "${!backups[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "$(basename "${backups[$i]}")"
        done
        printf '  0) Cancel\n'
    } > "$list_file"
    printf '\n%sAvailable verified-backup candidates%s\n' "$C_CYAN" "$C_RESET"
    show_file_scrollable "$list_file" "backup list"
    rm -f "$list_file"
    printf '\n'

    local selection=""
    read -r -p "Select a backup: " selection
    if [[ "$selection" == "0" || -z "$selection" ]]; then
        return 0
    fi
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#backups[@]} )); then
        error "Invalid backup selection."
        return 1
    fi

    local selected_backup="${backups[$((selection - 1))]}"
    if ! archive_is_safe "$selected_backup"; then
        error "The selected archive failed security and structure validation."
        return 1
    fi

    if ! confirm "Restore $(basename "$selected_backup") and replace the current database/settings?" no; then
        return 0
    fi

    local backup_path temp_dir safety_backup was_running=0
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    temp_dir="$(mktemp -d "$APP_DIR/.restore-stage.XXXXXX")" || return 1
    safety_backup="$backup_path/pre-restore_$(date +'%Y-%m-%d_%H-%M-%S').tar.gz"

    if ! safe_extract_archive "$selected_backup" "$temp_dir"; then
        error "Safe extraction of the selected backup failed."
        rm -rf "$temp_dir"
        return 1
    fi

    if ! docker compose --project-directory "$temp_dir" --env-file "$temp_dir/.env" -f "$temp_dir/compose.yaml" config --quiet; then
        error "The staged backup contains an invalid Compose configuration."
        rm -rf "$temp_dir"
        return 1
    fi

    if container_is_running; then
        was_running=1
        compose stop || {
            rm -rf "$temp_dir"
            return 1
        }
    fi

    if ! tar -czf "$safety_backup" -C "$APP_DIR" config compose.yaml .env; then
        warn "Could not create a pre-restore safety backup. Restore cancelled."
        (( was_running == 1 )) && compose start || true
        rm -rf "$temp_dir"
        return 1
    fi

    local old_config="$APP_DIR/.config-before-restore"
    local old_compose="$APP_DIR/.compose-before-restore.yaml"
    local old_env="$APP_DIR/.env-before-restore"
    rm -rf "$old_config"
    rm -f "$old_compose" "$old_env"
    cp -a "$COMPOSE_FILE" "$old_compose" || {
        (( was_running == 1 )) && compose start || true
        rm -rf "$temp_dir"
        return 1
    }
    cp -a "$ENV_FILE" "$old_env" || {
        rm -f "$old_compose"
        (( was_running == 1 )) && compose start || true
        rm -rf "$temp_dir"
        return 1
    }
    mv "$CONFIG_DIR" "$old_config" || {
        rm -f "$old_compose" "$old_env"
        (( was_running == 1 )) && compose start || true
        rm -rf "$temp_dir"
        return 1
    }

    local restore_failed=0
    if ! mv "$temp_dir/config" "$CONFIG_DIR" \
        || ! install -m 0644 "$temp_dir/compose.yaml" "$COMPOSE_FILE" \
        || ! install -m 0640 "$temp_dir/.env" "$ENV_FILE"; then
        restore_failed=1
    fi

    if (( restore_failed == 0 )); then
        chown -R "$SERVICE_UID:$SERVICE_GID" "$CONFIG_DIR"
        chown "$SERVICE_UID:$SERVICE_GID" "$COMPOSE_FILE" "$ENV_FILE"
        if ! compose config --quiet; then
            restore_failed=1
        fi
    fi

    if (( restore_failed == 1 )); then
        error "Restore failed; rolling back the previous configuration."
        rm -rf "$CONFIG_DIR"
        mv "$old_config" "$CONFIG_DIR" || true
        mv -f "$old_compose" "$COMPOSE_FILE" || true
        mv -f "$old_env" "$ENV_FILE" || true
        rm -rf "$temp_dir"
        (( was_running == 1 )) && compose up -d || true
        return 1
    fi

    rm -rf "$old_config" "$temp_dir"
    rm -f "$old_compose" "$old_env"
    chown "$SERVICE_UID:$SERVICE_GID" "$safety_backup" 2>/dev/null || true
    chmod 0640 "$safety_backup" 2>/dev/null || true

    if (( was_running == 1 )); then
        preflight_application && compose up -d || {
            error "Restore succeeded, but the service could not be restarted."
            return 1
        }
    fi

    success "Backup restored successfully."
    info "Pre-restore safety backup: $safety_backup"
}

update_application() {
    require_configuration || return 1
    ensure_docker || return 1
    preflight_application || return 1

    if confirm "Create a verified configuration/database backup before updating?" yes; then
        create_backup || return 1
    fi

    local docker_root
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
    ensure_free_space "$docker_root" "$MIN_DOCKER_FREE_BYTES" "Docker data filesystem" || return 1
    check_dns_and_https || return 1

    info "Pulling configured image: $(env_get KES_IMAGE "$DEFAULT_IMAGE")"
    compose pull || return 1
    compose up -d --remove-orphans || return 1
    success "$APP_NAME was updated and restarted."
    compose ps
    test_http_service || true
}

show_configuration() {
    require_configuration || return 1
    printf '\n%sSaved settings%s\n' "$C_CYAN" "$C_RESET"
    printf '  Manager version:       %s\n' "$SCRIPT_VERSION"
    printf '  Application directory: %s\n' "$APP_DIR"
    printf '  Database/config:       %s\n' "$CONFIG_DIR"
    printf '  Media path:            %s\n' "$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")"
    printf '  Media mode:            %s\n' "$(env_get KES_MEDIA_PATH_MODE local)"
    printf '  Media expected mount:  %s\n' "$(env_get KES_EXPECTED_MOUNT none)"
    printf '  Bind address:          %s\n' "$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")"
    printf '  Host port:             %s\n' "$(env_get KES_HOST_PORT "$DEFAULT_PORT")"
    printf '  Timezone:              %s\n' "$(env_get TZ "$DEFAULT_TZ")"
    printf '  Image:                 %s\n' "$(env_get KES_IMAGE "$DEFAULT_IMAGE")"
    printf '  Backup path:           %s\n' "$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"
    printf '  Backup mode:           %s\n' "$(env_get KES_BACKUP_PATH_MODE local)"
    printf '  Backup expected mount: %s\n' "$(env_get KES_BACKUP_EXPECTED_MOUNT none)"
    printf '  Backup retention:      %s\n' "$(env_get KES_BACKUP_RETENTION "$DEFAULT_BACKUP_RETENTION")"
    printf '  Container media path:  /mnt/karaoke\n'
    if [[ -f "$SAMBA_STATE_FILE" ]]; then
        printf '  Samba share:           %s (%s)\n' \
            "$(samba_state_get SAMBA_SHARE_NAME "$DEFAULT_SAMBA_SHARE")" \
            "$(samba_state_get SAMBA_ACCESS_MODE unknown)"
    else
        printf '  Samba share:           not configured\n'
    fi
    show_access_information
}


samba_state_get() {
    local key="$1"
    local fallback="${2:-}"
    local value=""
    if [[ -f "$SAMBA_STATE_FILE" ]]; then
        value="$(grep -m1 -E "^${key}=" "$SAMBA_STATE_FILE" 2>/dev/null | cut -d= -f2- || true)"
    fi
    printf '%s\n' "${value:-$fallback}"
}

validate_samba_share_name() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]]
}

validate_ipv4_cidr() {
    python3 - "$1" <<'PY_CIDR' >/dev/null 2>&1
import ipaddress
import sys
ipaddress.IPv4Network(sys.argv[1], strict=False)
PY_CIDR
}

suggest_lan_cidr() {
    local address=""
    address="$(ip -4 -o addr show scope global 2>/dev/null | awk '$4 !~ /^127\./ {print $4; exit}')"
    [[ -n "$address" ]] || return 0
    python3 - "$address" <<'PY_NETWORK'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY_NETWORK
}

samba_package_ready() {
    command -v smbd >/dev/null 2>&1 \
        && command -v testparm >/dev/null 2>&1 \
        && command -v smbpasswd >/dev/null 2>&1 \
        && command -v pdbedit >/dev/null 2>&1
}

install_samba_packages() {
    check_supported_host || return 1
    export DEBIAN_FRONTEND=noninteractive
    info "Installing Samba file-server packages..."
    apt-get update || return 1
    apt-get install -y samba smbclient || return 1

    if ! samba_package_ready; then
        error "Samba packages installed, but required commands are unavailable."
        return 1
    fi

    systemctl enable --now smbd.service || return 1
    if systemctl list-unit-files nmbd.service >/dev/null 2>&1; then
        systemctl enable --now nmbd.service >/dev/null 2>&1 || warn "nmbd could not be enabled; direct SMB access over TCP 445 can still work."
    fi
    success "Samba is installed and smbd is running."
}

strip_manager_samba_block() {
    local source="$1"
    local destination="$2"
    python3 - "$source" "$destination" "$SAMBA_BLOCK_BEGIN" "$SAMBA_BLOCK_END" <<'PY_STRIP'
from pathlib import Path
import sys
src, dst, begin, end = sys.argv[1:]
lines = Path(src).read_text(errors="surrogateescape").splitlines(keepends=True)
out = []
in_block = False
found_begin = False
for line in lines:
    marker = line.rstrip("\r\n")
    if marker == begin:
        if in_block:
            raise SystemExit("nested manager Samba block")
        in_block = True
        found_begin = True
        continue
    if marker == end:
        if not in_block:
            raise SystemExit("unmatched manager Samba end marker")
        in_block = False
        continue
    if not in_block:
        out.append(line)
if in_block:
    raise SystemExit("unterminated manager Samba block")
Path(dst).write_text("".join(out), errors="surrogateescape")
PY_STRIP
}

samba_share_exists_in_file() {
    local config_file="$1"
    local share_name="$2"
    python3 - "$config_file" "$share_name" <<'PY_SHARE'
from pathlib import Path
import re
import sys
path, wanted = sys.argv[1:]
wanted = wanted.casefold()
for line in Path(path).read_text(errors="surrogateescape").splitlines():
    match = re.match(r"^\s*\[([^]]+)\]\s*$", line)
    if match and match.group(1).strip().casefold() == wanted:
        raise SystemExit(0)
raise SystemExit(1)
PY_SHARE
}

check_samba_user_media_access() {
    local user="$1"
    local media_path="$2"
    local access_mode="$3"

    if ! runuser -u "$user" -- test -r "$media_path" \
        || ! runuser -u "$user" -- test -x "$media_path"; then
        error "Linux user $user cannot read/traverse the media directory: $media_path"
        namei -l "$media_path" 2>/dev/null || true
        return 1
    fi

    if [[ "$access_mode" == "read-write" ]]; then
        local test_file="$media_path/.kes-samba-write-test.$$.$RANDOM"
        if ! runuser -u "$user" -- touch -- "$test_file"; then
            error "Linux user $user cannot create files in $media_path."
            error "Choose read-only access or correct the directory ownership/permissions first."
            return 1
        fi
        runuser -u "$user" -- rm -f -- "$test_file" || rm -f -- "$test_file"
    fi

    success "Linux permissions are compatible with Samba $access_mode access for $user."
}

write_samba_state() {
    local share_name="$1"
    local samba_user="$2"
    local access_mode="$3"
    local media_path="$4"
    local ufw_cidr="$5"
    local ufw_added="$6"

    cat > "$SAMBA_STATE_FILE" <<EOF_SAMBA_STATE
SAMBA_SHARE_NAME=$share_name
SAMBA_USER=$samba_user
SAMBA_ACCESS_MODE=$access_mode
SAMBA_MEDIA_PATH=$media_path
SAMBA_UFW_CIDR=$ufw_cidr
SAMBA_UFW_RULE_ADDED=$ufw_added
EOF_SAMBA_STATE
    chown root:root "$SAMBA_STATE_FILE"
    chmod 0600 "$SAMBA_STATE_FILE"
}

append_samba_share_block() {
    local target_file="$1"
    local share_name="$2"
    local media_path="$3"
    local samba_user="$4"
    local access_mode="$5"
    local read_only="yes"
    [[ "$access_mode" == "read-write" ]] && read_only="no"

    cat >> "$target_file" <<EOF_SAMBA_BLOCK

$SAMBA_BLOCK_BEGIN
[$share_name]
    comment = Karaoke Eternal media library
    path = $media_path
    browsable = yes
    guest ok = no
    read only = $read_only
    valid users = $samba_user
    force user = $samba_user
    create mask = 0664
    directory mask = 0775
    inherit permissions = yes
$SAMBA_BLOCK_END
EOF_SAMBA_BLOCK
}

ensure_samba_password() {
    local samba_user="$1"
    if pdbedit -L -u "$samba_user" >/dev/null 2>&1; then
        if confirm "A Samba password already exists for $samba_user. Reset it now?" no; then
            smbpasswd "$samba_user" || return 1
        fi
    else
        info "Create a Samba password for Windows access as user: $samba_user"
        smbpasswd -a "$samba_user" || return 1
        smbpasswd -e "$samba_user" >/dev/null 2>&1 || true
    fi
}

configure_samba_media_share() {
    require_configuration || return 1
    initialize_identity
    check_media_path || return 1
    samba_package_ready || install_samba_packages || return 1

    local media_path current_share current_user current_access old_ufw_cidr old_ufw_added
    media_path="$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")"
    current_share="$(samba_state_get SAMBA_SHARE_NAME "$DEFAULT_SAMBA_SHARE")"
    current_user="$(samba_state_get SAMBA_USER "$SERVICE_USER")"
    current_access="$(samba_state_get SAMBA_ACCESS_MODE read-write)"
    old_ufw_cidr="$(samba_state_get SAMBA_UFW_CIDR '')"
    old_ufw_added="$(samba_state_get SAMBA_UFW_RULE_ADDED no)"

    printf '\n%sSamba media-share configuration%s\n' "$C_CYAN" "$C_RESET"
    printf 'Only this folder will be shared: %s\n\n' "$media_path"

    local share_name samba_user access_mode
    while true; do
        share_name="$(prompt_value "Windows share name" "$current_share")"
        validate_samba_share_name "$share_name" && break
        warn "Use 1-32 characters: letters, numbers, underscore, or hyphen; begin with a letter."
    done

    while true; do
        samba_user="$(prompt_value "Existing Ubuntu user for Samba authentication" "$current_user")"
        if [[ "$samba_user" == "root" ]]; then
            warn "Do not expose the root account through Samba."
        elif id "$samba_user" >/dev/null 2>&1; then
            break
        else
            warn "The Samba username must already exist as an Ubuntu system account."
        fi
    done

    while true; do
        access_mode="$(prompt_value "Access mode (read-only or read-write)" "$current_access")"
        case "$access_mode" in
            read-only|read-write) break ;;
            *) warn "Enter read-only or read-write." ;;
        esac
    done

    check_samba_user_media_access "$samba_user" "$media_path" "$access_mode" || return 1
    ensure_samba_password "$samba_user" || return 1

    local backup_file temp_file clean_file
    backup_file="${SAMBA_CONFIG_FILE}.kes-backup-$(date +%Y%m%d-%H%M%S)"
    temp_file="$(mktemp "$(dirname "$SAMBA_CONFIG_FILE")/smb.conf.kes-new.XXXXXX")" || return 1
    clean_file="$(mktemp "$(dirname "$SAMBA_CONFIG_FILE")/smb.conf.kes-clean.XXXXXX")" || {
        rm -f "$temp_file"
        return 1
    }

    cp -a "$SAMBA_CONFIG_FILE" "$backup_file" || {
        rm -f "$temp_file" "$clean_file"
        return 1
    }

    if ! strip_manager_samba_block "$SAMBA_CONFIG_FILE" "$clean_file"; then
        error "The existing manager-owned Samba block is malformed; no changes were applied."
        rm -f "$temp_file" "$clean_file"
        return 1
    fi

    if samba_share_exists_in_file "$clean_file" "$share_name"; then
        error "A Samba share named [$share_name] already exists outside the manager-owned block."
        error "Choose a different share name; no changes were applied."
        rm -f "$temp_file" "$clean_file"
        return 1
    fi

    cp "$clean_file" "$temp_file" || {
        rm -f "$temp_file" "$clean_file"
        return 1
    }
    append_samba_share_block "$temp_file" "$share_name" "$media_path" "$samba_user" "$access_mode"

    if ! testparm -s "$temp_file" >/dev/null; then
        error "Samba rejected the generated configuration. No changes were applied."
        rm -f "$temp_file" "$clean_file"
        return 1
    fi

    install -o root -g root -m 0644 "$temp_file" "$SAMBA_CONFIG_FILE" || {
        cp -a "$backup_file" "$SAMBA_CONFIG_FILE"
        rm -f "$temp_file" "$clean_file"
        return 1
    }
    rm -f "$temp_file" "$clean_file"

    if ! testparm -s "$SAMBA_CONFIG_FILE" >/dev/null \
        || ! systemctl restart smbd.service; then
        error "Samba validation/startup failed. Restoring: $backup_file"
        cp -a "$backup_file" "$SAMBA_CONFIG_FILE"
        systemctl restart smbd.service >/dev/null 2>&1 || true
        return 1
    fi
    if systemctl is-active --quiet nmbd.service 2>/dev/null; then
        systemctl restart nmbd.service >/dev/null 2>&1 || true
    fi

    local ufw_cidr="" ufw_added="no"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        local suggested_cidr
        suggested_cidr="$(suggest_lan_cidr || true)"
        if confirm "UFW is active. Allow Samba only from a LAN IPv4 subnet?" yes; then
            while true; do
                ufw_cidr="$(prompt_value "Allowed LAN subnet" "${suggested_cidr:-192.168.1.0/24}")"
                validate_ipv4_cidr "$ufw_cidr" && break
                warn "Enter a valid IPv4 network such as 192.168.1.0/24."
            done
            if ufw app info Samba >/dev/null 2>&1 \
                && ufw --dry-run allow from "$ufw_cidr" to any app Samba >/dev/null 2>&1 \
                && ufw allow from "$ufw_cidr" to any app Samba; then
                ufw_added="yes"
                success "UFW permits Samba from $ufw_cidr."
            else
                warn "The Samba UFW rule could not be added. Review 'ufw status verbose'."
                ufw_cidr=""
            fi
        else
            warn "UFW remains active without a manager-added Samba rule. Windows clients may be blocked."
        fi
    else
        info "UFW is absent or inactive; the manager did not alter firewall rules."
    fi

    if [[ "$old_ufw_added" == "yes" && -n "$old_ufw_cidr" ]]         && [[ "$ufw_added" != "yes" || "$ufw_cidr" != "$old_ufw_cidr" ]]         && command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow from "$old_ufw_cidr" to any app Samba >/dev/null 2>&1             || warn "The previous manager-added Samba UFW rule could not be removed automatically."
    fi

    write_samba_state "$share_name" "$samba_user" "$access_mode" "$media_path" "$ufw_cidr" "$ufw_added"
    success "Samba share [$share_name] is configured for $media_path."
    info "Configuration backup: $backup_file"
    show_samba_status
}

show_samba_status() {
    printf '\n%sSamba media-share status%s\n' "$C_CYAN" "$C_RESET"

    if ! samba_package_ready; then
        warn "Samba is not installed or required commands are missing."
        return 1
    fi

    printf '  Samba version: %s\n' "$(smbd --version 2>/dev/null || echo unknown)"
    printf '  smbd enabled:  %s\n' "$(systemctl is-enabled smbd.service 2>/dev/null || echo no)"
    printf '  smbd active:   %s\n' "$(systemctl is-active smbd.service 2>/dev/null || echo no)"

    if testparm -s "$SAMBA_CONFIG_FILE" >/dev/null; then
        success "Samba configuration passes testparm."
    else
        error "Samba configuration fails testparm."
    fi

    if [[ ! -f "$SAMBA_STATE_FILE" ]]; then
        info "No Karaoke Eternal manager-owned Samba share is recorded."
        return 0
    fi

    local share_name samba_user access_mode media_path recorded_path ufw_cidr
    share_name="$(samba_state_get SAMBA_SHARE_NAME "$DEFAULT_SAMBA_SHARE")"
    samba_user="$(samba_state_get SAMBA_USER unknown)"
    access_mode="$(samba_state_get SAMBA_ACCESS_MODE unknown)"
    recorded_path="$(samba_state_get SAMBA_MEDIA_PATH unknown)"
    media_path="$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")"
    ufw_cidr="$(samba_state_get SAMBA_UFW_CIDR '')"

    printf '  Share name:    %s\n' "$share_name"
    printf '  Samba user:    %s\n' "$samba_user"
    printf '  Access:        %s\n' "$access_mode"
    printf '  Shared path:   %s\n' "$recorded_path"
    [[ -n "$ufw_cidr" ]] && printf '  UFW subnet:    %s\n' "$ufw_cidr"

    if [[ "$recorded_path" != "$media_path" ]]; then
        warn "The configured Karaoke Eternal media path changed to $media_path. Reconfigure Samba."
    fi
    if pdbedit -L -u "$samba_user" >/dev/null 2>&1; then
        success "Samba account exists for $samba_user."
    else
        error "No Samba password database entry exists for $samba_user."
    fi
    if [[ -d "$recorded_path" ]]; then
        check_samba_user_media_access "$samba_user" "$recorded_path" "$access_mode" || true
    else
        error "Shared media directory is missing: $recorded_path"
    fi

    printf '\n%sSMB listeners%s\n' "$C_CYAN" "$C_RESET"
    ss -lntup 2>/dev/null | awk '$5 ~ /:(139|445)$/ {print}' || true

    printf '\n%sWindows paths%s\n' "$C_CYAN" "$C_RESET"
    local address
    while read -r address; do
        [[ -n "$address" ]] && printf '  \\\\%s\\%s\n' "$address" "$share_name"
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
}

reset_samba_password() {
    if [[ ! -f "$SAMBA_STATE_FILE" ]]; then
        error "No manager-owned Samba share is configured."
        return 1
    fi
    samba_package_ready || return 1
    local samba_user
    samba_user="$(samba_state_get SAMBA_USER '')"
    [[ -n "$samba_user" ]] || return 1
    if pdbedit -L -u "$samba_user" >/dev/null 2>&1; then
        smbpasswd "$samba_user"
    else
        smbpasswd -a "$samba_user"
    fi
}

remove_samba_media_share() {
    local account_action="${1:-ask}"
    local share_name samba_user ufw_cidr ufw_added
    share_name="$(samba_state_get SAMBA_SHARE_NAME "$DEFAULT_SAMBA_SHARE")"
    samba_user="$(samba_state_get SAMBA_USER '')"
    ufw_cidr="$(samba_state_get SAMBA_UFW_CIDR '')"
    ufw_added="$(samba_state_get SAMBA_UFW_RULE_ADDED no)"

    if [[ ! -f "$SAMBA_CONFIG_FILE" ]]; then
        rm -f "$SAMBA_STATE_FILE"
        return 0
    fi

    local backup_file clean_file
    backup_file="${SAMBA_CONFIG_FILE}.kes-backup-$(date +%Y%m%d-%H%M%S)"
    clean_file="$(mktemp "$(dirname "$SAMBA_CONFIG_FILE")/smb.conf.kes-remove.XXXXXX")" || return 1
    cp -a "$SAMBA_CONFIG_FILE" "$backup_file" || {
        rm -f "$clean_file"
        return 1
    }
    if ! strip_manager_samba_block "$SAMBA_CONFIG_FILE" "$clean_file" \
        || ! testparm -s "$clean_file" >/dev/null; then
        error "Unable to produce a valid Samba configuration without the manager-owned share."
        rm -f "$clean_file"
        return 1
    fi
    install -o root -g root -m 0644 "$clean_file" "$SAMBA_CONFIG_FILE"
    rm -f "$clean_file"

    if ! systemctl restart smbd.service; then
        error "Samba restart failed; restoring the previous configuration."
        cp -a "$backup_file" "$SAMBA_CONFIG_FILE"
        systemctl restart smbd.service >/dev/null 2>&1 || true
        return 1
    fi

    if [[ "$ufw_added" == "yes" && -n "$ufw_cidr" ]] \
        && command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow from "$ufw_cidr" to any app Samba >/dev/null 2>&1 \
            || warn "The previously recorded Samba UFW rule could not be removed automatically."
    fi

    if [[ "$account_action" == "ask" && -n "$samba_user" ]] \
        && pdbedit -L -u "$samba_user" >/dev/null 2>&1 \
        && confirm "Also remove the Samba password entry for $samba_user?" no; then
        smbpasswd -x "$samba_user" || warn "Unable to remove the Samba password entry."
    fi

    rm -f "$SAMBA_STATE_FILE"
    success "Manager-owned Samba share [$share_name] was removed. Samba packages and other shares were preserved."
}

samba_media_menu() {
    while true; do
        printf '\n%sSamba share for Karaoke Eternal media only%s\n' "$C_CYAN" "$C_RESET"
        cat <<'MENU'
  1) Install or reconfigure authenticated media share
  2) Check Samba configuration, service, account, permissions, and ports
  3) Reset Samba password
  4) Remove only the manager-owned media share
  0) Return
MENU
        local choice=""
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) configure_samba_media_share || true; pause_screen ;;
            2) show_samba_status || true; pause_screen ;;
            3) reset_samba_password || true; pause_screen ;;
            4)
                if confirm "Remove the manager-owned Samba media share?" no; then
                    remove_samba_media_share ask || true
                fi
                pause_screen
                ;;
            0) return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

show_network_firewall_checks() {
    require_configuration || return 1
    ensure_docker || return 1

    local bind_address port
    bind_address="$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")"
    port="$(env_get KES_HOST_PORT "$DEFAULT_PORT")"

    printf '\n%sNetwork binding%s\n' "$C_CYAN" "$C_RESET"
    printf '  Configured bind: %s:%s\n' "$bind_address" "$port"
    if bind_address_is_present "$bind_address"; then
        success "Bind address exists on this server."
    else
        error "Bind address is not assigned to this server."
    fi

    printf '\n%sPort listener%s\n' "$C_CYAN" "$C_RESET"
    if port_has_listener "$port"; then
        ss -ltnp "sport = :$port" 2>/dev/null || true
        if container_mapping_matches "$bind_address" "$port"; then
            success "The listener belongs to $CONTAINER_NAME."
        else
            warn "The selected port is used by another process or container."
        fi
    else
        info "Nothing is currently listening on TCP port $port."
    fi

    printf '\n%sDocker published ports%s\n' "$C_CYAN" "$C_RESET"
    docker port "$CONTAINER_NAME" 2>/dev/null || info "Container has no published port mapping or is absent."

    printf '\n%sUFW status%s\n' "$C_CYAN" "$C_RESET"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose || true
    else
        info "UFW is not installed."
    fi

    printf '\n%sDocker firewall chains%s\n' "$C_CYAN" "$C_RESET"
    if command -v iptables >/dev/null 2>&1; then
        iptables -S DOCKER-USER 2>/dev/null || info "DOCKER-USER chain is unavailable (possibly nftables backend or no Docker rules yet)."
    else
        info "iptables command is unavailable."
    fi

    if [[ "$bind_address" == "0.0.0.0" ]]; then
        warn "Karaoke Eternal is published on every IPv4 interface."
        warn "Docker-published ports can bypass ordinary UFW INPUT rules. Do not expose this port through your router."
        info "For tighter LAN access, reconfigure with the server's specific LAN IPv4 address."
    elif [[ "$bind_address" == "127.0.0.1" ]]; then
        success "The service is bound to loopback only and is not directly reachable from the LAN."
    else
        success "The service is restricted to one host IPv4 address: $bind_address"
    fi
}

run_apt_update() {
    check_supported_host || return 1
    info "Refreshing Ubuntu package indexes with apt-get update..."
    apt-get update
}

run_apt_upgrade() {
    check_supported_host || return 1
    info "Refreshing package indexes before upgrading installed Ubuntu packages..."
    apt-get update || return 1
    info "Installing available package upgrades with apt-get upgrade -y..."
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get upgrade -y || return 1

    success "Ubuntu package upgrade completed."
    if [[ -f /var/run/reboot-required ]]; then
        warn "A reboot is required to finish applying one or more updates."
        [[ -r /var/run/reboot-required.pkgs ]] && sed 's/^/  /' /var/run/reboot-required.pkgs
    else
        success "Ubuntu does not currently report that a reboot is required."
    fi
}

system_maintenance_menu() {
    while true; do
        printf '\n%sUbuntu system diagnostics and updates%s\n' "$C_CYAN" "$C_RESET"
        cat <<'MENU'
  1) Run full system diagnostics
  2) Check manager prerequisite utilities
  3) Install/repair manager prerequisites, including tmux, less, and unzip
  4) Refresh package indexes (apt-get update)
  5) Update installed system packages (apt-get update + apt-get upgrade -y)
  6) Check whether a reboot is required
  0) Return
MENU
        printf '\n'
        local choice=""
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) show_host_diagnostics; pause_screen ;;
            2) show_host_prerequisite_status; pause_screen ;;
            3) repair_host_prerequisites; pause_screen ;;
            4) run_apt_update; pause_screen ;;
            5) run_apt_upgrade; pause_screen ;;
            6)
                if [[ -f /var/run/reboot-required ]]; then
                    warn "Ubuntu reports that a reboot is required."
                    [[ -r /var/run/reboot-required.pkgs ]] && cat /var/run/reboot-required.pkgs
                else
                    success "No reboot-required marker is present."
                fi
                pause_screen
                ;;
            0) return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

show_host_diagnostics() {
    printf '\n%sUbuntu Server%s\n' "$C_CYAN" "$C_RESET"
    if check_supported_host; then
        load_os_release
        success "Supported host: ${PRETTY_NAME:-Ubuntu}, architecture $(host_architecture)"
    fi
    printf '  Kernel: %s\n' "$(uname -r)"
    printf '  Memory: %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
    [[ -f /var/run/reboot-required ]] && warn "Ubuntu reports that a reboot is required."

    show_host_prerequisite_status || true

    printf '\n%sTime and maintenance%s\n' "$C_CYAN" "$C_RESET"
    timedatectl show -p Timezone -p NTPSynchronized 2>/dev/null || true
    systemctl is-enabled unattended-upgrades.service 2>/dev/null | sed 's/^/  unattended-upgrades: /' || true
    systemctl is-enabled fstrim.timer 2>/dev/null | sed 's/^/  fstrim.timer: /' || true

    printf '\n%sFilesystems%s\n' "$C_CYAN" "$C_RESET"
    df -hT "$APP_DIR" 2>/dev/null || df -hT /data 2>/dev/null || df -hT /
    df -Pi "$APP_DIR" 2>/dev/null || true

    printf '\n%sDocker%s\n' "$C_CYAN" "$C_RESET"
    if docker_is_ready; then
        docker version --format '  Engine: {{.Server.Version}}' 2>/dev/null || true
        printf '  Compose: %s\n' "$(docker compose version --short 2>/dev/null || echo unknown)"
        docker info --format '  Root dir: {{.DockerRootDir}}\n  Storage driver: {{.Driver}}\n  Logging driver: {{.LoggingDriver}}\n  Live restore: {{.LiveRestoreEnabled}}' 2>/dev/null || true
        systemctl is-enabled docker.service 2>/dev/null | sed 's/^/  docker enabled: /' || true
        systemctl is-enabled containerd.service 2>/dev/null | sed 's/^/  containerd enabled: /' || true
    else
        warn "Docker Engine/Compose is not ready."
    fi

    if configuration_exists; then
        printf '\n%sKaraoke Eternal%s\n' "$C_CYAN" "$C_RESET"
        compose config --quiet && success "Compose configuration is valid." || error "Compose configuration is invalid."
        check_media_path || true
        check_backup_path || true
        show_network_firewall_checks || true
        if container_is_running; then
            test_http_service || true
        fi
    else
        info "$APP_NAME is not configured yet."
    fi
}

remove_container_keep_data() {
    require_configuration || return 1
    ensure_docker || return 1
    if ! confirm "Remove the $APP_NAME container but keep configuration, backups, and media?" no; then
        return 0
    fi
    compose down --remove-orphans || return 1
    success "Container removed. Persistent data remains."
}

full_remove() {
    local media_path backup_path
    media_path="$(env_get KES_MEDIA_PATH "$DEFAULT_MEDIA_DIR")"
    backup_path="$(env_get KES_BACKUP_PATH "$DEFAULT_BACKUP_DIR")"

    printf '%sWARNING:%s This removes the container, manager command, and %s.\n' "$C_RED" "$C_RESET" "$APP_DIR"
    if path_is_within "$media_path" "$APP_DIR"; then
        warn "Local media under $media_path will be deleted."
    else
        info "External media path will not be deleted: $media_path"
    fi
    if path_is_within "$backup_path" "$APP_DIR"; then
        warn "Local backups under $backup_path will be deleted."
    else
        info "External backup path will not be deleted: $backup_path"
    fi
    printf 'Docker Engine will remain installed.\n'
    printf 'Type DELETE-KARAOKE-ETERNAL to continue: '
    local confirmation=""
    read -r confirmation
    [[ "$confirmation" == "DELETE-KARAOKE-ETERNAL" ]] || return 0

    if [[ -f "$SAMBA_STATE_FILE" ]] || grep -Fq "$SAMBA_BLOCK_BEGIN" "$SAMBA_CONFIG_FILE" 2>/dev/null; then
        remove_samba_media_share keep-account || warn "The Samba media share could not be removed automatically."
    fi

    if configuration_exists && docker_is_ready; then
        compose down --remove-orphans || true
    elif command -v docker >/dev/null 2>&1; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    rm -rf "$APP_DIR"
    rm -f "$MANAGER_PATH"
    success "$APP_NAME application data and manager command were removed."
}

print_header() {
    clear 2>/dev/null || true
    printf '%s================================================================%s\n' "$C_CYAN" "$C_RESET"
    printf '%s  Karaoke Eternal Optimized Docker Manager v%s%s\n' "$C_CYAN" "$SCRIPT_VERSION" "$C_RESET"
    printf '%s================================================================%s\n' "$C_CYAN" "$C_RESET"

    if configuration_exists && command -v docker >/dev/null 2>&1; then
        local state=""
        state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        printf 'Status: %s\n' "${state:-not running}"
        printf 'Bind:   %s:%s\n' \
            "$(env_get KES_BIND_ADDRESS "$DEFAULT_BIND_ADDRESS")" \
            "$(env_get KES_HOST_PORT "$DEFAULT_PORT")"
    else
        printf 'Status: not configured\n'
    fi
    printf '\n'
}

main_menu() {
    while true; do
        print_header
        cat <<'MENU'
  1) Ubuntu system diagnostics and package updates
  2) Install / repair / update Docker Engine
  3) Apply safe Docker daemon optimizations
  4) Install or reconfigure Karaoke Eternal
  5) Start Karaoke Eternal / scan media on startup
  6) Stop Karaoke Eternal
  7) Restart Karaoke Eternal
  8) Status, paths, storage, and web test
  9) View live logs
 10) Update Karaoke Eternal
 11) Back up database and configuration
 12) Restore a backup safely
 13) Check media and backup paths
 14) Check ports and firewall behavior
 15) Test ZIPs / Fast Scan by media folder
 16) Filter/review ZIP errors: keep, quarantine, delete, or restore
 17) Restore quarantined ZIP media files
 18) Samba share for the configured media folder
 19) Show saved configuration
 20) Remove container (keep all data)
 21) Fully remove Karaoke Eternal data
  0) Exit
MENU
        printf '\n'
        local choice=""
        read -r -p "Choose an option: " choice
        printf '\n'

        case "$choice" in
            1) system_maintenance_menu ;;
            2) install_or_update_docker; pause_screen ;;
            3) optimize_docker; pause_screen ;;
            4) configure_application; pause_screen ;;
            5) start_application_menu ;;
            6) stop_application; pause_screen ;;
            7) restart_application; pause_screen ;;
            8) show_status; pause_screen ;;
            9) show_logs; pause_screen ;;
            10) update_application; pause_screen ;;
            11) create_backup; pause_screen ;;
            12) restore_backup; pause_screen ;;
            13) check_media_path; check_backup_path; pause_screen ;;
            14) show_network_firewall_checks; pause_screen ;;
            15) zip_integrity_scan_menu; pause_screen ;;
            16) zip_error_review_menu ;;
            17) zip_quarantine_restore_menu ;;
            18) samba_media_menu ;;
            19) show_configuration; pause_screen ;;
            20) remove_container_keep_data; pause_screen ;;
            21) full_remove; pause_screen ;;
            0) exit 0 ;;
            *) warn "Invalid selection."; pause_screen ;;
        esac
    done
}

print_help() {
    cat <<EOF_HELP
Usage: sudo $0 [OPTION]

Without an option, opens the interactive management menu.

Options:
  --no-tmux           Open the interactive menu in the current SSH session
  --attach-manager    Attach to the reconnectable tmux manager session, or create it
  --manager-tmux-status
                      Show reconnectable tmux manager sessions
  --check-prereqs     Check manager prerequisite utilities, including tmux, less, and unzip
  --install-prereqs   Install/repair manager prerequisites, including tmux, less, and unzip
  --diagnostics       Run Ubuntu, Docker, storage, path, port, and firewall checks
  --apt-update        Refresh Ubuntu package indexes
  --system-update     Run apt-get update followed by apt-get upgrade -y
  --install-docker    Install, repair, or update Docker Engine and Compose
  --optimize-docker   Configure optional Docker live-restore/default local logging
  --install           Install or reconfigure Karaoke Eternal
  --start             Start the container after preflight checks
  --start-scan [TARGET]
                      Start/recreate the container with KES_SCAN for startup media scanning
  --stop              Stop the container
  --restart           Restart the container after preflight checks
  --status            Show status, paths, storage use, and HTTP response test
  --logs              Follow container logs
  --update            Back up, pull the image, and recreate the container
  --backup            Create and verify a backup, then apply retention
  --restore           Select and safely restore a backup
  --check-paths       Verify media and backup paths and expected mounts
  --check-network     Inspect bind address, port use, UFW, and Docker firewall state
  --verify-zips [DIR] [TIMEOUT]
                      Recursively test every ZIP with unzip -tqq and log each failure
  --verify-zips-by-folder [ROOT] [TIMEOUT]
                      Select one immediate media subfolder, scan it, then optionally review by exit code
  --zip-fast-scan [DIR] [TIMEOUT]
                      Choose or use one folder, scan recursively, show exit-code counts, then review one code
  --zip-report        Show the latest recursive ZIP test report
  --zip-exit-summary [INDEX]
                      Count ZIP failures by exact per-file unzip exit code
  --zip-exit-summary-folder FOLDER [INDEX]
                      Count ZIP failures by exit code only under one folder
  --review-zip-errors [INDEX]
                      Review all logged ZIP failures and keep, quarantine, or delete one
  --review-zip-exit-code CODE [INDEX]
                      Review only failures matching one exact exit code
  --review-zip-folder-exit-code FOLDER CODE [INDEX]
                      Review failures under one folder matching one exact exit code
  --list-quarantine   List quarantined ZIP media files recorded in the action log
  --restore-quarantine
                      Open the restore menu for quarantined ZIP media files
  --restore-quarantine-folder FOLDER
                      Restore one available quarantined ZIP by original media folder
  --list-orphan-quarantine
                      List ZIPs found under quarantine that are not usable through the normal restore log
  --recover-orphan-quarantine
                      Move orphaned quarantine ZIPs into the restored media folder for manual inspection
  --recover-orphan-quarantine-batch
                      Choose one orphaned quarantine batch/folder and recover it into the restored media folder
  --samba-setup       Install/reconfigure authenticated Samba access to the media folder only
  --samba-status      Check Samba config, service, account, permissions, firewall, and listeners
  --samba-password    Reset the configured Samba user's password
  --samba-remove      Remove only the manager-owned Samba media share
  --config            Show saved configuration
  --remove-container  Remove the container while retaining persistent data
  --full-remove       Remove Karaoke Eternal application data and manager command
  --version           Show manager version
  --help              Show this help

After installation, the manager is available as:
  sudo $MANAGER_PATH
EOF_HELP
}

main() {
    require_root "$@"
    initialize_identity

    safe_manager_launcher "${1:-}"

    case "${1:-}" in
        "") main_menu ;;
        --no-tmux) main_menu ;;
        --attach-manager)
            if manager_tmux_install_if_requested; then
                if manager_tmux_session_exists "$MANAGER_TMUX_SESSION"; then
                    manager_tmux_attach "$MANAGER_TMUX_SESSION"
                else
                    manager_tmux_start_attached "$MANAGER_TMUX_SESSION" "$(script_self_path)"
                fi
            else
                main_menu
            fi
            ;;
        --manager-tmux-status) show_manager_tmux_status ;;
        --check-prereqs) show_host_prerequisite_status ;;
        --install-prereqs) repair_host_prerequisites ;;
        --diagnostics) show_host_diagnostics ;;
        --apt-update) run_apt_update ;;
        --system-update) run_apt_upgrade ;;
        --install-docker) install_or_update_docker ;;
        --optimize-docker) optimize_docker ;;
        --install) configure_application ;;
        --start) start_application ;;
        --start-scan) start_application_with_media_scan "${2:-all}" ;;
        --stop) stop_application ;;
        --restart) restart_application ;;
        --status) show_status ;;
        --logs) show_logs ;;
        --update) update_application ;;
        --backup) create_backup ;;
        --restore) restore_backup ;;
        --check-paths) check_media_path; check_backup_path ;;
        --check-network) show_network_firewall_checks ;;
        --verify-zips) zip_integrity_scan "${2:-}" "${3:-$DEFAULT_ZIP_TEST_TIMEOUT}" ;;
        --verify-zips-by-folder) zip_integrity_scan_by_folder_workflow "${2:-$DEFAULT_MEDIA_DIR}" "${3:-$DEFAULT_ZIP_TEST_TIMEOUT}" ;;
        --zip-fast-scan) zip_fast_scan_workflow "${2:-}" "${3:-$DEFAULT_ZIP_TEST_TIMEOUT}" ;;
        --zip-report) show_latest_zip_error_log ;;
        --zip-exit-summary) zip_exit_code_summary "${2:-}" ;;
        --zip-exit-summary-folder) zip_exit_code_summary "${3:-}" "${2:-}" ;;
        --review-zip-errors) review_zip_error_log "${2:-}" ;;
        --review-zip-exit-code) review_zip_errors_by_exit_code "${2:-}" "${3:-}" ;;
        --review-zip-folder-exit-code) review_zip_errors_by_folder_and_exit_code "${2:-}" "${3:-}" "${4:-}" ;;
        --list-quarantine) list_quarantined_zip_files ;;
        --restore-quarantine) zip_quarantine_restore_menu ;;
        --restore-quarantine-folder) restore_quarantined_zips_by_original_folder "${2:-}" ;;
        --list-orphan-quarantine) list_orphan_quarantined_zip_files ;;
        --recover-orphan-quarantine) recover_orphan_quarantined_zips_to_restored_media ;;
        --recover-orphan-quarantine-batch) recover_orphan_quarantined_zips_by_batch ;;
        --samba-setup) configure_samba_media_share ;;
        --samba-status) show_samba_status ;;
        --samba-password) reset_samba_password ;;
        --samba-remove) remove_samba_media_share ask ;;
        --config) show_configuration ;;
        --remove-container) remove_container_keep_data ;;
        --full-remove) full_remove ;;
        --version) printf '%s\n' "$SCRIPT_VERSION" ;;
        --help|-h) print_help ;;
        *) error "Unknown option: $1"; print_help; exit 2 ;;
    esac
}

main "$@"

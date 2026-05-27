# =============================================================================
# lib/common.sh — общие helpers для setup.sh и его модулей
# =============================================================================
# Sourced from setup.sh ДО загрузки модулей.
# Все state-переменные (INSTALLED, FAILED, SKIPPED) объявлены здесь.
# =============================================================================

# ----- Цвета -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

# ----- Базовые переменные -----
REPO_RAW="https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main"
T7_LABEL="t7"
T7_MOUNT="/mnt/t7"
CONFIG_DIR="/etc/travel-nas"
SCRIPT_DIR="/usr/local/bin"

# ----- Отчёт компонентов -----
INSTALLED=()
FAILED=()
SKIPPED=()

mark_ok() {
    local name="$1"
    local detail="${2:-}"
    INSTALLED+=("$name")
    log "✓ $name${detail:+: $detail}"
    if [[ -x /usr/local/bin/tg-notify.sh ]] && [[ -f /etc/travel-nas/tg-notify.conf ]]; then
        /usr/local/bin/tg-notify.sh --append info "Installed" "$name${detail:+ — $detail}" 2>/dev/null || true
    fi
}

mark_fail() {
    local name="$1"
    local reason="${2:-unknown}"
    FAILED+=("$name: $reason")
    err "✗ $name FAILED: $reason"
    if [[ -x /usr/local/bin/tg-notify.sh ]] && [[ -f /etc/travel-nas/tg-notify.conf ]]; then
        /usr/local/bin/tg-notify.sh -l warning "Install failed: $name" "$reason" 2>/dev/null || true
    fi
}

try() {
    local desc="$1"; shift
    if "$@"; then
        return 0
    else
        local code=$?
        warn "$desc — exit $code"
        return "$code"
    fi
}

# =============================================================================
# wait_for_apt — ждёт пока кто-то другой не отпустит dpkg lock
# =============================================================================
# Свежая PiOS на первой загрузке гоняет apt-daily.service + unattended-upgrades
# в фоне, и наш `apt-get update` падает с "Could not get lock". Это убивало
# UPDATE/UTILS/SAMBA/LOG2RAM/COMITUP/CASAOS пачкой в предыдущих ранах.
# Вызывать ПЕРЕД каждым apt-get.
# =============================================================================
wait_for_apt() {
    local max_wait="${1:-600}"   # 10 минут по умолчанию
    local elapsed=0
    local interval=5
    local locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    while sudo fuser "${locks[@]}" >/dev/null 2>&1; do
        if (( elapsed == 0 )); then
            warn "Другой apt процесс держит lock — жду до ${max_wait}с..."
            # Аккуратно: попробуем остановить known-фоновые apt-сервисы
            for svc in unattended-upgrades.service apt-daily.service apt-daily-upgrade.service; do
                sudo systemctl stop "$svc" 2>/dev/null || true
            done
        fi
        if (( elapsed >= max_wait )); then
            err "apt lock не освободился за ${max_wait}с"
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 0
}

# Удобная обёртка: ждём lock, потом apt-get с переданными аргументами.
apt_get() {
    wait_for_apt || return 1
    sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# =============================================================================
# fetch_script / fetch_conf_example — копируют из локального чекаута или curl с GitHub
# =============================================================================
fetch_script() {
    local name="$1"
    local target="$2"
    local repo_root="${SETUP_REPO_ROOT:-$(dirname "$0")}"
    if [[ -f "$repo_root/scripts/$name" ]]; then
        sudo cp "$repo_root/scripts/$name" "$target"
    else
        sudo curl -fsSL "$REPO_RAW/scripts/$name" -o "$target"
    fi
    sudo chmod +x "$target"
}

fetch_conf_example() {
    local name="$1"
    local target="$2"
    local repo_root="${SETUP_REPO_ROOT:-$(dirname "$0")}"
    if [[ -f "$repo_root/conf-examples/$name" ]]; then
        sudo cp "$repo_root/conf-examples/$name" "$target"
    else
        sudo curl -fsSL "$REPO_RAW/conf-examples/$name" -o "$target"
    fi
}

# Helper: создаёт systemd unit-файл из stdin (heredoc) идемпотентно.
# Usage:
#   write_systemd_unit my-service.service <<EOF
#   [Unit]...
#   EOF
write_systemd_unit() {
    local name="$1"
    sudo tee "/etc/systemd/system/$name" >/dev/null
}

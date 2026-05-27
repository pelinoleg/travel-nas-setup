#!/bin/bash
# =============================================================================
# nas-backup.sh - Бэкап с UGREEN NAS на T7 через rsync daemon
# =============================================================================
# Адаптирован для travel-NAS Pi из домашнего Mac-скрипта.
#
# Запуск:
#   nas-backup.sh                  # интерактивно (whiptail меню)
#   nas-backup.sh --run            # запуск бэкапа без вопросов
#   nas-backup.sh --dry-run        # симуляция
#   nas-backup.sh --diff           # показать различия
#   nas-backup.sh --config         # отредактировать конфиг
#
# Конфиг: /etc/travel-nas/nas-backup.conf
# Логи: /mnt/t7/nas-backup/_logs/
# =============================================================================

set -u

CONFIG="/etc/travel-nas/nas-backup.conf"
TG_NOTIFY="/usr/local/bin/tg-notify.sh"
DEFAULT_DEST="/mnt/t7/nas-backup"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

# Проверка зависимостей
check_deps() {
    local missing=()
    for cmd in rsync sshpass; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing tools: ${missing[*]}"
        echo "Install: sudo apt install -y ${missing[*]}"
        exit 1
    fi
}

# Загрузка конфига
load_config() {
    if [[ ! -f "$CONFIG" ]]; then
        err "Config not found at $CONFIG"
        info "Run: sudo nas-backup --config"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG"

    # Проверки
    [[ -z "${NAS_HOST:-}" ]] && err "NAS_HOST not set in $CONFIG" && exit 1
    [[ -z "${NAS_USER:-}" ]] && err "NAS_USER not set in $CONFIG" && exit 1
    [[ -z "${NAS_PASS:-}" ]] && err "NAS_PASS not set in $CONFIG" && exit 1
    [[ -z "${DEST:-}" ]] && DEST="$DEFAULT_DEST"
    [[ -z "${MODULES[*]:-}" ]] && err "MODULES list is empty in $CONFIG" && exit 1
}

# Helper для Telegram
tg_notify() {
    local level="$1"
    local title="$2"
    local msg="$3"
    if [[ -x "$TG_NOTIFY" ]]; then
        "$TG_NOTIFY" -l "$level" "$title" "$msg" 2>/dev/null || true
    fi
}

# Проверка сети и NAS
check_connectivity() {
    if ! ping -c 1 -W 3 "$NAS_HOST" &>/dev/null; then
        err "NAS unreachable: $NAS_HOST"
        return 1
    fi
    if ! sshpass -p "$NAS_PASS" rsync "$NAS_USER@$NAS_HOST::" &>/dev/null; then
        err "Cannot connect to NAS rsync daemon (wrong password?)"
        return 1
    fi
    return 0
}

# Конвертация байтов в human-readable
human_size() {
    local bytes=$1
    if   [ "$bytes" -ge 1099511627776 ]; then
        awk "BEGIN {printf \"%.1fT\", $bytes/1099511627776}"
    elif [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1fG\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fK\", $bytes/1024}"
    else
        echo "${bytes}B"
    fi
}

# Запуск бэкапа одного модуля
run_module() {
    local module="$1"
    local dest_folder="$2"
    local dest_path="$DEST/$dest_folder"
    local deleted_path="$DEST/_deleted/$(date '+%d-%m-%Y')/$dest_folder"
    local log_dir="$DEST/_logs"
    local log_file="$log_dir/$(date '+%d-%m-%Y_%H-%M')_$dest_folder.log"

    mkdir -p "$dest_path" "$deleted_path" "$log_dir"

    info "📦 $dest_folder ← NAS::$module"
    echo "   → $dest_path"

    # --info=progress2 --no-inc-recursive --outbuf=N нужен для глобального % и парсинга
    # writer-скриптом (вместо просто -P).
    local rsync_args=(
        -rltD
        --info=progress2 --no-inc-recursive --outbuf=N
        --no-owner --no-group --no-perms --chown=oleg:oleg
        --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r
        --omit-dir-times
        --human-readable
        --stats
        --backup
        --backup-dir="$deleted_path"
        --delete
    )

    [[ "${DRY_RUN:-false}" == "true" ]] && rsync_args+=("--dry-run")

    for excl in "${EXCLUDES[@]:-}"; do
        [[ -n "$excl" ]] && rsync_args+=("--exclude=$excl")
    done

    rsync_args+=("$NAS_USER@$NAS_HOST::$module/" "$dest_path/")

    local progress_writer="/usr/local/bin/backup-progress-writer.py"
    local exit_code
    if [[ -x "$progress_writer" ]] && [[ "${DRY_RUN:-false}" != "true" ]]; then
        sshpass -p "$NAS_PASS" rsync "${rsync_args[@]}" 2>&1 \
            | "$progress_writer" \
                --source nas \
                --device "$NAS_HOST" \
                --label "$dest_folder" \
                --target "$dest_path" \
            | tee "$log_file"
        exit_code="${PIPESTATUS[0]}"
    else
        sshpass -p "$NAS_PASS" rsync "${rsync_args[@]}" 2>&1 | tee "$log_file"
        exit_code="${PIPESTATUS[0]}"
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        log "Module $dest_folder OK"
        return 0
    elif [[ "$exit_code" -eq 24 ]]; then
        warn "Module $dest_folder finished with warnings (vanished files)"
        return 0
    else
        err "Module $dest_folder FAILED with rsync exit $exit_code"
        return 1
    fi
}

# Главная функция бэкапа
do_backup() {
    info "Checking connectivity..."
    if ! check_connectivity; then
        tg_notify error "NAS-backup failed" "Cannot reach NAS at $NAS_HOST"
        exit 1
    fi

    # Уведомление: старт
    local count=${#MODULES[@]}
    tg_notify normal "NAS-backup started" "Source: \`$NAS_HOST\`
Modules: $count
Target: \`$DEST\`"

    mkdir -p "$DEST"
    cd "$DEST" || exit 1

    local start_time=$(date +%s)
    local errors=0
    local ok_count=0

    for module_pair in "${MODULES[@]}"; do
        local module="${module_pair%%|*}"
        local dest_folder="${module_pair##*|}"

        echo ""
        echo "─────────────────────────────────────────────────"
        if run_module "$module" "$dest_folder"; then
            ((ok_count++)) || true
        else
            ((errors++)) || true
        fi
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local mins=$(((duration % 3600) / 60))
    local secs=$((duration % 60))

    # Размер бэкапа
    local total_size
    total_size=$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')

    echo ""
    echo "================================================="
    if [[ "$errors" -eq 0 ]]; then
        log "Backup completed successfully"
        tg_notify success "NAS-backup complete" "Modules: $ok_count/$count
Total size: $total_size
Duration: ${hours}h ${mins}m ${secs}s"
    else
        warn "Backup completed with $errors errors"
        tg_notify warning "NAS-backup with errors" "OK: $ok_count
Failed: $errors
Total: $count
Duration: ${hours}h ${mins}m ${secs}s

Check: \`$DEST/_logs/\`"
    fi
    echo "================================================="

    # Триггерим обновление JSON-status для dashboard (фоном чтобы не задерживать
    # завершение). Может занять минуту на большой папке.
    if [[ -x /usr/local/bin/nas-backup-status.py ]]; then
        nohup /usr/bin/python3 /usr/local/bin/nas-backup-status.py \
            >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
}

# Diff mode
do_diff() {
    info "Calculating differences..."
    if ! check_connectivity; then
        err "Cannot reach NAS"
        exit 1
    fi

    for module_pair in "${MODULES[@]}"; do
        local module="${module_pair%%|*}"
        local dest_folder="${module_pair##*|}"
        local dest_path="$DEST/$dest_folder"

        echo ""
        echo "📂 $dest_folder ← NAS::$module"
        echo "─────────────────────────────────────────"

        local exclude_args=()
        for excl in "${EXCLUDES[@]:-}"; do
            [[ -n "$excl" ]] && exclude_args+=("--exclude=$excl")
        done

        local result
        result=$(sshpass -p "$NAS_PASS" rsync \
            --dry-run -rlt --itemize-changes --size-only \
            "${exclude_args[@]}" \
            "$NAS_USER@$NAS_HOST::$module/" \
            "$dest_path/" 2>/dev/null)

        local new_count changed_count deleted_count
        new_count=$(echo "$result" | grep -c "^>f+")
        changed_count=$(echo "$result" | grep -c "^>f\\.")
        deleted_count=$(echo "$result" | grep -c "^\\*deleting")

        if [[ "$new_count" -eq 0 && "$changed_count" -eq 0 && "$deleted_count" -eq 0 ]]; then
            echo "  ✅ In sync"
        else
            [[ "$new_count" -gt 0 ]] && echo "  ➕ New: $new_count"
            [[ "$changed_count" -gt 0 ]] && echo "  📝 Changed: $changed_count"
            [[ "$deleted_count" -gt 0 ]] && echo "  🗑  Will delete: $deleted_count"
        fi
    done
    echo ""
}

# Интерактивное меню (whiptail)
interactive_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "NAS Backup → T7" \
            --menu "Choose action:" 16 60 8 \
            "1" "Run backup" \
            "2" "Dry-run (simulate)" \
            "3" "Show diff (what will change)" \
            "4" "Edit config" \
            "5" "View last log" \
            "6" "Test connectivity" \
            "0" "Exit" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            1) do_backup ;;
            2) DRY_RUN=true do_backup ;;
            3) do_diff ;;
            4) edit_config ;;
            5) view_last_log ;;
            6) test_connectivity ;;
            0) break ;;
        esac

        echo ""
        echo "Press Enter to continue..."
        read -r
    done
}

# Редактирование конфига
edit_config() {
    sudo nano "$CONFIG"
    info "Config saved. Re-loading..."
    load_config
}

# Тест соединения
test_connectivity() {
    info "Testing $NAS_HOST..."
    if check_connectivity; then
        log "Connection OK"
        echo ""
        info "Available rsync modules on NAS:"
        sshpass -p "$NAS_PASS" rsync "$NAS_USER@$NAS_HOST::" 2>/dev/null || echo "  (cannot list)"
    fi
}

# Последний лог
view_last_log() {
    local log_dir="$DEST/_logs"
    if [[ ! -d "$log_dir" ]]; then
        warn "No logs yet"
        return
    fi
    local latest
    latest=$(ls -1t "$log_dir"/*.log 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
        less "$latest"
    else
        warn "No log files"
    fi
}

# Парсинг аргументов
DRY_RUN=false
ACTION="menu"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)
            ACTION="run"
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=true
            ACTION="run"
            shift
            ;;
        --diff|-d)
            ACTION="diff"
            shift
            ;;
        --config|-c)
            ACTION="config"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [OPTIONS]

  --run         Run backup immediately
  --dry-run     Simulate backup (no files copied)
  --diff        Show differences NAS vs T7
  --config      Edit config file
  (no args)     Interactive menu

Config: $CONFIG
EOF
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Главная логика
check_deps
load_config

case "$ACTION" in
    menu)
        if ! command -v whiptail &>/dev/null; then
            warn "whiptail not installed, falling back to direct run"
            do_backup
        else
            interactive_menu
        fi
        ;;
    run)
        do_backup
        ;;
    diff)
        do_diff
        ;;
    config)
        edit_config
        ;;
esac

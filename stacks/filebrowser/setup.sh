# Filebrowser pre-seed: задаём пароль детерминированно ДО старта сервера, чтобы
# образ не сгенерил случайный (как s6-вариант). Образ :v2 умеет config init /
# users add|update через CLI. БД (bbolt) залочена работающим сервером — поэтому
# сперва останавливаем контейнер (если жив), потом правим БД одноразовыми
# `docker run`, владельца чиним на 1000 (docker run пишет от root).
stack_pre() {
    local data="/mnt/storage/_appdata/filebrowser" db="/database/filebrowser.db"
    local img="filebrowser/filebrowser:v2"
    sudo install -d -o 1000 -g 1000 "$data"

    sudo mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_DIR/filebrowser.conf" ]] || \
        fetch_conf_example "filebrowser.conf.example" "$CONFIG_DIR/filebrowser.conf"
    local FB_USER="admin" FB_PASS="changeme"
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/filebrowser.conf" 2>/dev/null || true
    [[ -n "$FB_USER" ]] || FB_USER="admin"
    [[ "$FB_PASS" == "changeme" ]] && FB_PASS=""   # placeholder = ещё не задан

    # Креды не заданы (свежая установка) → спрашиваем в wizard, если есть терминал.
    # Иначе (--all / pipe) или если пароль оставили пустым — генерим случайный.
    if [[ -z "$FB_PASS" ]]; then
        if [[ -t 0 ]] && command -v whiptail &>/dev/null; then
            local nu np
            nu="$(whiptail --title "Filebrowser (:8082)" --inputbox \
                  "Логин для веб-морды Filebrowser:" 9 60 "$FB_USER" 3>&1 1>&2 2>&3)" || nu=""
            [[ -n "$nu" ]] && FB_USER="$nu"
            np="$(whiptail --title "Filebrowser (:8082)" --passwordbox \
                  "Пароль (пусто = сгенерю случайный, покажу в дашборде):" 9 64 3>&1 1>&2 2>&3)" || np=""
            FB_PASS="$np"
        fi
        if [[ -z "$FB_PASS" ]]; then
            # LC_ALL=C — иначе на UTF-8 locale tr давится бинарём (illegal byte seq).
            FB_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)"
            [[ ${#FB_PASS} -eq 16 ]] || FB_PASS="$(openssl rand -hex 8 2>/dev/null)"
            [[ -n "$FB_PASS" ]] || FB_PASS="admin1234"
            info "Filebrowser: пароль сгенерён (виден в дашборде → Services)"
        fi
        # Пишем креды в conf (дашборд читает FB_PASS). printf — без sed-экранирования.
        local U; U="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; U="${U:-root}"
        { printf '# Filebrowser креды (:8082). Записано setup.sh. Дашборд показывает.\n'
          printf 'FB_USER="%s"\n' "$FB_USER"
          printf 'FB_PASS="%s"\n' "$FB_PASS"; } | sudo tee "$CONFIG_DIR/filebrowser.conf" >/dev/null
        sudo chown "$U:$U" "$CONFIG_DIR/filebrowser.conf"
    fi
    sudo chmod 0600 "$CONFIG_DIR/filebrowser.conf" 2>/dev/null || true   # секрет → 600

    sudo docker stop filebrowser >/dev/null 2>&1 || true     # release bbolt lock
    [[ -f "$data/filebrowser.db" ]] || \
        sudo docker run --rm -v "$data:/database" "$img" config init -d "$db" >/dev/null 2>&1 || true
    # выставить/обновить пароль admin'а из conf (update если юзер уже есть, иначе add)
    if ! sudo docker run --rm -v "$data:/database" "$img" \
            users update "$FB_USER" --password "$FB_PASS" -d "$db" >/dev/null 2>&1; then
        sudo docker run --rm -v "$data:/database" "$img" \
            users add "$FB_USER" "$FB_PASS" --perm.admin -d "$db" >/dev/null 2>&1 || true
    fi
    sudo chown -R 1000:1000 "$data"
    info "Filebrowser: логин $FB_USER (пароль из filebrowser.conf)"
}

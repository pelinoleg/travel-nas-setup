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
    [[ -n "$FB_PASS" ]] || FB_PASS="changeme"
    local U; U="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; U="${U:-root}"
    sudo chown "$U:$U" "$CONFIG_DIR/filebrowser.conf"; sudo chmod 0600 "$CONFIG_DIR/filebrowser.conf"
    [[ "$FB_PASS" == "changeme" ]] && warn "Filebrowser: пароль 'changeme' — поставь свой в $CONFIG_DIR/filebrowser.conf и перезапусти setup"

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

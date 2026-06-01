# Filebrowser pre: appdata + конфиг с кредами. post: выставить логин/пароль
# (из filebrowser.conf) в уже поднятый контейнер.
stack_pre() {
    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/filebrowser
    sudo mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/filebrowser.conf" ]]; then
        fetch_conf_example "filebrowser.conf.example" "$CONFIG_DIR/filebrowser.conf"
    fi
    local U; U="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; U="${U:-root}"
    sudo chown "$U:$U" "$CONFIG_DIR/filebrowser.conf"; sudo chmod 0600 "$CONFIG_DIR/filebrowser.conf"
}

stack_post() {
    local FB_USER="" FB_PASS=""
    source "$CONFIG_DIR/filebrowser.conf" 2>/dev/null || true
    [[ -z "$FB_USER" ]] && FB_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
    [[ -z "$FB_USER" ]] && FB_USER="admin"
    [[ -z "$FB_PASS" ]] && FB_PASS="changeme"
    # Дождаться инициализации БД (дефолтный admin), затем выставить наши креды.
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sudo docker exec filebrowser filebrowser users ls >/dev/null 2>&1 && break
        sleep 2
    done
    sudo docker exec filebrowser filebrowser users add "$FB_USER" "$FB_PASS" --perm.admin 2>/dev/null \
        || sudo docker exec filebrowser filebrowser users update "$FB_USER" --password "$FB_PASS" 2>/dev/null || true
    [[ "$FB_USER" != "admin" ]] && sudo docker exec filebrowser filebrowser users rm admin 2>/dev/null || true
}

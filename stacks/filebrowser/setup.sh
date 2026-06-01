# Filebrowser (LSIO/s6): пароль admin'а генерится СЛУЧАЙНО в БД при первой
# инициализации. БД (bbolt) залочена работающим сервером — извне (docker exec)
# поменять нельзя. Поэтому не навязываем свой пароль, а ловим сгенерированный
# из логов → пишем в conf → дашборд показывает (page_services). Сменить можно
# в самой веб-морде (Settings → User Management).
stack_pre() {
    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/filebrowser
}

stack_post() {
    # Строка "User 'admin' initialized with randomly generated password: XXXX"
    # появляется ТОЛЬКО при первой инициализации (пустая БД). При adopt'е БД уже
    # есть → строки нет → держим ранее сохранённый conf.
    local pass="" i
    for i in $(seq 1 10); do
        pass="$(sudo docker logs filebrowser 2>&1 \
                | grep -oE 'randomly generated password: [A-Za-z0-9_./+-]+' \
                | tail -1 | awk '{print $NF}')"
        [[ -n "$pass" ]] && break
        sleep 1
    done
    if [[ -n "$pass" ]]; then
        sudo mkdir -p "$CONFIG_DIR"
        printf 'FB_USER="admin"\nFB_GENERATED_PASS="%s"\n' "$pass" \
            | sudo tee "$CONFIG_DIR/filebrowser.conf" >/dev/null
        local U; U="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; U="${U:-root}"
        sudo chown "$U:$U" "$CONFIG_DIR/filebrowser.conf"
        sudo chmod 0600 "$CONFIG_DIR/filebrowser.conf"
        info "Filebrowser admin / $pass  (сохранён в filebrowser.conf, виден в дашборде)"
    else
        warn "Filebrowser: пароль не найден в логах (БД уже инициализирована?) — 'docker logs filebrowser'"
    fi
}

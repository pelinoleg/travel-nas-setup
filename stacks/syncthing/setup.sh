# Syncthing pre: папки данных/конфига (PUID 1000), TZ в .env, тема Vellum.
# LSIO мапит /config → appdata; кастомные темы веб-морды лежат в <config>/gui/.
stack_pre() {
    sudo install -d -o 1000 -g 1000 /mnt/storage/sync
    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/syncthing
    # TZ + CPU-лимит хеширования (адаптивно под модель Pi) в .env.
    local model st_cpu; model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    case "$model" in
        *"Pi 5"*) st_cpu="2.5" ;;
        *"Pi 4"*) st_cpu="2.0" ;;
        *)        st_cpu="1.5" ;;
    esac
    printf 'TZ=%s\nST_CPU_LIMIT=%s\n' "$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)" "$st_cpu" \
        | sudo tee "$STACK_DIR/.env" >/dev/null

    # Тема Vellum (light+dark) для веб-морды. Кладём в <config>/gui/ — syncthing
    # покажет в Settings → GUI → Theme. Дефолт выставит stack_post. Тарболом,
    # чтобы не зависеть от git.
    local gui="/mnt/storage/_appdata/syncthing/gui" tmp src
    sudo install -d -o 1000 -g 1000 "$gui"
    tmp="$(mktemp -d)"
    if curl -fsSL "https://github.com/pelinoleg/syncthing-vellum/archive/refs/heads/main.tar.gz" \
            -o "$tmp/v.tgz" 2>/dev/null && tar -xzf "$tmp/v.tgz" -C "$tmp" 2>/dev/null; then
        src="$(find "$tmp" -maxdepth 1 -type d -name 'syncthing-vellum*' | head -1)"
        if [[ -n "$src" ]]; then
            sudo cp -R "$src/vellum-light" "$src/vellum-light" "$gui/" 2>/dev/null || true
            sudo chown -R 1000:1000 "$gui"
            info "Syncthing: тема Vellum (light+dark) установлена"
        fi
    else
        warn "Syncthing: не смог скачать тему Vellum (нет сети?) — поставишь позже из репо"
    fi
    rm -rf "$tmp"
}

stack_post() {
    # Выставить Vellum-light темой по умолчанию. config.xml syncthing создаёт при
    # первом старте — ждём его, правим <theme> при остановленном контейнере
    # (чтобы syncthing не перезатёр), перезапускаем. Идемпотентно.
    local cfg="/mnt/storage/_appdata/syncthing/config.xml" i
    for i in $(seq 1 15); do [[ -f "$cfg" ]] && break; sleep 1; done
    if [[ -f "$cfg" ]] && ! grep -q '<theme>vellum' "$cfg"; then
        sudo docker stop syncthing >/dev/null 2>&1 || true
        sudo sed -i 's#<theme>[^<]*</theme>#<theme>vellum-light</theme>#' "$cfg" 2>/dev/null || true
        sudo docker start syncthing >/dev/null 2>&1 || true
        info "Syncthing: тема по умолчанию → vellum-light"
    fi
}

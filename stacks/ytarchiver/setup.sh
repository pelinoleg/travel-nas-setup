# YT-Archiver pre/post. Адаптивный CPU-лимит под модель Pi; .env для compose;
# path-unit для авто-применения YT_CPU_LIMIT при правке конфига.
stack_pre() {
    # Папки данных (владелец = человек-юзер, чтобы yt-dlp мог писать).
    local U; U="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; U="${U:-root}"
    sudo install -d -o "$U" -g "$U" /mnt/storage/media/YT-Archiver/data
    sudo install -d -o "$U" -g "$U" /mnt/storage/media/YT-Archiver/video
    # cookies/ — опц. fallback (положи youtube.txt). Mount :ro, но папка нужна.
    sudo install -d -o "$U" -g "$U" /mnt/storage/media/YT-Archiver/cookies

    # Дефолт CPU-лимита под модель Pi (Pi5 быстрее → больше ядер).
    local model; model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    local yt_def; case "$model" in
        *"Pi 5"*) yt_def="2.5" ;; *"Pi 4"*) yt_def="2.0" ;; *) yt_def="1.5" ;;
    esac
    local ram_kb; ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    (( ram_kb > 0 && ram_kb < 2000000 )) && warn "Мало RAM (<2GB) — yt-archiver будет впритык"
    local mem; mem=$(( ram_kb > 0 ? ram_kb * 1024 / 4 * 3 : 6000000000 ))

    # Конфиг (источник правды для YT_CPU_LIMIT, правится юзером/дашбордом).
    sudo mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/yt-archiver.conf" ]]; then
        fetch_conf_example "yt-archiver.conf.example" "$CONFIG_DIR/yt-archiver.conf"
        sudo sed -i "s/^YT_CPU_LIMIT=.*/YT_CPU_LIMIT=\"$yt_def\"/" "$CONFIG_DIR/yt-archiver.conf"
    fi
    sudo chown "$U:$U" "$CONFIG_DIR/yt-archiver.conf"; sudo chmod 0644 "$CONFIG_DIR/yt-archiver.conf"

    local YT_CPU_LIMIT=""; source "$CONFIG_DIR/yt-archiver.conf" 2>/dev/null || true
    YT_CPU_LIMIT="${YT_CPU_LIMIT:-$yt_def}"
    [[ "$YT_CPU_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || YT_CPU_LIMIT="$yt_def"

    # .env рядом с compose — docker compose подставит ${YT_CPU_LIMIT}/${MEM_LIMIT}.
    printf 'YT_CPU_LIMIT=%s\nMEM_LIMIT=%s\n' "$YT_CPU_LIMIT" "$mem" | sudo tee "$STACK_DIR/.env" >/dev/null
}

stack_post() {
    # Авто-применение YT_CPU_LIMIT при правке yt-archiver.conf (path-unit) и на boot.
    write_systemd_unit yt-cpu-apply.service << 'U'
[Unit]
Description=Apply YT-Archiver CPU limit from yt-archiver.conf
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
# Применяет лимит из conf к живому контейнеру (docker update) И синхронит .env
# стека — иначе при пересоздании контейнера (recreate/pull) docker compose взял
# бы стейл-значение из .env, и лимит откатился бы.
ExecStart=/bin/bash -c 'source /etc/travel-nas/yt-archiver.conf 2>/dev/null; [[ "${YT_CPU_LIMIT:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || exit 0; docker update --cpus="$YT_CPU_LIMIT" ytarchiver-backend 2>/dev/null || true; env=/opt/stacks/ytarchiver/.env; [[ -f "$env" ]] && sed -i "s/^YT_CPU_LIMIT=.*/YT_CPU_LIMIT=$YT_CPU_LIMIT/" "$env" || true'

[Install]
WantedBy=multi-user.target
U
    write_systemd_unit yt-cpu-apply.path << 'U'
[Unit]
Description=Watch yt-archiver.conf for CPU-limit changes

[Path]
PathChanged=/etc/travel-nas/yt-archiver.conf
Unit=yt-cpu-apply.service

[Install]
WantedBy=paths.target
U
    sudo systemctl daemon-reload
    sudo systemctl enable --now yt-cpu-apply.service yt-cpu-apply.path
}

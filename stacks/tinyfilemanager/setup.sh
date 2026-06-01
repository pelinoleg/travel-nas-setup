# TinyFileManager pre: appdata + config.php с кредами. Пароль хешируется bcrypt'ом
# (php самого образа — он всё равно тянется; fallback htpasswd). config.php
# монтируется в контейнер :ro и переопределяет дефолты ($auth_users, $root_path).
stack_pre() {
    local app="/mnt/storage/_appdata/tinyfilemanager"
    sudo install -d -o 1000 -g 1000 "$app"
    printf 'TZ=%s\n' "$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)" | sudo tee "$STACK_DIR/.env" >/dev/null

    sudo mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_DIR/tinyfilemanager.conf" ]] || \
        fetch_conf_example "tinyfilemanager.conf.example" "$CONFIG_DIR/tinyfilemanager.conf"
    local TFM_USER="admin" TFM_PASS="changeme"
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/tinyfilemanager.conf" 2>/dev/null || true
    [[ -n "$TFM_USER" ]] || TFM_USER="admin"
    [[ -n "$TFM_PASS" ]] || TFM_PASS="changeme"
    local U; U="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; U="${U:-root}"
    sudo chown "$U:$U" "$CONFIG_DIR/tinyfilemanager.conf"; sudo chmod 0600 "$CONFIG_DIR/tinyfilemanager.conf"

    # bcrypt-хеш ($2y$...) пароля
    local hash=""
    hash="$(sudo docker run --rm --entrypoint php tinyfilemanager/tinyfilemanager:master \
            -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS" 2>/dev/null)"
    if [[ "$hash" != \$2* ]]; then
        hash="$(htpasswd -bnBC 10 "" "$TFM_PASS" 2>/dev/null | tr -d ':\n' | sed 's/^[^$]*//')"
    fi

    if [[ "$hash" == \$2* ]]; then
        printf '<?php\n$use_auth = true;\n$auth_users = array(\n    %s => %s,\n);\n$root_path = %s;\n' \
            "'$TFM_USER'" "'$hash'" "'/var/www/html/data'" | sudo tee "$app/config.php" >/dev/null
        info "TinyFileManager: логин $TFM_USER (пароль из tinyfilemanager.conf)"
    else
        printf '<?php\n$use_auth = false;\n$root_path = %s;\n' "'/var/www/html/data'" \
            | sudo tee "$app/config.php" >/dev/null
        warn "TinyFileManager: не сгенерил bcrypt-хеш → авторизация ОТКЛЮЧЕНА. Задай пароль в $app/config.php"
    fi
    sudo chown 1000:1000 "$app/config.php"
}

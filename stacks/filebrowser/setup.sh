# Filebrowser Quantum pre: data-каталог + config.yaml с детерминированными
# кредами (auth.adminPassword) и источниками (/srv/storage + /srv/config).
# Пароль сидится из filebrowser.conf при ПЕРВОМ старте (пустая БД). Меняешь
# пароль — в самой веб-морде, либо снеси БД в _appdata/filebrowser-quantum и
# перезапусти setup. config.yaml пишется python'ом (безопасное YAML-квотирование).
stack_pre() {
    local data="/mnt/storage/_appdata/filebrowser-quantum"
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

    local tmp; tmp="$(mktemp)"
    python3 - "$tmp" "$FB_USER" "$FB_PASS" <<'PY'
import sys
path, user, pw = sys.argv[1], sys.argv[2], sys.argv[3]
def q(s): return "'" + s.replace("'", "''") + "'"   # безопасное YAML single-quote
open(path, "w").write(f"""server:
  port: 8080
  sources:
    - path: "/srv/storage"
      config:
        defaultEnabled: true
    - path: "/srv/config"
auth:
  adminUsername: {q(user)}
  adminPassword: {q(pw)}
  methods:
    password:
      enabled: true
""")
PY
    sudo install -o 1000 -g 1000 -m 600 "$tmp" "$data/config.yaml"
    rm -f "$tmp"
    info "Filebrowser (Quantum): логин $FB_USER (пароль из filebrowser.conf)"
}

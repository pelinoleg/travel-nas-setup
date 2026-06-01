[[ -n "${DO_DOCKER:-}" ]] || return 0

info "=== Docker ==="

# Docker уже стоит → не переустанавливаем (идемпотентно при повторном setup).
if command -v docker &>/dev/null && sudo docker info &>/dev/null; then
    info "Docker уже установлен ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
elif (
    set -e
    apt_install ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt_get update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
); then
    info "Docker установлен"
else
    mark_fail "DOCKER" "install failed"
    return 0
fi

sudo systemctl enable --now docker 2>/dev/null || true

# Docker должен стартовать ПОСЛЕ монтирования /mnt/storage. Иначе на ребуте
# daemon поднимается раньше fstab-mount'а → stateful-контейнеры (photoview-db,
# ytarchiver) биндятся на пустой mountpoint (диск ещё не примонтирован) → видят
# пустые данные / падают. RequiresMountsFor заставляет ждать mount-юнит диска.
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/wait-storage.conf >/dev/null << 'EOF'
[Unit]
RequiresMountsFor=/mnt/storage
EOF
sudo systemctl daemon-reload 2>/dev/null || true

# Юзер (uid 1000) в группу docker — чтобы docker без sudo (применится после релогина).
INSTALL_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
[[ -n "$INSTALL_USER" ]] && sudo usermod -aG docker "$INSTALL_USER" 2>/dev/null || true

# docker-mgr.sh — обёртка для dashboard/tg-listener (list/start/stop/restart/audit).
fetch_script "docker-mgr.sh" "$SCRIPT_DIR/docker-mgr.sh"

# memory cgroup: PiOS по умолчанию его ВЫКЛЮЧАЕТ (в cmdline стоит
# cgroup_disable=memory; cgroup.controllers = cpuset cpu io pids, без memory) →
# docker memory-лимиты молча отбрасываются ("kernel does not support memory
# limit"). Чиним: убираем disable + добавляем enable. cmdline.txt — ОДНА строка.
CMDLINE=/boot/firmware/cmdline.txt
if [[ -f "$CMDLINE" ]]; then
    CHANGED=""
    if grep -q 'cgroup_disable=memory' "$CMDLINE"; then
        sudo sed -i 's/ *cgroup_disable=memory//g' "$CMDLINE"; CHANGED=1
    fi
    if ! grep -q 'cgroup_enable=memory' "$CMDLINE"; then
        sudo sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"; CHANGED=1
    fi
    [[ -n "$CHANGED" ]] && warn "Включил memory cgroup в cmdline.txt — применится после reboot (docker memory-лимиты заработают)."
fi

# NetworkManager: игнорим docker bridge/veth/br-* интерфейсы. Без этого
# каждый docker start/stop генерит NM state-change → desktop notification
# с именем вида "You are now connected to vetha45aeae" → выглядит как
# непонятные символы (по факту это имя docker veth-интерфейса).
if [[ -d /etc/NetworkManager/conf.d ]]; then
    sudo tee /etc/NetworkManager/conf.d/no-docker.conf >/dev/null << 'EOF'
# Travel-NAS: NM ignore docker bridges/veths. Без этого popup при
# docker start/stop с именем veth-интерфейса (выглядит как мусор).
[keyfile]
unmanaged-devices=interface-name:veth*;interface-name:docker*;interface-name:br-*
EOF
    sudo systemctl reload NetworkManager 2>/dev/null || true
fi

mark_ok "DOCKER" "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d , || echo installed)"

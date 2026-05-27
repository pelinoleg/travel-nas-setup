[[ -n "${DO_SAMBA:-}" ]] || return 0

info "=== Samba ==="
if (
    set -e
    if ! command -v smbd &>/dev/null; then
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y samba samba-common-bin
    fi
    if mountpoint -q "$T7_MOUNT"; then
        SHARE_PATH="$T7_MOUNT"
    else
        SHARE_PATH="/home/$(whoami)/share"
        sudo mkdir -p "$SHARE_PATH"
        sudo chmod 777 "$SHARE_PATH"
    fi
    if ! sudo grep -q "^\[travel-nas\]" /etc/samba/smb.conf 2>/dev/null; then
        sudo tee -a /etc/samba/smb.conf > /dev/null << EOF

[travel-nas]
   comment = Travel NAS storage
   path = $SHARE_PATH
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   create mask = 0666
   directory mask = 0777
   force user = nobody
   force group = nogroup
EOF
    fi
    sudo systemctl restart smbd nmbd
    sudo systemctl enable smbd nmbd
); then
    mark_ok "SAMBA"
else
    mark_fail "SAMBA" "install/config failed"
fi

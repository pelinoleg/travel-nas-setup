[[ -n "${DO_CONF_PERMS:-}" ]] || return 0

info "=== Conf perms auto-restore (path-unit) ==="
if (
    set -e
    fetch_script "fix-conf-perms.sh" "$SCRIPT_DIR/fix-conf-perms.sh"

    write_systemd_unit fix-conf-perms.service << 'EOF'
[Unit]
Description=Restore correct ownership/mode of /etc/travel-nas/ files

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-conf-perms.sh
EOF

    write_systemd_unit fix-conf-perms.path << 'EOF'
[Unit]
Description=Watch /etc/travel-nas/ for file changes

[Path]
# PathChanged триггерит когда любой файл в директории закрылся после записи
# (inotify IN_CLOSE_WRITE). То есть после того как редактор сохранил.
PathChanged=/etc/travel-nas

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now fix-conf-perms.path
    # Однократный прогон сейчас — выровнять текущее состояние
    sudo /usr/local/bin/fix-conf-perms.sh
); then
    mark_ok "CONF_PERMS" "path-unit активен, лог в /var/lib/travel-nas/fix-conf-perms.log"
else
    mark_fail "CONF_PERMS" "setup failed"
fi

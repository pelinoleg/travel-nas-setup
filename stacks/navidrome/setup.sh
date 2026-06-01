# Navidrome pre: appdata (база/кэш) + папка музыки. Владелец 1000 — контейнер
# бежит user 1000:1000. Кидай музыку в /mnt/storage/media/Music (или через Samba).
stack_pre() {
    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/navidrome
    sudo install -d -o 1000 -g 1000 /mnt/storage/media/Music
}

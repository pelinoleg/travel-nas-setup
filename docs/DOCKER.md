# Docker + Dockge стеки

Раньше Docker-приложениями рулил **CasaOS**. Его убрали — он держал порт 80
(ломал comitup captive-portal в поле), ставил devmon (асинхронный авто-маунт
ломал формат диска) и был тяжёлым. Теперь:

- **Docker** ставится напрямую (apt-репо `download.docker.com`) — модуль `16-docker.sh`.
- **Dockge** (`louislam/dockge`) — лёгкий web-менеджер docker-compose стеков, `:5001`.
- Приложения — отдельные **стеки** в `/opt/stacks/`.

## Конвенция стеков
```
/opt/stacks/<name>/compose.yaml      # каждый стек: каталог + compose.yaml
/opt/dockge/compose.yaml             # сам Dockge (НЕ в /opt/stacks)
```
- Файл строго `compose.yaml` (Dockge сканит именно его), НЕ `docker-compose.yml`.
- В каждом compose обязателен `name: <project>` — стабильное имя compose-проекта,
  чтобы `docker-mgr.sh` и Dockge находили стек независимо от каталога.
- **Кто поднимает**: модуль делает первый `docker compose up -d` (стек сразу живой);
  Dockge показывает его в UI (тот же проект — конфликта нет). Дальше управляешь
  через Dockge ИЛИ `cd /opt/stacks/<name> && docker compose up -d`.

## Порты
| Сервис | Порт | |
|---|---|---|
| comitup captive-portal | **80** | детект «войти в сеть» бьёт в :80 |
| Dockge | 5001 | менеджер стеков |
| Photoview | 8000 | фото-галерея |
| yt-archiver | 8081 | YouTube-архиватор |
| Syncthing | 8384 | синхронизация (+22000 sync, 21027 discovery) |
| Filebrowser | 8082 | файлы + редактор конфигов |

## Стеки
- **photoview** — `/opt/stacks/photoview`, БД на `/mnt/storage/_appdata/photoview` (mariadb uid 999), диск как `/storage:ro`.
- **ytarchiver** — `/opt/stacks/ytarchiver`, данные `/mnt/storage/media/YT-Archiver`. CPU-лимит через `YT_CPU_LIMIT` в `yt-archiver.conf` (см. модуль 18).
- **syncthing** — PUID/PGID=1000, данные `/mnt/storage/sync`, конфиг `/mnt/storage/_appdata/syncthing`.
- **filebrowser** — PUID/PGID=1000, монтирует `/mnt/storage` (`/srv/storage`) и `/etc/travel-nas` (`/srv/config`).

## Filebrowser — безопасность
Монтирует **весь** `/etc/travel-nas/` (вкл. секреты: токен бота, пароль NAS) и
бежит PUID=1000 (иначе не прочитать 600-секреты). Любой, кто залогинится в
веб-морду, видит секреты. Поэтому:
- Креды в `/etc/travel-nas/filebrowser.conf` (`FB_USER`/`FB_PASS`, **не** в git).
- Поставь нормальный пароль (НЕ переиспользуй login/sudo). Не открывай :8082 наружу.
- После правки конфига через веб `CONF_PERMS` path-unit вернёт owner/mode (600 секретам).

## Memory cgroup
PiOS по умолчанию выключает memory cgroup (`cgroup_disable=memory` в cmdline) →
docker memory-лимиты молча отбрасываются. Модуль `16-docker.sh` чинит cmdline
(убирает disable, добавляет `cgroup_enable=memory cgroup_memory=1`) — **нужен reboot**.
CPU-лимиты работают и без этого.

## Миграция с CasaOS (существующие установки)
1. `casaos-uninstall` — выбрать «оставить Docker». Освобождает :80.
2. Перезапустить `setup.sh` (DOCKER детектит существующий Docker → не переставляет;
   стеки адаптируют существующие контейнеры по `name:`; comitup флипает на :80).
3. Опц. `rm -rf /var/lib/casaos /etc/casaos /etc/conf.d/devmon`.

Модуль `16-docker.sh` сам детектит остатки CasaOS и печатает предупреждение.
Альтернатива — чистая перепрошивка (для новых сборок).

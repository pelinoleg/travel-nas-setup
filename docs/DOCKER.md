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
- **Кто поднимает**: `17-stacks.sh` делает первый `docker compose up -d` (стек сразу
  живой); Dockge показывает его в UI (тот же проект — конфликта нет). Дальше управляешь
  через Dockge ИЛИ `cd /opt/stacks/<name> && docker compose up -d`.

## Как добавить приложение
Стеки лежат в репо в `stacks/<name>/` и авто-обнаруживаются — **новый модуль не нужен**:
```
stacks/<name>/
  compose.yaml     # сам compose, обязателен `name: <name>` (= имя каталога)
  meta.conf        # LABEL="Имя — описание"  PORT=NNNN  (для wizard + dashboard)
  setup.sh         # ОПЦ. хуки stack_pre()/stack_post() — папки/права/.env/units
```
1. Создай каталог + три файла (setup.sh опционален).
2. Допиши имя каталога строкой в `stacks/index.txt`.
3. `git push` → на устройстве `travel-nas-setup` → wizard покажет `STACK_<NAME>` галкой.

`17-stacks.sh` для каждого выбранного `DO_STACK_<NAME>`: `stack_pre` → копирует
`compose.yaml` в `/opt/stacks/<name>/` → `docker compose up -d` → `stack_post`.
`.env` рядом с compose подхватывается автоматически (используется для `${YT_CPU_LIMIT}`,
`${TZ}` и т.п.) — пиши его в `stack_pre`.

## Порты
| Сервис | Порт | |
|---|---|---|
| comitup captive-portal | **80** | детект «войти в сеть» бьёт в :80 |
| Dockge | 5001 | менеджер стеков |
| Photoview | 8000 | фото-галерея |
| yt-archiver | 8081 | YouTube-архиватор |
| Syncthing | 8384 | синхронизация (+22000 sync, 21027 discovery) |
| Filebrowser | 8082 | файлы + редактор конфигов |
| Dozzle | 8083 | live-логи контейнеров (stateless) |

## Стеки
- **photoview** — `/opt/stacks/photoview`, БД на `/mnt/storage/_appdata/photoview` (mariadb uid 999), диск как `/storage:ro`.
- **ytarchiver** — `/opt/stacks/ytarchiver`, данные `/mnt/storage/media/YT-Archiver`. CPU/RAM-лимит через `${YT_CPU_LIMIT}`/`${MEM_LIMIT}` в `.env` (пишется `stack_pre`, адаптивно по модели Pi).
- **syncthing** — PUID/PGID=1000, данные `/mnt/storage/sync`, конфиг `/mnt/storage/_appdata/syncthing`.
- **filebrowser** — PUID/PGID=1000, монтирует `/mnt/storage` (`/srv/storage`) и `/etc/travel-nas` (`/srv/config`).
- **dozzle** — live-логи контейнеров, читает `docker.sock:ro`. Stateless (нет appdata, нет setup.sh).

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

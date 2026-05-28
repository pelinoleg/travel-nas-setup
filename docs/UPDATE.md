# travel-nas-update — две скорости

В travel-NAS три команды для разной частоты:

| Команда | Что делает | Когда |
|---|---|---|
| `travel-nas-update` | Тянет наши скрипты с GitHub, рестартит `tg-listener` + dashboard. ~30 сек. | После любого `git push` в `pelinoleg/travel-nas-setup` |
| **`travel-nas-update --full`** | То же + **apt upgrade + docker pull/up**. ~5-15 мин. | Раз в неделю-две на стационаре. Не в дороге (может потащить kernel → reboot). |
| `travel-nas-setup` | Полный whiptail-wizard. Меняет /etc/travel-nas/, systemd-units, sudoers, NetworkManager. Долго. | При добавлении новой компоненты или после реинсталла microSD. |

## Что делает `--full`

После обычного fast-update (наши скрипты + restart):

1. **`apt-get update && apt-get upgrade -y`**
   - С `--force-confold` чтобы кастомизированные конфиги (sshd_config и т.п.) не перетёрлись
   - Считает сколько пакетов реально обновилось (`grep "^Setting up "`)
   - Если есть `/var/run/reboot-required` — выставляет флаг `REBOOT_NEEDED`
   - Tailscale обновляется тут же (он установлен из своего apt-репо)

2. **Docker compose pull + up -d** по всем CasaOS-приложениям
   - Идёт по `/var/lib/casaos/apps/*/docker-compose.yml`
   - `docker compose pull --quiet` (тянет свежие образы)
   - `docker compose up -d` (перезапускает только то, у чего образ изменился)
   - В конце `docker image prune -f` — чистит старые образы (могут весить десятки GB)

## Запуск

### Из терминала

```bash
travel-nas-update          # fast
travel-nas-update --full   # full
travel-nas-update --help   # справка
```

### Из Telegram

```
/update         — fast
/update full    — full
```

После завершения бот сам пришлёт `✅ Update done` со сводкой и хвостом лога.
Если был флаг `REBOOT_NEEDED` — сообщение содержит «⚠ Нужен reboot».

### С рабочего стола

Ярлык **Update** (на десктопе LXDE) запускает fast-режим. Для full — открой
терминал и набери `travel-nas-update --full`.

## Что НЕ делает (никогда)

- **Не трогает** `/etc/travel-nas/*.conf` — твои настройки сохраняются между запусками
- **Не создаёт** systemd-units / sudoers (только sync существующих) — это работа `travel-nas-setup`
- **Не делает ребут сам** — только печатает варнинг. Хочешь ребутнуть — `sudo reboot`

## Why split `fast` and `full`

`fast` создан под итерации разработки — поправил скрипт в репо, пушнул, на Pi
`travel-nas-update`, через 30 сек тестим. **`apt upgrade` каждый раз тут не нужен**:
он берёт минуты и иногда требует reboot.

`full` нужен раз в 1-2 недели чтобы:
- Получить kernel-патчи безопасности
- Обновить Photoview / yt-archiver / CasaOS до свежих docker-образов
- Закрыть CVE в системных пакетах (например, openssh)

В **дороге запускай только `fast`**. `--full` может потребовать reboot после
kernel-обновы — на powerbank'е и без второго устройства это рискованно.

## Marker и Telegram

После завершения скрипт пишет `/tmp/travel-nas-update.done` (одно- или
многострочный):

```
21 ok / 21 fetched, sudoers +1
apt: 3 upgraded, docker: 2 apps
REBOOT_NEEDED
```

`tg-listener` при старте читает этот marker и шлёт `✅ Update done` —
работает даже если бот сам был перезапущен в процессе апдейта.

# Thermal guard

Sustained-temperature защита. Если CPU temp Pi держится высоко **подряд несколько минут** — `thermal-guard.py` поэтапно ограничивает / морозит / стопит docker-контейнер с максимальной нагрузкой. Когда остынет — всё откатывается.

Поверх существующего `power-mode auto` (тот переключает governor в saver при 75°C). Thermal-guard это **второй слой** для случаев когда saver-уровень не справился.

## Стадии

| Стадия | Триггер (по умолчанию) | Действие |
|---|---|---|
| 1. **throttle** | temp ≥ 80°C × 3 мин подряд | `docker update --cpus=0.5` на top-CPU контейнер |
| 2. **pause**    | temp ≥ 82°C × 3 мин подряд (на следующем кандидате) | `docker pause <c>` (freeze cgroup'ом) |
| 3. **stop**     | temp ≥ 85°C × 3 мин подряд | `docker stop <c>` |
| restore         | temp ≤ 70°C × 5 мин подряд | Откат всех actions: cpu-limit reset / unpause / start |

Эскалация идёт **по разным контейнерам**, не на одном. Если throttle на ytarchiver не помог — следующая жертва другой top-CPU контейнер. Это сохраняет работающие сервисы как можно дольше.

## Конфиг

`/etc/travel-nas/thermal-guard.conf`:

```bash
ENABLED=true               # главный выключатель
MODE=warn                  # warn = только TG-алёрт; auto = реально эскалирует
SUSTAINED_MIN=3            # сколько минут подряд должно быть жарко
THROTTLE_TEMP=80
PAUSE_TEMP=82
STOP_TEMP=85
COOLDOWN_TEMP=70
COOLDOWN_MIN=5
EXCLUDE_REGEX=-db(-\d+)?$|^casaos  # *-db и casaos не трогать
EXCLUDE_DURING_BACKUP=true # nas-backup идёт — не вмешиваемся
CPUS_THROTTLE=0.5          # сколько ядер оставлять при throttle
```

## По умолчанию: MODE=warn

При первой установке скрипт **ничего не делает**, только шлёт TG-алёрт когда стабильно жарко. Это даёт неделю-две посмотреть как часто триггерится без риска.

Чтобы включить реальные действия:

```bash
# через TG:
/thermal mode auto

# или вручную:
sudo sed -i 's/^MODE=.*/MODE=auto/' /etc/travel-nas/thermal-guard.conf
```

## Telegram

```
/thermal               — статус (temp, mode, actions list, thresholds)
/thermal enable        — включить
/thermal disable       — выключить (timer остаётся, скрипт молча выходит)
/thermal mode warn     — только алёрты
/thermal mode auto     — реальные эскалации
/thermal restore       — форс-откат всех текущих actions
```

## Что и когда делает

```
t=0   temp=85°C  → counter=1
t=1   temp=84°C  → counter=2
t=2   temp=85°C  → counter=3 ≥ SUSTAINED_MIN
                ↓
       docker stats → top CPU = ytarchiver-backend (62%)
       не в exclude → ESCALATE → docker update --cpus=0.5
                ↓
       TG: "🌡 Thermal escalation: ytarchiver-backend → throttle"
       counter сбрасывается в 0 (антиспам)

t=3-6 temp=82°C  → counter=1..4
t=7   temp=83°C  → counter=5
                ↓
       (temp всё ещё ≥ PAUSE_TEMP) → следующий top-CPU кандидат
       Если ytarchiver-backend всё ещё лидер с 0.5 CPU — escalate его до pause.
       Иначе берём следующий.

…

t=N   temp=68°C → cool_counter=1
t=N+1 temp=67°C → cool_counter=2
…
t=N+4 temp=66°C → cool_counter=5 ≥ COOLDOWN_MIN
                ↓
       restore_all: unpause / start / cpu-limit reset
       TG: "🌡 Thermal recovery: restored ytarchiver-backend"
```

## Защита от глупостей

- **Backup interlock** — пока `nas-backup-runtime` бежит, **никаких** действий. Бэкап генерит температуру, но прервать = битый архив.
- **Exclude regex** — по умолчанию защищены `*-db` (БД) и `casaos`. Можно расширить.
- **MODE=warn по умолчанию** — первое впечатление без риска.
- **Restore идемпотентен** — если ты вручную стартанул остановленный контейнер, `restore_all` не сломается; просто `docker start` второй раз = no-op.
- **`/thermal restore`** в TG — экстренная кнопка вернуть всё прямо сейчас.

## Логи

```
/mnt/t7/_logs/thermal-guard.log   — каждый tick + эскалации
sudo journalctl -u thermal-guard.service   — systemd-уровень
cat /var/lib/travel-nas/thermal-guard.state.json   — state (actions, counters)
```

## Удалить

```bash
sudo systemctl disable --now thermal-guard.timer
sudo rm /etc/systemd/system/thermal-guard.{service,timer}
sudo systemctl daemon-reload
sudo /usr/local/bin/thermal-guard.py --restore   # откат если что-то применил
```

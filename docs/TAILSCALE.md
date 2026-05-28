# Tailscale на travel-NAS

Tailscale — zero-config VPN на базе WireGuard. После установки Pi становится
доступен с **любого устройства в твоём tailnet** (другой ноутбук, телефон) **из
любой сети мира** — без проброса портов, DDNS и публичного IP.

## Зачем это в travel-NAS

- Photoview / Samba / SSH доступны из отеля / кафе / самолёта без сложной настройки
- SSH через Tailscale работает **без публичных ключей и паролей** (опция `--ssh`)
- Если кто-то украдёт powerbank + Pi — без твоего Tailscale-аккаунта они не подключатся

## Установка

В whiptail-меню `travel-nas-setup` отметь `TAILSCALE` (включён по умолчанию).

Что произойдёт:
1. `curl -fsSL https://tailscale.com/install.sh | sudo sh` — добавит apt-repo и поставит пакет
2. `systemctl enable --now tailscaled` — запустит демон
3. `sudo tailscale up --ssh --hostname=$(hostname) --operator=$USER --accept-routes` — попросит авторизацию

На экране появится URL вида:
```
To authenticate, visit: https://login.tailscale.com/a/abc123def...
```

Открой URL **на телефоне / ноутбуке** → залогинься (Google / GitHub / Microsoft) → жми **Approve**.

Скрипт сам продолжит как только Tailscale получит ключ. Авторизоваться нужно **один раз** — ключ сохраняется в `/var/lib/tailscale/`.

### Что значат флаги

| Флаг | Зачем |
|---|---|
| `--ssh` | Включает Tailscale SSH — можно `ssh oleg@travel-nas` из tailnet без публичных ключей |
| `--hostname=$(hostname)` | Имя устройства в админке (https://login.tailscale.com/admin/machines) |
| `--operator=$USER` | Юзер `oleg` сможет вызывать `tailscale status/ip` без `sudo` — нужно дашборду |
| `--accept-routes` | Принимать subnet-routes других устройств (если ты настроишь advertised routes на роутере) |

## Где смотреть статус

### Dashboard (страница Network)

В нижней секции:
- `Tailscale: online / offline`
- `TS IP` — 100.x.x.x
- `magic DNS` — `travel-nas.tailnet-xyz.ts.net`
- `peers` — сколько других устройств в tailnet

### Telegram

```
/tailscale    или    /ts
```

Покажет:
- BackendState (Running / NeedsLogin / Stopped)
- Tailscale IP + magic DNS этого устройства
- До 6 peer'ов с их статусом (🟢/⚪) и IP
- Готовую `ssh` команду для подключения

### CLI

```bash
tailscale status         # peers + IP
tailscale ip -4          # только IP этого устройства
tailscale ping <peer>    # latency до другого устройства в tailnet
```

## Как подключаться отсюда

С другого устройства которое **тоже в твоём tailnet**:

```bash
# SSH через Tailscale (--ssh флаг на Pi устранил необходимость в ключах)
ssh oleg@travel-nas                        # magic DNS
ssh oleg@100.x.x.x                         # прямой IP

# Photoview через Tailscale
http://travel-nas:8000

# Samba через Tailscale (Finder → ⌘K)
smb://travel-nas/travel-nas
```

Никакого VPN-клиента на mac/телефон ставить отдельно не надо — после установки
**Tailscale-приложения** (https://tailscale.com/download) оно само поднимет туннель.

## Безопасность

- Ключ устройства в `/var/lib/tailscale/tailscaled.state` (root-readable)
- ACL'ы по умолчанию: «все мои устройства видят все мои устройства» — норма для домашнего tailnet
- Можно ограничить через https://login.tailscale.com/admin/acls если paranoid
- Не нужно открывать порты в роутере — Tailscale делает NAT-traversal сам (DERP-relay если не получается)

## Troubleshooting

### `tailscale status` говорит NeedsLogin

```bash
sudo tailscale up --ssh --hostname=$(hostname) --operator=$USER
```
Открой URL, авторизуйся снова.

### IP не назначился

```bash
sudo systemctl restart tailscaled
sleep 3
sudo tailscale status
```

### Peer недоступен (ping не идёт)

- Проверь что у тебя есть интернет вообще: `ping 1.1.1.1`
- Проверь что peer Online: `tailscale status | grep <peer-name>`
- Если оба за strict NAT — Tailscale автоматически фолбэкнется на DERP-relay (медленнее но работает)

### Удалить Tailscale полностью

```bash
sudo tailscale logout
sudo systemctl disable --now tailscaled
sudo apt-get remove --purge tailscale
sudo rm -rf /var/lib/tailscale
```

## Telegram-команды (краткое резюме)

| Команда | Действие |
|---|---|
| `/tailscale` | Полный статус + список peer'ов |
| `/ts` | Алиас для `/tailscale` |

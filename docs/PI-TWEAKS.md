# Pi-specific tweaks

Модуль `24-pi-tweaks.sh` ставит 4 настройки, специфичные для Raspberry Pi (5/4) в роли travel-NAS. Они не критичны для базовой работы, но заметно улучшают надёжность и сетевую отзывчивость.

## 1. Hardware watchdog (BCM2712)

**Зачем:** если ядро завесится (kernel panic, deadlocked I/O wait — мы видели такое при hot-pull T7), watchdog-чип на BCM2712 сам ребутает Pi через 15 сек. На travel-кейсе где никто не подойдёт — это разница между «вернулись утром, всё работает» и «потеряли день».

**Что делает модуль:**
- `dtparam=watchdog=on` в `/boot/firmware/config.txt` (даёт `/dev/watchdog`)
- `apt install watchdog`
- `/etc/watchdog.conf` с разумными порогами:
  - `watchdog-timeout = 15` сек
  - `max-load-1 = 24` (для Pi 5 норма под полной нагрузкой ~6)
  - `realtime = yes` (watchdog-daemon не свопится сам)
- `systemctl enable --now watchdog`

**Требует reboot** один раз — `/dev/watchdog` появляется только после device-tree apply.

**Удалить:**
```bash
sudo systemctl disable --now watchdog
sudo sed -i '/^dtparam=watchdog=on/d' /boot/firmware/config.txt
sudo apt remove watchdog
sudo reboot
```

## 2. EEPROM auto-update (Pi 5 firmware)

**Зачем:** EEPROM на Pi 5 содержит bootloader и USB/PCIe init. Broadcom выпускает обновления почти ежемесячно — фиксят USB-SSD stability (наш use case), PCIe init bugs, и т.п. Без auto-update легко жить на firmware годовой давности с известными багами.

**Что делает модуль:**
- `apt install rpi-eeprom` (обычно уже стоит на PiOS)
- systemd-timer `eeprom-check.timer` запускает раз в месяц:
  ```
  /usr/bin/rpi-eeprom-update -a
  ```
- `-a` означает «применить если есть свежее». Если новое — bootloader обновится на следующем reboot.

**Удалить:**
```bash
sudo systemctl disable --now eeprom-check.timer
sudo rm /etc/systemd/system/eeprom-check.{service,timer}
sudo systemctl daemon-reload
```

## 3. WiFi powersave OFF

**Зачем:** PiOS по дефолту включает WiFi powersave — экономит ~10мВт, но добавляет 50-150 мс латентности на первый пакет после простоя. На NAS-юзкейсе с Samba это **виден лаг** когда тыкаешь файл в Finder: пауза перед началом загрузки.

**Что делает модуль:**
- Для каждого сохранённого `802-11-wireless` соединения NetworkManager:
  ```
  nmcli connection modify "$conn" 802-11-wireless.powersave 2
  ```
  (`2` = disable, `3` = enable, `0` = default = enable на Pi)
- Это **persistent** — выдержит реконнект.
- Одноразово на текущей сессии: `iw dev wlan0 set power_save off`

**Удалить:**
```bash
for c in $(nmcli -t -f NAME,TYPE c show | awk -F: '$2=="802-11-wireless"{print $1}'); do
    sudo nmcli connection modify "$c" 802-11-wireless.powersave 0
done
```

## 4. Sysctl tunes

**Зачем:** PiOS-дефолты заточены под десктопный сценарий. Для NAS лучше подкрутить три вещи.

**Файл:** `/etc/sysctl.d/99-travel-nas-tunes.conf`

```sysctl
# SSD-friendly: меньше свопить (default 60)
# Мы на ext4 + zram, обычный swap почти не используется
vm.swappiness = 10

# Больше TCP listen backlog — много concurrent клиентов Samba/Photoview
net.core.somaxconn = 512

# Более частый keepalive — быстрее детектим dead TCP (хороший WiFi)
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
```

Применяется сразу через `sysctl -p`.

**Удалить:**
```bash
sudo rm /etc/sysctl.d/99-travel-nas-tunes.conf
sudo sysctl --system   # переприменит остальные дефолты
```

## Что НЕ делаем (рассмотрено и отброшено)

- **Disable Bluetooth** (`dtoverlay=disable-bt`) — экономит ~200мВт, но user может использовать BT-наушники в дороге
- **Disable HDMI clocks** (`hdmi_blanking=2`) — мало даёт, ломает emergency-HDMI-debug
- **Overclock** — Pi 5 уже на пределе без активного охлаждения
- **Pin GPU memory** — на Pi 5 unified memory, deprecated
- **Disable serial console** — может пригодиться при boot-проблемах
- **`/tmp` в tmpfs** — log2ram уже большую часть RAM-cache даёт, плюс /tmp нужен docker'у для большых файлов

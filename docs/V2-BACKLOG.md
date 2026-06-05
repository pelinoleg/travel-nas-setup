# Web-дашборд — backlog идей

Короткий список (отредактируй/выкинь ненужное). Сделанное — см. V2-WEB-DASHBOARD.md.

## Файлы / хранилище
- [ ] File browser `/mnt/storage` (превью фото, delete/rename/move)
- [ ] Корзина `_deleted/` (восстановить файл)
- [ ] Storage analyzer (treemap: что съело диск)
- [ ] Duplicate finder (jdupes) в usb-imports
- [ ] Folder bookmarks (Music/Photos quick-access)

## Фото (твой кейс)
- [ ] Галерея со свайпом + EXIF
- [ ] Cull mode (keep/reject свайпом → `_rejected/`)
- [ ] Auto-sort usb-imports → `Photos/YYYY/MM-DD/`
- [ ] RAW-превью генератор (.thumb)
- [ ] Slideshow последнего импорта (fullscreen)

## Бэкапы
- [ ] Backup folder picker (дерево папок NAS, чекбоксы вместо правки conf)
- [ ] Backup timeline (календарь: что/когда/размер)

## Сеть / travel
- [ ] Speedtest (iperf3 к дому / speedtest-cli)
- [ ] Captive-portal helper (нет инета → открыть portal в Chromium)
- [ ] Trip log (когда/где работал, по WiFi BSSID)

## Диагностика
- [ ] SMART history (атрибуты SSD во времени, Wear/Power_On_Hours)
- [ ] Container restart history (граф падений)
- [ ] Прогресс-бар у verify scrub

## Медиа / fun
- [ ] Music player (mpd/mpv, cover art, BT-наушники)
- [ ] DLNA-каст на ТВ в отеле
- [ ] Internet radio

## Безопасность (если понадобится)
- [ ] Lockscreen PIN
- [ ] Failed SSH attempts
- [ ] Basic-auth на сетевой доступ (сейчас не нужно — сети доверенные)

## Железо (если докупишь)
- [ ] Battery/power widget (INA219/UPS HAT): V/A/%, ватты во времени
- [ ] GPS dongle → карта/местоположение

## Интеграции
- [ ] MQTT → Home Assistant
- [ ] Webhook при завершении бэкапа

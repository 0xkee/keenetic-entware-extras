# geo-bypass TODO

## Бэклог

- [ ] **Деплой на router-2** — применить ту же конфигурацию geo-bypass + SmartDNS на втором роутере
- [ ] **Создать либу для списков** — включение подсписков по `@[dir/]filename`; общие функции: сортировка, дедупликация, валидация формата; библиотека для всех подпроектов (`lib/`), сразу .ipk!
- [ ] **TTL-aware domain cache** — учитывать TTL DNS записей при обновлении кэша доменов, не перезаписывать при неизменных данных
- [ ] **Мониторинг** — периодическая проверка доступности OZON/критичных доменов через cron; алерт при маршрутных аномалиях
- [ ] кешировать последний удачный iface для subnet loader и начинать с него

---

## Выполнено

### OZON geo-fix (2026-04-11)

**Проблема:** подсеть OZON `185.73.192.0/22` отсутствовала в GeoIP-источнике MaxMind GeoLite2 → трафик не попадал в table 1000 → уходил через WireGuard → немецкий IP.

- [x] **Сменить GeoIP-источник** — `SUBNET_URL` → `ipdeny.com/ipblocks/data/countries/ru.zone` (RIR-аллокации, содержит OZON). Формат plain CIDR, совместим с `SUBNET_LOADER="cidr-plain"`.
- [x] **Перезагрузить подсети на Барвихе** — 11285 подсетей, `185.73.192.0/22` подтверждён в table 1000.
- [x] **Расширить init script** — standalone `S99geo-bypass` в `rootfs/opt/etc/init.d/`, 7 команд: start / stop / restart / status / update / update-subnets / update-domains. `install.sh` копирует из `rootfs/` вместо heredoc.
- [x] **Доработать update-domains.sh → attach-rules.sh** — расширен `attach-rules.sh` для загрузки domain IP `/32` из `DOMAINS_CACHE_FILE`. `update-domains.sh` вызывает `attach-rules.sh` при изменении кэша.
- [x] **Множественные A-записи** — SmartDNS `max-reply-ip-num 16` + второй bind :6153 `-no-speed-check`. Автодетект DNS resolver (6153 → 6053 → system). Кэш: 2 → 8 IP.
- [x] **Формат кэша доменов** — `IP # domain.com`, дедупликация по IP через awk, BusyBox-совместимая сортировка.
- [x] **Проверка** — OZON показывает +7 (Россия), LAN-трафик через `lte_br1`.

### Инфраструктура

- [x] Унифицировать пути — оба хоста: `/opt/keenetic-entware-extras/geo-bypass/`, `remote_base` в target-hosts.json
- [x] `transfer_method: scp-legacy` (scp -O) — работает без sftp-server

### Автоматизация

- [x] **Cron** — `install.sh` добавляет `update-subnets.sh` + `update-domains.sh` каждые 15 мин в `/opt/etc/crontab`. Скрипты проверяют свежесть кэша.

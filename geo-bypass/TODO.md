# geo-bypass TODO

## Бэклог

- [x] **Деплой на router-2** — применить ту же конфигурацию geo-bypass + SmartDNS на втором роутере
- [x] **Создать либу для списков** — включение подсписков по `@[dir/]filename`; общие функции: сортировка, дедупликация, валидация формата; библиотека для всех подпроектов (`lib/`), сразу .ipk!
- [ ] **TTL-aware domain cache** — учитывать TTL DNS записей при обновлении кэша доменов, не перезаписывать при неизменных данных
- [ ] **Мониторинг** — периодическая проверка доступности OZON/критичных доменов через cron; алерт при маршрутных аномалиях
- [ ] кешировать последний удачный iface для subnet loader и начинать с него
- [ ] сгенерировать белый список для ru (из беголо списка ркн)

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

### Деплой на router-2 (2026-04-11)

- [x] **SmartDNS** — конфиг обновлён, restart, UDP :6053 + :6153 работают
- [x] **DNS-перенаправление** — ndnproxy → SmartDNS:6053 (уже настроено ранее)
- [x] **geo-bypass** — install.sh, 11285 ipset entries, 11285 routes в table 1000, ISP через ppp0
- [x] **Верификация** — OZON/Yandex/Mail.ru → ppp0 (ISP), Google/Cloudflare → nwg3 (VPN)
- [x] **Исправлена проблема** — стаёлый ru-subnets.txt заменён свежим от ipdeny.com

### Создать либу для списков (2026-04-11)

- [x] **`lib/lists.sh`** — 4 функции: `list_read` (@include, strip, trim), `list_strip` (pipe-фильтр), `list_dedup` (pipe-фильтр), `list_count` (подсчёт значащих строк)
- [x] **`is_cache_fresh()` → `lib/common.sh`** — перенесена из дублированных update-subnets.sh / update-domains.sh
- [x] **Миграция 5 скриптов** — update-domains.sh, update-subnets.sh, load-ipset.sh, attach-rules.sh, cidr-plain.sh
- [x] **Shellcheck** — все файлы проходят `shellcheck -x -s sh` без ошибок
- [x] **Тестирование** — деплой + restart на router-1 и router-2, PASS на обоих
- [x] **Design doc** — `docs/lists-lib-design.md`

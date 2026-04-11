# geo-bypass TODO

## Бэклог

- [x] **Деплой на router-2** — применить ту же конфигурацию geo-bypass + SmartDNS на втором роутере
- [x] **Создать либу для списков** — включение подсписков по `@[dir/]filename`; общие функции: сортировка, дедупликация, валидация формата; библиотека для всех подпроектов (`lib/`), сразу .ipk!
- [ ] **TTL-aware domain cache** — учитывать TTL DNS записей при обновлении кэша доменов, не перезаписывать при неизменных данных
- [ ] **Мониторинг** — периодическая проверка доступности OZON/критичных доменов через cron; алерт при маршрутных аномалиях
- [x] кешировать последний удачный iface для subnet loader и начинать с него
- [ ] сгенерировать белый список для ru (из беголо списка ркн)
- [x] **Деплой .ipk на router-2** — установить keenetic-entware-extras + geo-bypass через opkg
- [ ] **GitHub Releases** — CI/CD для автоматической сборки и публикации .ipk при тегах (потом)
- [ ] надо изучитить инет на предмет какие интерфейсы туннелей, кроме nwg,opvn бывают в кинетиках и добавить в дефолт конфига все

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

### .ipk пакетирование (2026-04-11)

- [x] **Обновлён план** — `docs/opkg-packaging-plan.md`: 2 пакета (keenetic-entware-extras + geo-bypass), Entware tar.gz формат
- [x] **Пакет `keenetic-entware-extras`** — `packaging/keenetic-entware-extras/control`: lib/common.sh + lib/lists.sh
- [x] **Пакет `geo-bypass`** — `packaging/geo-bypass/`: control, conffiles, postinst (cron, NDM hook), prerm (stop, cleanup), postrm (rmdir)
- [x] **Скрипт сборки** — `scripts/build-ipk.sh`: `./scripts/build-ipk.sh all` → `dist/*.ipk`
- [x] **Фиксы** — Entware формат (tar.gz не ar), tar `--owner=0 --group=0`, postrm cleanup каталогов
- [x] **Протестировано на router-1** — `opkg install/remove/reinstall` PASS, ownership root:root, postrm cleanup OK

### Деплой .ipk на router-2 (2026-04-11)

- [x] **opkg install** — очистка старого scp-деплоя (`uninstall.sh` + `rm -rf`), установка `keenetic-entware-extras 0.1.0` + `geo-bypass 0.1.0` через opkg
- [x] **Фикс double-lib** — `build-ipk.sh:67`: dest `$data_dir/opt/keenetic-entware-extras` вместо `$data_dir/opt/keenetic-entware-extras/lib`
- [x] **Фикс cold-start crash** — `attach-rules.sh`: graceful degradation (`return 0` вместо `exit 1`); `S99geo-bypass`: cold/warm split (sync download при отсутствии кэша)

### Рефакторинг архитектуры (2026-04-11)

- [x] **update-скрипты → чистые fetcher-ы** — `update-subnets.sh` и `update-domains.sh` больше не вызывают активацию (apply-routes/attach-rules). Exit code: 0 = данные обновлены, 10 = кэш свежий.
- [x] **Единый оркестратор** — `S99geo-bypass`: `_refresh_if_stale()` helper, cold/warm start split, `update-subnets)`/`update-domains)` команды с условной активацией
- [x] **Cron через S99** — `postinst`: `*/15 * * * * root /opt/etc/init.d/S99geo-bypass update-subnets`
- [x] **Нормализация путей** — `_LISTS_DIR` в `config.sh` через parameter expansion `${_CONFIG_DIR%/*}/lists`; `_CONFIG_DIR` резолвится через `cd && pwd` в 6 скриптах
- [x] **status.sh** — 7 новых метрик: cron jobs, NDM hook, version, domain sources, секционная группировка
- [x] **Деплой** — оба роутера (router-2 + router-1) обновлены, status ✓

# geo-split TODO

## Бэклог

- [x] **Деплой на router-2** — применить ту же конфигурацию geo-split + SmartDNS на втором роутере
- [x] **Создать либу для списков** — включение подсписков по `@[dir/]filename`; общие функции: сортировка, дедупликация, валидация формата; библиотека для всех подпроектов (`lib/`), сразу .ipk!
- [ ] **TTL-aware domain cache** — учитывать TTL DNS записей при обновлении кэша доменов, не перезаписывать при неизменных данных
- [ ] **Мониторинг** — периодическая проверка доступности OZON/критичных доменов через cron; алерт при маршрутных аномалиях
- [x] кешировать последний удачный iface для subnet loader и начинать с него
- [x] сгенерировать белый список для ru (из белого списка ркн)
- [x] **Деплой .ipk на router-2** — установить keenetic-entware-extras + geo-split через opkg
- [ ] **GitHub Releases** — CI/CD для автоматической сборки и публикации .ipk при тегах (потом)
- [x] надо изучитить инет на предмет какие интерфейсы туннелей, кроме nwg,opvn бывают в кинетиках и добавить в дефолт конфига все
- [x] сделать строгую(!) агрегацию соседних подсетей после скачивания geo базы, добавить опцию в конфиг - по умолчанию вкл. после добавления доменов
- [x] **Разделить на 2 пакета: `geo-split` + `geo-split-data`** — в `-data` включены списки доменов (`geo-split-data/lists/`) + агрегированные geo-ip подсети из ipdeny.com (`lists/geoip/ru.zone`), скачиваются при билде; `geo-split` зависит от `geo-split-data`
- [x] убрать все упоминания/использования ipset (мы же их не используем?) из кода и актуальных доков
- [x] ~~ошибка в кеше subnets~~ — фикс: cron вызывает `refresh` (проверяет кеш), а не `update-subnets --force`
- [x] ~~добавить поддержку нескольких iface в LAN_INTERFACE~~ — ROUTE_IN поддерживает space-separated интерфейсы
- [x] ~~переименовать ifaces in conf/code to IN/OUT~~ — ROUTE_OUT (целевой) + ROUTE_IN (LAN-источники)
- [x] переименовать в geo-split, поправить все описания в док/коде как split общего случая, с примерами о VPN & ru zone
- [x] refactor apply-routes нужен? и вообще проверка и рекомендации по refactor arch
- [x] **Разделение route tables + async reload** — план: [tables-separation-plan.md](docs/tables-separation-plan.md)
- [x] выбрать лицензию kee, с учетом используемых зависимостей/данных — MIT (LICENSE в корне)
- [ ] надо изучить, удаляются ли старые домены из роутинга, ещё вопрос как лучше и надоли добавить опцию в конфиг
---

## Выполнено

### Подготовка к публикации на форуме (2026-04-13)

- [x] **Лицензия MIT** — файл `LICENSE` (Copyright (c) 2026 KEE Team)
- [x] **README обновлены** — корневой, geo-split, geo-split-data: убраны bash/ipset/scp, добавлен opkg install, актуальные flows/параметры
- [x] **README в .ipk** — `build-ipk.sh` включает README.md в каждый пакет
- [x] **Тестирование** — сборка 3 пакетов, деплой на router-1, conffiles upgrade ✓, dependency warning ✓
- [x] **Черновик поста** — `docs/forum-post-draft.md`

### Зоны ЕАЭС в geo-split-data (2026-04-15)

- [x] **fetch-zones.sh** — `COUNTRIES=(ru by kz am kg)` (Россия, Беларусь, Казахстан, Армения, Кыргызстан)
- [x] **geo-split-data v0.3.0** — bump версии, README обновлён с EAEU зонами
- [x] **Зоны скачаны** — ru: 8588, by: 102, kz: 579, am: 183, kg: 109 агрегированных CIDRs

### Разделение route tables + async reload (2026-04-12)

- [x] **config.sh** — `DOMAIN_ROUTE_TABLE="1000"` prio 50, `SUBNET_ROUTE_TABLE="1001"` prio 51 (переименованы из ROUTE_TABLE/RULE_PRIORITY)
- [x] **lib/ip.sh** — `resolve_target_interface()`, `fill_routes_batch()` (flush+batch load), `detect_out_iface()` (переименован из detect_isp_interface)
- [x] **update-subnets.sh** — download + `fill_routes_batch $SUBNET_ROUTE_TABLE`, поддержка `--refill` (NDM hook)
- [x] **update-domains.sh** — resolve + `fill_routes_batch $DOMAIN_ROUTE_TABLE ... host`, поддержка `--refill`
- [x] **detach-rules.sh** — del rules + flush обеих таблиц
- [x] **attach-rules.sh** — полная перезапись → только `ip rule add/del` для обеих таблиц (убраны lib/lists.sh, lib/ip.sh, load_routes_batch)
- [x] **S99geo-split** — async loaders (`& wait`), убран `_refresh_if_stale()`, загрузчики сами fill-ят таблицы
- [x] **ndm-hook.sh** — UP: sleep 2 debounce + refill обеих таблиц + attach (background). DOWN: проверка обеих таблиц + detach
- [x] **status.sh** — per-table ip rules display, per-table route counts, active out из обеих таблиц
- [x] **shellcheck** — все файлы проходят `shellcheck -x -s sh` без ошибок

### Архитектурный cleanup (2026-04-12)

- [x] **apply-routes.sh удалён** — мёртвый indirection (16 строк, после удаления ipset единственный вызов — attach-rules.sh)
- [x] **S99geo-split переименован** — 5× `geo-bypass` → `geo-split` (включая INSTALL_DIR path)
- [x] **detect_isp_interface() → lib/ip.sh** — устранено дублирование (attach-rules.sh + status.sh)
- [x] **detect_dns_port() → lib/ip.sh** — устранено дублирование DNS auto-detect (update-domains.sh + status.sh)
- [x] **Документы обновлены** — target-arch.md, README.md, opkg-packaging-plan.md, workspace config

### Удаление ipset dead code (2026-04-12)

- [x] **load-ipset.sh удалён** — весь файл (130 строк) dead code: ipset загружался, но не использовался ни одним iptables-правилом
- [x] **Убраны ссылки из 8 файлов** — apply-routes.sh, update-domains.sh, config.sh, S99geo-split, status.sh, ndm-hook.sh, packaging/control, packaging/prerm
- [x] **Убрана зависимость** — `ipset` удалён из `Depends:` в packaging/geo-split/control
- [x] **Маршрутизация** — работает как прежде через `ip rule` + `ip route table 1000` (attach-rules.sh)

### OZON geo-fix (2026-04-11)

**Проблема:** подсеть OZON `185.73.192.0/22` отсутствовала в GeoIP-источнике MaxMind GeoLite2 → трафик не попадал в table 1000 → уходил через WireGuard → немецкий IP.

- [x] **Сменить GeoIP-источник** — `SUBNET_URL` → `ipdeny.com/ipblocks/data/countries/ru.zone` (RIR-аллокации, содержит OZON). Формат plain CIDR, совместим с `SUBNET_LOADER="cidr-plain"`.
- [x] **Перезагрузить подсети на Барвихе** — 11285 подсетей, `185.73.192.0/22` подтверждён в table 1000.
- [x] **Расширить init script** — standalone `S99geo-split` в `rootfs/opt/etc/init.d/`, 7 команд: start / stop / restart / status / update / update-subnets / update-domains. `install.sh` копирует из `rootfs/` вместо heredoc.
- [x] **Доработать update-domains.sh → attach-rules.sh** — расширен `attach-rules.sh` для загрузки domain IP `/32` из `DOMAINS_CACHE_FILE`. `update-domains.sh` вызывает `attach-rules.sh` при изменении кэша.
- [x] **Множественные A-записи** — SmartDNS `max-reply-ip-num 16` + второй bind :6153 `-no-speed-check`. Автодетект DNS resolver (6153 → 6053 → system). Кэш: 2 → 8 IP.
- [x] **Формат кэша доменов** — `IP # domain.com`, дедупликация по IP через awk, BusyBox-совместимая сортировка.
- [x] **Проверка** — OZON показывает +7 (Россия), LAN-трафик через `lte_br1`.

### Инфраструктура

- [x] Унифицировать пути — оба хоста: `/opt/keenetic-entware-extras/geo-split/`, `remote_base` в target-hosts.json
- [x] `transfer_method: scp-legacy` (scp -O) — работает без sftp-server

### Автоматизация

- [x] **Cron** — `install.sh` добавляет `update-subnets.sh` + `update-domains.sh` каждые 15 мин в `/opt/etc/crontab`. Скрипты проверяют свежесть кэша.

### Деплой на router-2 (2026-04-11)

- [x] **SmartDNS** — конфиг обновлён, restart, UDP :6053 + :6153 работают
- [x] **DNS-перенаправление** — ndnproxy → SmartDNS:6053 (уже настроено ранее)
- [x] **geo-split** — install.sh, 11285 ipset entries, 11285 routes в table 1000, ISP через ppp0
- [x] **Верификация** — OZON/Yandex/Mail.ru → ppp0 (ISP), Google/Cloudflare → nwg3 (VPN)
- [x] **Исправлена проблема** — стаёлый ru-subnets.txt заменён свежим от ipdeny.com

### Создать либу для списков (2026-04-11)

- [x] **`lib/lists.sh`** — 4 функции: `list_read` (@include, strip, trim), `list_strip` (pipe-фильтр), `list_dedup` (pipe-фильтр), `list_count` (подсчёт значащих строк)
- [x] **`is_cache_fresh()` → `lib/common.sh`** — перенесена из дублированных update-subnets.sh / update-domains.sh
- [x] **Миграция 5 скриптов** — update-domains.sh, update-subnets.sh, ~~load-ipset.sh~~ (удалён), attach-rules.sh, cidr-plain.sh
- [x] **Shellcheck** — все файлы проходят `shellcheck -x -s sh` без ошибок
- [x] **Тестирование** — деплой + restart на router-1 и router-2, PASS на обоих
- [x] **Design doc** — `docs/lists-lib-design.md`

### .ipk пакетирование (2026-04-11)

- [x] **Обновлён план** — `docs/opkg-packaging-plan.md`: 2 пакета (keenetic-entware-extras + geo-split), Entware tar.gz формат
- [x] **Пакет `keenetic-entware-extras`** — `packaging/keenetic-entware-extras/control`: lib/common.sh + lib/lists.sh
- [x] **Пакет `geo-split`** — `packaging/geo-split/`: control, conffiles, postinst (cron, NDM hook), prerm (stop, cleanup), postrm (rmdir)
- [x] **Скрипт сборки** — `scripts/build-ipk.sh`: `./scripts/build-ipk.sh all` → `dist/*.ipk`
- [x] **Фиксы** — Entware формат (tar.gz не ar), tar `--owner=0 --group=0`, postrm cleanup каталогов
- [x] **Протестировано на router-1** — `opkg install/remove/reinstall` PASS, ownership root:root, postrm cleanup OK

### Деплой .ipk на router-2 (2026-04-11)

- [x] **opkg install** — очистка старого scp-деплоя (`uninstall.sh` + `rm -rf`), установка `keenetic-entware-extras 0.1.0` + `geo-split 0.1.0` через opkg
- [x] **Фикс double-lib** — `build-ipk.sh:67`: dest `$data_dir/opt/keenetic-entware-extras` вместо `$data_dir/opt/keenetic-entware-extras/lib`
- [x] **Фикс cold-start crash** — `attach-rules.sh`: graceful degradation (`return 0` вместо `exit 1`); `S99geo-split`: cold/warm split (sync download при отсутствии кэша)

### Рефакторинг архитектуры (2026-04-11)

- [x] **update-скрипты → чистые fetcher-ы** — `update-subnets.sh` и `update-domains.sh` больше не вызывают активацию (apply-routes/attach-rules). Exit code: 0 = данные обновлены, 10 = кэш свежий.
- [x] **Единый оркестратор** — `S99geo-split`: `_refresh_if_stale()` helper, cold/warm start split, `update-subnets)`/`update-domains)` команды с условной активацией
- [x] **Cron через S99** — `postinst`: `*/15 * * * * root /opt/etc/init.d/S99geo-split update-subnets`
- [x] **Нормализация путей** — `_LISTS_DIR` в `config.sh` через parameter expansion `${_CONFIG_DIR%/*/*}/geo-split-data/lists`; `_CONFIG_DIR` резолвится через `cd && pwd` в 6 скриптах
- [x] **status.sh** — 7 новых метрик: cron jobs, NDM hook, version, domain sources, секционная группировка
- [x] **Деплой** — оба роутера (router-2 + router-1) обновлены, status ✓

### ru-whitelist (2026-04-11)

- [x] **`geo-split-data/lists/ru-whitelist.txt`** — 104 домена в 14 категориях (госуслуги, банки, стриминг, e-commerce, телеком, Яндекс и др.)
- [x] **Подключение** — `domains.txt` включает `@ru-whitelist.txt` по умолчанию, `list_read` корректно резолвит @include
- [x] **Деплой** — оба роутера (router-1 + router-2), `update-domains.sh --force` → 175/172 unique IP
- [x] **Верификация** — `status.sh` → all healthy; host-route `rkn.gov.ru` в table 1000 через `lte_br1` ✓

# lib — TODO

**Updated:** 2026-08-22

---

- [ ] `lib/ecosystem.sh` — единый API для получения зоны/настроек из экосистемы.
      Сейчас net-check/wan.sh, webui/api-router.lua и geo-split/status.sh
      каждый отдельно парсят конфиги smartdns-geo-conf (grep DNS_ZONE, ROUTE_OUT и т.д.).
      Вынести в shared library:
      - `get_active_zone()` — DNS_ZONE из smartdns-geo-conf
      - `get_zone_cc_list()` — resolve через lib/geo.sh
      - `get_zone_route_dev()` — ROUTE_OUT из geo-split
      - `get_zone_dns_provider()` — ZONE_DNS_PROVIDER из smartdns-geo-conf
      Заменит дублирование grep-парсинга в 3+ пакетах.
- [ ] зачем нам 2 buiuld-ipk и make? можем мигрировать на make?
- [x] `lib/privacy.sh` — shared IP/ASN/IPv6 masking filter.
      Extracted from `net-check/scripts/lib/privacy.sh` (53-line `_priv_mask_patterns()`
      inlined awk + IPv6 sed). Provides: `priv_mask_ip_asn()`, `priv_mask_ipv6()`,
      `priv_basic_filter()`. Used by `bug-report.sh` (default on) and net-check
      (`--privacy` flag delegates to shared lib). Well-known IPs preserved (DNS resolvers,
      RFC 1918, loopback).
- [x] format_age и поискать во всех проектах и вынести общее сюда, в либу
      → вынесено в `lib/common.sh`. Попутно:
      - `installed_pkg_version <pkg>` вынесено туда же (3 дубля `show_version`)
      - `smartdns-geo-conf/scripts/status.sh` подключён к `lib/common.sh`,
        заменён inline `stat -t ... awk '13'` на `file_mtime()`,
        нормализованы отступы (4 → 2 пробела)

- [x] status.sh — выделить общие check/show паттерны из всех status-скриптов
      → создано `lib/status.sh`. Содержит:
      - `status_detect_pid()` — PID от pidfile/pidof (убрано из smartdns, webui)
      - `status_check_process()` — running/mem (убрано из smartdns, webui)
      - `status_check_uptime()` — uptime из pidfile mtime (убрано из всех 4-х)
      - `status_check_port()` — netstat/ss порт-проверка (убрано из smartdns, webui, redirect)
      - `status_check_version()` — opkg version (убрано из всех 4-х)
      - + 4 show-функции: status_show_process/uptime/version/port
      Все 4 status.sh рефакторены: check-функции выделены, хак
      `show_* >/dev/null` удалён, JSON и текст используют единые проверки.

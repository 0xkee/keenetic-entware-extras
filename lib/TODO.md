# lib — TODO

**Updated:** 2026-05-01

---

- [ ] зачем нам 2 buiuld-ipk и make? можем мигрировать на make?
- [x] format_age и поискать во всех проектах и вынести общее сюда, в либу
      → вынесено в `lib/common.sh`. Попутно:
      - `installed_pkg_version <pkg>` вынесено туда же (3 дубля `show_version`)
      - `smartdns-conf-ru-split/scripts/status.sh` подключён к `lib/common.sh`,
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

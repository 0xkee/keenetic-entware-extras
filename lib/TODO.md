# lib — TODO

**Updated:** 2026-04-17

---

- [x] format_age и поискать во всех проектах и вынести общее сюда, в либу
      → вынесено в `lib/common.sh`. Попутно:
      - `installed_pkg_version <pkg>` вынесено туда же (3 дубля `show_version`)
      - `smartdns-conf-ru-split/scripts/status.sh` подключён к `lib/common.sh`,
        заменён inline `stat -t ... awk '13'` на `file_mtime()`,
        нормализованы отступы (4 → 2 пробела)

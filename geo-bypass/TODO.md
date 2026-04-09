# geo-bypass TODO

## Инфраструктура

- [x] Унифицировать пути установки geo-bypass на роутерах
  - Оба хоста: `/opt/keenetic-entware-extras/geo-bypass/`
  - router-1 (10.0.0.1) и router-2 (10.0.2.1) — единый формат
  - `remote_base` в target-hosts.json → `/opt/keenetic-entware-extras`
- [x] Добавить хостам `transfer_method: scp-legacy` (scp -O)
  - Оба хоста: `"scp-legacy"` — работает без sftp-server
  - Обновлена схема в ssh-remote SKILL.md + example template
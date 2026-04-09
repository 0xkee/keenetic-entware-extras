# geo-bypass TODO

## Инфраструктура

- [x] Унифицировать пути установки geo-bypass на роутерах
  - Оба хоста: `/opt/keenetic-entware-extras/geo-bypass/`
  - router-1 (10.0.0.1) и router-2 (10.0.2.1) — единый формат
  - `remote_base` в target-hosts.json → `/opt/keenetic-entware-extras`
 - [] добавить хостам метод взаимодействия scp -O (и в example, но там можно, что ты любишь, rsync)
# geo-bypass

Прямая маршрутизация .ru доменов и российских IP-подсетей в обход VPN-туннеля.

## Принцип работы

1. Скрипт `update-domains.sh` получает актуальные IP-подсети для .ru зоны
2. IP загружаются в `ipset` (набор IP-адресов в ядре)
3. Правила `iptables`/`ip rule` маршрутизируют трафик к этим IP напрямую (через ISP), минуя VPN

## Файлы

| Файл | Назначение |
|------|-----------|
| `scripts/update-domains.sh` | Обновление списка IP-подсетей .ru |
| `scripts/apply-routes.sh` | Применение маршрутов (ipset + ip rule) |
| `scripts/install.sh` | Установка в cron и автозапуск |
| `config/config.sh` | Настройки (интерфейсы, ipset имя и т.д.) |
| `lists/` | Загруженные списки IP (генерируются автоматически) |

## Установка на роутере

```bash
# 1. Скопировать на роутер
scp -r geo-bypass/ root@192.168.1.1:/opt/keenetic-entware/geo-bypass/

# 2. Запустить установку
ssh root@192.168.1.1 '/opt/keenetic-entware/geo-bypass/scripts/install.sh'
```

## Настройка

Отредактируйте `config/config.sh`:

```bash
# Интерфейс ISP (прямой, не VPN)
ISP_INTERFACE="eth3"

# Имя ipset
IPSET_NAME="geo-bypass"

# Таблица маршрутизации
ROUTE_TABLE="100"
```

## Зависимости (Entware)

```bash
opkg install ipset curl bash
```

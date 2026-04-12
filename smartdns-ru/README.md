# smartdns-ru

Кастомный конфиг SmartDNS для разделения DNS-запросов по зонам на Keenetic-роутерах с Entware.

## Принцип работы

1. SmartDNS слушает на порту `6053` (Keenetic перенаправляет DNS-запросы на него)
2. Домены `.ru` / `.рф` / `.su` резолвятся через российские DNS (Yandex, AdGuard DoT)
3. Все остальные домены — через международные DNS (Cloudflare DoT/DoH, Google UDP)

## Файлы

| Файл | Назначение |
|------|-----------|
| `config/smartdns.conf` | Конфигурация SmartDNS (группы, серверы, правила) |
| `scripts/install.sh` | Установка: пакет, конфиг, custom init script |
| `scripts/uninstall.sh` | Удаление: остановка, восстановление defaults |

## Установка на роутере

```sh
# 1. Скопировать на роутер
scp -r smartdns/ root@192.168.1.1:/opt/keenetic-entware-extras/smartdns-ru/

# 2. Запустить установку
ssh root@192.168.1.1 '/opt/keenetic-entware-extras/smartdns-ru/scripts/install.sh'
```

Скрипт установки:
- Устанавливает пакет `smartdns` через `opkg`
- Бэкапит существующий конфиг
- Деплоит `config/smartdns.conf` → `/opt/etc/smartdns/smartdns.conf`
- Отключает стандартный init (`S38smartdns`)
- Создаёт custom init (`S60smartdns`) с управлением PID-файлом
- Запускает SmartDNS

## Удаление

```sh
ssh root@192.168.1.1 '/opt/keenetic-entware-extras/smartdns-ru/scripts/uninstall.sh'
```

## Настройка

### Добавить домен в группу `ru`

Отредактируйте `config/smartdns.conf`, добавьте строку в секцию "RU routing rules":

```
nameserver /example.com/ru
```

Затем перезапустите SmartDNS:

```sh
/opt/etc/init.d/S60smartdns restart
```

### DNS-группы

| Группа | Серверы | Протокол |
|--------|---------|----------|
| `ru` | Yandex (77.88.8.8/1), AdGuard (94.140.14.14/15) | DoT + UDP |
| `default` | Cloudflare (1.1.1.1, 1.0.0.1), Google (8.8.8.8, 8.8.4.4) | DoT + DoH + UDP |

## Зависимости (Entware)

```sh
opkg install smartdns
```

## Связанные подпроекты

- **[geo-split](../geo-split/)** — split routing по GeoIP-подсетям и доменам. Рекомендуется SmartDNS для резолвинга доменов (`dig @localhost` → порт 6053).

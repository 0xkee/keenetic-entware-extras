# keenetic-entware-extras — Руководство пользователя

## Что это такое

**keenetic-entware-extras** — базовый пакет проекта. Содержит общие shell-библиотеки и CLI-утилиту `kee-status` для агрегированной диагностики всех установленных модулей.

### Состав

| Компонент | Описание |
|-----------|----------|
| `lib/common.sh` | Логирование, валидация, определение IP роутера, JSON-хелперы |
| `lib/ip.sh` | IP/интерфейс утилиты: CIDR-агрегация, определение ISP, DNS-резолвер |
| `lib/lists.sh` | Обработка списков (@include, дедупликация) |
| `lib/status.sh` | Общие check/show функции для диагностики сервисов |
| `lib/geo.sh` | Гео-данные: 40+ союзов/альянсов (EAEU, BRICS, CIS, SCO…), работа с зонами |
| `lib/zones.sh` | Метки зон: полный ISO 3166-1 alpha-2 справочник (249 стран/территорий) |
| `kee-status` | CLI команда — агрегированный статус всех подпакетов |
| `bug-report.sh` | Сбор диагностики для баг-репортов (безопасный, без паролей/ключей) |

### Зачем нужен

Этот пакет **обязателен** для работы всех остальных модулей проекта (geo-split, smartdns-geo-conf, smartdns-redirect, webui). Устанавливается первым.

---

## Требования

- Роутер Keenetic с Entware
- **KeeneticOS 5.0+**

### Программные зависимости

| Пакет | Назначение |
|-------|-----------|
| `cron` | Планировщик задач (обновление данных по расписанию) |

---

## Установка

```sh
opkg install keenetic-entware-extras_<версия>_all.ipk
```

Устанавливается в `/opt/keenetic-entware-extras/`. Зависимость `cron` подтягивается автоматически.

---

## Использование

### kee-status — агрегированная диагностика

После установки доступна команда `kee-status` (`/opt/bin/kee-status`), которая запускает `status.sh` каждого установленного подпакета и показывает сводку.

```sh
kee-status
```

Пример вывода (все сервисы работают):

```
keenetic-entware-extras status:
  geo-split            Alive
  smartdns-geo-conf Alive
  smartdns-redirect    Alive
  webui                Alive
```

Пример вывода (есть проблемы):

```
keenetic-entware-extras status:
  geo-split            Alive
  smartdns-geo-conf FAIL
    Service:
      Ports:       none listening ✗
  smartdns-redirect    Alive
  webui                Disabled
```

При сбое показываются только строки с `✗`, сгруппированные по секциям.

### Флаги

| Флаг | Описание |
|------|----------|
| `-d` / `--details` | Показать полный вывод status для каждого пакета |
| `-n` / `--no-color` | Отключить ANSI-цвета (plain text для логов) |
| `-c` / `--color=always` | Принудительные цвета (для `kee-status \| less -R`) |
| `-h` / `--help` | Справка |

Также поддерживается переменная окружения `NO_COLOR=1`.

### Exit code

| Код | Значение |
|-----|----------|
| `0` | Все пакеты `Alive` или `Disabled` |
| `1` | Хотя бы один пакет `FAIL` |

### bug-report.sh — сбор диагностики для баг-репортов

Скрипт собирает полную информацию о системе для отправки в форум/тикет. Вывод **очищен от паролей, ключей и WAN-IP** — безопасен для публичной вставки.

```sh
/opt/keenetic-entware-extras/scripts/bug-report.sh
```

Собирает:
- Версия прошивки, ядро, архитектура
- Память и диск
- Установленные kee-пакеты (версии)
- Полный `kee-status --details`
- ip rules, route tables
- Cron, NDM hooks
- Конфиги (без секретов)

Вывод можно скопировать и вставить в сообщение на форуме — или сохранить в файл:
```sh
/opt/keenetic-entware-extras/scripts/bug-report.sh > /tmp/bug-report.txt
```

---

## Порядок установки проекта

Рекомендуемый порядок установки всех пакетов:

```sh
# 1. Базовый пакет (обязательно первым)
opkg install keenetic-entware-extras_<ver>_all.ipk

# 2. Данные (опционально, для быстрого старта geo-split)
opkg install geo-split-data_<ver>_all.ipk

# 3. Модули (в любом порядке)
opkg install geo-split_<ver>_all.ipk
opkg install smartdns-geo-conf_<ver>_all.ipk
opkg install smartdns-redirect_<ver>_all.ipk
opkg install net-check_<ver>_all.ipk
opkg install webui_<ver>_all.ipk
```

### Зависимости между модулями

```
keenetic-entware-extras  ← обязательная база для всех
  ├── geo-split          ← требует geo-split-data
  │     └── geo-split-data
  ├── smartdns-geo-conf
  ├── smartdns-redirect
  ├── net-check
  └── webui
```

---

## Обновление

```sh
opkg upgrade keenetic-entware-extras
```

Библиотеки обновляются на месте. Все модули продолжают использовать обновлённые версии `lib/*.sh` автоматически.

---

## Удаление

```sh
opkg remove keenetic-entware-extras
```

> ⚠️ Перед удалением базового пакета удалите все зависящие модули — без `lib/*.sh` они не смогут работать.

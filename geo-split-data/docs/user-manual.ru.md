# geo-split-data — Руководство пользователя

## Что это такое

**geo-split-data** — пакет данных для модуля [`geo-split`](../../geo-split/docs/user-manual.ru.md). Содержит курированные списки доменов и предзагруженные GeoIP-зоны для быстрого и надёжного первого запуска.

### Назначение

Основная роль пакета — обеспечить **надёжный первый старт** geo-split без зависимости от внешних источников:

- **Списки доменов** — готовые к использованию файлы с российскими сервисами, подверженными геоблокировке
- **GeoIP-зоны** — предзагруженные подсети стран, чтобы geo-split мог заполнить route tables сразу при загрузке, даже если интернет недоступен

> 📝 После первого запуска geo-split **самостоятельно скачивает и обновляет** подсети из интернета. Предзагруженные данные — стартовый seed, который обеспечивает работу до первого успешного обновления.

### Содержимое

| Файл | Описание |
|------|----------|
| `lists/domains.txt` | Основной список доменов для DNS-маршрутизации |
| `lists/ru-whitelist.txt` | Белый список (100+ RU-доменов: госуслуги, банки, стриминг и др.) |
| `lists/geoip/*.zone` | Предзагруженные GeoIP-подсети стран (CIDR-формат) |

---

## Требования

- Роутер Keenetic с Entware
- **KeeneticOS 5.0+**

### Программные зависимости

| Пакет | Назначение |
|-------|-----------|
| `keenetic-entware-extras` | Общие библиотеки проекта (обязательно) |

---

## Установка

```sh
opkg install geo-split-data_<версия>_all.ipk
```

Файлы устанавливаются в `/opt/keenetic-entware-extras/geo-split-data/`.

---

## Содержимое подробно

### domains.txt — список доменов

Расположение: `/opt/keenetic-entware-extras/geo-split-data/lists/domains.txt`

Этот файл используется `geo-split` для DNS-резолвинга — домены резолвятся в IP-адреса и добавляются как /32 host routes.

Формат:
- Один домен на строку
- `#` — комментарий
- `@filename` — подключение внешнего файла

По умолчанию включает:
```
@ru-whitelist.txt
```

Вы можете добавлять свои домены в этот файл.

### ru-whitelist.txt — белый список российских сервисов

Расположение: `/opt/keenetic-entware-extras/geo-split-data/lists/ru-whitelist.txt`

Курированный список 100+ российских доменов с геоблокировкой:

| Категория | Примеры |
|-----------|---------|
| Госуслуги | gosuslugi.ru, mos.ru, nalog.ru |
| Банки | sberbank.ru, tinkoff.ru, vtb.ru, alfabank.ru |
| Стриминг | kinopoisk.ru, ivi.ru, okko.tv |
| Соцсети | vk.com, ok.ru, mail.ru |
| Маркетплейсы | wildberries.ru, ozon.ru, avito.ru |
| Доставка | delivery-club.ru, sbermarket.ru |

### geoip/*.zone — предзагруженные подсети стран

Расположение: `/opt/keenetic-entware-extras/geo-split-data/lists/geoip/`

Предагрегированные зоны стран ЕАЭС (загружены при сборке пакета из ipdeny.com):

| Файл | Страна |
|------|--------|
| `ru.zone` | 🇷🇺 Россия |
| `by.zone` | 🇧🇾 Беларусь |
| `kz.zone` | 🇰🇿 Казахстан |
| `am.zone` | 🇦🇲 Армения |
| `kg.zone` | 🇰🇬 Кыргызстан |

Эти файлы используются geo-split как начальные данные при первом запуске. В дальнейшем geo-split обновляет подсети из интернета по расписанию.

---

## Использование

### Добавить свой домен

```sh
echo "my-service.ru" >> /opt/keenetic-entware-extras/geo-split-data/lists/domains.txt
```

Применить:
```sh
/opt/etc/init.d/S99geo-split update-domains
```

### Создать свой файл списка

```sh
vi /opt/keenetic-entware-extras/geo-split-data/lists/custom-domains.txt
```

Подключить в `domains.txt`:
```
@custom-domains.txt
```

---

## Обновление

```sh
opkg upgrade geo-split-data
```

> 📝 **conffiles:** Файлы `domains.txt` и `ru-whitelist.txt` — conffiles. При обновлении ваши изменения **сохраняются**. Новая версия из пакета будет создана рядом с суффиксом `.opkg-new` — вы можете вручную сравнить и обновить.

---

## Удаление

```sh
opkg remove geo-split-data
```

> 📝 geo-split продолжит работать — подсети уже закэшированы и будут обновляться из интернета. Однако файл `domains.txt` станет недоступен (если не переопределён в конфиге geo-split).

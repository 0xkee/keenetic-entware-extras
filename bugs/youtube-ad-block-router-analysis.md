# YouTube Premium через роутер (как Shadowrocket) — анализ

> **Дата:** 2026-07-06
> **Источник:** запрос пользователя Valerios на форуме (NC-1812)
> **Статус:** ❌ Нецелесообразно

## Запрос

Пользователь нашёл способ блокировки рекламы YouTube на iOS через Shadowrocket:
- HTTPS-перехват с установкой сертификата
- Модуль блокировки рекламы + PiP + фоновое воспроизведение
- Вопрос: можно ли реализовать аналогичное на роутере Keenetic?

**Ссылки от пользователя:**
- https://apps.apple.com/ru/app/shadowrocket/id932747118
- https://raw.githubusercontent.com/misha-tgshv/shadowrocket-configuration-file/refs/heads/main/modules/YT-Premium-V1-RU.module

## Как работает Shadowrocket-модуль

Изучены оба файла — `.module` и `youtube.response.js` (~2500 строк минифицированного кода). Механизм состоит из 3 уровней:

### 1. MITM (Man-in-the-Middle) — ключевой элемент

```
[MITM]
hostname = *.googlevideo.com, www.youtube.com, s.youtube.com, youtubei.googleapis.com
```

Shadowrocket **расшифровывает HTTPS-трафик** к этим доменам. Для этого генерирует собственный CA-сертификат, устанавливает его в доверенные на устройстве, и подменяет SSL-сертификаты налету.

### 2. URL Rewrite — блокировка рекламных запросов

- `googlevideo.com/initplayback...&oad` → reject (рекламные pre-roll)
- `youtube.com/api/stats/ads` → reject
- `youtube.com/pagead`, `ptracking` → reject
- UDP-трафик к `googlevideo.com` и `youtubei.googleapis.com` → reject (QUIC)

### 3. Script — модификация protobuf-ответов API

JS-скрипт перехватывает ответы `youtubei.googleapis.com/youtubei/v1/{browse,next,player,search,...}` и:

- **Парсит бинарный Protocol Buffers** (не JSON!) ответ YouTube
- **Удаляет** `adPlacements`, `adSlots`, `pageadViewthroughconversion`
- **Инжектит** `pictureInPictureRender` с `active: true` → PiP
- **Инжектит** `backgroundPlayerRender` с `active: true` → фоновое воспроизведение
- **Удаляет** Shorts из навигации
- **Пересобирает** protobuf и отдаёт модифицированный ответ

## Можно ли сделать это на роутере Keenetic?

**Короткий ответ: технически возможно, но практически — нет. Не имеет смысла.**

### Причины

| Проблема | Детали |
|----------|--------|
| **MITM HTTPS** | Нужен SSL-прокси (mitmproxy / squid ssl-bump), который расшифровывает HTTPS на лету. Это +100-300% CPU на каждое соединение |
| **Ресурсы NC-1812** | ~880 МГц MIPS/ARM, 256 МБ RAM. SSL interception одного YouTube-потока = 30-50% CPU. Несколько устройств = роутер ляжет |
| **Protobuf-обработка** | Нужен JavaScript-рантайм (Node.js) на роутере для парсинга и модификации бинарных protobuf-ответов YouTube API. Node.js на MIPS = ~80 МБ RAM |
| **Сертификат на каждом устройстве** | Всё равно придётся ставить CA-сертификат роутера на КАЖДОЕ устройство в сети — iPhone, Android, ПК, TV |
| **Certificate Pinning** | Приложение YouTube на Android/iOS использует certificate pinning — отклонит поддельный сертификат. Работать будет только в браузере |
| **QUIC/HTTP3** | YouTube активно использует QUIC (UDP). На роутере надо блокировать весь QUIC чтобы заставить YouTube использовать TCP/HTTPS |

### Почему DNS-блокировка (AdGuard Home / Pi-hole) не поможет

- Реклама YouTube идёт с **тех же самых доменов** что и контент (`googlevideo.com`)
- На уровне DNS невозможно отличить рекламный видеопоток от контентного
- PiP и фоновое воспроизведение — это модификация API-ответов, DNS тут бессилен

## Что реально работает (альтернативы)

| Платформа | Решение | Как работает |
|-----------|---------|--------------|
| **iOS** | Shadowrocket (что у пользователя) | MITM-прокси на устройстве |
| **Android** | ReVanced | Патченый YouTube-клиент, не требует прокси |
| **ПК (браузер)** | uBlock Origin | Блокирует рекламу в веб-версии YouTube |
| **SmartTV / AppleTV** | YouTube Premium | Для них решений на уровне роутера нет вообще |

## Вердикт

**Нельзя перенести этот подход на роутер.** Причина фундаментальная — это не фильтрация на уровне DNS/IP, а **MITM с модификацией бинарных API-ответов внутри HTTPS-сессии**. Роутер Keenetic не потянет ни по CPU, ни по RAM, и всё равно придётся ставить сертификат на каждое устройство (что ничем не лучше Shadowrocket на каждом устройстве отдельно).

Для пользователя оптимальная стратегия: **Shadowrocket на iOS + ReVanced на Android + uBlock в браузере ПК**. Каждая платформа — своё решение.

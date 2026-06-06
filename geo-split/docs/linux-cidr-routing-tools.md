# Linux инструменты для CIDR/GeoIP routing

**Дата**: 2026-06-04  
**Контекст**: Исследование всех доступных механизмов Linux для загрузки CIDR-списков (8K–50K подсетей) и маршрутизации по ним.

---

## 1. Kernel FIB (ip route) — то что использует geo-split

```sh
# Загрузка через batch
ip -batch <<'EOF'
route add 5.8.0.0/14 via 176.65.44.1 dev eth3 table 1001
route add 5.16.0.0/15 via 176.65.44.1 dev eth3 table 1001
... × 8000
EOF
```

| Характеристика | Значение |
|----------------|----------|
| **Структура** | LC-trie (Level-Compressed trie) |
| **Lookup** | O(log n), ~200ns per lookup |
| **Memory** | ~270 bytes/route (FIB) + ~400 bytes (route object) |
| **8K routes** | ~5.5 MB RAM |
| **Загрузка** | ~1 сек через `ip -batch` |
| **Max** | Практически ~500K+ routes (ограничено RAM) |
| **Longest Prefix Match** | ✅ Нативный (kernel делает LPM) |
| **HW offload** | ✅ Не затрагивает netfilter → HW NAT работает |
| **Update** | `ip route replace` — атомная замена одного route |
| **Bulk update** | `ip route flush table X` + `ip -batch` |

**Это самый эффективный механизм на Linux для CIDR matching** — kernel FIB optimized for prefix lookup with LPM.

---

## 2. ipset hash:net — CIDR в ipset

```sh
ipset create geoip hash:net maxelem 65536
ipset add geoip 5.8.0.0/14
ipset add geoip 185.73.192.0/22
# ... × 8000

# Matching in iptables
iptables -t mangle -A PREROUTING -m set --match-set geoip dst -j MARK --set-mark 0x1
```

| Характеристика | Значение |
|----------------|----------|
| **Структура** | Hash table с prefix bucketing |
| **Lookup** | O(1) amortized |
| **Memory** | ~100 bytes/entry (более компактно чем routes) |
| **8K entries** | ~800 KB RAM |
| **Загрузка** | `ipset restore` — быстрее чем ip batch |
| **Max** | `maxelem` (default 65536, можно больше) |
| **LPM** | ✅ Реализован (nested prefix matching) |
| **HW offload** | ❌ Требует iptables match → netfilter hook → HW NAT off |
| **Atomic swap** | ✅ `ipset swap tmp main` |
| **Persist** | `ipset save > file; ipset restore < file` |

---

## 3. nftables sets type ipv4_addr + flags interval

```sh
# Создать named set с таймаутом
nft add set inet filter geoip '{ type ipv4_addr; flags interval; }'
nft add element inet filter geoip '{ 5.8.0.0/14, 185.73.192.0/22 }'
# Bulk:
nft -f /tmp/geoip.nft  # atomic file load

# In rule:
nft add rule inet mangle prerouting ip daddr @geoip meta mark set 0x1
```

| Характеристика | Значение |
|----------------|----------|
| **Структура** | Red-black tree (interval set) / pipapo (для multiple dimensions) |
| **Lookup** | O(log n) |
| **Memory** | ~50-80 bytes/entry (наиболее компактно) |
| **CIDR support** | ✅ `flags interval` |
| **Atomic load** | ✅ Весь файл — одна транзакция |
| **HW offload** | ❌ Всё ещё netfilter hook |
| **Concatenation** | ✅ Можно: `type ipv4_addr . inet_service` (IP + port) |

---

## 4. xt_geoip (xtables-addons) — GeoIP прямо в iptables

```sh
# Загрузить GeoIP базу в /usr/share/xt_geoip/
xt_geoip_dl  # скрипт скачивает MaxMind
xt_geoip_build -D /usr/share/xt_geoip/

# Использовать в правиле
iptables -m geoip --dst-cc RU -j MARK --set-mark 0x1
iptables -m geoip --dst-cc RU,BY,KZ -j ACCEPT
```

| Характеристика | Значение |
|----------------|----------|
| **Структура** | Memory-mapped binary file (sorted IP ranges) |
| **Lookup** | O(log n) binary search |
| **Memory** | Загружается по требованию (mmap) |
| **Updates** | Пересобрать binary → модуль перечитает |
| **Код страны** | Напрямую в правиле (`--dst-cc RU`) |
| **HW offload** | ❌ iptables hook |
| **Kernel module** | Нужен `xt_geoip.ko` (xtables-addons) |
| **Keenetic** | ❌ Нет модуля |

---

## 5. BIRD / FRRouting — routing daemons

```
# bird.conf — импорт CIDR через static routes
protocol static geo_ru {
    route 5.8.0.0/14 via "eth3";
    route 5.16.0.0/15 via "eth3";
    include "/etc/bird/ru-cidrs.conf";
}

protocol kernel {
    table 1001;
    export filter { accept; };
}
```

| Характеристика | Значение |
|----------------|----------|
| **Struct** | Routing daemon (BGP/OSPF/static) |
| **CIDRs** | Загружает из конфига → kernel routing table |
| **Updates** | `birdc reload` — graceful перечитывание |
| **Memory** | +daemon overhead (~5-10 MB) |
| **LPM** | ✅ Kernel FIB |
| **HW offload** | ✅ (просто routes в table) |
| **Keenetic** | ⚠️ Есть в Entware (`opkg install bird2`) |
| **Overkill?** | Да, для статичного списка |

---

## 6. tc (traffic control) u32 classifier

```sh
# Создать route-based classifier
tc qdisc add dev br0 root handle 1: prio
tc filter add dev br0 parent 1: protocol ip prio 1 \
    u32 match ip dst 5.8.0.0/14 \
    action mirred egress redirect dev eth3
```

| Характеристика | Значение |
|----------------|----------|
| **Lookup** | Hash table в tc (efficient) |
| **8K rules** | Работает, но overhead на hashing |
| **HW offload** | ✅ Некоторые NIC поддерживают TC offload (не Keenetic) |
| **Keenetic** | ⚠️ `ip-full` включает tc, но kernel support неизвестен |
| **Практичность** | Низкая — сложно управлять, нет batch load |

---

## 7. WireGuard AllowedIPs

```ini
[Peer]
AllowedIPs = 5.8.0.0/14, 5.16.0.0/15, 37.9.0.0/18, ...
```

| Характеристика | Значение |
|----------------|----------|
| **Структура** | In-kernel AllowedIPs trie (Aho-Corasick вариант) |
| **Lookup** | O(prefix_length), очень быстрый |
| **Ограничение** | Statically configured, нет dynamic updates |
| **8K entries** | ⚠️ WireGuard может тормозить с >1K entries в AllowedIPs |
| **Reload** | Нужен `wg set` или перезапуск |
| **HW offload** | N/A (WireGuard — software crypto) |

---

## 8. eBPF LPM trie map

```c
// BPF_MAP_TYPE_LPM_TRIE — longest prefix match in BPF
struct bpf_map_def SEC("maps") geo_map = {
    .type = BPF_MAP_TYPE_LPM_TRIE,
    .key_size = 8,       // prefix_len (4) + ipv4 (4)
    .value_size = 4,     // action/mark
    .max_entries = 65536,
};

SEC("cls_tc")
int geo_classify(struct __sk_buff *skb) {
    struct lpm_key key = { .prefixlen = 32, .addr = skb->remote_ip4 };
    int *action = bpf_map_lookup_elem(&geo_map, &key);
    if (action) skb->mark = *action;
    return TC_ACT_OK;
}
```

| Характеристика | Значение |
|----------------|----------|
| **Структура** | Kernel LPM trie (optimized for BPF) |
| **Lookup** | O(prefix_length), ~100-200ns |
| **Memory** | Очень эффективно (~40 bytes/entry) |
| **8K entries** | ~320 KB |
| **HW offload** | ✅ Возможен через TC/XDP offload (smart NIC) |
| **Updates** | `bpf_map_update_elem` — online, без перезагрузки |
| **Kernel** | ❌ 4.11+ для LPM trie, TC BPF — 4.15+ |
| **Keenetic** | ❌ Kernel 4.9 |

---

## Сравнительная таблица для 8K CIDR

| Механизм | RAM | Load time | LPM | HW NAT | Dynamic update | Keenetic |
|----------|:---:|:---------:|:---:|:------:|:--------------:|:--------:|
| **ip route table** | 5.5 MB | ~1 сек | ✅ | ✅ | ✅ (`replace`) | ✅ |
| **ipset hash:net** | 0.8 MB | <0.5 сек | ✅ | ❌ | ✅ (`add/del`) | ⚠️ |
| **nft set interval** | 0.5 MB | <0.5 сек | ✅ | ❌ | ✅ (atomic) | ❌ |
| **xt_geoip** | mmap | instant | ✅ | ❌ | File reload | ❌ |
| **BIRD daemon** | 15 MB | 2 сек | ✅ | ✅ | `birdc reload` | ⚠️ |
| **eBPF LPM** | 0.3 MB | instant | ✅ | ✅* | ✅ (in-place) | ❌ |
| **WireGuard** | in-peer | on `wg set` | ✅ | N/A | ✅ (`wg set`) | ✅ |
| **tc u32** | ~2 MB | slow | ❌ | ⚠️ | Rebuild | ⚠️ |

---

## Вывод для Keenetic

На kernel 4.9 для 8K+ CIDR подсетей **kernel FIB** (`ip route`) — объективно лучший вариант:

1. **Не нужен netfilter** → HW NAT сохранён
2. **Нативный LPM** → kernel оптимизирован именно для этого (это его основная работа!)
3. **Самый быстрый lookup** в production (kernel FIB lookup для routing — hardware-path, zero overhead)
4. **Нет внешних зависимостей** — только `ip-full`
5. **`ip -batch`** — быстрая загрузка

Альтернативы (`ipset`, `nft sets`, `eBPF`) — либо требуют netfilter (HW NAT off), либо недоступны на kernel 4.9. Единственная реальная альтернатива — **BIRD2** (из Entware), но это overkill для статического списка.

**geo-split использует оптимальный механизм для данной платформы.** FIB trie ядра — это буквально то, для чего ядро Linux оптимизировано больше всего (routing — core kernel function).

---

## Дополнение: инструменты для DNS-based dynamic routing

Для задачи «DNS-запрос → IP в список → routing»:

| DNS-сервер | Директива | Механизм |
|------------|-----------|----------|
| **dnsmasq** | `ipset=/domain/setname` | Добавляет resolved IP в kernel ipset |
| **dnsmasq** | `nftset=/domain/4#inet#table#set` | Добавляет в nftables set |
| **SmartDNS** | `ipset /domain/#4:setname` | Аналог dnsmasq ipset |
| **SmartDNS** | `nftset /domain/#4:inet#table#set` | Аналог dnsmasq nftset |
| **Unbound** | `module: ipset` | Добавляет в ipset при resolve |
| **Knot Resolver** | Lua policy module | Произвольный скрипт на resolve |

### Паттерны routing

**A: Classic fwmark** (наиболее распространённый):
```sh
iptables -t mangle -A PREROUTING -m set --match-set vpn_set dst -j MARK --set-mark 0x1
ip rule add fwmark 0x1 table 100
```
❌ HW NAT off, mark conflict

**B: CONNMARK** (оптимизация):
```sh
iptables -t mangle -A PREROUTING -m conntrack --ctstate NEW \
    -m set --match-set vpn_set dst -j CONNMARK --set-mark 0x1/0xFF
iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark --mask 0xFF
```
Только NEW connections → ipset check. Partial offload на некоторых платформах.

**C: ipset → route sync** (без netfilter — подход для Keenetic):
```sh
# SmartDNS ipset → watcher → ip route replace в table
while true; do
    ipset list vpn_set | sync_to_routes table 1000
    sleep 3
done
```
✅ HW NAT сохранён, NDM совместим

**D: Stock NDM policy** (AWG-Manager подход):
```sh
ndmc -c "ip policy GeoBypass permit domain ozon.ru"
```
✅ Real-time, native firmware, HW NAT, NDM compatible. Только домены, не CIDR.

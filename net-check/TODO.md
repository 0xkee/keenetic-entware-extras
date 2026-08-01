# TODO — net-check

## `all` command — section order

1. **geo** — Egress Point Verification (Layers 3+7)
2. **conn** — Basic Connectivity (Layers 3–7)
3. **ipv6** — IPv6 Leak Test (Layers 3+7)
4. **dns** — DNS Resolution & ISP Filtering (Layer 7)
5. **dns-leak** — DNS Leak Test (Layer 7)
6. **comp** — HTTP Target Comparison (Layers 4–7)
7. **cdn** — CDN Geo-Steering Analysis (Layers 3+7)
8. **tls** — TLS Certificate Check (Layers 5–7)
9. **speed** — Throughput Test (Layers 4+7)

## Future

- [x] ~~определять ► по следующему хопу~~ — **Сделано (2026-08-01):** `nexthop_active_dev()` в `wan.sh` — traceroute first-hop (эмпирический, без `--interface`) → `ip route get $FIRST_HOP` → dev. Per-run cache. Заменяет FIB fallback в `active_dev_for_target()`.
- [ ] **`dns-providers.conf` unification** — consider merging IP prefix and ASN sections
  into ASN-only approach; IP globs may become redundant if ASN matching is sufficient
  for both `identify_dns_provider()` and `_is_known_dns_provider()`.
- [ ] сделать колонку ip шириной с максимальный ipv6 везде, где он может быть (видимо везде)
- [ ] **`--as MAC` client perspective** — `net-check comp --as AA:BB:CC:DD:EE:FF` to show
  ► from a specific client's routing perspective (resolves MAC → fwmark via iptables mangle).
  `--as auto` = first tunnel fwmark. Reuses logic from `route-check.sh --from`.
- [ ] **`tls` true per-interface binding** — `openssl s_client` ignores interface routing.
  Options: `socat` TCP relay, curl with `--with-ssl-details`, iptables PREROUTING
- [ ] geo-split integration: auto-recommend domains for split routing
- [ ] WebUI card + diagnostics modal
- [ ] Caching of results for WebUI dashboard
- [ ] History of check results (trending)
- [ ] Connectivity: detect encapsulated tunnels by MTU jumps

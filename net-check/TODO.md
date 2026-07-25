# TODO — net-check

## CLI / UX

- [ ] **Resolver info in cmd_geo** — show `Resolver: SmartDNS (via :53)` like dns does
- [ ] **Target endpoint in cmd_connectivity** — show tested host for transparency

## `all` command — section order

1. **geo** — Egress Point Verification (Layers 3+7)
2. **conn** — Basic Connectivity (Layers 3–7)
3. **ipv6** — IPv6 Leak Test (Layers 3+7)
4. **dns** — DNS Leak & ISP Filtering (Layer 7)
5. **comp** — HTTP Target Comparison (Layers 4–7)
6. **cdn** — CDN Geo-Steering Analysis (Layers 3+7)
7. **tls** — TLS Certificate Check (Layers 5–7)
8. **speed** — Throughput Test (Layers 4+7)

## Future

- [ ] **`tls` true per-interface binding** — `openssl s_client` ignores interface routing.
  Options: `socat` TCP relay, curl with `--with-ssl-details`, iptables PREROUTING
- [ ] geo-split integration: auto-recommend domains for split routing
- [ ] WebUI card + diagnostics modal
- [ ] Caching of results for WebUI dashboard
- [ ] History of check results (trending)
- [ ] Connectivity: detect encapsulated tunnels by MTU jumps
- [ ] Throughput: pseudo-graph of tunnel speeds (min-max)

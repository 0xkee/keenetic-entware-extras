# Bundle Patch Files

Version-specific sed patches for Keenetic stock UI Angular bundles.

Different routers may run different KeeneticOS firmware versions and CPU
architectures. Each firmware produces a unique Angular bundle (`main-<HASH>.js`).
Patches are grouped into **patch sets** (`v1.sh`, `v2.sh`, ...) and mapped to
bundle hashes via `hash-map.conf`.

## How it works

1. `patch-stock-ui.sh` copies stock UI to tmpfs (`/tmp/ew-webui/`)
2. Detects JS bundle hash from `main-<HASH>.js`
3. Looks up hash in `hash-map.conf` → gets patch set version (e.g. `v1`)
4. If hash not found: **fallback** to the latest patch set (last entry in hash-map)
5. Sources `<version>.sh` and calls `apply_patches "$BUNDLE"`
6. Verifies critical patterns in the patched bundle

## File structure

```
webui/patches/
├── hash-map.conf   # Firmware version → patch set mapping
├── v1.sh           # Patch set v1 (KeeneticOS 5.0.x)
├── v2.sh           # Patch set v2 (KeeneticOS 5.1 Beta)
├── v3.sh           # Patch set v3 (KeeneticOS 5.1.0+)
└── README.md
```

## Adding support for new firmware

After a firmware upgrade (or deploying to a router with different firmware):

```sh
# 1. SSH to router, find the new hash
ls /usr/share/htdocs_/main-*.js
# => main-NEWHASH.js

# 2. Test v1 patterns against the new bundle
for pat in 'TELEPHONY:"TELEPHONY"}' \
  '[Po.TELEPHONY]:"dashboard.card_nvox.title"};' \
  'set order(e){this.elementsOrder=e}'; do
  grep -qF "$pat" /usr/share/htdocs_/main-NEWHASH.js && echo "✅ $pat" || echo "❌ $pat"
done

# 3a. If all patterns match: just add hash to hash-map.conf
echo "NEWHASH v1" >> webui/patches/hash-map.conf

# 3b. If patterns changed: create v2.sh with updated sed commands
#     and map the new hash to v2 in hash-map.conf

# 4. Deploy and verify
ssh root@router /opt/etc/init.d/S80nginx-webui restart
# Check logs: logread -e ew-patch
```

## Known bundle hashes

| JS Hash | CSS Hash | Firmware | Arch | Patch Set |
|---------|----------|----------|------|-----------|
| `ZYVOXYLQ` | `AVEVNDW4` | KeeneticOS 5.0.4 | mipsel | v1 |
| `XXXXXXXX` | `J4CVWJOW` | KeeneticOS 5.0.8 | aarch64 | v1 |
| `4QPHZXFY` | `D5VNMMPD` | KeeneticOS 5.0.8 | mipsel | v1 |
| `TXLLNFBH` | `DKYWR66I` | KeeneticOS 5.0.10 | mipsel | v1 |
| `JELMZ7TJ` | `DKYWR66I` | KeeneticOS 5.0.11 | mipsel | v1 |
| `3FF05DF` | `3FF05DF` | KeeneticOS 5.1 Beta 3 | mipsel | v2 |
| `8787931` | `8787931` | KeeneticOS 5.1.0 | mipsel | v3 |

## Patch set contract

Each `v<N>.sh` file must:

- Define `apply_patches()` function accepting one argument (bundle path)
- Use `sed -i` for in-place modifications
- Not call `exit` (sourced by main script)
- Be POSIX sh compatible (no bash-isms)

## See also

- [Stock htdocs backup runbook](../docs/stock-backup-runbook.md) — how to capture stock UI after firmware upgrades

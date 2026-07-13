# Bundle Patch Files

Version-specific sed patches for Keenetic stock UI Angular bundles.

Different routers may run different KeeneticOS firmware versions and CPU
architectures. Each firmware produces a unique Angular bundle (`main-<HASH>.js`).
Patches are grouped into **patch sets** (`v1.sh`, `v2.sh`, ...) and auto-detected
from the bundle content.

## How it works

1. `patch-stock-ui.sh` copies stock UI to tmpfs (`/tmp/ew-webui/`)
2. Content-based detection: greps the stock bundle for `Xx={INTERNET:"INTERNET"` —
   the DashboardSection enum **definition** (unique across the bundle)
3. Extracts the enum variable name (e.g. `Po`, `Vo`, `Mo`, `Oo`)
4. Scans all `patches/v*.sh` files for matching `PATCH_ENUM="<EnumName>"`
5. First matching patch file is selected
6. Sources `<version>.sh` and calls `apply_patches "$BUNDLE"`
7. Verifies critical patterns in the patched bundle
8. Writes `/tmp/ew-webui/.patch-state` for `status.sh`

## File structure

```
webui/patches/
├── families/
│   ├── setter.sh   # Shared logic for setter-based Angular (v1, v2)
│   └── signal.sh   # Shared logic for signal-based Angular (v3, v4)
├── v1.sh           # Patch set v1: Po enum (KeeneticOS 5.0.x)
├── v2.sh           # Patch set v2: Vo enum (KeeneticOS 5.1 pre-release)
├── v3.sh           # Patch set v3: Mo enum (KeeneticOS 5.1.0+)
├── v4.sh           # Patch set v4: Oo enum (KeeneticOS 5.1.1+)
└── README.md
```

## Patch families

Patch files within the same Angular architecture differ **only** by the minified
enum name (e.g. `Po` vs `Vo`). To avoid duplicating ~60 lines of sed patterns,
the common logic is extracted into **family files** under `families/`:

| Family | File | Architecture | Used by |
|--------|------|-------------|---------|
| **setter** | `families/setter.sh` | `set order(e)`, `templateMap.get(e)`, single layout array | v1, v2 |
| **signal** | `families/signal.sh` | `order=V([])` signal, `templateMap().get(e)`, desktop/mobile split | v3, v4 |

Each `v<N>.sh` is now a ~20-line declarative wrapper:
1. Declares `PATCH_ENUM="<EnumName>"`
2. Sources the appropriate family: `. "$PATCHES_DIR/families/<family>.sh"`
3. Defines `apply_patches()` → delegates to `_apply_<family>_patches "$PATCH_ENUM" "$1"`

### Adding a new enum (same family)

When a firmware upgrade only renames the enum (e.g. `Oo` → `Xo`), create
a new ~20-line file:

```sh
#!/opt/bin/sh
# Patch set v5 — dashboard card integration for ENTWARE_EXTRAS
# shellcheck disable=SC2034
PATCH_ENUM="Xo"
# Verified against stock bundles:
#   <firmware>  <arch>  main-<HASH>.js  styles-<HASH>.css

: "${PATCHES_DIR:=$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=families/signal.sh
. "$PATCHES_DIR/families/signal.sh"

apply_patches() { _apply_signal_patches "$PATCH_ENUM" "$1"; }
```

### When to create a new family

Create a new `families/<name>.sh` when Angular changes its architecture
fundamentally (e.g. setter → signal transition in 5.1.0). Signs:
- `getTemplate` signature changes
- Order management changes (setter vs signal vs something new)
- Layout structure changes (single array vs desktop/mobile split)

## Adding support for new firmware

After a firmware upgrade when patches stop applying (new enum in bundle):

```sh
# 1. SSH to router, find the enum name in the stock bundle
grep -o '[A-Za-z][A-Za-z0-9]*={INTERNET:"INTERNET"' /usr/share/htdocs_/main-*.js
# => Xo={INTERNET:"INTERNET"  — new enum Xo!

# 2. Test existing patch patterns (signal family example)
for pat in 'TELEPHONY:"TELEPHONY"}' \
  '[Oo.TELEPHONY]:"dashboard.card_nvox.title"};' \
  'getTemplate(e){return this.templateMap().get(e)??null}'; do
  grep -qF "$pat" /usr/share/htdocs_/main-*.js && echo "✅ $pat" || echo "❌ $pat"
done

# 3a. Same family, new enum only: create v5.sh (~10 lines)
#     PATCH_ENUM="Xo", source families/signal.sh — done!

# 3b. Architecture changed: create families/new-arch.sh with new sed patterns,
#     then create v5.sh sourcing it

# 4. Deploy and verify
ssh root@router /opt/etc/init.d/S80nginx-webui restart
# Check logs: logread -e ew-patch
```

## Known bundle hashes

| JS Hash | CSS Hash | Firmware | Arch | Patch Set | Enum |
|---------|----------|----------|------|-----------|------|
| `ZYVOXYLQ` | `AVEVNDW4` | KeeneticOS 5.0.4 | mipsel | v1 | Po |
| `XXXXXXXX` | `J4CVWJOW` | KeeneticOS 5.0.8 | aarch64 | v1 | Po |
| `4QPHZXFY` | `D5VNMMPD` | KeeneticOS 5.0.8 | mipsel | v1 | Po |
| `TXLLNFBH` | `DKYWR66I` | KeeneticOS 5.0.10 | mipsel | v1 | Po |
| `JELMZ7TJ` | `DKYWR66I` | KeeneticOS 5.0.11 | mipsel | v1 | Po |
| `3FF05DF` | `3FF05DF` | KeeneticOS 5.1 Beta 3 | mipsel | v2 | Vo |
| `8787931` | `8787931` | KeeneticOS 5.1.0+ | mipsel | v3 | Mo |
| `553997B` | `553997B` | KeeneticOS 5.1.1 | mipsel | v4 | Oo |

## Patch set contract

Each `v<N>.sh` file must:

- Declare `PATCH_ENUM="<EnumName>"` — the DashboardSection enum for this bundle
- Define `apply_patches()` function accepting one argument (bundle path)
- Use `patch_sed "<label>" "<check>" "<sed_expr>" "$_bundle"` for each patch (sed + verify in one call, defined in `patch-stock-ui.sh`)
- Not call `exit` (sourced by main script)
- Be POSIX sh compatible (no bash-isms)

## See also

- [Stock htdocs backup runbook](../docs/stock-backup-runbook.md) — how to capture stock UI after firmware upgrades

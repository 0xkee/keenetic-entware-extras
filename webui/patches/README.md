# Bundle Patch System

Auto-detected sed patches for Keenetic stock UI Angular bundles.

Different routers may run different KeeneticOS firmware versions and CPU
architectures. Each firmware produces a unique Angular bundle (`main-<HASH>.js`).
Patches are auto-detected from bundle content and applied dynamically — no
per-enum configuration files needed.

## How it works

1. `patch-stock-ui.sh` copies stock UI bundles to `webui/htdocs-cache/`
2. Extracts the DashboardSection enum name from the bundle
   (greps for `Xx={INTERNET:"INTERNET"` — the unique enum definition)
3. Detects **patch family** from architecture markers:
   - `signal`: `this.templateMap().get` (KeeneticOS 5.1.0+)
   - `setter`: `set order(e){this.elementsOrder=e}` (KeeneticOS 5.0.x)
4. Sources `families/<family>.sh` and applies patches with the detected enum
5. Verifies each patch via `patch_sed()` (check string after sed)
6. On any patch failure: rolls back to clean stock bundle
7. Writes `webui/htdocs-cache/.patch-state` for `status.sh`

**Key benefit:** when a firmware upgrade only renames the minified enum
(e.g. `Mo`→`Oo`→`Lo`→`zo`), patches apply automatically with zero changes.
A new release is only needed when the Angular **architecture** changes
(e.g. setter→signal transition in 5.1.0).

## File structure

```
webui/patches/
├── families/
│   ├── setter.sh   # Patch logic for setter-based Angular (5.0.x)
│   └── signal.sh   # Patch logic for signal-based Angular (5.1.0+)
└── README.md
```

## Patch families

Each family file contains the sed patterns for a specific Angular architecture.
The enum name is passed as a parameter (`$_E`) — patterns are enum-agnostic.

| Family | File | Architecture | Marker |
|--------|------|-------------|--------|
| **setter** | `families/setter.sh` | `set order(e)`, `templateMap.get(e)`, single layout array | `set order(e){this.elementsOrder=e}` |
| **signal** | `families/signal.sh` | `order=V([])` signal, `templateMap().get(e)`, desktop/mobile split | `this.templateMap().get` |

### When to create a new family

Create a new `families/<name>.sh` when Angular changes its architecture
fundamentally (e.g. setter → signal transition in 5.1.0). Signs:
- `getTemplate` signature changes
- Order management changes (setter vs signal vs something new)
- Layout structure changes (single array vs desktop/mobile split)

Also add a new architecture marker grep in `patch-stock-ui.sh` (the
`DETECTED_FAMILY` detection block).

## Rollback on failure

Before applying patches, `patch-stock-ui.sh` backs up the bundle:
`cp "$BUNDLE" "$BUNDLE.orig"`. If any `patch_sed` fails (`_PATCH_FAIL > 0`),
the original is restored. This ensures the UI is never left in a partially
patched (broken) state — it falls back to stock UI + inject.js overlay.

## Diagnostics after firmware upgrade

```sh
# 1. SSH to router, check auto-patch result
logread -e ew-patch

# 2. Check patch state
cat /opt/keenetic-entware-extras/webui/htdocs-cache/.patch-state

# 3. Verify architecture markers in stock bundle
grep -o '[A-Za-z][A-Za-z0-9]*={INTERNET:"INTERNET"' /usr/share/htdocs_/main-*.js
grep -c 'this.templateMap().get' /usr/share/htdocs_/main-*.js

# 4. Full compatibility check from dev machine
./scripts/stock-webui-check.sh --host <router>
```

## Family file contract

Each `families/<name>.sh` must:

- Define `_apply_<name>_patches()` accepting two arguments: enum name and bundle path
- Use `patch_sed "<label>" "<check>" "<sed_expr>" "$_bundle"` for each patch
  (`patch_sed` is defined in `patch-stock-ui.sh`)
- Not call `exit` (sourced by main script)
- Be POSIX sh compatible (no bash-isms)
- Use `$_E` (first argument) for enum substitution in sed patterns

## See also

- [Stock htdocs backup runbook](../docs/stock-backup-runbook.md) — how to capture stock UI after firmware upgrades

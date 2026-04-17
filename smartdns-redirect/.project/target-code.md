# Code Quality Targets — smartdns-redirect

Inherits all rules from root [`.project/target-code.md`](../../.project/target-code.md).

## Additional Constraints

### Shebang

- `#!/opt/bin/sh` — все скрипты smartdns-redirect используют POSIX sh / BusyBox ash only
- Никаких bash-specific features (`pipefail`, `[[ ]]`, arrays, `declare`)

### Sourcing lib/common.sh

В отличие от smartdns-ru (который использует inline helpers), smartdns-redirect **source'ит** [`lib/common.sh`](../../lib/common.sh) для `log`, `log_error`, `require_cmd`, `file_mtime`.

Паттерн (как в [`geo-split/scripts/attach-rules.sh`](../../geo-split/scripts/attach-rules.sh)):

```sh
#!/opt/bin/sh
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/smartdns-redirect.conf"
```

### Config Location (conffile)

**Single source of truth**: `/opt/keenetic-entware-extras/smartdns-redirect/config/smartdns-redirect.conf` — по этому же пути он хранится в репо и в installed package. `opkg` помечает его `conffile` — пользовательские правки preserves при upgrade.

НЕ создавать `/opt/etc/smartdns-redirect.conf` или симлинки — избыточно. Паттерн идентичен [`geo-split`](../../geo-split/).

### iptables (НЕ ip rule)

В отличие от [`geo-split`](../../geo-split/) (который делает routing через `ip rule`), smartdns-redirect использует **только `iptables -t nat PREROUTING REDIRECT`**. Это stateless NAT, совместимый с Keenetic NDM.

**Категорически избегать**:
- `iptables -t mangle MARK` — конфликтует с NDM fwmark system ([`docs/knowledge/keenetic-fwmark-analysis.md`](../../docs/knowledge/keenetic-fwmark-analysis.md))
- `ipset` — не нужен; список `br0` + `br1` держится в `INTERFACES` переменной
- `iptables-save` / `iptables-restore` — NDM управляет таблицами, persistence через `netfilter.d` hook

### Idempotency mandatory

**Любой** скрипт, модифицирующий iptables, обязан быть идемпотентным:
- `add_rule_if_missing()` — проверка `iptables -C` перед `-I`
- `del_all_rules()` — парсит `-S` и удаляет по сигнатуре (не по текущему конфигу)
- `stop` после `stop` — не падает (`|| true` или `while -C ... do -D done`)

### Logging via common.sh

- `log "message"` — для успешных операций (syslog + stdout)
- `log_error "message"` — для ошибок (syslog `user.err` + stderr)
- Никаких `echo "WARNING: ..."` — только `log`/`log_error`

### Size limits (per script)

| Script | Target | Actual (v0.1.1) |
|--------|--------|-----------------|
| `dns-redirect.sh` | ≤150 | 138 |
| `watchdog.sh` | ≤120 | 92 |
| `status.sh` | ≤200 | ~175 |
| `netfilter-hook.sh` | ≤30 | 20 |
| `S39smartdns-redirect` (init) | ≤60 | 44 |
| `packaging/*/postinst` | ≤40 | 28 |
| `packaging/*/prerm` | ≤30 | 18 |
| `packaging/*/postrm` | ≤20 | 12 |

Total: ~330 строк shell-кода (target ≤300, marginal overage acceptable).

### Shellcheck

ВСЕ скрипты (включая maintainer-скрипты `postinst`/`prerm`/`postrm`) обязаны проходить:

```bash
shellcheck -x -s sh <script>
```

Без warnings. Допускаются только:
- `# shellcheck disable=SC3043` — `local` supported by ash/busybox sh
- `# shellcheck disable=SC1091` — sourced files resolved at runtime
- `# shellcheck source=/dev/null` — для conditional source

### BusyBox-specific restrictions

В дополнение к root `target-code.md`:

- `iptables -C` — проверка наличия правила; используй для idempotency
- `iptables -S PREROUTING | grep -E '...'` — извлечение правил для `del_all_rules`
- `netstat -lnu` — проверка UDP listeners (fallback когда нет `dig`)
- `logger -t smartdns-redirect` — syslog tagging для filter через `logread | grep`
- `command -v ip6tables` — guard перед IPv6 операциями

### Naming conventions

- Scripts: `kebab-case.sh` (`dns-redirect.sh`, `netfilter-hook.sh`)
- Init: `S##name` (`S39smartdns-redirect`) — S39 после S38smartdns
- NDM hook symlink: `smartdns-redirect-hook` в `netfilter.d/` (без numeric prefix)
- Cron entry tag: `smartdns-redirect` — для `sed -i '/smartdns-redirect/d'`

### Versioning (.ipk per [`AGENTS.md`](../../AGENTS.md))

- `0.1.x` — initial stable releases (Phase 1-4 implemented, Phase 5 optional pending)
- Bump `PATCH` (0.1.1 → 0.1.2) — bug fixes, minor config tweaks, docs
- Bump `MINOR` (0.1.x → 0.2.0) — new features (Phase 5 MAC-exclusion, AGH/Unbound presets)
- Bump `MAJOR` (0.x → 1.0) — breaking changes (config format change, symlink rename, etc.)

Текущая версия фиксируется в [`packaging/smartdns-redirect/control`](../../packaging/smartdns-redirect/control) → `Version:` field.

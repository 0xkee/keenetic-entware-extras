# Code Quality Targets — smartdns-conf-ru-split

Inherits all rules from root [`.project/target-code.md`](../../.project/target-code.md).

## Additional Constraints

### Shebang
- `#!/opt/bin/sh` — all smartdns-conf-ru-split scripts use POSIX sh only

### No lib/common.sh
- `lib/common.sh` uses `#!/opt/bin/bash` with bash-specific features (`local`, `&>/dev/null`)
- Since smartdns-conf-ru-split scripts use POSIX sh, they MUST NOT source `lib/common.sh`
- Define local `log()` / `log_error()` helpers directly in each script

### Available Entware Tools
- `opkg` — package management (`opkg install smartdns`)
- `smartdns` — DNS server binary (`/opt/sbin/smartdns`)
- `logger` — syslog logging
- `pidof` — process lookup

### Init Script Pattern
- Custom init at `/opt/etc/init.d/S60smartdns` (higher priority than default S38)
- Default `/opt/etc/init.d/S38smartdns` disabled via `chmod -x`
- PID file: `/opt/var/run/smartdns.pid`

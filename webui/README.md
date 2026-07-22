# webui

> 📖 **[User Manual (RU)](docs/user-manual.ru.md)** — step-by-step installation, configuration, troubleshooting.

Monitoring web panel for Keenetic/Entware — service status dashboard + stock WebUI patching with custom menu and card injection.

Typical use cases:
- 📊 **Monitoring:** unified status dashboard for geo-split, smartdns-geo-conf, smartdns-redirect, system (uptime, RAM, disk)
- 🎨 **Integration:** Entware Extras card on stock Keenetic dashboard + Cards Position dialog via inject.js (dashboard card + optional sidebar, `INJECT_SIDEBAR=0` by default)
- 🔌 **API:** JSON endpoints for automation and monitoring via Lua

## Installation

Primary method — via opkg:

```sh
opkg install webui_<ver>_all.ipk
```

Dependencies (`keenetic-entware-extras`, `nginx`, `nginx-mod-lua`, `logrotate`) are installed automatically.

> `config/nginx.conf`, `config/logrotate.conf`, `config/config.conf` — conffiles: preserved during `opkg upgrade`.

After installation:

```sh
# Dashboard is available immediately (postinst starts the service)
# Custom dashboard:
curl http://<router-ip>:8080/custom/

# Patched stock WebUI:
curl http://<router-ip>:8080/
```

## Removal

```sh
opkg remove webui
```

Automatically performs: nginx-webui stop, htdocs-cache removal, init script and logrotate config deletion. Logs are preserved for inspection.

## Architecture

A separate nginx instance on port `:8080`, independent of stock Keenetic httpd (:80). Stock UI is patched in tmpfs on start/reload — no modification of original files.

```
Browser → nginx :8080
  ├── /custom/*     → static (custom dashboard, JS/CSS)
  ├── /api/*        → content_by_lua (api-router.lua) → shell → JSON
  ├── /auth, /rci/  → proxy_pass 127.0.0.1:80 (stock httpd, WebSocket)
  └── /*            → static webui/htdocs-cache/ (patched bundles) + @stock /usr/share/htdocs_ (flash)
                      └── patch-stock-ui.sh: inject.js + inject.css + v1/v2/v3/v4.sh bundle patches
```

### Stock UI patching

On `start` or `reload`, script `patch-stock-ui.sh`:

1. Copies only bundle files (`index.html`, `main-*.js`, `polyfills-*.js`, `styles-*.css`) from `/usr/share/htdocs_/` → `webui/htdocs-cache/`
2. Patches `index.html` — injects `<script>` and `<link>` tags (`inject.js`, `inject.css`)
3. Auto-detects patch set by scanning the stock bundle for `PATCH_ENUM` patterns
4. Calls `source patches/vN.sh` → `apply_patches` on JS bundle (sed replacements for CDK DragDrop integration)
5. Pre-compresses bundles with gzip for `gzip_static`
6. Writes `webui/htdocs-cache/.patch-state` for `status.sh`
7. nginx serves patched files from htdocs-cache/, unpatched files via `@stock` fallback from flash

**Auto-detection** — each `vN.sh` declares `PATCH_ENUM="<EnumName>"` (the Angular DashboardSection enum). The script greps the stock bundle for `Xx={INTERNET:"INTERNET"` — the enum **definition** — and matches exactly one patch set:

| Patch set | Enum | Firmware |
|-----------|------|----------|
| `v1` | `Po` | KeeneticOS 5.0.x |
| `v2` | `Vo` | KeeneticOS 5.1 pre-release |
| `v3` | `Mo` | KeeneticOS 5.1.0+ |
| `v4` | `Oo` | KeeneticOS 5.1.1+ |

**Adding a new firmware:** if enum changed, create `vN.sh` with new `PATCH_ENUM` and updated sed patterns. See [patches/README.md](patches/README.md).

## Management commands

```sh
/opt/etc/init.d/S80nginx-webui <command>
```

| Command | Action |
|---------|--------|
| `start` | Patches stock UI (`patch-stock-ui.sh`) + starts nginx-webui |
| `stop` | Stops nginx-webui + removes `webui/htdocs-cache` |
| `restart` | `stop` + `start` |
| `reload` | Re-patch + `nginx -s reload` (for updates after firmware upgrade) |
| `check` / `status` | Check status (running/not running) |

Detailed diagnostics:

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
/opt/keenetic-entware-extras/webui/scripts/status.sh --json
```

## Configuration

Config file: `config/config.conf`

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ENABLED` | `"yes"` | Enable/disable service (`"yes"` / `"no"`) |
| `LISTEN_PORT` | `8080` | nginx-webui port |
| `INJECT_SIDEBAR` | `0` | Sidebar menu injection into stock UI (0/1) |
| `DASH_POLL_INTERVAL` | `30000` | Dashboard API polling interval (ms) |
| `PIDFILE` | `/tmp/nginx-webui.pid` | PID file (tmpfs — reset on reboot) |
| `LOG_TAG` | `"kee-webui"` | Tag for logger |

> **Listen address:** generated in `config/listen.conf` during `postinst` (via `detect_router_ip`) + `listen 127.0.0.1:8080`. No hardcoded IP.

After changing config:

```sh
/opt/etc/init.d/S80nginx-webui restart
```

## API

All endpoints are served via `content_by_lua_file api-router.lua`.

### GET (status)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/system/info` | System info (hostname, uptime, RAM, disk) |
| GET | `/api/system/zones` | Geo-zone list for dropdown (TTL 1h) |
| GET | `/api/system/dns-providers` | DNS providers for config editor (TTL 1h) |
| GET | `/api/geo-split/status` | geo-split status |
| GET | `/api/smartdns/status` | smartdns-geo-conf status |
| GET | `/api/smartdns-redirect/status` | smartdns-redirect status |
| GET | `/api/webui/status` | webui self-diagnostics |

### POST (actions)

Return `405 Method Not Allowed` if called via non-POST.

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/geo-split/start` | Start geo-split |
| POST | `/api/geo-split/stop` | Stop geo-split |
| POST | `/api/smartdns/start` | Enable smartdns config |
| POST | `/api/smartdns/stop` | Disable smartdns config |
| POST | `/api/smartdns-redirect/start` | Start dns-redirect |
| POST | `/api/smartdns-redirect/stop` | Stop dns-redirect |
| POST | `/api/geo-split/update-subnets` | Update subnets (background) |
| POST | `/api/geo-split/update-domains` | Update domains (background) |
| POST | `/api/webui/flush-cache` | Flush UI status cache (force fresh data) |
| POST | `/api/smartdns/flush-cache` | Flush SmartDNS persistent cache (stop + rm + restart) |

### GET/POST (configuration)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/{service}/config` | Read current service configuration |
| POST | `/api/{service}/config` | Save configuration + restart service |

### GET (diagnostics)

Rate-limited: 1 request/sec per IP (nginx `limit_req`).

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/geo-split/route-check?host=...&from=...` | Route check to host (from: client MAC or `local`) |
| GET | `/api/smartdns/dns-check?host=...` | DNS diagnostics: zone, upstream, resolution |
| GET | `/api/geo-split/wan-paths` | WAN path list (for diagram) |
| GET | `/api/system/clients` | Client list with routing policies |
| GET | `/api/system/interfaces` | Network interfaces with labels |

### Response format

**system/info:**
```json
{"ok":true,"hostname":"Keenetic","uptime":"5d 3h 12m","memory":{"total_kb":262144,"available_kb":180000},"disk_opt":{"total_kb":7654321,"used_kb":1234567,"free_kb":6419754}}
```

**status endpoints:** direct JSON from `status.sh --json`:
```json
{"running":true,"ok":true,"details":{...}}
```

**action endpoints:**
```json
{"ok":true,"output":"..."}
```

## Diagnostics (status.sh)

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
```

Example output:

```
nginx-webui status:
  Service:
    Process:     running (pid 1234 via pidfile, RSS 2048kB) ✓
    Config:      /opt/keenetic-entware-extras/webui/config/nginx.conf ✓
    Lua module:  /opt/lib/nginx/modules/ngx_http_lua_module.so ✓
    Port:        :8080 listening ✓

  HTTP:
    Static:      GET / → 200 ✓
    API:         GET /api/system/info → 200 ✓

  Logrotate:
    Binary:      /opt/sbin/logrotate ✓
    Config:      /opt/etc/logrotate.d/nginx-webui ✓
    Cron daily:  /opt/etc/cron.daily/logrotate ✓

  System:
    Uptime:      5d 3h 12m ✓
    Version:     x.y.z
```

**Exit code:** `0` — all OK, `1` — issues detected (✗ in output).

## Files

| File | Purpose |
|------|---------|
| `config/config.conf` | Configuration (ENABLED, port, sidebar, poll interval) |
| `config/nginx.conf` | nginx configuration (listen, proxy, lua paths, gzip) |
| `config/logrotate.conf` | Logrotate: nginx-webui error log rotation |
| `config/listen.conf` | Listen address (generated by postinst, not a conffile) |
| `lua/api-router.lua` | Lua router: /api/* → shell commands → JSON |
| `lua/serve-index.lua` | (not used in current architecture) |
| `lua/stock-css-init.lua` | Lua: stock CSS scanning on nginx start |
| `patches/v1.sh` | Patch set v1: Po enum (KeeneticOS 5.0.x) |
| `patches/v2.sh` | Patch set v2: Vo enum (KeeneticOS 5.1 pre-release) |
| `patches/v3.sh` | Patch set v3: Mo enum (KeeneticOS 5.1.0+) |
| `patches/v4.sh` | Patch set v4: Oo enum (KeeneticOS 5.1.1+) |
| `patches/families/setter.sh` | Shared patch logic for setter-based Angular (v1, v2) |
| `patches/families/signal.sh` | Shared patch logic for signal-based Angular (v3, v4) |
| `scripts/patch-stock-ui.sh` | Copies stock UI to tmpfs and applies patches |
| `scripts/status.sh` | Diagnostics: process, port, config, HTTP, logrotate |
| `static/index.html` | Custom dashboard — HTML |
| `static/app.js` | Custom dashboard — JS (status cards, tabs, API) |
| `static/shared.js` | Shared utilities EW.* (SERVICE_APIS, formatters, ticker, poller) |
| `static/inject.js` | Stock UI injection (sidebar, dashboard card, toggle, expand) |
| `static/inject.css` | Styles for inject.js components |
| `static/common.css` | Shared styles (update buttons, tooltips) |
| `static/layout.css` | Custom dashboard layout styles |
| `static/config-editor.js` | Config Editor (~790 lines, extracted from app.js) |
| `static/route-check.js` | Route Check UI |
| `static/route-diagram.js` | SVG route diagram |
| `static/route-diagram.css` | SVG diagram styles |
| `static/502.html` | Error page when stock httpd is unavailable |
| `init.d/S80nginx-webui` | Init script (start/stop/restart/check/status/reload) |

## Logs

| File | Description |
|------|-------------|
| `/tmp/nginx-webui-error.log` | nginx + Lua errors (level: error, tmpfs — lost on reboot) |
| Access log | Disabled (I/O savings; diagnostics via `status.sh`) |
| `/opt/etc/logrotate.d/nginx-webui` | Logrotate config (daily, rotate 3, compress, USR1 reopen) |

## Dependencies

| Package | Type | Purpose |
|---------|------|---------|
| `keenetic-entware-extras` | Depends | Base package (shared libraries) |
| `nginx` | Depends | Web server |
| `nginx-mod-lua` | Depends | Lua module for nginx (API, init) |
| `logrotate` | Depends | Log rotation |

## For developers

Build .ipk:

```sh
./scripts/build-ipk.sh webui
# Result: dist/webui_<ver>_all.ipk
```

Deploy without .ipk:

```sh
scp -O -r webui/ root@<router>:/opt/keenetic-entware-extras/webui/
scp -O -r lib/ root@<router>:/opt/keenetic-entware-extras/lib/
ssh root@<router> '/opt/etc/init.d/S80nginx-webui restart'
```

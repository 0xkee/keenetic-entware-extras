# WebUI Dashboard

> **Status: SPIKE** (proof-of-concept)

Web dashboard for keenetic-entware-extras services.  
Shows status of geo-split, smartdns, smartdns-redirect and system info.

## Stack

- **Entware nginx** + **nginx-mod-lua** (LuaJIT)
- Vanilla HTML/JS/CSS frontend
- Shell scripts called via `io.popen` for status data

## Architecture

```
Browser (JS) → Entware nginx :8080 → location / (static HTML/JS/CSS)
                                    → location /api/ → content_by_lua (api-router.lua)
                                                       → io.popen(shell) → JSON
```

## Prerequisites

```sh
opkg install nginx-ssl nginx-mod-lua
```

> **Note:** `lua-resty-core` may not work on ARM — `lua_load_resty_core off` is set in config.

## File Structure (on router)

| Source (repo)                         | Target (router)                         |
|---------------------------------------|-----------------------------------------|
| `config/nginx.conf`                   | `/opt/keenetic-entware-extras/webui/config/nginx.conf` |
| `lua/api-router.lua`                  | `/opt/keenetic-entware-extras/webui/lua/api-router.lua` |
| `lua/stock-css-init.lua`              | `/opt/keenetic-entware-extras/webui/lua/stock-css-init.lua` |
| `static/*`                            | `/opt/keenetic-entware-extras/webui/static/` |
| `rootfs/opt/etc/init.d/S80nginx-webui`| `/opt/etc/init.d/S80nginx-webui`        |
| `scripts/status.sh`                   | `/opt/keenetic-entware-extras/webui/scripts/status.sh` |

## Deploy (manual spike)

```sh
# 1. Install packages
opkg install nginx-ssl nginx-mod-lua

# 2. Deploy project tree (all files live under remote_base)
# Files are deployed via scp/opkg to /opt/keenetic-entware-extras/webui/

# 3. Copy init script
cp static/* /opt/share/keenetic-webui/

# 5. Copy init script
cp rootfs/opt/etc/init.d/S80nginx-webui /opt/etc/init.d/
chmod +x /opt/etc/init.d/S80nginx-webui

# 6. Start
/opt/etc/init.d/S80nginx-webui start

# 7. Verify
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/api/system/info
```

## API Endpoints

| Method | Endpoint                        | Description                |
|--------|---------------------------------|----------------------------|
| GET    | `/api/system/info`              | System info (JSON, native) |
| GET    | `/api/geo-split/status`         | geo-split status.sh output |
| GET    | `/api/smartdns/status`          | smartdns status.sh output  |
| GET    | `/api/smartdns-redirect/status` | smartdns-redirect status   |
| GET    | `/api/webui/status`             | webui self-status          |

### Response format

**system/info:**
```json
{
  "ok": true,
  "hostname": "Keenetic",
  "uptime": "5d 3h 12m",
  "memory": {"total_kb": 262144, "available_kb": 180000},
  "disk_opt": {"total_kb": 7654321, "used_kb": 1234567, "free_kb": 6419754}
}
```

**status endpoints:**
```json
{
  "ok": true,
  "output": "geo-split:\n    Process: running ✓\n    ..."
}
```

## Logs

- Error log: `/opt/var/log/nginx-webui-error.log`
- Access log: `/opt/var/log/nginx-webui-access.log`

#!/opt/bin/sh
# Configuration for webui.
# Custom dashboard + reverse proxy for Keenetic stock WebUI.
# Edit these values to customize webui behavior.
# shellcheck disable=SC2034  # all variables are used by sourcing scripts

# Enable/disable webui service ("yes" / "no")
ENABLED="yes"

# Listen port for nginx-webui
LISTEN_PORT=8080

# Inject Entware Extras sidebar section into stock Keenetic menu (0/1).
# When 1: adds "Entware Extras" group with pages (Dashboard, Geo Split,
# SmartDNS Config, DNS Redirect, WebUI) into the stock Keenetic sidebar.
# When 0: stock sidebar untouched, custom pages accessible only
# via /custom/ URL directly.
# Default: 0 (disabled — don't modify stock menu)
INJECT_SIDEBAR=0

# Dashboard polling interval (milliseconds)
DASH_POLL_INTERVAL=30000

# PID file
PIDFILE="/tmp/nginx-webui.pid"

# Log tag
LOG_TAG="kee-webui"

#!/opt/bin/sh
# Install geo-bypass: init script + cron jobs + NDM hook.
#
# NOTE: Deploy via tar may overwrite lists/domains.txt on the router.
# Use: tar cf - lib/ geo-bypass/ --exclude='geo-bypass/lists/*.txt' | ssh ...
# Or restore from backup after deploy.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log "Installing geo-bypass from: $INSTALL_DIR"

# --- Install Entware dependencies ---

install_dependencies() {
  log "Checking required dependencies..."
  for pkg in ipset curl ip-full; do
    if opkg status "$pkg" 2>/dev/null | grep -q "Status:.*installed"; then
      log "$pkg: already installed"
    else
      log "Installing $pkg..."
      opkg install "$pkg"
    fi
  done

  # Optional: dig for domain DNS resolution
  if ! command -v dig >/dev/null 2>&1; then
    log "Optional: dig not found. Install for domain resolution: opkg install bind-dig"
  else
    log "dig: already installed (domain resolution available)"
  fi
}

# --- Install init script ---

create_init_script() {
  local init_target="/opt/etc/init.d/S99geo-bypass"
  local init_source="$INSTALL_DIR/rootfs/opt/etc/init.d/S99geo-bypass"

  if [ ! -f "$init_source" ]; then
    log_error "Init script source not found: $init_source"
    exit 1
  fi

  # Copy and patch INSTALL_DIR to match actual install location
  sed "s|^INSTALL_DIR=.*|INSTALL_DIR=\"$INSTALL_DIR\"|" "$init_source" > "$init_target"
  chmod +x "$init_target"
  log "Installed init script: $init_target (INSTALL_DIR=$INSTALL_DIR)"
}

# --- Install NDM hook (interface up/down) ---

install_ndm_hook() {
  local ndm_hook_dir="/opt/etc/ndm/ifstatechanged.d"
  local ndm_hook_link="$ndm_hook_dir/geo-bypass-hook"
  local hook_script="$INSTALL_DIR/scripts/ndm-hook.sh"

  mkdir -p "$ndm_hook_dir"
  chmod +x "$hook_script"
  ln -sf "$hook_script" "$ndm_hook_link"
  log "Installed NDM hook: $ndm_hook_link -> $hook_script"
}

# --- Install cron jobs ---

install_cron_jobs() {
  local cron_file="/opt/etc/crontab"

  # Remove old geo-bypass cron entries first
  if [ -f "$cron_file" ]; then
    sed -i '/geo-bypass/d' "$cron_file"
    log "Cleaned old cron entries"
  fi

  # Add new cron jobs (system crontab format: schedule + user + command)
  {
    echo "# geo-bypass: periodic updates (cache freshness checked internally)"
    echo "*/15 * * * * root $INSTALL_DIR/scripts/update-subnets.sh"
    echo "*/15 * * * * root $INSTALL_DIR/scripts/update-domains.sh"
  } >> "$cron_file"
  log "Added cron jobs to $cron_file"

  # Restart crond to pick up new entries
  if [ -x /opt/etc/init.d/S10cron ]; then
    /opt/etc/init.d/S10cron restart
    log "Restarted crond"
  fi
}

# --- Main ---

install_dependencies
create_init_script
install_ndm_hook
install_cron_jobs

log "Installation complete. Run: /opt/etc/init.d/S99geo-bypass start"

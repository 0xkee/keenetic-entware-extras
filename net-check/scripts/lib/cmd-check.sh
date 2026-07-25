# net-check: Deep single-resource check — HTTP + DNS + TLS + CDN for one domain.
# Multi-domain mode delegates to bulk functions (cmd_compare, cmd_dns, etc.).
# Dependencies: lib/cmd-targets.sh (cmd_check_target, cmd_compare),
#   lib/cmd-dns.sh (_dns_check_single, cmd_dns),
#   lib/cmd-tls.sh (cmd_tls_check, cmd_tls_check_targets),
#   lib/cmd-cdn.sh (cmd_cdn, cmd_cdn_all),
#   lib/output.sh (section_title, emit_error, is_quiet),
#   lib/http-core.sh (url_to_host)
# Globals used: OUTPUT_JSON, C_BOLD, C_CYAN, C_RST, _EXIT_CODE
# shellcheck disable=SC3043

# ─── Command: deep check (single or multi domain) ─────────────────────────────

# Run diagnostic checks for one or more domains.
# Single domain: HTTP + DNS + TLS + CDN per-domain detailed flow.
# Multi domain: delegates to bulk functions (cmd_compare, cmd_dns, etc.).
# Args: $@ - one or more domains/URLs
cmd_check() {
  if [ $# -eq 0 ] || [ -z "${1:-}" ]; then
    emit_error "Usage: net-check check <url> [url2 ...]"
    return 1
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    _cmd_check_multi_json "$@"
  else
    _cmd_check_multi_text "$@"
  fi
}

# ─── Single-domain helpers ────────────────────────────────────────────────────

# Text-mode deep check: master header + 4 sequential sub-checks.
# Each sub-check prints its own section_title and table to stdout.
# _EXIT_CODE is updated by sub-checks in the same shell.
# Args: $1 - bare host, $2 - URL with scheme
_cmd_check_text() {
  local host="$1" url="$2"

  section_title "$host — $_TITLE_CHECK"

  # 1. HTTP reachability
  cmd_check_target "$url"

  # 2. DNS resolution
  _dns_check_single "$host"

  # 3. TLS certificate
  cmd_tls_check "$host"

  # 4. CDN geo-steering (manual section_title — cmd_cdn "no_header" skips its own)
  section_title "${_TITLE_CDN}: $host"
  cmd_cdn "$host" "" "no_header"
}

# JSON-mode deep check: capture each sub-check's JSON, assemble combined object.
# Sub-checks run in subshells ($(...)) — _EXIT_CODE is derived from JSON "ok" fields.
# Args: $1 - bare host, $2 - URL with scheme
_cmd_check_json() {
  local host="$1" url="$2"

  local _json_http _json_dns _json_tls _json_cdn

  _json_http=$(cmd_check_target "$url" 2>/dev/null) || true
  _json_dns=$(_dns_check_single "$host" 2>/dev/null) || true
  _json_tls=$(cmd_tls_check "$host" 2>/dev/null) || true
  _json_cdn=$(cmd_cdn "$host" "" "no_header" 2>/dev/null) || true

  # Emit combined JSON
  printf '{%s,%s,"http":%s,"dns":%s,"tls":%s,"cdn":%s}\n' \
    "$(json_kv "check" "deep")" \
    "$(json_kv "target" "$host")" \
    "${_json_http:-null}" \
    "${_json_dns:-null}" \
    "${_json_tls:-null}" \
    "${_json_cdn:-null}"

  # Derive _EXIT_CODE from sub-check ok fields
  local _any_fail=0
  case "${_json_http:-}" in *'"ok":false'*) _any_fail=1 ;; esac
  case "${_json_dns:-}" in *'"ok":false'*) _any_fail=1 ;; esac
  case "${_json_tls:-}" in *'"ok":false'*) _any_fail=1 ;; esac
  case "${_json_cdn:-}" in *'"ok":false'*) _any_fail=1 ;; esac
  [ "$_any_fail" = 1 ] && [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
}

# ─── Multi-domain helpers ─────────────────────────────────────────────────────

# Text-mode multi-domain check: bulk functions with passed domains.
# Args: $@ - domains/URLs
_cmd_check_multi_text() {
  section_title "$_TITLE_CHECK ($# domains)"
  print_zone_header_once

  # Populate geo cache silently so table headers show actual CC per interface
  local _saved_exit="$_EXIT_CODE"
  cmd_geo > /dev/null 2>&1 || true
  _EXIT_CODE="$_saved_exit"

  cmd_compare "$@"
  cmd_dns "$@"
  cmd_tls_check_targets "$@"
  cmd_cdn_all "$@"
}

# JSON-mode multi-domain check: capture each bulk function's JSON output.
# Args: $@ - domains/URLs
_cmd_check_multi_json() {
  local _j_comp _j_dns _j_tls _j_cdn

  _j_comp=$(cmd_compare "$@" 2>/dev/null) || true
  _j_dns=$(cmd_dns "$@" 2>/dev/null) || true
  _j_tls=$(cmd_tls_check_targets "$@" 2>/dev/null) || true
  _j_cdn=$(cmd_cdn_all "$@" 2>/dev/null) || true

  printf '{%s,"http":%s,"dns":%s,"tls":%s,"cdn":%s}\n' \
    "$(json_kv "check" "deep")" \
    "${_j_comp:-null}" \
    "${_j_dns:-null}" \
    "${_j_tls:-null}" \
    "${_j_cdn:-null}"
}

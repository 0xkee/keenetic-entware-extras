# net-check: Table rendering — simple tables and multi-interface comparison tables.
# Dependencies: colors.sh (color_status, _no_emoji, C_*), sections.sh (is_quiet)
# Globals used: OUTPUT_JSON, _TBL_FMT, _TBL_GROUP_PREV,
#   _CMP_COL_W, _CMP_LABEL_W, _ZONE_LABEL, _CELL
# shellcheck disable=SC2034
# shellcheck disable=SC2059
# shellcheck disable=SC3043

# ─── Simple Table ─────────────────────────────────────────────────────────────
# Simple table generator: header + separator + rows with consistent format.
# Globals set: _TBL_FMT (printf format string, reused by tbl_row)
#   _TBL_GROUP_PREV (previous group for tbl_group_sep)

# Print table header + separator. Stores printf format for tbl_row.
# Args: "Name:width" ... (last column without :width → unbounded)
# Skips output in JSON or quiet mode.
tbl_header() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _fmt="" _hdr="" _total_w=0 _spec _name _w
  for _spec in "$@"; do
    case "$_spec" in
      *:*) _name="${_spec%%:*}"; _w="${_spec#*:}" ;;
      *)   _name="$_spec"; _w=0 ;;
    esac
    if [ "$_w" -gt 0 ]; then
      _fmt="${_fmt}%-${_w}s "
      _hdr="${_hdr}$(printf "%-${_w}s " "$_name")"
      _total_w=$((_total_w + _w + 1))
    else
      _fmt="${_fmt}%s"
      _hdr="${_hdr}${_name}"
      _total_w=$((_total_w + ${#_name}))
    fi
  done
  _TBL_FMT="$_fmt"
  printf '%s\n' "$_hdr"
  printf '%*s\n' "$_total_w" '' | tr ' ' '-'
}

# Print table data row using stored _TBL_FMT from tbl_header.
# Args: cell values (same count as tbl_header columns)
# Skips output in JSON or quiet mode.
tbl_row() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  # shellcheck disable=SC2059
  printf "${_TBL_FMT}\n" "$@"
}

# Pad text to exact visual width, then wrap in color.
# Fixes ANSI escape codes breaking printf %-Ns alignment.
# Use for colored cells in non-last columns.
# Args: $1 - width (0 = no pad), $2 - text, $3 - color status (ok/warn/fail/dim; empty = plain)
# stdout: padded text optionally wrapped in color
tbl_cell() {
  local _w="$1" _text="$2" _st="${3:-}"
  local _padded
  if [ "$_w" -gt 0 ] 2>/dev/null; then
    # Compensate multi-byte UTF-8: em-dash "—" = 3 bytes, 1 visual column.
    # printf "%-Ns" counts bytes, not visual width → add +2 per em-dash.
    local _extra=0
    case "$_text" in *—*) _extra=2 ;; esac
    _padded=$(printf "%-$((_w + _extra))s" "$_text")
  else
    _padded="$_text"
  fi
  if [ -n "$_st" ]; then
    color_status "$_st" "$_padded"
  else
    printf '%s' "$_padded"
  fi
}

# Same as tbl_cell() but sets global _CELL instead of printing to stdout.
# Avoids subshell overhead when used as: tbl_cell_v 3 "$code" "$st"; var="$_CELL"
# Args: $1 - width, $2 - text, $3 - color status (optional)
# Sets: _CELL
tbl_cell_v() {
  local _w="$1" _text="$2" _st="${3:-}"
  if [ "$_w" -gt 0 ] 2>/dev/null; then
    local _extra=0
    case "$_text" in *—*) _extra=2 ;; esac
    _CELL=$(printf "%-$((_w + _extra))s" "$_text")
  else
    _CELL="$_text"
  fi
  if [ -n "$_st" ]; then
    case "$_st" in
      ok)   _CELL="${C_GREEN}${_CELL}${C_RST}" ;;
      warn) _CELL="${C_YELLOW}${_CELL}${C_RST}" ;;
      fail) _CELL="${C_RED}${_CELL}${C_RST}" ;;
      dim)  _CELL="${C_DIM}${_CELL}${C_RST}" ;;
    esac
  fi
}

# Print category group separator inside a table (e.g. "── Global ──").
# Tracks previous group via _TBL_GROUP_PREV global; prints separator only on group change.
# Call tbl_group_reset() before each new table to reset tracking.
# Args: $1 - category from check-targets.conf (e.g. "global", "zone-ru", "intl-streaming")
# Skips output in JSON or quiet mode.
# Depends: _ZONE_LABEL from wan.sh load_zone_context()
tbl_group_sep() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _cat="$1"
  local _cur="${_cat%%-*}"
  [ "$_cur" = "${_TBL_GROUP_PREV:-}" ] && return 0
  [ -z "$_cur" ] && return 0
  local _label
  case "$_cur" in
    global) _label="Global" ;;
    zone)   _label="Zone (${_ZONE_LABEL:-})" ;;
    intl)   _label="International" ;;
    check)  return 0 ;;
    *)      _label="$_cur" ;;
  esac
  printf '%s── %s ──%s\n' "$C_DIM" "$_label" "$C_RST"
  _TBL_GROUP_PREV="$_cur"
}

# Reset group separator tracking for a new table.
tbl_group_reset() {
  _TBL_GROUP_PREV=""
}

# ─── Comparison Table ─────────────────────────────────────────────────────────
# Multi-interface comparison table: rows = targets, columns = WAN interfaces.
# Used by: compare, tls, cdn-all.
# Globals set: _CMP_COL_W (per-interface column width)

# Print comparison table header + separator line.
# Args: $1 - first column label (e.g., "Resource", "Host", "Domain")
#       $2 - WAN interfaces list (space-separated)
#       $3 - column width (optional, default 19)
# Skips output in JSON or quiet mode.
cmp_header() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _label="$1" _ifaces="$2" _col_w="${3:-19}" _label_w="${4:-20}"
  _CMP_COL_W="$_col_w"
  _CMP_LABEL_W="$_label_w"
  printf "%-${_label_w}s" "$_label"
  local _hdr_iface _hdr_cc
  for _hdr_iface in $_ifaces; do
    _hdr_cc=$(geo_cached_cc "$_hdr_iface")
    [ -z "$_hdr_cc" ] && _hdr_cc="-"
    printf ' |  %-*s' "$_col_w" "${_hdr_iface} (${_hdr_cc})"
  done
  printf ' | %s\n' "Verdict"
  local _n_ifaces _sep_len
  _n_ifaces=$(printf '%s' "$_ifaces" | wc -w | tr -d ' ')
  _sep_len=$((_label_w + (_col_w + 4) * _n_ifaces + 12))
  printf '%*s\n' "$_sep_len" "" | tr ' ' '-'
}

# Print first cell of a comparison row.
# Args: $1 - row label (e.g., hostname)
# Skips output in JSON or quiet mode.
cmp_row_start() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  printf "%-${_CMP_LABEL_W:-20}s" "$1"
}

# Print one interface cell in the current row.
# Args: $1 - pre-formatted cell content,
#        $2 - "1" to mark as active route (►),
#        $3 - "1" to mark as recommended/best path (★) (optional)
# Marker combos: ►★ active+best, ►  active,  ★ best only, (none).
# Skips output in JSON or quiet mode.
cmp_cell() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _active="${2:-0}" _rec="${3:-0}"
  if _no_emoji; then
    if [ "$_active" = "1" ] && [ "$_rec" = "1" ]; then
      printf ' |>*%s' "$1"
    elif [ "$_active" = "1" ]; then
      printf ' |> %s' "$1"
    elif [ "$_rec" = "1" ]; then
      printf ' | *%s' "$1"
    else
      printf ' |  %s' "$1"
    fi
  else
    if [ "$_active" = "1" ] && [ "$_rec" = "1" ]; then
      printf ' |%s►%s%s★%s%s' "$C_CYAN" "$C_RST" "$C_YELLOW" "$C_RST" "$1"
    elif [ "$_active" = "1" ]; then
      printf ' |%s►%s %s' "$C_CYAN" "$C_RST" "$1"
    elif [ "$_rec" = "1" ]; then
      printf ' | %s★%s%s' "$C_YELLOW" "$C_RST" "$1"
    else
      printf ' |  %s' "$1"
    fi
  fi
}

# End row with verdict column + newline.
# Args: $1 - pre-formatted verdict text
# Skips output in JSON or quiet mode.
cmp_row_end() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  printf ' | %s\n' "$1"
}

# ─── Auto Width ───────────────────────────────────────────────────────────────

# Compute auto-width for first table column from item list.
# Args: $1 - space-separated items, $2 - min width (default 20), $3 - max width (default 30)
# stdout: computed width (integer)
auto_label_width() {
  local _alw_items="$1" _alw_min="${2:-20}" _alw_max="${3:-30}" _alw_w _alw_h
  _alw_w="$_alw_min"
  for _alw_h in $_alw_items; do
    [ "${#_alw_h}" -gt "$_alw_w" ] && _alw_w="${#_alw_h}"
  done
  _alw_w=$((_alw_w + 2))
  [ "$_alw_w" -gt "$_alw_max" ] && _alw_w="$_alw_max"
  printf '%d' "$_alw_w"
}

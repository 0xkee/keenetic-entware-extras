# net-check: Terminal color setup, status marks, emoji handling.
# Dependencies: status_setup_colors() from lib/status.sh
# Globals used: USE_COLOR, NO_COLOR,
#   C_RST, C_BOLD, C_DIM, C_GREEN, C_RED, C_YELLOW, C_CYAN
# shellcheck disable=SC2034
# shellcheck disable=SC2153
# shellcheck disable=SC3043

# Set up terminal color escape codes.
# Delegates to lib/status.sh status_setup_colors(), then aliases C_* from _SC_*.
# Respects --no-color flag, NO_COLOR env, and non-tty output.
setup_colors() {
  status_setup_colors "$USE_COLOR"
  C_RST="$_SC_RST"
  C_BOLD="$_SC_BOLD"
  C_DIM="$_SC_DIM"
  C_GREEN="$_SC_GREEN"
  C_RED="$_SC_RED"
  C_YELLOW="$_SC_YELLOW"
  C_CYAN="$_SC_CYAN"
}

# Colorize text based on status.
# Args: $1 - "ok"|"warn"|"fail"|"dim", $2 - text
# stdout: colored text (or plain if no color)
color_status() {
  local _st="$1" _txt="$2"
  case "$_st" in
    ok)   printf '%s%s%s' "$C_GREEN" "$_txt" "$C_RST" ;;
    warn) printf '%s%s%s' "$C_YELLOW" "$_txt" "$C_RST" ;;
    fail) printf '%s%s%s' "$C_RED" "$_txt" "$C_RST" ;;
    dim)  printf '%s%s%s' "$C_DIM" "$_txt" "$C_RST" ;;
    *)    printf '%s' "$_txt" ;;
  esac
}

# Check if emoji are explicitly disabled (--no-color / NO_COLOR env).
# Emoji are inherently colored and work without ANSI codes;
# only explicit --no-color replaces them with b/w Unicode.
_no_emoji() {
  [ "$USE_COLOR" = "never" ] || [ "${NO_COLOR:-}" = 1 ]
}

# Status mark: ✅ / ⚠️ / ❌ (emoji); ✓/!/✗ (--no-color).
# Args: $1 - "ok"|"warn"|"fail"|"skip"|"dim"
# stdout: emoji or b/w Unicode mark
status_mark() {
  if _no_emoji; then
    case "$1" in
      ok)   printf '✓' ;;
      warn) printf '!' ;;
      fail) printf '✗' ;;
      *)    printf '-' ;;
    esac
  else
    # Trailing space after emoji prevents terminal glyph-width eating next char.
    # ⚠️ (U+26A0+U+FE0F) is especially prone to this with variation selector.
    case "$1" in
      ok)   printf '%s✅ %s' "$C_GREEN" "$C_RST" ;;
      warn) printf '%s⚠️ %s'  "$C_YELLOW" "$C_RST" ;;
      fail) printf '%s❌ %s' "$C_RED" "$C_RST" ;;
      skip|dim) printf '%s— %s'  "$C_DIM" "$C_RST" ;;
      *)    printf '— ' ;;
    esac
  fi
}

# Cache indicator: ℹ️ cached (emoji) or 🛈 cached (--no-color).
# stdout: cache mark with label
cache_mark() {
  if _no_emoji; then
    printf '🛈 cached'
  else
    printf '%sℹ️  cached%s' "$C_DIM" "$C_RST"
  fi
}

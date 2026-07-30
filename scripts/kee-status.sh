#!/opt/bin/sh
# Aggregated status for all installed keenetic-entware-extras packages.
#
# Runs each package's scripts/status.sh (output captured, not streamed),
# prints one short row per package (Alive / FAIL) and, for failing
# packages, the filtered error lines grouped by their originating
# subsection (e.g. Service, Rules, DNS Tests).
#
# Exit code: 0 if every package is Alive, 1 otherwise.
#
# Flags:
#   -d | --details        show full status output for every package
#                         (not just ✗ lines for failures)
#   -n | --no-color       disable ANSI colors (also: NO_COLOR=1 env var)
#   -c | --color=always   force ANSI colors even when stdout is not a TTY
#                         (useful for `kee-status | less -R`)
#   -h | --help           show usage
#
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

BASE="/opt/keenetic-entware-extras"
NAME_COL_WIDTH=20

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [-d|--details] [-n|--no-color] [-c|--color=always] [-h|--help]

Aggregated status of installed keenetic-entware-extras packages.

Discovers every ${BASE}/<pkg>/scripts/status.sh, runs it, and reports
Alive / FAIL plus filtered error lines (lines containing ✗) grouped
by their source subsection.

  -d, --details      show full status output for every package
  -n, --no-color     disable ANSI colors
  -c, --color=always force ANSI colors even when stdout is not a TTY

Exit status: 0 if all Alive, 1 if any FAIL.
EOF
}

NO_COLOR_OPT=""
FORCE_COLOR=""
DETAILS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--details)       DETAILS=1 ;;
    -n|--no-color)      NO_COLOR_OPT=1 ;;
    -c|--color=always)  FORCE_COLOR=1 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Color setup (TTY-aware; honours NO_COLOR env var / -n flag)
# ---------------------------------------------------------------------------

# Bright+bold for high contrast on Alive/FAIL labels; dim for the ✗ glyph
# so individual error lines do not visually scream louder than the
# summary row (user preference: bright labels, muted markers).
# Color is enabled when:
#   - stdout is a TTY, OR
#   - --color=always / -c was passed,
# AND NO_COLOR env var is unset AND --no-color was not passed.
if { [ -t 1 ] || [ -n "$FORCE_COLOR" ]; } \
   && [ -z "${NO_COLOR:-}" ] && [ -z "$NO_COLOR_OPT" ]; then
  C_GREEN=$(printf '\033[1;92m')   # bold bright green — Alive
  C_RED=$(printf '\033[1;91m')     # bold bright red   — FAIL label
  C_YELLOW=$(printf '\033[1;93m')  # bold bright yellow — Disabled
  C_XMARK=$(printf '\033[31m')     # plain red         — ✗ glyph (visible but not shouting)
  C_DIM=$(printf '\033[2m')        # dim               — notes
  C_RESET=$(printf '\033[0m')
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_XMARK=""; C_DIM=""; C_RESET=""
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print a name-aligned package row: "  <pkg>   <label>"
# Args: $1 - pkg, $2 - label text, $3 - ANSI color (may be empty)
print_pkg_row() {
  local pkg="$1" label="$2" color="$3"
  printf "  %-${NAME_COL_WIDTH}s %s%s%s\n" "$pkg" "$color" "$label" "$C_RESET"
}

# Re-indent full status output for --details display.
# Prepends 4 spaces to every non-empty line so the block nests visually
# under the package summary row.
# stdin:  raw status output
# stdout: re-indented output
indent_output() {
  sed 's/^/    /'
}

# Filter error lines from a sub-status output stream.
#
# Reads full status.sh output on stdin. For every line containing ✗ emits
# that line under its nearest preceding subsection header (2-space-indented
# line ending with ':'). Prepends 2 extra spaces so the error block nests
# visually under the package row. The ✗ glyph is colorised when C_RED is set.
#
# stdin:  raw status output
# stdout: filtered, re-indented error block
filter_errors() {
  awk -v xmark="$C_XMARK" -v reset="$C_RESET" '
    # Subsection header: exactly "  Word[ Word...]:"
    /^  [A-Z][A-Za-z0-9 ]*:$/ {
      section = $0
      section_printed = 0
      next
    }
    # Error line: anything containing the ✗ marker
    /✗/ {
      if (!section_printed && section != "") {
        print "  " section
        section_printed = 1
      }
      line = $0
      if (xmark != "") {
        gsub(/✗/, xmark "✗" reset, line)
      }
      print "  " line
    }
  '
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "keenetic-entware-extras status:"

OVERALL_RC=0
FOUND=0
_PKG_SEP=""

# Build sub-script color flag: pass --color in --details mode when color is active
_SUB_COLOR=""
if [ -n "$DETAILS" ] && [ -n "$C_GREEN" ]; then
  _SUB_COLOR="--color"
fi

for script in "$BASE"/*/scripts/status.sh; do
  # Glob may expand to literal if no matches exist
  [ -f "$script" ] || continue
  FOUND=1

  # Print separator between packages in --details mode
  if [ -n "$DETAILS" ] && [ -n "$_PKG_SEP" ]; then
    echo
  fi
  _PKG_SEP=1

  # Derive package name: strip BASE prefix, take first path segment
  pkg="${script#"$BASE"/}"
  pkg="${pkg%%/*}"

  # Run sub-status; capture stdout+stderr and exit code without tripping set -e
  set +e
  output=$(sh "$script" $_SUB_COLOR 2>&1)
  rc=$?
  set -e

  # Parse status from first line: "<name> status: <marker> <word>"
  first_line=$(printf "%s" "$output" | head -1)
  case "$first_line" in
    *Alive*)    status="alive" ;;
    *Disabled*) status="disabled" ;;
    *Fail*)     status="fail" ;;
    *)
      # Fallback: use exit code (for scripts not yet updated)
      if [ "$rc" -eq 0 ]; then status="alive"; else status="fail"; fi
      ;;
  esac

  # Extract version from "Version: X.Y.Z" line (dim suffix for summary row)
  pkg_ver=""
  if [ -n "$output" ]; then
    pkg_ver=$(printf "%s" "$output" | sed -n 's/.*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)
  fi
  ver_suffix=""
  [ -n "$pkg_ver" ] && ver_suffix="  ${C_DIM}v${pkg_ver}${C_RESET}"

  case "$status" in
    alive)
      print_pkg_row "$pkg" "Alive${ver_suffix}" "$C_GREEN"
      if [ -n "$DETAILS" ] && [ -n "$output" ]; then
        printf "%s\n" "$output" | indent_output
      fi
      ;;
    disabled)
      print_pkg_row "$pkg" "Disabled${ver_suffix}" "$C_YELLOW"
      if [ -n "$DETAILS" ] && [ -n "$output" ]; then
        printf "%s\n" "$output" | indent_output
      fi
      ;;
    fail)
      OVERALL_RC=1
      print_pkg_row "$pkg" "FAIL${ver_suffix}" "$C_RED"
      if [ -n "$output" ]; then
        if [ -n "$DETAILS" ]; then
          printf "%s\n" "$output" | indent_output
        else
          printf "%s\n" "$output" | filter_errors
        fi
      else
        printf "    %s(no output, exit code %d)%s\n" "$C_DIM" "$rc" "$C_RESET"
      fi
      ;;
  esac
done

if [ "$FOUND" -eq 0 ]; then
  printf "  %s(no packages with scripts/status.sh found in %s)%s\n" \
    "$C_DIM" "$BASE" "$C_RESET"
fi

exit "$OVERALL_RC"

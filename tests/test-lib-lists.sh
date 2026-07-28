#!/bin/sh
# Unit tests for deterministic helpers in lib/lists.sh.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kee-tests.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

# shellcheck disable=SC1091
. "$SCRIPT_DIR/testlib.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/lists.sh"

cat > "$TMP_DIR/base.txt" <<'EOF'
# A comment
 example.com
example.net # Inline comment
@nested.txt
EOF
cat > "$TMP_DIR/nested.txt" <<'EOF'

example.org
EOF
cat > "$TMP_DIR/duplicate.txt" <<'EOF'
first
second
first
third
second
EOF
cat > "$TMP_DIR/circular-a.txt" <<'EOF'
@circular-b.txt
EOF
cat > "$TMP_DIR/circular-b.txt" <<'EOF'
@circular-a.txt
EOF

assert_eq 'list_strip removes comments and whitespace' 'one
two' "$(printf '  one  \n# comment\ntwo # inline\n\n' | list_strip)"
assert_eq 'list_dedup preserves first occurrence' 'first
second
third' "$(list_dedup < "$TMP_DIR/duplicate.txt")"
assert_eq 'list_read expands includes and normalizes lines' 'example.com
example.net
example.org' "$(list_read "$TMP_DIR/base.txt")"
assert_eq 'list_count counts meaningful source lines' '3' "$(list_count "$TMP_DIR/base.txt")"
assert_eq 'list_count_expanded includes nested entries' '3' "$(list_count_expanded "$TMP_DIR/base.txt")"
assert_eq 'list_read stops circular includes' '' "$(list_read "$TMP_DIR/circular-a.txt" 2>/dev/null)"
assert_eq 'list_count_expanded returns zero for missing file' '0' "$(list_count_expanded "$TMP_DIR/missing.txt")"

test_summary 'lib/lists.sh'

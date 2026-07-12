# Stock htdocs Backup — Runbook

> **When:** After every KeeneticOS firmware upgrade on any router from
> [`.project/target-hosts.json`](../../.project/target-hosts.json).
>
> **Storage:** `docs/knowledge/keenetic-webui-research/stock-backup-<version>/`
> (gitignored — local reference only).
>
> **Full MCP-based runbook** (with CSS extraction, DOM snapshots):
> [`ndms-upgrade-diff-runbook.md`](../../docs/knowledge/keenetic-webui-research/ndms-upgrade-diff-runbook.md)

---

## Quick backup (SSH only)

```sh
# --- Step 0: Set variables ---
ROUTER="10.0.0.1"        # from target-hosts.json
PORT=222
VERSION="5.0.X"          # fill in actual version

BACKUP_DIR="docs/knowledge/keenetic-webui-research/stock-backup-${VERSION}"

# --- Step 1: Check firmware version and arch ---
ssh -p "$PORT" root@"$ROUTER" 'cat /tmp/run/version.js; echo "---"; uname -m'
# Expected output:
#   window.NDM.version = '...';
#   window.NDM.hw_id = 'XX-XXXX';
#   ---
#   mips (or aarch64)

# --- Step 2: Identify bundle hashes (before copying) ---
ssh -p "$PORT" root@"$ROUTER" 'ls /usr/share/htdocs_/main-*.js /usr/share/htdocs_/styles-*.css'
# => main-NEWHASH.js  styles-NEWCSS.css

# --- Step 3: Copy full htdocs_ ---
mkdir -p "$BACKUP_DIR"
scp -O -r -P "$PORT" root@"$ROUTER":/usr/share/htdocs_ "$BACKUP_DIR/"

# --- Step 4: Verify backup ---
ls "$BACKUP_DIR/htdocs_/main-"*.js "$BACKUP_DIR/htdocs_/styles-"*.css
wc -l "$BACKUP_DIR/htdocs_/index.html"

# --- Step 5: Scan bundle — detect patch set compatibility ---
# This determines if existing patches work or a new vN.sh is needed.
BUNDLE="$BACKUP_DIR/htdocs_/main-"*.js
JS_HASH=$(basename $BUNDLE | sed 's/main-\(.*\)\.js/\1/')

echo "=== Bundle: main-${JS_HASH}.js ==="

# 5a. Detect DashboardSection enum (content-based: Xx={INTERNET:"INTERNET")
ENUM=$(grep -o '[A-Za-z][A-Za-z0-9]*={INTERNET:"INTERNET"' "$BUNDLE" | head -1 | sed 's/=.*//')
echo "DashboardSection enum: ${ENUM:-NOT FOUND}"

# 5b. Check which vN.sh matches this enum
MATCHED=""
for pf in webui/patches/v*.sh; do
  pe=$(sed -n 's/^PATCH_ENUM="\(.*\)".*/\1/p' "$pf")
  if [ "$pe" = "$ENUM" ]; then
    MATCHED=$(basename "$pf" .sh)
    echo "✅ Matched: $MATCHED (PATCH_ENUM=$pe)"
  fi
done
[ -z "$MATCHED" ] && echo "❌ No patch set matches enum '$ENUM' — new vN.sh needed!"

# 5c. Verify all sed search patterns from matched patch set
if [ -n "$MATCHED" ]; then
  echo ""
  echo "--- Verifying sed patterns from ${MATCHED}.sh ---"
  # Extract search patterns from sed commands
  grep "sed -i" "webui/patches/${MATCHED}.sh" | while IFS= read -r line; do
    # Extract the search part between the first pair of delimiters
    pat=$(echo "$line" | sed -n "s/.*sed -i 's[|#]\([^|#]*\)[|#].*/\1/p")
    [ -z "$pat" ] && continue
    desc=$(echo "$line" | sed -n 's/.*# \(#[^ ]*\).*/\1/p')
    if grep -qE "$pat" "$BUNDLE" 2>/dev/null; then
      echo "  ✅ ${desc:-(pattern)} found"
    else
      echo "  ❌ ${desc:-(pattern)} NOT FOUND — patch will silently fail"
    fi
  done
fi

# 5d. Check signals vs setter architecture
echo ""
echo "--- Architecture markers ---"
grep -qF 'set order(e){this.elementsOrder=e}' "$BUNDLE" \
  && echo "  Setter-based (v1/v2 style)" \
  || echo "  No setter (v3 signal-based or new)"
grep -qF 'this.templateMap().get' "$BUNDLE" \
  && echo "  Signal templateMap (v3 style)" \
  || echo "  Classic templateMap (v1/v2 style)"
grep -qF 'this.templateMap.get' "$BUNDLE" \
  && echo "  Classic templateMap.get (v1/v2 style)" || true

# If Step 5 shows all ✅ — existing patch works, no changes needed.
# If enum changed but patterns similar — copy vN.sh, update PATCH_ENUM + sed patterns.
# If architecture changed — create new vN.sh from scratch.
```

## Stock backups inventory

| Version | Arch | hw_id | JS Hash | CSS Hash | Patch | Backup Dir |
|---------|------|-------|---------|----------|-------|------------|
| 5.0.4 | mipsel | KN-2310 | `ZYVOXYLQ` | `AVEVNDW4` | v1 | `stock-backup-5.0.4-mipsel/` |
| 5.0.8 | aarch64 | NC-4110 | `XXXXXXXX` | `J4CVWJOW` | v1 | `stock-backup-5.0.8-aarch64/` |
| 5.0.8 | mipsel | KN-1011 | `4QPHZXFY` | `D5VNMMPD` | v1 | `stock-backup-5.0.8-mipsel/` |
| 5.0.10 | mipsel | KN-2310 | `TXLLNFBH` | `DKYWR66I` | v1 | `stock-backup-5.0.10-mipsel/` |
| 5.0.11 | mipsel | KN-1011 | `JELMZ7TJ` | `DKYWR66I` | v1 | `stock-backup-5.0.11-mipsel/` |
| 5.1 Beta 3 | mipsel | KN-2310 | `3FF05DF` | `3FF05DF` | v2 | `stock-backup-5.1-beta3-mipsel/` |
| 5.1.0 | mipsel | KN-2310 | `8787931` | `8787931` | v3 | `stock-backup-5.1.0-mipsel/` |
| 5.1.1 | mipsel | KN-2310 | `553997B` | `553997B` | v4 | `stock-backup-5.1.1-mipsel/` |

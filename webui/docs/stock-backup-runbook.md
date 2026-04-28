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

# --- Step 5: Test patch patterns ---
BUNDLE="$BACKUP_DIR/htdocs_/main-"*.js
for pat in 'TELEPHONY:"TELEPHONY"}' \
  '[Po.TELEPHONY]:"dashboard.card_nvox.title"};' \
  'Object.keys(Po).filter(a=>this.viewService.isCardAvailable(a))' \
  'set order(e){this.elementsOrder=e}' \
  'getTemplate(e){return this.templateMap.get(e)}' \
  'd("ngTemplateOutlet",i.getTemplate(e))' \
  'Po.INTERNET,Po.USB,Po.APPLICATIONS,Po.SYSTEM,Po.TELEPHONY]'; do
  grep -qF "$pat" $BUNDLE && echo "✅ $pat" || echo "❌ $pat"
done

# --- Step 6: Update hash-map.conf ---
JS_HASH=$(basename $BUNDLE | sed 's/main-\(.*\)\.js/\1/')
echo "# KeeneticOS ${VERSION}, <arch>"  >> webui/patches/hash-map.conf
echo "${JS_HASH} v1"                     >> webui/patches/hash-map.conf
echo "Added ${JS_HASH} → v1"

# If any pattern from Step 5 failed:
# Create v2.sh with updated sed commands and map to v2 instead.
```

## Stock backups inventory

| Version | Arch | hw_id | JS Hash | CSS Hash | Backup Dir |
|---------|------|-------|---------|----------|------------|
| 5.0.4 | mipsel | KN-2310 | `ZYVOXYLQ` | `AVEVNDW4` | `stock-backup-5.0.4-mipsel/` |
| 5.0.8 | aarch64 | NC-4110 | `XXXXXXXX` | `J4CVWJOW` | `stock-backup-5.0.8-aarch64/` |
| 5.0.8 | mipsel | KN-1011 | `4QPHZXFY` | `D5VNMMPD` | `stock-backup-5.0.8-mipsel/` |
| 5.0.10 | mipsel | KN-2310 | `TXLLNFBH` | `DKYWR66I` | `stock-backup-5.0.10-mipsel/` |

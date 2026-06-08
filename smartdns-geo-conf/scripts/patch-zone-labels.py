#!/usr/bin/env python3
"""Patch zone conf first lines: add flag emoji + country name (no domains in UI)."""
import os, re

ZONES_DIR = "smartdns-geo-conf/config/zones"

def get_flag(cc):
    """Generate flag emoji from 2-letter country code."""
    return "".join(chr(0x1F1E6 + ord(c) - ord('a')) for c in cc.lower())

patched = 0
for fname in sorted(os.listdir(ZONES_DIR)):
    if not fname.endswith(".conf") or fname == "test-domains.conf":
        continue
    cc = fname[:-5]
    filepath = os.path.join(ZONES_DIR, fname)
    
    with open(filepath) as f:
        lines = f.readlines()
    if not lines:
        continue
    
    first_line = lines[0]
    # Extract current label from (Name) if present
    m = re.match(r'^# Zone: (\w+)\s*\(([^)]+)\)', first_line)
    if m:
        label = m.group(2)
    else:
        label = cc.upper()
    
    # Remove existing flag emoji if any (idempotent)
    label = re.sub(r'^[\U0001F1E6-\U0001F1FF]{2}\s*', '', label)
    
    flag = get_flag(cc)
    # Format: # Zone: XX (Flag Name) — .xx
    new_first_line = f"# Zone: {cc.upper()} ({flag} {label})\n"
    lines[0] = new_first_line
    
    with open(filepath, 'w') as f:
        f.writelines(lines)
    patched += 1

print(f"Patched {patched} zone files (flag + name only, no domains)")
for cc in ['ru', 'de', 'us', 'cn']:
    fp = os.path.join(ZONES_DIR, f"{cc}.conf")
    if os.path.exists(fp):
        with open(fp) as f:
            print(f.readline().rstrip())

#!/bin/sh
# Hot update: add a LuCI toggle to skip the charging screen.
#
# Pushes the modified charge-mode.py (reads UCI toggle) and settings.js (adds
# the on/off switch in LuCI → 适配设置).  After running this on the device,
# the toggle appears under 设置 → 适配设置 → 充电模式 → 跳过充电界面.
#
# Usage (as root on the device, over SSH):
#   sh /tmp/e5-charge-toggle-deploy.sh
#
# The original files are backed up with a .bak extension.
# To revert, restore the .bak files and remove the charger section from UCI.
set -eu

BACKUP_SUFFIX='.bak'
CHARGE_MODE='/usr/libexec/e5-charge-mode'
SETTINGS_JS='/www/luci-static/resources/view/mu300/settings.js'
CONFIG_FILE='/etc/config/unisoc_modem'

echo "=== E5 charge-screen toggle hot update ==="

# 1. Backup originals
for f in "$CHARGE_MODE" "$SETTINGS_JS" "$CONFIG_FILE"; do
    if [ -f "$f" ] && [ ! -f "$f$BACKUP_SUFFIX" ]; then
        cp "$f" "$f$BACKUP_SUFFIX"
        echo "backed up: $f"
    fi
done

# 2. Patch charge-mode.py: add UCI skip check at the top of run()
if grep -q 'skip_screen' "$CHARGE_MODE" 2>/dev/null; then
    echo "charge-mode.py already patched, skipping"
else
    # Insert the skip_enabled() function and the call after the shebang line.
    # We use python3 to do an in-place edit since the file is python.
    python3 - "$CHARGE_MODE" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path, 'r').read()

skip_func = '''
def skip_enabled():
    """Read the UCI toggle ``unisoc_modem.charger.skip_screen``."""
    try:
        result = subprocess.run(['uci', '-q', 'get', 'unisoc_modem.charger.skip_screen'],
                                capture_output=True, text=True, timeout=3)
        return result.stdout.strip() == '1'
    except (OSError, subprocess.SubprocessError):
        return False


'''

# Insert skip_enabled() before def run()
if 'def skip_enabled' not in src:
    src = src.replace('def run():', skip_func + 'def run():', 1)

# Insert the skip check right after the charger_boot / failsafe early return
if 'skip_enabled()' not in src.split('def skip_enabled')[1] if 'def skip_enabled' in src else True:
    # Find the block: "if not charger_boot(...) or ...:\n        return"
    # and add the skip check after it
    pattern = r"(if not charger_boot\(commandline\) or Path\('/tmp/\.failsafe'\)\.exists\(\):\n        return\n)"
    replacement = r"\1    if skip_enabled():\n        report('normal', 'charging screen skipped by UCI toggle')\n        return\n"
    src = re.sub(pattern, replacement, src, count=1)

open(path, 'w').write(src)
print("patched: " + path)
PYEOF
fi

# 3. Add charger section to UCI config if not present
if uci -q get unisoc_modem.charger.skip_screen >/dev/null 2>&1; then
    echo "UCI charger section already exists, skipping"
else
    uci set unisoc_modem.charger=charger
    uci set unisoc_modem.charger.skip_screen='0'
    uci commit unisoc_modem
    echo "added UCI section: unisoc_modem.charger.skip_screen=0"
fi

# 4. Patch settings.js to add the toggle (inline since it's a static JS file)
if grep -q 'skip_screen' "$SETTINGS_JS" 2>/dev/null; then
    echo "settings.js already patched, skipping"
else
    # Append the charger section before "return m.render();"
    python3 - "$SETTINGS_JS" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, 'r').read()

toggle = """
\t\t// Charging screen toggle
\t\tvar cs = m.section(form.NamedSection, 'charger', 'charger', '跳过充电界面');
\t\tcs.addremove = false;
\t\tvar so = cs.option(form.Flag, 'skip_screen', '跳过充电界面');
\t\tso.description = '开启后，插充电器开机时不再显示充电界面，直接进入系统。';
"""

src = src.replace("\t\treturn m.render();", toggle + "\n\t\treturn m.render();")
open(path, 'w').write(src)
print("patched: " + path)
PYEOF
fi

echo ""
echo "=== Done! ==="
echo "Toggle location: LuCI → 设置 → 适配设置 → 充电模式"
echo "To enable skip: turn on '跳过充电界面' and Save"
echo "To revert: restore .bak files and 'uci delete unisoc_modem.charger'"

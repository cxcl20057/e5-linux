#!/bin/sh
# Hot update: add a LuCI toggle to skip the charging screen on boot.
#
# This script directly replaces three files on the device with patched versions
# that add a UCI toggle (unisoc_modem.charger.skip_screen).  After running it,
# the toggle appears in LuCI under:
#
#   设置 → 适配设置 → 充电模式 → 跳过充电界面
#
# Usage (as root on the device, over SSH):
#   wget --no-check-certificate -O /tmp/deploy.sh https://raw.githubusercontent.com/cxcl20057/e5-linux/main/openwrt/e5-charge-toggle-deploy.sh
#   sh /tmp/deploy.sh
#
# Or scp from your PC:
#   scp openwrt/e5-charge-toggle-deploy.sh root@E5_IP:/tmp/
#   sh /tmp/e5-charge-toggle-deploy.sh
#
# Originals are backed up to .bak.  To revert:
#   sh /tmp/e5-charge-toggle-deploy.sh --revert
set -eu

CHARGE_MODE=/usr/libexec/e5-charge-mode
SETTINGS_JS=/www/luci-static/resources/view/mu300/settings.js
CONFIG_FILE=/etc/config/unisoc_modem
BAK='.bak'

revert() {
    echo "=== Reverting E5 charge-screen toggle ==="
    for f in "$CHARGE_MODE" "$SETTINGS_JS" "$CONFIG_FILE"; do
        if [ -f "$f$BAK" ]; then
            cp "$f$BAK" "$f"
            echo "restored: $f"
        fi
    done
    uci -q delete unisoc_modem.charger 2>/dev/null || true
    uci commit unisoc_modem 2>/dev/null || true
    echo "=== Reverted. Reboot to confirm. ==="
    exit 0
}

[ "${1:-}" = "--revert" ] && revert

echo "=== E5 charge-screen toggle hot update ==="

# 1. Backup originals (only on first run)
for f in "$CHARGE_MODE" "$SETTINGS_JS" "$CONFIG_FILE"; do
    if [ -f "$f" ] && [ ! -f "$f$BAK" ]; then
        cp "$f" "$f$BAK"
        echo "backed up: $f"
    fi
done

# 2. Patch charge-mode.py: add skip_enabled() + early return in run()
if grep -q 'skip_screen' "$CHARGE_MODE" 2>/dev/null; then
    echo "charge-mode.py: already patched"
else
    python3 - "$CHARGE_MODE" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path).read()

func = (
    "def skip_enabled():\n"
    "    \"\"\"Read the UCI toggle ``unisoc_modem.charger.skip_screen``.\n"
    "\n"
    "    When set to ``1`` the charging screen is bypassed and the system boots\n"
    "    straight through.  Any read failure defaults to ``False`` so a corrupt\n"
    "    config never prevents the gate from running.\n"
    "    \"\"\"\n"
    "    try:\n"
    "        result = subprocess.run(['uci', '-q', 'get', 'unisoc_modem.charger.skip_screen'],\n"
    "                                capture_output=True, text=True, timeout=3)\n"
    "        return result.stdout.strip() == '1'\n"
    "    except (OSError, subprocess.SubprocessError):\n"
    "        return False\n"
    "\n"
    "\n"
)

# Insert skip_enabled() before def run()
src = src.replace('def run():', func + 'def run():', 1)

# Insert skip check after the charger_boot / failsafe early return
pattern = r"(if not charger_boot\(commandline\) or Path\('/tmp/\.failsafe'\)\.exists\(\):\n        return\n)"
replacement = r"\1    if skip_enabled():\n        report('normal', 'charging screen skipped by UCI toggle')\n        return\n"
src = re.sub(pattern, replacement, src, count=1)

open(path, 'w').write(src)
print("patched: " + path)
PYEOF
fi

# 3. Add charger section to UCI config
if uci -q get unisoc_modem.charger.skip_screen >/dev/null 2>&1; then
    echo "UCI charger section: already exists"
else
    uci set unisoc_modem.charger=charger
    uci set unisoc_modem.charger.skip_screen='0'
    uci commit unisoc_modem
    echo "added UCI: unisoc_modem.charger.skip_screen=0"
fi

# 4. Patch settings.js: add the toggle section (use python3, not sed)
if grep -q 'skip_screen' "$SETTINGS_JS" 2>/dev/null; then
    echo "settings.js: already patched"
else
    python3 - "$SETTINGS_JS" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, 'r').read()

toggle = """
		// Charging screen toggle
		var cs = m.section(form.NamedSection, 'charger', 'charger', t('充电模式'));
		cs.addremove = false;
		var so = cs.option(form.Flag, 'skip_screen', t('跳过充电界面'));
		so.description = t('开启后，插充电器开机时不再显示充电界面，直接进入系统。与安卓侧跳过充电模式的 Magisk 模块效果一致。关闭则恢复长按电源键 1.5 秒启动的行为。');

"""

src = src.replace("\t\treturn m.render();", toggle + "\t\treturn m.render();", 1)
open(path, 'w').write(src)
print("patched: " + path)
PYEOF
fi

echo ""
echo "=== Done! ==="
echo "Toggle: LuCI → 设置 → 适配设置 → 充电模式 → 跳过充电界面"
echo "Enable it and Save to skip the charging screen on next charger boot."
echo "To revert: sh $0 --revert"

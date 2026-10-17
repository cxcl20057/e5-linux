#!/bin/sh
# ============================================================
#  E5 OpenWrt 热更新补丁
#  整合：充电界面跳过开关 + AT 终端 IMEI 命令
# ============================================================
#
#  功能：
#    1. 充电模式跳过 —— LuCI 设置→适配设置 新增"跳过充电界面"开关
#    2. AT 终端增强 —— 基础组新增 IMEI 读写命令，所有命令带中文说明
#
#  用法（设备上 root 执行）：
#    wget --no-check-certificate -O /tmp/patch.sh \
#      https://raw.githubusercontent.com/cxcl20057/e5-linux/main/openwrt/e5-hotfix.sh
#    sh /tmp/patch.sh          # 打补丁
#    sh /tmp/patch.sh --revert # 恢复原样
#
#  或从电脑 scp：
#    scp openwrt/e5-hotfix.sh root@E5_IP:/tmp/
#    sh /tmp/e5-hotfix.sh
# ============================================================
set -eu

# ---- 文件路径 ----
F_CHARGE=/usr/libexec/e5-charge-mode
F_SETTINGS=/www/luci-static/resources/view/mu300/settings.js
F_AT=/www/luci-static/resources/view/mu300/at.js
F_CONFIG=/etc/config/unisoc_modem
BAK='.bak'

ALL_FILES="$F_CHARGE $F_SETTINGS $F_AT $F_CONFIG"

# ---- 恢复 ----
revert() {
    echo "=== 恢复 E5 原始文件 ==="
    for f in $ALL_FILES; do
        if [ -f "$f$BAK" ]; then
            cp "$f$BAK" "$f"
            echo "  已恢复: $f"
        fi
    done
    uci -q delete unisoc_modem.charger 2>/dev/null || true
    uci commit unisoc_modem 2>/dev/null || true
    echo "=== 已恢复，重启生效 ==="
    exit 0
}

[ "${1:-}" = "--revert" ] && revert

echo "=== E5 OpenWrt 热更新 ==="
echo ""

# ---- 备份（仅首次） ----
for f in $ALL_FILES; do
    if [ -f "$f" ] && [ ! -f "$f$BAK" ]; then
        cp "$f" "$f$BAK"
        echo "备份: $f"
    fi
done
echo ""

# ============================================================
#  补丁 1: charge-mode.py — 添加 UCI 开关检查
# ============================================================
echo "--- [1/4] charge-mode.py ---"
if grep -q 'skip_screen' "$F_CHARGE" 2>/dev/null; then
    echo "  已打补丁，跳过"
else
    python3 - "$F_CHARGE" <<'PYEOF'
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
    "\n\n"
)
src = src.replace('def run():', func + 'def run():', 1)

pattern = r"(if not charger_boot\(commandline\) or Path\('/tmp/\.failsafe'\)\.exists\(\):\n        return\n)"
replacement = r"\1    if skip_enabled():\n        report('normal', 'charging screen skipped by UCI toggle')\n        return\n"
src = re.sub(pattern, replacement, src, count=1)

open(path, 'w').write(src)
print("  已打补丁")
PYEOF
fi

# ============================================================
#  补丁 2: UCI 配置 — 添加 charger section
# ============================================================
echo "--- [2/4] UCI 配置 ---"
if uci -q get unisoc_modem.charger.skip_screen >/dev/null 2>&1; then
    echo "  已存在，跳过"
else
    uci set unisoc_modem.charger=charger
    uci set unisoc_modem.charger.skip_screen='0'
    uci commit unisoc_modem
    echo "  已添加: unisoc_modem.charger.skip_screen=0"
fi

# ============================================================
#  补丁 3: settings.js — 添加充电模式开关 UI
# ============================================================
echo "--- [3/4] settings.js (充电开关 UI) ---"
if grep -q 'skip_screen' "$F_SETTINGS" 2>/dev/null; then
    echo "  已打补丁，跳过"
else
    python3 - "$F_SETTINGS" <<'PYEOF'
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
print("  已打补丁")
PYEOF
fi

# ============================================================
#  补丁 4: at.js — 添加 IMEI 命令 + 所有命令中文说明
# ============================================================
echo "--- [4/4] at.js (AT 终端增强) ---"
if [ ! -f "$F_AT" ]; then
    echo "  文件不存在，跳过"
else
    if grep -q 'SPIMEI' "$F_AT" 2>/dev/null; then
        echo "  已打补丁，跳过"
    else
        python3 - "$F_AT" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, 'r').read()

# 替换整个 GROUPS 定义
old_start = "var GROUPS = ["
old_end = "];\n"

start = src.find(old_start)
if start < 0:
    print("  锚点未找到，跳过")
    sys.exit(0)

# 找到 GROUPS 的闭合 ];
brace_depth = 0
i = start + len(old_start) - 1  # 指向 [
# 找到匹配的 ]
i = src.find('[', start)
brace_depth = 1
i += 1
while i < len(src) and brace_depth > 0:
    if src[i] == '[':
        brace_depth += 1
    elif src[i] == ']':
        brace_depth -= 1
    i += 1
# 现在 i 指向 ];\n 中的 ] 后面
# 往前找 ]
end = src.rfind(']', start, i)
# 往后找分号
semi = src.find(';', end)
if semi < 0:
    print("  无法确定 GROUPS 结束位置，跳过")
    sys.exit(0)

new_groups = '''var GROUPS = [
	[ '基础', [
		{ cmd: 'AT', desc: '测试 AT 通道是否正常（应返回 OK）' },
		{ cmd: 'AT+CFUN?', desc: '查询当前射频功能模式（0=关机, 1=在线, 4=飞行模式）' },
		{ cmd: 'AT+CPIN?', desc: '查询 SIM 卡 PIN 解锁状态（READY=已解锁）' },
		{ cmd: 'AT+CGMR', desc: '查询模组固件版本号' },
		{ cmd: 'AT+CCID', desc: '读取 SIM 卡 ICCID 序列号' },
		{ cmd: 'AT+CIMI', desc: '读取 SIM 卡的 IMSI 标识' },
		{ cmd: 'AT+CGSN', desc: '读取模组 IMEI（15 位国际移动设备识别码）' },
		{ cmd: 'AT+CNUM', desc: '查询本机号码（需运营商写入 SIM）' },
		{ cmd: 'AT+SPIMEI=0,"改为你的串号"', desc: '设置卡槽 0 的 IMEI（写入 NV 持久保存），先改成你自己的串号再发送' },
		{ cmd: 'AT+SPIMEI?', desc: '查询当前已写入的 IMEI（含两个卡槽的 IMEI）' }
	] ],
	[ '注册/信号', [
		{ cmd: 'AT+CSQ', desc: '查询 2G/3G 信号强度（RSSI, 0-31, 99=无效）' },
		{ cmd: 'AT+CESQ', desc: '查询 LTE/5G 详细信号强度（RSRP, RSRQ, SINR）' },
		{ cmd: 'AT+CEREG?', desc: '查询 LTE 网络注册状态与小区信息' },
		{ cmd: 'AT+C5GREG?', desc: '查询 5G NR 网络注册状态与小区信息' },
		{ cmd: 'AT+COPS?', desc: '查询当前注册的运营商与接入制式' },
		{ cmd: 'AT+CGATT?', desc: '查询 PS 域是否已附着（1=已附着）' },
		{ cmd: 'AT+CGACT?', desc: '查询已激活的 PDP 上下文（数据承载）' }
	] ],
	[ '承载', [
		{ cmd: 'AT+CGDCONT?', desc: '查询所有 PDP 上下文定义（APN 配置）' },
		{ cmd: 'AT+CGPADDR=1', desc: '查询 CID 1 的 PDP 地址（IP 地址）' },
		{ cmd: 'AT+CGCONTRDP=1', desc: '查询 CID 1 的动态 PDP 参数（IP/DNS/MTU）' },
		{ cmd: 'AT+CGEQOSRDP=1', desc: '查询 CID 1 的 QoS 服务质量参数' }
	] ],
	[ '工程模式', [
		{ cmd: 'AT+SPENGMD=0,6,0', desc: '工程模式：关闭工程日志' },
		{ cmd: 'AT+SPENGMD=0,14,1', desc: '工程模式：开启锁网日志' },
		{ cmd: 'AT+SPENGMD=0,6,6', desc: '工程模式：开启完整调试日志' },
		{ cmd: 'AT+SPQ5GNCELLEX', desc: '查询 5G NR 邻区信息' },
		{ cmd: 'AT+SPENDC?', desc: '查询 EN-DC 双连接状态' },
		{ cmd: 'AT+SPTESTMODE?', desc: '查询工厂测试模式状态' },
		{ cmd: 'AT+SP5GRAN?', desc: '查询 5G NR 频段与带宽配置' }
	] ]
];'''

src = src[:start] + new_groups + src[semi+1:]
open(path, 'w').write(src)
print("  已打补丁")
PYEOF
    fi
fi

# ---- 更新 chip 渲染逻辑（cmd/desc 格式） ----
if grep -q 'SPIMEI' "$F_AT" 2>/dev/null && ! grep -q "c\.desc" "$F_AT" 2>/dev/null; then
    python3 - "$F_AT" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, 'r').read()

old_render = "g[1].map(function(c) { return '<span class=\"mud-chip\">' + c + '</span>'; }).join('')"
new_render = "g[1].map(function(c) { return '<span class=\"mud-chip\" title=\"' + M.esc(c.desc) + '\">' + M.esc(c.cmd) + '</span>'; }).join('')"

if old_render in src:
    src = src.replace(old_render, new_render, 1)
    open(path, 'w').write(src)
    print("  chip 渲染已更新")
else:
    print("  chip 渲染已是最新")
PYEOF
fi

# ---- 修改 chip 和历史点击行为：只填入不自动发送 ----
if grep -q 'SPIMEI' "$F_AT" 2>/dev/null; then
    python3 - "$F_AT" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, 'r').read()

changed = False

# chip 点击：self.send() -> self.Q('at-cmd').focus()
old_chip = "ch.onclick = function() { self.Q('at-cmd').value = ch.textContent; self.send(); };"
new_chip = "ch.onclick = function() { self.Q('at-cmd').value = ch.textContent; self.Q('at-cmd').focus(); };"
if old_chip in src:
    src = src.replace(old_chip, new_chip, 1)
    changed = True

# 历史点击：self.send() -> self.Q('at-cmd').focus()
old_hist = "self.Q('at-cmd').value = ev.target.getAttribute('data-cmd');\n\t\t\t\tself.send();"
new_hist = "self.Q('at-cmd').value = ev.target.getAttribute('data-cmd');\n\t\t\t\tself.Q('at-cmd').focus();"
if old_hist in src:
    src = src.replace(old_hist, new_hist, 1)
    changed = True

if changed:
    open(path, 'w').write(src)
    print("  chip/历史点击改为仅填入（不自动发送）")
else:
    print("  点击行为已是最新（仅填入）")
PYEOF
fi

echo ""
echo "=========================================="
echo "  全部完成！"
echo "=========================================="
echo ""
echo "充电跳过: LuCI → 设置 → 适配设置 → 充电模式"
echo "         打开'跳过充电界面'开关并保存"
echo ""
echo "AT 终端: LuCI → AT 页面，基础组新增 IMEI 命令"
echo "         鼠标悬停每个命令可看中文说明"
echo ""
echo "浏览器需强制刷新 (Ctrl+Shift+R) 清除缓存"
echo ""
echo "恢复原样: sh $0 --revert"

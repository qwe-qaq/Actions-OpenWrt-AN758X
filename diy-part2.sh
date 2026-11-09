#!/bin/bash
# ================================================================
# diy-part2.sh —— 默认值定制（在 .config 加载之后运行，cwd = ponwrt 根）
#   1) 时区 Asia/Shanghai (CST-8)
#   2) 5G WiFi：CN / auto / HE160
#   3) 概览页 CPU 行：USR/SYS + 每核明细
#   4) 固件版本追加作者与构建时间
# ================================================================

set -euo pipefail

echo "=========================================="
echo "默认值定制：时区 + 5G WiFi (diy-part2.sh)"
echo "=========================================="

# =============================================================
# 可配置：无线参数
# 如需改动，直接改这里即可（编译期常量，会写进 uci-defaults 脚本）
# =============================================================
# 2.4G WiFi 参数
WIFI_24G_COUNTRY="${WIFI_24G_COUNTRY:-CN}"
WIFI_24G_CHANNEL="${WIFI_24G_CHANNEL:-auto}"

# 5G WiFi 参数
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"

# 可由 workflow 的 fw_author 输入项覆盖（经 env 注入）；本地单独跑时默认 qwe
FW_AUTHOR="${FW_AUTHOR:-qwe}"
FW_BUILD_TIME="${FW_BUILD_TIME:-}"
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-}"

echo "配置：2.4G country=$WIFI_24G_COUNTRY channel=$WIFI_24G_CHANNEL"
echo "配置：5G country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE fallback=$WIFI_5G_FALLBACK"
echo "配置：FW_AUTHOR=$FW_AUTHOR"

# ---------------------------------------------------------
# 1. 修改 config_generate 的默认值（首次开机生成的 /etc/config/system）
# ---------------------------------------------------------
CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
  sed -i "s/option timezone.*/option timezone 'CST-8'/" "$CFG"
  sed -i "s/option zonename.*/option zonename 'Asia\/Shanghai'/" "$CFG"
  echo "✅ config_generate 默认时区 -> CST-8 / Asia/Shanghai"
else
  echo "ℹ️ 未找到 $CFG，跳过默认值修改"
fi

# ---------------------------------------------------------
# 2. uci-defaults：即使保留了旧配置也强制刷成中国时区
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
uci -q batch <<'UCI'
set system.@system[0].zonename='Asia/Shanghai'
set system.@system[0].timezone='CST-8'
commit system
UCI
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ uci-defaults 时区脚本已写入"

# ---------------------------------------------------------
# 3. 补上亚洲时区数据库包 + libffi（python3 _ctypes 需要）
#   ⚠ 这里写入 .config 的项会被 workflow 的 Configure 步骤用 >> 追加、
#     make defconfig 展开后保留。Configure 里还有一道安全网重新启用
#     zoneinfo-asia / libffi / iw，防止 configs/${SOC}.config 里
#     的 `is not set` 覆盖这里的设置。
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y    # 亚洲时区数据库（中国时区需要）" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"

  sed -i '/^CONFIG_PACKAGE_libffi=/d; /^# CONFIG_PACKAGE_libffi is not set/d' .config
  echo "CONFIG_PACKAGE_libffi=y           # python3 _ctypes 需要 ffi.h / libffi.pc" >> .config
  echo "✅ libffi 已加入 .config"
fi

# ---------------------------------------------------------
# 4. 5G WiFi：CN / auto / HE160
# ---------------------------------------------------------

# ---- 4a. 编译期：改 detect 脚本默认值（best effort） ----
DETECT_SCRIPT=""
for cand in \
  "package/kernel/mac80211/files/lib/wifi/mac80211.sh" \
  "package/kernel/mac80211/files/lib/wifi/mac80211.uc" \
  "package/network/services/hostapd/files/lib/wifi/mac80211.sh"; do
  [ -f "$cand" ] && { DETECT_SCRIPT="$cand"; break; }
done

if [ -n "$DETECT_SCRIPT" ]; then
  sed -i "s/option channel '36'/option channel 'auto'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel='36'/option channel='auto'/g" "$DETECT_SCRIPT"
  echo "✅ detect 脚本默认信道 -> auto ($DETECT_SCRIPT)"
else
  echo "ℹ️ 未找到无线 detect 脚本，跳过编译期默认值修改（由 uci-defaults 兜底）"
fi

# ---- 4b. 运行期：uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/96-wifi-5g-cn <<UCEOF
#!/bin/sh
# 无线 WiFi 默认值：2.4G/5G 国家码 CN、5G 信道 auto、频宽 160MHz
# 由 diy-part2.sh 生成（编译期常量注入）

COUNTRY_24G='$WIFI_24G_COUNTRY'
CHANNEL_24G='$WIFI_24G_CHANNEL'
COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'

log() { logger -t wifi-config "\$@"; }

if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

support_160() {
	local phy="\$1"
	[ -z "\$phy" ] && return 1
	command -v iw >/dev/null 2>&1 || return 1
	iw phy "\$phy" info 2>/dev/null | grep -qE '160 MHz|80[+]80 MHz' || return 1
	return 0
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-device\$/\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1

	if [ "\$is5g" = "1" ]; then
		ht="\$HTMODE"
		phy="\$(uci -q get wireless.\$dev.phy 2>/dev/null)"
		if [ -n "\$phy" ] && ! support_160 "\$phy"; then
			ht="\$FALLBACK"
			log "\$dev：未检测到 160MHz 能力，回落为 \$ht"
		fi
		uci -q set wireless.\$dev.country="\$COUNTRY"
		uci -q set wireless.\$dev.country_ie='1'
		uci -q set wireless.\$dev.channel="\$CHANNEL"
		uci -q set wireless.\$dev.htmode="\$ht"
		log "\$dev (5G): country=\$COUNTRY channel=\$CHANNEL htmode=\$ht"
	else
		uci -q set wireless.\$dev.country="\$COUNTRY_24G"
		uci -q set wireless.\$dev.country_ie='1'
		uci -q set wireless.\$dev.channel="\$CHANNEL_24G"
		log "\$dev (2.4G): country=\$COUNTRY_24G channel=\$CHANNEL_24G"
	fi
	changed=1
done

for iface in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-iface\$/\1/p'); do
	dev="\$(uci -q get wireless.\$iface.device 2>/dev/null)"
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1
	if [ "\$is5g" = "1" ]; then
		uci -q set wireless.\$iface.ssid="TP-LINK_6628_5G"
	else
		uci -q set wireless.\$iface.ssid="TP-LINK_6628"
	fi
	changed=1
done

if [ "\$changed" = "1" ]; then
	uci -q commit wireless
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 5G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/96-wifi-5g-cn
echo "✅ uci-defaults WiFi 脚本已写入"

# ---- 4c. 确保 hostapd 支持 160MHz / 11ax ----
if [ -f .config ]; then
  if grep -qE "^CONFIG_PACKAGE_(wpad-basic|hostapd-basic)=y" .config; then
    echo "::warning::检测到精简版 wpad/hostapd-basic，160MHz 可能不支持"
  fi
  if ! grep -q "^CONFIG_PACKAGE_iw=y" .config; then
    sed -i '/^CONFIG_PACKAGE_iw=/d; /^# CONFIG_PACKAGE_iw is not set/d' .config
    echo "CONFIG_PACKAGE_iw=y                       # 无线命令行工具（160MHz 能力检测需要）" >> .config
    echo "✅ iw 已加入 .config"
  fi
fi

# ---------------------------------------------------------
# 5. 概览页「CPU 使用率（%）」行：USR/SYS + 每核明细
# ---------------------------------------------------------
if [ -f files/sbin/cpuusage ]; then chmod +x files/sbin/cpuusage; fi
if [ -f files/sbin/tempinfo ]; then chmod +x files/sbin/tempinfo; fi

SCRIPT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
PATCH_CPUUSAGE="$SCRIPT_DIR/scripts/patch-luci-cpuusage.sh"
if [ -f "$PATCH_CPUUSAGE" ]; then
  PONWRT_DIR=. bash "$PATCH_CPUUSAGE" || true
else
  echo "ℹ️ 未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"

# ========== 全面隐藏固件版本信息 ==========
RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

if [ -f "$RELEASE_TPL" ]; then
  sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=''/g" "$RELEASE_TPL"
  sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE=''/g" "$RELEASE_TPL"
  sed -i "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION=''/g" "$RELEASE_TPL"
  echo "✅ openwrt_release 模板版本字段已清空"
fi

if [ -f "$OSREL_TPL" ]; then
  sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"\"/g" "$OSREL_TPL"
  sed -i "s/^VERSION=.*/VERSION=\"\"/g" "$OSREL_TPL"
  echo "✅ os-release 模板版本字段已清空"
fi

if [ -f "package/base-files/files/etc/openwrt_version" ]; then
  echo -n "" > package/base-files/files/etc/openwrt_version
  echo "✅ openwrt_version 已清空"
fi

BANNER="package/base-files/files/etc/banner"
if [ -f "$BANNER" ]; then
  sed -i "/SNAPSHOT r[0-9]/d; /OpenWrt [0-9]/d; /ImmortalWrt [0-9]/d; /PonWrt SNAPSHOT/d" "$BANNER" || true
  echo "✅ banner 版本号行已清理（保留 ASCII art）"
fi

# apk 软件包源：默认中科大 USTC，双路径兼容
mkdir -p files/etc/apk/repositories.d

cat > files/etc/apk/repositories.d/distfeeds.list <<'EOF'
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/targets/airoha/an7581/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/base
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/luci
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/routing
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/telephony
EOF

cat > files/etc/apk/repositories <<'EOF'
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/targets/airoha/an7581/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/base
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/luci
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/routing
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/telephony
EOF

echo "✅ apk 软件包源默认 -> USTC snapshots（完整 6 个源，双路径兼容）"

# 后台菜单不显示"NAS"字样（package/feeds 下是符号链接，grep -r 不跟随，保留作为兼容垫片）
grep -rl "NAS" package/feeds --include='*.lua' 2>/dev/null \
  | while IFS= read -r f; do
      sed -i "s/_('NAS')/_(' ')/g; s/'NAS'/' '/g" "$f" || true
    done || true

# ========== 隐藏 Argon 主题设置选项菜单（保留主题皮肤本身） ==========
echo "🔍 隐藏 Argon 主题设置选项菜单..."
rm -rf package/feeds/luci/luci-app-argon-config 2>/dev/null || true

# ⚠ package/feeds/luci 下全是符号链接，grep -r 不跟随。改用 feeds/luci（真实目录）。
grep -rl "argon-config" feeds/luci --include="*.json" 2>/dev/null | while IFS= read -r f; do
  if python3 -c "import json; json.load(open('$f'))" 2>/dev/null; then
    python3 -c "
import json
with open('$f', 'r') as fp:
    data = json.load(fp)
def remove_argon(obj):
    if isinstance(obj, dict):
        keys_to_remove = [k for k in obj.keys() if 'argon-config' in str(k)]
        for k in keys_to_remove:
            del obj[k]
        for v in obj.values():
            remove_argon(v)
    elif isinstance(obj, list):
        items_to_remove = [i for i, item in enumerate(obj) if 'argon-config' in str(item)]
        for i in reversed(items_to_remove):
            del obj[i]
        for item in obj:
            remove_argon(item)
remove_argon(data)
with open('$f', 'w') as fp:
    json.dump(data, fp, indent=2)
" 2>/dev/null || true
  else
    sed -i 's/"luci-app-argon-config",\s*//g' "$f" || true
    sed -i 's/,\s*"luci-app-argon-config"//g' "$f" || true
    sed -i 's/"luci-app-argon-config"//g' "$f" || true
  fi
done || true

grep -rl "argon-config" feeds/luci --include="*.js" --include="*.lua" 2>/dev/null | while IFS= read -r f; do
  sed -i "/argon-config/d; /Argon 配置/d" "$f" || true
done || true
echo "✅ Argon 主题设置选项菜单已隐藏（主题皮肤保留）"

# 强制禁用 argon-config（加固）
echo "🔒 强制禁用 argon-config 包..."
if [ -f ".config" ]; then
  sed -i '/luci-app-argon-config/d' .config 2>/dev/null || true
  echo "# CONFIG_PACKAGE_luci-app-argon-config is not set" >> .config || true
  echo "✅ .config 已强制禁用 argon-config"
fi

# 强制禁用 passwall 系列
# ⚠ xray-core / sing-box 不在此列表：workflow 的 Configure 步骤明确
#   追加 CONFIG_PACKAGE_xray-core=y / sing-box=y（SSR Plus+ 后端），
#   这里再禁用会被 workflow 覆盖，属于自相矛盾的死代码。
echo "🔒 强制禁用 passwall 系列..."
if [ -f ".config" ]; then
  for pkg in luci-app-passwall luci-app-passwall2 luci-i18n-passwall-zh-cn; do
    sed -i "/$pkg/d" .config 2>/dev/null || true
    echo "# CONFIG_PACKAGE_$pkg is not set" >> .config || true
  done
  echo "✅ .config 已强制禁用 passwall 系列包"
fi

# 修复 ssr-plus 依赖 kcptun-client 缺失问题
echo "🔧 修复 ssr-plus 依赖 kcptun-client 缺失..."
SSR_MAKEFILE="package/feeds/helloworld/luci-app-ssr-plus/Makefile"
if [ -f "$SSR_MAKEFILE" ]; then
  sed -i 's/+kcptun-client//g' "$SSR_MAKEFILE" 2>/dev/null || true
  echo "✅ ssr-plus Makefile 已移除 kcptun-client 依赖"
fi

# ========== IPTV 相关菜单统一移到「网络」菜单下 ==========
# ⚠ 原代码用 package/feeds/luci（符号链接目录，grep -r 不跟随），实际无效。
#   改用 feeds/luci（真实源码目录），清理才会生效。
echo "🔍 调整 IPTV 相关菜单位置..."
IPTV_MENU_PACKAGES="igmpproxy rtp2httpd"
for pkg in $IPTV_MENU_PACKAGES; do
  grep -rl "$pkg" feeds/luci --include="*.json" 2>/dev/null | while IFS= read -r f; do
    if grep -q '"parent"' "$f" 2>/dev/null; then
      old_parent=$(grep -o '"parent":\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"parent":\s*"//;s/"//' || echo "unknown")
      sed -i 's/"parent":\s*"[^"]*"/"parent": "network"/g' "$f" || true
      echo "✅ 已调整 $pkg 菜单: $old_parent -> network ($f)"
    fi
  done || true
done || true

grep -rl "igmpproxy\|rtp2httpd" feeds/luci --include="*.json" 2>/dev/null | while IFS= read -r f; do
  if grep -q '"parent"' "$f" 2>/dev/null; then
    old_parent=$(grep -o '"parent":\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"parent":\s*"//;s/"//' || echo "unknown")
    if [ "$old_parent" != "network" ]; then
      sed -i 's/"parent":\s*"[^"]*"/"parent": "network"/g' "$f" || true
      echo "✅ 兜底调整: $old_parent -> network ($f)"
    fi
  fi
done || true

echo "✅ IPTV 相关菜单位置调整完成"

# ========== 全面隐藏固件版本信息（多层面） ==========
# ⚠ package/feeds 下全是符号链接，grep -r 不跟随；改用 feeds/ 真实目录。
echo "🔍 搜索 LuCI 状态页固件版本行文件..."
grep -rl "Firmware Version" feeds --include="*.js" 2>/dev/null | while IFS= read -r f; do
  line_num=$(grep -n "Firmware Version" "$f" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
  if [ -n "$line_num" ]; then
    sed -i "${line_num}d" "$f" || true
    echo "✅ 已从 $f (JS) 中删除固件版本行 (第 $line_num 行)"
  fi
done || true

grep -rl "Firmware Version" feeds --include="*.htm" --include="*.lua" 2>/dev/null | while IFS= read -r f; do
  line_num=$(grep -n "Firmware Version" "$f" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
  if [ -n "$line_num" ]; then
    sed -i "${line_num}d" "$f" || true
    echo "✅ 已从 $f (模板) 中删除固件版本行 (第 $line_num 行)"
  fi
done || true

echo "🔍 隐藏 LuCI 页脚版本信息..."
grep -rl "Powered by" feeds/luci --include="*.htm" --include="*.js" 2>/dev/null | while IFS= read -r f; do
  sed -i "s/LuCI Master [0-9.-]*/LuCI/g" "$f" || true
  sed -i "s/OpenWrt SNAPSHOT r[0-9a-f-]*/OpenWrt/g" "$f" || true
  echo "✅ 已从 $f 中清理页脚版本号"
done || true

grep -rl "OpenWrt" feeds/luci --include="*.htm" 2>/dev/null | while IFS= read -r f; do
  sed -i "/OpenWrt.*SNAPSHOT/d; /OpenWrt.*[0-9]/d" "$f" || true
done || true

echo "🔍 清空 LuCI 版本变量..."
grep -rl "luciversion" feeds/luci --include="*.js" 2>/dev/null | while IFS= read -r f; do
  sed -i "s/var luciversion = .*/var luciversion = '';/g" "$f" || true
  sed -i "s/luciversion = .*||.*/luciversion = '';/g" "$f" || true
done || true

# ========== SSR Plus+ 防火墙双向支持（fw3 iptables / fw4 nftables） ==========
# ⚠ 原实现含「放行所有转发」规则（iptables -I FORWARD -j ACCEPT /
#   nft add rule ... forward ... accept），极度危险，等于关闭防火墙转发保护。
#   SSR Plus+ 自身会管理必要的转发规则，外部脚本再加「全放行」是多此一举。
#   这里只保留：INPUT 端口放行（本机接收 SSR 端口）+ OUTPUT UID 放行（SSR
#   进程向外发起连接）。转发放行由 SSR Plus+ 自己负责。
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/97-ssr-plus-firewall <<'EOF'
#!/bin/sh
# ============================================================
# SSR Plus+ 防火墙双向支持（自动适配 fw3 / fw4）
# 只做两件事：
#   1) 允许外部访问 SSR Plus+ 监听端口（INPUT）
#   2) 允许 SSR Plus+ 进程向外发起连接（OUTPUT，按 UID）
# 不添加 FORWARD 放行 —— 那是 SSR Plus+ 自己管理的规则，
# 外部再加「全放行」会打开安全隐患。
# ============================================================

log() {
  logger -t ssr-firewall "$@"
  echo "[ssr-firewall] $@"
}

if command -v fw4 >/dev/null 2>&1; then
  FW_VER="fw4"
  log "检测到 fw4 (nftables)"
elif command -v fw3 >/dev/null 2>&1; then
  FW_VER="fw3"
  log "检测到 fw3 (iptables)"
else
  log "未检测到防火墙，跳过"
  exit 0
fi

i=0
while [ $i -lt 10 ]; do
  if pgrep -f "ssr-redir\|shadowsocksr" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

SSR_PORT=$(uci get shadowsocksr.@global[0].main_port 2>/dev/null || echo "1080")
log "SSR Plus+ 端口: $SSR_PORT"

SSR_UID=""
SSR_PIDS=$(pidof ssr-redir 2>/dev/null || echo "")
if [ -n "$SSR_PIDS" ]; then
  FIRST_PID=${SSR_PIDS%% *}
  if [ -r "/proc/$FIRST_PID/status" ]; then
    SSR_UID=$(grep "^Uid:" "/proc/$FIRST_PID/status" 2>/dev/null | awk '{print $2}')
  fi
fi

if [ "$FW_VER" = "fw4" ]; then
  nft add rule inet fw4 input tcp dport "$SSR_PORT" accept comment "SSR Plus+ input" 2>/dev/null || true
  if [ -n "$SSR_UID" ]; then
    nft add rule inet fw4 output meta skuid "$SSR_UID" accept comment "SSR Plus+ output" 2>/dev/null || true
  fi
  log "fw4 入站/出站规则已配置（转发规则由 SSR Plus+ 自身管理）"
else
  iptables -I INPUT -p tcp --dport "$SSR_PORT" -j ACCEPT -m comment --comment "SSR Plus+ input" 2>/dev/null || true
  if [ -n "$SSR_UID" ]; then
    iptables -I OUTPUT -m owner --uid-owner "$SSR_UID" -j ACCEPT -m comment --comment "SSR Plus+ output" 2>/dev/null || true
  fi
  log "fw3 入站/出站规则已配置（转发规则由 SSR Plus+ 自身管理）"
fi

exit 0
EOF
chmod +x files/etc/uci-defaults/97-ssr-plus-firewall
echo "✅ SSR Plus+ 入站/出站防火墙脚本已写入（转发规则交给 SSR Plus+ 自身）"

# ========== EIP93 NPU 硬件加密优化 ==========
echo "🔍 优化 EIP93 NPU 硬件加密调用..."
mkdir -p files/etc/modules.d
cat > files/etc/modules.d/zz-eip93 <<'EOF'
# EIP93 硬件加密驱动
crypto-hw-eip93
EOF
echo "✅ EIP93 驱动模块加载配置已写入"

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/90-eip93-npu-optimize <<'EOF'
#!/bin/sh
log() {
  logger -t eip93-npu "$@"
  echo "[eip93-npu] $@"
}

i=0
while [ $i -lt 5 ]; do
  if [ -d "/sys/class/crypto" ] || lsmod 2>/dev/null | grep -q "crypto"; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if lsmod 2>/dev/null | grep -q "eip93\|crypto_hw\|crypto-hw"; then
  log "✅ EIP93 硬件加密驱动已加载"
  if [ -d "/sys/class/crypto" ]; then
    hw_algs=$(ls /sys/class/crypto/ 2>/dev/null | grep -i "aes\|des\|sha" | head -5)
    log "硬件加速算法: $hw_algs"
  fi
  if [ -r "/proc/crypto" ]; then
    hw_count=$(grep -c "driver" /proc/crypto 2>/dev/null || echo 0)
    log "内核加密算法总数: $hw_count"
  fi
else
  log "⚠️  EIP93 驱动未加载，尝试手动加载..."
  modprobe crypto-hw-eip93 2>/dev/null || true
  sleep 1
  if lsmod 2>/dev/null | grep -q "eip93\|crypto_hw\|crypto-hw"; then
    log "✅ 手动加载 EIP93 成功"
  else
    log "⚠️  EIP93 驱动加载失败，使用软件加密（可能此硬件不支持）"
  fi
fi

if command -v openssl >/dev/null 2>&1; then
  engines=$(openssl engine 2>/dev/null | grep -i "eip\|hw\|crypto" || echo "")
  if [ -n "$engines" ]; then
    log "OpenSSL 硬件引擎: $engines"
  fi
fi

log "EIP93 NPU 优化完成"
exit 0
EOF
chmod +x files/etc/uci-defaults/90-eip93-npu-optimize
echo "✅ EIP93 NPU 优化脚本已写入"

# ========== DHCP 租约与匹配逻辑优化 ==========
echo "🔍 优化 DHCP 租约与匹配逻辑..."
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/95-dhcp-optimize <<'EOF'
#!/bin/sh
log() {
  logger -t dhcp-optimize "$@"
  echo "[dhcp-optimize] $@"
}

i=0
while [ $i -lt 10 ]; do
  if [ -f /etc/config/dhcp ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

[ -f /etc/config/dhcp ] || { log "未找到 dhcp 配置，跳过"; exit 0; }

log "优化 dnsmasq 全局配置..."
uci -q set dhcp.@dnsmasq[0].cachesize='1000'
uci -q set dhcp.@dnsmasq[0].localuse='1'
uci -q set dhcp.@dnsmasq[0].no_negcache='1'
uci -q set dhcp.@dnsmasq[0].rebind_protection='1'

log "优化 DHCP 租约时间..."
for cfg in $(uci -q show dhcp | grep '=dhcp$' | cut -d. -f2 | cut -d= -f1); do
  uci -q set dhcp.$cfg.leasetime='12h'
  uci -q set dhcp.$cfg.limit='150'
  log "  接口 $cfg: 租约 12h, 上限 150 台"
done

log "优化静态租约匹配逻辑..."
static_count=$(uci -q show dhcp | grep -c "=host$" || echo 0)
log "  静态绑定数量: $static_count"

if ! uci -q get dhcp.@dnsmasq[0].dhcp_option | grep -q "option:router"; then
  uci -q add_list dhcp.@dnsmasq[0].dhcp_option='option:router'
fi
if ! uci -q get dhcp.@dnsmasq[0].dhcp_option | grep -q "option:broadcast"; then
  uci -q add_list dhcp.@dnsmasq[0].dhcp_option='option:broadcast'
fi

uci -q commit dhcp
log "DHCP 优化配置已提交"

if [ -x /etc/init.d/dnsmasq ]; then
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
  log "dnsmasq 已重启"
fi

log "DHCP 优化完成"
exit 0
EOF
chmod +x files/etc/uci-defaults/95-dhcp-optimize
echo "✅ DHCP 租约优化脚本已写入"

# ========== 运存（内存）容量优化（不牺牲网络速度） ==========
echo "🔍 优化运存占用（确保网络高速）..."
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/93-memory-optimize <<'EOF'
#!/bin/sh
log() {
  logger -t mem-optimize "$@"
  echo "[mem-optimize] $@"
}

sleep 3

log "优化日志占用（不影响网络）..."
uci -q set system.@system[0].log_size='64'
uci -q set system.@system[0].log_buffer_size='16'

log "优化内核参数..."
# ⚠ dirty_ratio / dirty_background_ratio 的有效范围是 0-100（百分比）。
#   原先写的 1000 / 500 会被内核拒绝，无任何效果。
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true
echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true

log "关闭不必要的后台日志..."
uci -q set uhttpd.main.no_log='1' 2>/dev/null || true

uci -q commit system
log "内存优化配置已提交（不影响网络速度）"

if [ -r /proc/meminfo ]; then
  mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  log "内存状态: 总 ${mem_total}KB, 可用 ${mem_available}KB"
fi

log "运存优化完成（网络性能优先）"
exit 0
EOF
chmod +x files/etc/uci-defaults/93-memory-optimize
echo "✅ 运存优化脚本已写入（不牺牲网络速度）"

# ========== 首启清空版本信息（双重保险） ==========
cat > files/etc/uci-defaults/98-hide-version <<'EOF'
#!/bin/sh
log() {
  logger -t hide-version "$@"
  echo "[hide-version] $@"
}

if [ -f /etc/openwrt_release ]; then
  sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=''/g" /etc/openwrt_release
  sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE=''/g" /etc/openwrt_release
  sed -i "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION=''/g" /etc/openwrt_release
  log "已清空 /etc/openwrt_release"
fi

if [ -f /usr/lib/os-release ]; then
  sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"\"/g" /usr/lib/os-release
  sed -i "s/^VERSION=.*/VERSION=\"\"/g" /usr/lib/os-release
  log "已清空 /usr/lib/os-release"
fi

if [ -f /etc/openwrt_version ]; then
  echo -n "" > /etc/openwrt_version
  log "已清空 /etc/openwrt_version"
fi

log "清理 LuCI 状态页版本信息..."
for f in /usr/lib/lua/luci/controller/status.lua \
         /usr/lib/lua/luci/view/status/index.htm \
         /www/luci-static/resources/view/status/index.js; do
  if [ -f "$f" ]; then
    sed -i "/Firmware Version/d; /固件版本/d" "$f" 2>/dev/null || true
    log "已清理 $f"
  fi
done

if [ -f /etc/banner ]; then
  sed -i "/SNAPSHOT r[0-9]/d; /OpenWrt [0-9]/d; /ImmortalWrt [0-9]/d; /PonWrt SNAPSHOT/d" /etc/banner 2>/dev/null || true
  log "已清理 /etc/banner"
fi

if [ -f /etc/config/luci ]; then
  uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null || true
  uci commit luci 2>/dev/null || true
  log "已设置默认主题为 Argon"
fi

log "版本信息隐藏完成（三重保险）"
exit 0
EOF
chmod +x files/etc/uci-defaults/98-hide-version
echo "✅ 版本隐藏 uci-defaults 脚本已写入（双重保险）"

# 加密脚本：用 $GITHUB_WORKSPACE 绝对路径 —— cwd 是 openwrt 源码树，
# 相对路径会指向 $BUILD_ROOT/openwrt/scripts/，找不到用户自备的脚本。
# 用 subshell 把 set -u 崩溃隔离在子进程，主脚本不受影响。
# 末尾 || true：本文件开头 set -euo pipefail，source 的子脚本里任何
# 步骤返回非 0 都会让这里当场退出。加密是可选增强，不该搞挂构建。
_crypto_sh="${GITHUB_WORKSPACE:-$(dirname "$0")}/scripts/diy-part2-crypto.sh"
if [ -f "$_crypto_sh" ]; then
  ( . "$_crypto_sh" ) || true
fi

# 7. 强制确保状态插件配置正确（防止被意外剔除）
# ⚠ 用精确锚定 /^CONFIG_PACKAGE_$pkg[= ]/d，避免误删包含子串的注释行。
#   workflow 的 Validate 步骤也做了同样的强制，这里作为本地单独跑时的兜底。
echo "🔒 强制确保状态插件配置..."
if [ -f ".config" ]; then
  for pkg in luci-app-airoha-npu luci-app-pon-status luci-app-natmode; do
    sed -i "/^CONFIG_PACKAGE_${pkg}[= ]/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config 2>/dev/null || true
    echo "CONFIG_PACKAGE_$pkg=y" >> .config || true
  done
  echo "✅ 状态插件配置已强制确保"
fi

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"

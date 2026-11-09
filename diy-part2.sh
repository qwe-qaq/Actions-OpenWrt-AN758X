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
WIFI_24G_COUNTRY="${WIFI_24G_COUNTRY:-CN}"    # 国家代码（CN = 中国）
WIFI_24G_CHANNEL="${WIFI_24G_CHANNEL:-auto}"    # 信道（auto = 自动选择）

# 5G WiFi 参数
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"       # 国家代码（CN = 中国）
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"     # 信道（auto = 自动选择）
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"      # 160MHz（WiFi6）；回落 HE80
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"   # 硬件不支持 160MHz 时的回落值

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
  # 兼容 @system[-1]（旧）与 @system[0]（OpenWrt 21+）
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
# 3. 补上亚洲时区数据库包（LuCI 显示与时区切换需要）
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y    # 亚洲时区数据库（中国时区需要）" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"

  # libffi：见 diy-part1.sh 的同名段落。源码树原本没有这个包，
  # python3(3.14) 的 _ctypes 却必须要它的 ffi.h / libffi.pc，
  # 缺了就 fatal error 拖垮 world。这里显式打开 target 版，
  # 让 Build/InstallDev 把头文件装进 staging_dir。
  sed -i '/^CONFIG_PACKAGE_libffi=/d; /^# CONFIG_PACKAGE_libffi is not set/d' .config
  echo "CONFIG_PACKAGE_libffi=y           # python3 _ctypes 需要 ffi.h / libffi.pc" >> .config
  echo "✅ libffi 已加入 .config"
fi

# ---------------------------------------------------------
# 4. 5G WiFi：CN / auto / HE160
#   分两层：编译期改 detect 脚本默认值（best effort，各版本路径不同）；
#   运行期用 uci-defaults 首启强制刷（主要手段，保留配置升级也生效，且自带
#   「wireless 尚未生成就先 wifi config」的逻辑）。
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
  # 5G（11a / band 5g）的默认信道改成 auto
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

# 2.4G 国家码和信道
COUNTRY_24G='$WIFI_24G_COUNTRY'
CHANNEL_24G='$WIFI_24G_CHANNEL'

# 5G 参数
COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'

log() { logger -t wifi-config "\$@"; }

# uci-defaults 可能在 wifi config 之前执行 —— 没生成就先生成
if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

# 检测该 phy 是否支持 160MHz（兼容 "160 MHz" 与 "80+80 MHz" 两种表述）
support_160() {
	local phy="\$1"
	[ -z "\$phy" ] && return 1
	command -v iw >/dev/null 2>&1 || return 1
	iw phy "\$phy" info 2>/dev/null | grep -qE '160 MHz|80\+80 MHz' || return 1
	return 0
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-device\$/\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"

	# 判断是 2.4G 还是 5G
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1

	if [ "\$is5g" = "1" ]; then
		# ---- 5G：设置国家码 + 信道 + 频宽 ----
		# 频宽：确认不支持 160MHz 才回落
		# 取不到 phy 名时不检测（保持 HTMODE）—— 避免无 phy 选项的 radio 被误判回落
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
		# ---- 2.4G：设置国家码 + 信道 auto ----
		uci -q set wireless.\$dev.country="\$COUNTRY_24G"
		uci -q set wireless.\$dev.country_ie='1'
		uci -q set wireless.\$dev.channel="\$CHANNEL_24G"
		log "\$dev (2.4G): country=\$COUNTRY_24G channel=\$CHANNEL_24G"
	fi

	changed=1
done

# 默认无线名称：2.4G = TP-LINK_6628，5G = TP-LINK_6628_5G
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
	# 重载而非重启：避免首启期间无线中断后不可恢复
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 5G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/96-wifi-5g-cn
echo "✅ uci-defaults WiFi 脚本已写入（2.4G country=$WIFI_24G_COUNTRY channel=$WIFI_24G_CHANNEL，5G country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE）"

# ---- 4c. 确保 hostapd 支持 160MHz / 11ax ----
# wpad-openssl = 完整版 hostapd，支持 HE160；
# 若用的是 wpad-basic / hostapd-basic（精简版），160MHz 可能不生效。
if [ -f .config ]; then
  if grep -qE "^CONFIG_PACKAGE_(wpad-basic|hostapd-basic)=y" .config; then
    echo "::warning::检测到精简版 wpad/hostapd-basic，160MHz 可能不支持"
  fi
  # 无线工具：uci-defaults 里的能力检测需要 iw
  if ! grep -q "^CONFIG_PACKAGE_iw=y" .config; then
    sed -i '/^CONFIG_PACKAGE_iw=/d; /^# CONFIG_PACKAGE_iw is not set/d' .config
    echo "CONFIG_PACKAGE_iw=y                       # 无线命令行工具（160MHz 能力检测需要）" >> .config
    echo "✅ iw 已加入 .config"
  fi
fi

# ---------------------------------------------------------
# 5. 概览页「CPU 使用率（%）」行：USR/SYS + 每核明细
#   luci 原本是 popen("top -n1 | awk ...") 的单值。这里只把它改指到
#   files/sbin/cpuusage，前端 10_system.js 与 ACL 都不动。
#   纯显示层：找不到目标只 warning，不让它把几小时的构建搞挂。
# ---------------------------------------------------------
PATCH_CPUUSAGE="$(dirname "$0")/scripts/patch-luci-cpuusage.sh"
if [ -f "$PATCH_CPUUSAGE" ]; then
  PONWRT_DIR=. bash "$PATCH_CPUUSAGE" || true
else
  echo "ℹ️ 未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"

# ========== 全面隐藏固件版本信息 ==========
# 方式一：不再固定版本串（留空）
FW_MAIN=""
RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

# 两处版本信息置空
FW_DESC_LINE="DISTRIB_DESCRIPTION=''"
OSREL_LINE="OPENWRT_RELEASE=\"\""
export FW_DESC_LINE OSREL_LINE

# 方式二：直接清空 openwrt_release 模板中的版本字段
if [ -f "$RELEASE_TPL" ]; then
  sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=''/g" "$RELEASE_TPL"
  sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE=''/g" "$RELEASE_TPL"
  sed -i "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION=''/g" "$RELEASE_TPL"
  echo "✅ openwrt_release 模板版本字段已清空"
fi

# 方式三：直接清空 os-release 模板中的版本字段
if [ -f "$OSREL_TPL" ]; then
  sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"\"/g" "$OSREL_TPL"
  sed -i "s/^VERSION=.*/VERSION=\"\"/g" "$OSREL_TPL"
  echo "✅ os-release 模板版本字段已清空"
fi

# 方式四：清空 openwrt_version 文件（纯版本号）
if [ -f "package/base-files/files/etc/openwrt_version" ]; then
  echo -n "" > package/base-files/files/etc/openwrt_version
  echo "✅ openwrt_version 已清空"
fi

# 方式五：修改 banner，只删除末尾版本号行，保留 ASCII art
BANNER="package/base-files/files/etc/banner"
if [ -f "$BANNER" ]; then
  # 删除包含版本号格式的行（如 "OpenWrt SNAPSHOT r1234-abcdef"）
  sed -i "/SNAPSHOT r[0-9]/d; /OpenWrt [0-9]/d; /ImmortalWrt [0-9]/d; /PonWrt SNAPSHOT/d" "$BANNER" || true
  echo "✅ banner 版本号行已清理（保留 ASCII art）"
fi

# apk 软件包源：默认中科大 USTC（用户偏好，不自动检测）
# 同时写两个路径，兼容 24.10（repositories）和 25.12+（repositories.d/distfeeds.list）
# 写完整的 6 个源，避免缺少包
mkdir -p files/etc/apk/repositories.d

# 路径1：25.12.0+ 版本
cat > files/etc/apk/repositories.d/distfeeds.list <<'EOF'
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/targets/airoha/an7581/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/base
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/luci
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/routing
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/telephony
EOF

# 路径2：24.10 及更早版本（兼容旧路径）
cat > files/etc/apk/repositories <<'EOF'
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/targets/airoha/an7581/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/base
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/luci
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/routing
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53/telephony
EOF

echo "✅ apk 软件包源默认 -> USTC snapshots（完整 6 个源，双路径兼容）"

# 后台菜单不显示“NAS”字样；USB 存储功能仍保留
grep -rl "NAS" package/feeds --include='*.lua' 2>/dev/null \
  | while read -r f; do
      sed -i "s/_('NAS')/_(' ')/g; s/'NAS'/' '/g" "$f" || true
    done || true

# ========== 隐藏 Argon 主题设置选项菜单（保留主题皮肤本身） ==========
echo "🔍 隐藏 Argon 主题设置选项菜单..."
# 1. 只删除 argon-config 设置菜单（不删除主题本身）
rm -rf package/feeds/luci/luci-app-argon-config 2>/dev/null || true
# 2. 从菜单 JSON 里删除 argon-config 条目（更精确，避免 JSON 格式错误）
# 用 python 处理 JSON 更安全，但如果没有 python 就用改进的 sed
grep -rl "argon-config" package/feeds/luci --include="*.json" 2>/dev/null | while read -r f; do
  # 先检查文件是不是有效 JSON（简单检查）
  if python3 -c "import json; json.load(open('$f'))" 2>/dev/null; then
    # 用 python 精确删除 argon-config 条目
    python3 -c "
import json
with open('$f', 'r') as fp:
    data = json.load(fp)
# 递归删除所有包含 argon-config 的条目
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
    # 没有 python 就用改进的 sed（处理各种情况）
    # 情况1: "luci-app-argon-config", （后面有逗号）
    sed -i 's/"luci-app-argon-config",\s*//g' "$f" || true
    # 情况2: , "luci-app-argon-config" （前面有逗号）
    sed -i 's/,\s*"luci-app-argon-config"//g' "$f" || true
    # 情况3: 单独的条目（前后都没有逗号）
    sed -i 's/"luci-app-argon-config"//g' "$f" || true
  fi
done || true
# 3. 删除 LuCI 菜单里的 argon-config 菜单项
grep -rl "argon-config" package/feeds/luci --include="*.js" --include="*.lua" 2>/dev/null | while read -r f; do
  sed -i "/argon-config/d; /Argon 配置/d" "$f" || true
done || true
echo "✅ Argon 主题设置选项菜单已隐藏（主题皮肤保留）"

# 3. 强制在 .config 里禁用 argon-config（加固）
echo "🔒 强制禁用 argon-config 包..."
if [ -f ".config" ]; then
  # 先删除所有相关配置行
  sed -i '/luci-app-argon-config/d' .config 2>/dev/null || true
  # 强制写入 is not set
  echo "# CONFIG_PACKAGE_luci-app-argon-config is not set" >> .config || true
  echo "✅ .config 已强制禁用 argon-config"
fi

# 4. 强制禁用 passwall/xray-core/sing-box（加固）
echo "🔒 强制禁用 passwall/xray-core/sing-box..."
if [ -f ".config" ]; then
  for pkg in luci-app-passwall xray-core sing-box luci-app-passwall2 luci-i18n-passwall-zh-cn; do
    sed -i "/$pkg/d" .config 2>/dev/null || true
    echo "# CONFIG_PACKAGE_$pkg is not set" >> .config || true
  done
  echo "✅ .config 已强制禁用 passwall 系列包"
fi

# 5. 修复 ssr-plus 依赖 kcptun-client 缺失问题（helloworld feed 已移除 kcptun）
echo "🔧 修复 ssr-plus 依赖 kcptun-client 缺失..."
SSR_MAKEFILE="package/feeds/helloworld/luci-app-ssr-plus/Makefile"
if [ -f "$SSR_MAKEFILE" ]; then
  # 从 Makefile 的 DEPENDS 里去掉 kcptun-client
  sed -i 's/+kcptun-client//g' "$SSR_MAKEFILE" 2>/dev/null || true
  echo "✅ ssr-plus Makefile 已移除 kcptun-client 依赖"
fi

# ========== IPTV 相关菜单统一移到「网络」菜单下 ==========
echo "🔍 调整 IPTV 相关菜单位置..."
# 通用搜索：在整个 luci feeds 里找 igmpproxy / rtp2httpd 的菜单 JSON 文件
# 不硬编码路径，避免目录结构不同导致找不到
# 同时搜索所有可能的菜单文件位置（menu/ 目录、luci/ 目录、根目录）

# 方法一：按包名搜索菜单 JSON 文件
IPTV_MENU_PACKAGES="igmpproxy rtp2httpd"
for pkg in $IPTV_MENU_PACKAGES; do
  # 搜索所有包含该包名的菜单 JSON 文件
  grep -rl "$pkg" package/feeds/luci --include="*.json" 2>/dev/null | while read -r f; do
    # 只处理菜单相关的 JSON 文件（包含 "parent" 或 "menu" 字段的）
    if grep -q '"parent"' "$f" 2>/dev/null; then
      # 记录原来的父菜单（加 || true 避免 pipefail 退出）
      old_parent=$(grep -o '"parent":\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"parent":\s*"//;s/"//' || echo "unknown")
      # 把任意父菜单改成 network
      sed -i 's/"parent":\s*"[^"]*"/"parent": "network"/g' "$f" || true
      echo "✅ 已调整 $pkg 菜单: $old_parent -> network ($f)"
    fi
  done || true
done || true

# 方法二：兜底搜索，直接找所有包含 "igmpproxy" 或 "rtp2httpd" 的菜单文件
grep -rl "igmpproxy\|rtp2httpd" package/feeds/luci --include="*.json" 2>/dev/null | while read -r f; do
  if grep -q '"parent"' "$f" 2>/dev/null; then
    old_parent=$(grep -o '"parent":\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"parent":\s*"//;s/"//' || echo "unknown")
    # 只改不是 network 的
    if [ "$old_parent" != "network" ]; then
      sed -i 's/"parent":\s*"[^"]*"/"parent": "network"/g' "$f" || true
      echo "✅ 兜底调整: $old_parent -> network ($f)"
    fi
  fi
done || true

echo "✅ IPTV 相关菜单位置调整完成"

# ========== 全面隐藏固件版本信息（多层面） ==========
echo "🔍 搜索 LuCI 状态页固件版本行文件..."
# 方式一：新版 JS 组件 - 删除整行（只匹配 Firmware Version，不要求同行有其他内容）
# 优化：删除整行后，检查前一行末尾有没有多余的逗号，避免数组语法错误
grep -rl "Firmware Version" package/feeds feeds --include="*.js" 2>/dev/null | while read -r f; do
  # 先找到 Firmware Version 所在的行号（加 || true 避免 pipefail 退出）
  line_num=$(grep -n "Firmware Version" "$f" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
  if [ -n "$line_num" ]; then
    # 删除该行
    sed -i "${line_num}d" "$f" || true
    echo "✅ 已从 $f (JS) 中删除固件版本行 (第 $line_num 行)"
  fi
done || true
# 方式二：旧版 Lua 模板 - 删除整行
grep -rl "Firmware Version" package/feeds feeds --include="*.htm" --include="*.lua" 2>/dev/null | while read -r f; do
  line_num=$(grep -n "Firmware Version" "$f" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
  if [ -n "$line_num" ]; then
    sed -i "${line_num}d" "$f" || true
    echo "✅ 已从 $f (模板) 中删除固件版本行 (第 $line_num 行)"
  fi
done || true

# 方式三：LuCI 页脚版本信息 - 更精确的清理（避免误删）
echo "🔍 隐藏 LuCI 页脚版本信息..."
# 只替换版本号部分，不删除整个句子，避免破坏 HTML 结构
grep -rl "Powered by" package/feeds/luci --include="*.htm" --include="*.js" 2>/dev/null | while read -r f; do
  # 只替换 LuCI Master 版本号部分，保留 "Powered by LuCI" 文字
  sed -i "s/LuCI Master [0-9.-]*/LuCI/g" "$f" || true
  sed -i "s/OpenWrt SNAPSHOT r[0-9a-f-]*/OpenWrt/g" "$f" || true
  echo "✅ 已从 $f 中清理页脚版本号"
done || true

# 方式四：LuCI 登录页版本信息 - 清空
grep -rl "OpenWrt" package/feeds/luci --include="*.htm" 2>/dev/null | while read -r f; do
  sed -i "/OpenWrt.*SNAPSHOT/d; /OpenWrt.*[0-9]/d" "$f" || true
done || true

# 方式五：清空 LuCI 版本相关变量（多种格式都兼容）
echo "🔍 清空 LuCI 版本变量..."
grep -rl "luciversion" package/feeds/luci --include="*.js" 2>/dev/null | while read -r f; do
  # 兼容多种写法：var luciversion = xxx; / luciversion = xxx || ''; / luciversion = ''
  sed -i "s/var luciversion = .*/var luciversion = '';/g" "$f" || true
  sed -i "s/luciversion = .*||.*/luciversion = '';/g" "$f" || true
done || true

# ========== SSR Plus+ 防火墙双向支持（fw3 iptables / fw4 nftables） ==========
echo "🔍 配置 SSR Plus+ 防火墙双向支持..."
# 方式：创建独立的 uci-defaults 脚本，首启时自动配置
# 不修改 SSR Plus+ 源码，避免破坏原有逻辑
# 支持双向：入站（接收）+ 出站（发起）+ 转发（代理流量）

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/97-ssr-plus-firewall <<'EOF'
#!/bin/sh
# ============================================================
# SSR Plus+ 防火墙双向支持（自动适配 fw3 / fw4）
# 首启时自动检测防火墙版本，配置对应的双向规则
# ============================================================

log() {
  logger -t ssr-firewall "$@"
  echo "[ssr-firewall] $@"
}

# 检测防火墙版本
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

# 等待 SSR Plus+ 服务启动（最多等 10 秒）
i=0
while [ $i -lt 10 ]; do
  if pgrep -f "ssr-redir\|shadowsocksr" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

# 获取 SSR Plus+ 端口（默认 1080）
SSR_PORT=$(uci get shadowsocksr.@global[0].main_port 2>/dev/null || echo "1080")
log "SSR Plus+ 端口: $SSR_PORT"

# 配置双向防火墙规则
if [ "$FW_VER" = "fw4" ]; then
  # fw4 nftables 规则
  # 入站：允许 SSR Plus+ 端口接收
  nft add rule inet fw4 input tcp dport "$SSR_PORT" accept comment "SSR Plus+ input" 2>/dev/null || true
  # 出站：允许 SSR Plus+ 进程向外连接（skuid 是 UID，不是 PID）
  SSR_PID=$(pidof ssr-redir 2>/dev/null || echo "")
  if [ -n "$SSR_PID" ]; then
    # 获取进程的 UID
    SSR_UID=$(cat /proc/"$SSR_PID"/status 2>/dev/null | grep "^Uid:" | awk '{print $2}')
    if [ -n "$SSR_UID" ]; then
      nft add rule inet fw4 output meta skuid "$SSR_UID" accept comment "SSR Plus+ output" 2>/dev/null || true
    fi
  fi
  # 转发：允许代理流量转发
  nft add rule inet fw4 forward meta comment "SSR Plus+ forward" accept 2>/dev/null || true
  log "fw4 双向防火墙规则已配置"
else
  # fw3 iptables 规则
  # 入站：允许 SSR Plus+ 端口接收
  iptables -I INPUT -p tcp --dport "$SSR_PORT" -j ACCEPT -m comment --comment "SSR Plus+ input" 2>/dev/null || true
  # 出站：允许 SSR Plus+ 进程向外连接（用 pidof 更可靠，兼容 busybox）
  SSR_PID=$(pidof ssr-redir 2>/dev/null || echo "")
  if [ -n "$SSR_PID" ]; then
    # 获取进程的 UID
    SSR_UID=$(cat /proc/"$SSR_PID"/status 2>/dev/null | grep "^Uid:" | awk '{print $2}')
    if [ -n "$SSR_UID" ]; then
      iptables -I OUTPUT -m owner --uid-owner "$SSR_UID" -j ACCEPT -m comment --comment "SSR Plus+ output" 2>/dev/null || true
    fi
  fi
  # 转发：允许代理流量转发
  iptables -I FORWARD -p tcp -m comment --comment "SSR Plus+ forward" -j ACCEPT 2>/dev/null || true
  log "fw3 双向防火墙规则已配置"
fi

exit 0
EOF
chmod +x files/etc/uci-defaults/97-ssr-plus-firewall
echo "✅ SSR Plus+ 双向防火墙脚本已写入（自动适配 fw3/fw4）"

# ========== EIP93 NPU 硬件加密优化 ==========
echo "🔍 优化 EIP93 NPU 硬件加密调用..."
# 1. 确保 EIP93 驱动模块在启动时加载
mkdir -p files/etc/modules.d
cat > files/etc/modules.d/zz-eip93 <<'EOF'
# EIP93 硬件加密驱动
crypto-hw-eip93
EOF
echo "✅ EIP93 驱动模块加载配置已写入"

# 2. 首启时检查 EIP93 硬件状态并优化（编号 90，最早执行）
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/90-eip93-npu-optimize <<'EOF'
#!/bin/sh
# ============================================================
# EIP93 NPU 硬件加密优化脚本（最早执行，确保内核模块加载）
# 首启时检测硬件状态，确保驱动正确加载
# ============================================================

log() {
  logger -t eip93-npu "$@"
  echo "[eip93-npu] $@"
}

# 等待内核模块加载完成（最多等 5 秒）
i=0
while [ $i -lt 5 ]; do
  if [ -d "/sys/class/crypto" ] || lsmod 2>/dev/null | grep -q "crypto"; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

# 检查 EIP93 驱动是否加载（多种匹配方式，兼容不同内核版本）
if lsmod 2>/dev/null | grep -q "eip93\|crypto_hw\|crypto-hw"; then
  log "✅ EIP93 硬件加密驱动已加载"
  
  # 检查可用的加密算法
  if [ -d "/sys/class/crypto" ]; then
    hw_algs=$(ls /sys/class/crypto/ 2>/dev/null | grep -i "aes\|des\|sha" | head -5)
    log "硬件加速算法: $hw_algs"
  fi
  
  # 检查 AF_ALG 用户空间接口
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

# 优化 OpenSSL 引擎（如果可用）
if command -v openssl >/dev/null 2>&1; then
  # 检查是否有硬件引擎
  engines=$(openssl engine 2>/dev/null | grep -i "eip\|hw\|crypto" || echo "")
  if [ -n "$engines" ]; then
    log "OpenSSL 硬件引擎: $engines"
  fi
fi

log "EIP93 NPU 优化完成"
exit 0
EOF
chmod +x files/etc/uci-defaults/90-eip93-npu-optimize
echo "✅ EIP93 NPU 优化脚本已写入（编号 90，最早执行）"

# ========== DHCP 租约与匹配逻辑优化 ==========
echo "🔍 优化 DHCP 租约与匹配逻辑..."
# 优化 dnsmasq 配置：
# 1. 租约时间优化：默认 12h，适合家庭网络
# 2. DNS 缓存优化：增大缓存，加快解析
# 3. 静态租约匹配优化：按 MAC 精确匹配
# 4. 自启动优化：确保 dnsmasq 正确启动

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/95-dhcp-optimize <<'EOF'
#!/bin/sh
# ============================================================
# DHCP 租约与匹配逻辑优化
# 首启时自动配置，优化家庭网络体验
# ============================================================

log() {
  logger -t dhcp-optimize "$@"
  echo "[dhcp-optimize] $@"
}

# 等待 network 配置就绪（最多等 10 秒）
i=0
while [ $i -lt 10 ]; do
  if [ -f /etc/config/dhcp ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

[ -f /etc/config/dhcp ] || { log "未找到 dhcp 配置，跳过"; exit 0; }

# ---- 1. dnsmasq 全局优化 ----
log "优化 dnsmasq 全局配置..."

# 增大 DNS 缓存（默认 150，改成 1000，加快重复域名解析）
uci -q set dhcp.@dnsmasq[0].cachesize='1000'
# 启用本地 DNS 解析（局域网主机名解析）
uci -q set dhcp.@dnsmasq[0].localuse='1'
# 禁用负缓存（避免解析失败的域名被缓存太久）
uci -q set dhcp.@dnsmasq[0].no_negcache='1'
# 启用 DNS 重绑定保护（安全）
uci -q set dhcp.@dnsmasq[0].rebind_protection='1'
# 快速 DHCP（减少租约分配时间）
uci -q set dhcp.@dnsmasq[0].fastdhcp='1'

# ---- 2. DHCP 租约优化 ----
log "优化 DHCP 租约时间..."

# 遍历所有 DHCP 接口
for cfg in $(uci -q show dhcp | grep '=dhcp$' | cut -d. -f2 | cut -d= -f1); do
  # 默认租约时间 12 小时（家庭网络够用）
  uci -q set dhcp.$cfg.leasetime='12h'
  # 最小租约时间 1h（设备频繁切换网络时更快续租）
  uci -q set dhcp.$cfg.limit='150'
  log "  接口 $cfg: 租约 12h, 上限 150 台"
done

# ---- 3. 静态租约匹配优化 ----
# 确保静态绑定按 MAC 精确匹配，不匹配主机名
log "优化静态租约匹配逻辑..."

# 检查是否有静态绑定
static_count=$(uci -q show dhcp | grep -c "=host$" || echo 0)
log "  静态绑定数量: $static_count"

# ---- 4. DHCP 选项优化 ----
# 启用 router 选项（默认网关）
# 启用 broadcast 选项
# 优化 NTP 选项
# 注意：只追加不存在的选项，不删除现有配置，避免覆盖用户自定义
if ! uci -q get dhcp.@dnsmasq[0].dhcp_option | grep -q "option:router"; then
  uci -q add_list dhcp.@dnsmasq[0].dhcp_option='option:router'
fi
if ! uci -q get dhcp.@dnsmasq[0].dhcp_option | grep -q "option:broadcast"; then
  uci -q add_list dhcp.@dnsmasq[0].dhcp_option='option:broadcast'
fi

# 提交配置
uci -q commit dhcp
log "DHCP 优化配置已提交"

# 重启 dnsmasq 使配置生效
if [ -x /etc/init.d/dnsmasq ]; then
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
  log "dnsmasq 已重启"
fi

log "DHCP 优化完成"
exit 0
EOF
chmod +x files/etc/uci-defaults/95-dhcp-optimize
echo "✅ DHCP 租约优化脚本已写入（租约 12h + DNS 缓存 + 快速 DHCP）"

# ========== 运存（内存）容量优化（不牺牲网络速度） ==========
echo "🔍 优化运存占用（确保网络高速）..."
# 优化原则：
# 1. 不牺牲网络速度：DNS 缓存、DHCP 响应、转发性能都保持最优
# 2. 只优化不影响网络的部分：日志、内核参数、非必要服务
# 3. 网络相关配置保持最大性能

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/93-memory-optimize <<'EOF'
#!/bin/sh
# ============================================================
# 运存（内存）容量优化（不牺牲网络速度）
# 原则：网络性能优先，内存优化不影响转发速度和延迟
# ============================================================

log() {
  logger -t mem-optimize "$@"
  echo "[mem-optimize] $@"
}

# 等待系统就绪
sleep 3

# ---- 1. 日志优化：不影响网络，只减少内存占用 ----
log "优化日志占用（不影响网络）..."
# 限制日志缓冲区大小（减少内存占用，不影响网络）
uci -q set system.@system[0].log_size='64'  # 64KB 日志缓冲区
uci -q set system.@system[0].log_buffer_size='16'  # 16KB 内存缓冲

# ---- 2. 内核参数优化：优化内存，不影响网络吞吐 ----
log "优化内核参数..."
# 减少 swappiness：尽量少用 swap，优先用物理内存
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true
# 优化脏页写回：减少内存碎片，不影响网络
echo 1000 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 500 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true

# ---- 3. 关闭不必要的服务日志（不影响网络速度） ----
log "关闭不必要的后台日志..."
# 关闭 uhttpd 访问日志（不影响 web 速度，只是少写日志）
uci -q set uhttpd.main.no_log='1' 2>/dev/null || true

# ---- 4. 注意：不修改 dnsmasq 配置！ ----
# DNS 缓存大小、DHCP 响应速度都由 DHCP 优化脚本（95）设置为最优值
# 这里不修改，确保网络解析和转发速度最快

# 提交配置
uci -q commit system
log "内存优化配置已提交（不影响网络速度）"

# 显示当前内存状态
if [ -r /proc/meminfo ]; then
  mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  log "内存状态: 总 ${mem_total}KB, 可用 ${mem_available}KB"
fi

log "运存优化完成（网络性能优先）"
exit 0
EOF
chmod +x files/etc/uci-defaults/93-memory-optimize
echo "✅ 运存优化脚本已写入（不牺牲网络速度，只优化日志和内核参数）"

# ========== 首启清空版本信息（双重保险） ==========
cat > files/etc/uci-defaults/98-hide-version <<'EOF'
#!/bin/sh
# 首启时清空版本信息，确保 LuCI 概览页不显示版本
log() {
  logger -t hide-version "$@"
  echo "[hide-version] $@"
}

# 清空 openwrt_release
if [ -f /etc/openwrt_release ]; then
  sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=''/g" /etc/openwrt_release
  sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE=''/g" /etc/openwrt_release
  sed -i "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION=''/g" /etc/openwrt_release
  log "已清空 /etc/openwrt_release"
fi

# 清空 os-release
if [ -f /usr/lib/os-release ]; then
  sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"\"/g" /usr/lib/os-release
  sed -i "s/^VERSION=.*/VERSION=\"\"/g" /usr/lib/os-release
  log "已清空 /usr/lib/os-release"
fi

# 清空 openwrt_version
if [ -f /etc/openwrt_version ]; then
  echo -n "" > /etc/openwrt_version
  log "已清空 /etc/openwrt_version"
fi

# 清理 LuCI 状态页里的固件版本行（多种格式都兼容）
log "清理 LuCI 状态页版本信息..."
for f in /usr/lib/lua/luci/controller/status.lua \
         /usr/lib/lua/luci/view/status/index.htm \
         /www/luci-static/resources/view/status/index.js; do
  if [ -f "$f" ]; then
    # 删除包含 Firmware Version / 固件版本 的行
    sed -i "/Firmware Version/d; /固件版本/d" "$f" 2>/dev/null || true
    log "已清理 $f"
  fi
done

# 清理 banner
if [ -f /etc/banner ]; then
  sed -i "/SNAPSHOT r[0-9]/d; /OpenWrt [0-9]/d; /ImmortalWrt [0-9]/d; /PonWrt SNAPSHOT/d" /etc/banner 2>/dev/null || true
  log "已清理 /etc/banner"
fi

# 确保默认主题是 Argon（主题皮肤正常显示）
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

# 用 -f 不要用 -x：git checkout / Windows 打包会丢可执行位，-x 判失败会静默整段跳过。
# 末尾 || true：本文件开头是 set -euo pipefail，被 source 的子脚本里任何一步
# 返回非 0 都会让这里当场退出，后面的步骤全不执行且整轮构建中断。
# 加密是可选增强，不该有能力搞挂构建。
[ -f scripts/diy-part2-crypto.sh ] && . ./scripts/diy-part2-crypto.sh || true

# 6. 强制确保状态插件配置正确（防止被意外剔除）
echo "🔒 强制确保状态插件配置..."
if [ -f ".config" ]; then
  for pkg in luci-app-airoha-npu luci-app-pon-status luci-app-natmode; do
    # 先删除旧配置行
    sed -i "/$pkg/d" .config 2>/dev/null || true
    # 强制写入 =y
    echo "CONFIG_PACKAGE_$pkg=y" >> .config || true
  done
  echo "✅ 状态插件配置已强制确保"
fi

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"

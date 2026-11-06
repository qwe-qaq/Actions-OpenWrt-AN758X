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
# 可配置：5G 无线参数
# 如需改动，直接改这里即可（编译期常量，会写进 uci-defaults 脚本）
# =============================================================
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"       # 国家代码（CN = 中国）
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"     # 信道（auto = 自动选择）
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"      # 160MHz（WiFi6）；回落 HE80
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"   # 硬件不支持 160MHz 时的回落值

# 可由 workflow 的 fw_author 输入项覆盖（经 env 注入）；本地单独跑时默认 qwe
FW_AUTHOR="${FW_AUTHOR:-qwe}"
FW_BUILD_TIME="${FW_BUILD_TIME:-}"
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-}"

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
  echo "::warning::未找到 $CFG，跳过默认值修改"
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
  echo "::warning::未找到无线 detect 脚本，跳过编译期默认值修改（由 uci-defaults 兜底）"
fi

# ---- 4b. 运行期：uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/96-wifi-5g-cn <<UCEOF
#!/bin/sh
# 5G WiFi 默认值：国家码 CN、信道 auto、频宽 160MHz
# 由 diy-part2.sh 生成（编译期常量注入）

COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'

log() { logger -t wifi-5g "\$@"; }

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

	# 只处理 5G：新版用 band='5g'，旧版用 hwmode='11a'
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1
	[ "\$is5g" = "0" ] && continue

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

	log "\$dev：country=\$COUNTRY channel=\$CHANNEL htmode=\$ht"
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
echo "✅ uci-defaults 5G WiFi 脚本已写入（country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE）"

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
  echo "::warning::未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"

FW_MAIN="PonWrt SNAPSHOT mutoli / LuCI Master 26.302.04020"
RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

# 两处版本信息固定为主串，不追加编译时间
FW_DESC_LINE="DISTRIB_DESCRIPTION='${FW_MAIN}'"
OSREL_LINE="OPENWRT_RELEASE=\"${FW_MAIN}\""
export FW_DESC_LINE OSREL_LINE

# 国内常用 apk 软件包源：默认 TUNA，首启自动测速选择可用镜像
mkdir -p files/etc/apk
cat > files/etc/apk/repositories <<'EOF'
https://mirrors.tuna.tsinghua.edu.cn/immortalwrt/snapshots/targets/airoha/an7581/packages
https://mirrors.tuna.tsinghua.edu.cn/immortalwrt/snapshots/packages/aarch64_cortex-a53
EOF
echo "✅ apk 软件包源默认 -> TUNA snapshots"

# USB 打印菜单显示名改为“USB 打印”，避免菜单里出现 p910nd 字样
find package/feeds -path '*p910nd*' -type f \( -name '*.lua' -o -name '*.po' \) 2>/dev/null \
  | while read -r f; do
      sed -i 's/p910nd Printer Server/USB打印/g; s/p910nd/USB打印/g; s/Network printer/USB打印/g' "$f" || true
    done

# 后台菜单不显示“NAS”字样；USB 存储功能仍保留
grep -rl "NAS" package/feeds --include='*.lua' 2>/dev/null \
  | while read -r f; do
      sed -i "s/_('NAS')/_(' ')/g; s/'NAS'/' '/g" "$f" || true
    done || true

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-apk-mirror-autodetect <<'EOF'
#!/bin/sh
# 首启自动选择可用的国内 ImmortalWrt apk 镜像
REPOS=/etc/apk/repositories
TARGET_PATH=snapshots/targets/airoha/an7581/packages
PKG_PATH=snapshots/packages/aarch64_cortex-a53
MIRRORS="
https://mirrors.tuna.tsinghua.edu.cn/immortalwrt
https://mirrors.ustc.edu.cn/immortalwrt
https://mirrors.aliyun.com/immortalwrt
"
for base in $MIRRORS; do
  if curl -fsS --connect-timeout 3 --max-time 8 "$base/$TARGET_PATH/Packages" >/dev/null 2>&1; then
    cat > "$REPOS" <<EOF2
$base/$TARGET_PATH
$base/$PKG_PATH
EOF2
    logger -t apk-mirror "使用软件源: $base"
    break
  fi
done
exit 0
EOF
chmod +x files/etc/uci-defaults/99-apk-mirror-autodetect
echo "✅ 首启自动检测国内镜像脚本已写入（TUNA / USTC / Aliyun）"

if [ -f "$RELEASE_TPL" ]; then
  # 只替换 DISTRIB_DESCRIPTION 行，不动 DISTRIB_ID / DISTRIB_RELEASE 等其它行
  perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$RELEASE_TPL"
  echo "✅ 固件版本模板 -> $FW_DESC_LINE"
else
  echo "::warning::未找到 $RELEASE_TPL，固件版本不会带构建信息"
fi

# os-release 同步（部分工具/LuCI 版本读它；%B 只是 SOURCE_DATE_EPOCH 时间戳，不好看）
if [ -f "$OSREL_TPL" ]; then
  perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$OSREL_TPL"
  echo "✅ os-release 同步 -> $OSREL_LINE"
fi

# LuCI 概览页只保留固定主版本：PonWrt SNAPSHOT mutoli / LuCI Master <目标版本号>
# 实际追加位置在 status/include/10_system.js：description + ' / ' + luciversion
# 直接改成只显示 boardinfo.release.description，去掉后面的 " / LuCI Master <commit>"
LUCI_SYS_JS="package/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
if [ -f "$LUCI_SYS_JS" ]; then
  perl -0pi -e "s/\s*\+\s*\(luciversion\s*\|\|\s*''\)//g" "$LUCI_SYS_JS" || true
fi

find package/feeds/luci -path "*status/include/10_system.js" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e "s/\s*\+\s*\(luciversion\s*\|\|\s*''\)//g" "$f" || true
done || true

find package/feeds/luci -path "*luci-app-argon-config*" -type f 2>/dev/null | while read -r f; do
  rm -f "$f" || true
done || true


# 用 -f 不要用 -x：git checkout / Windows 打包会丢可执行位，-x 判失败会静默整段跳过。
# 末尾 || true：本文件开头是 set -euo pipefail，被 source 的子脚本里任何一步
# 返回非 0 都会让这里当场退出，后面的步骤全不执行且整轮构建中断。
# 加密是可选增强，不该有能力搞挂构建。
[ -f scripts/diy-part2-crypto.sh ] && . ./scripts/diy-part2-crypto.sh || true

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"

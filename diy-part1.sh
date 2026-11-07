#!/bin/bash
# ================================================================
# diy-part1.sh —— 只做一件事：拉取可选插件到 package/custom
# 运行目录: ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
#
# 用法：把需要的插件开关改成 true，再到 configs/<机型>.config 里
#       把对应 "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
# ================================================================
echo "=========================================="
echo "拉取可选插件 (diy-part1.sh)"
echo "=========================================="
PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

# SSR Plus+：加入 helloworld feed，并安装其索引到 LuCI
grep -q '^src-git helloworld' feeds.conf.default || \
  echo 'src-git helloworld https://github.com/fw876/helloworld.git' >> feeds.conf.default
./scripts/feeds update helloworld
./scripts/feeds install -a -p helloworld

# ---------------------------------------------------------
# 插件开关
# 默认开启：Airoha SoC 状态页（config 里已 =y，必须拉否则 defconfig 会剔除）
#
# 温度不再用 luci-app-temp-status —— 由 autocore 的 /sbin/tempinfo 提供，
# 见 files/sbin/tempinfo（概览页「温度」行：CPU / WiFi / PON 温度 + 光功率）
# ---------------------------------------------------------
# ⚠ 下面这些包都在 configs/an7581.config 与 an7583.config 里 =y 了，
#   关掉开关会让 defconfig 把 =y 静默剔除 —— 两处必须一起改。
#
# ⚠ 标了「只用 feeds」的四个，是它们的本体（mosdns / smartdns / xray-core /
#   sing-box）feeds 里已经有同名包，第三方源再拉一份会让索引里出现两个同名
#   Package，package-metadata 按扫描顺序挑一个，行为不可预期。所以只拷 luci
#   前端，本体一律用 feeds 的。
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）
ADD_FLUENT=false       # luci-theme-fluent：纯净版不编
ADD_FLUENT_LITE=false
ADD_FLUENT_DASH=false
ADD_PASSWALL=false     # PassWall：纯净版不编
ADD_OPENCLASH=false    # OpenClash：纯净版不编
ADD_MOSDNS=false       # MosDNS：纯净版不编
ADD_LUCKY=false        # Lucky：纯净版不编
ADD_TAILSCALE=false    # Tailscale：纯净版不编
ADD_OPENLIST=false     # Openlist：纯净版不编
ADD_SMARTDNS=false     # SmartDNS：纯净版不编
ADD_EASYTIER=false     # EasyTier：纯净版不编
ADD_POWEROFF=false     # 关机按钮：纯净版不编
ADD_OWQ_WOL=false      # WOL：纯净版不编
ADD_WATCHDOG=false     # 看门狗：纯净版不编
ADD_TASKPLAN=false     # 定时任务：纯净版不编
ADD_OAF=false          # OAF：纯净版不编
ADD_LUCI_APP=true       # qwe-qaq/luci-app 仓库（monorepo）
                        #   ├─ luci-app-natmode     NAT 类型三选一（网络 → NAT 类型）
                        #   └─ luci-app-pon-status  PON 光模块卡片（概览页「系统」下一格）
# 下面这几个开关都能被环境变量覆盖（: ${VAR:=默认} 的写法）：
# workflow 里选了「不拉私有仓库」时会注入 ADD_FTTR=false，整段直接跳过。
: "${ADD_FTTR:=true}"       # FTTR 全家桶总开关（下面的子开关都受它管）★仅 HM2004-DU
: "${ADD_FMCS:=true}"       # h3c-fmcs：Micro-OLT FPGA 内核驱动（kmod-h3c-fmcs）
: "${ADD_FTTR_TOOLS:=true}" # h3c-fttr-tools：fttrd 控制器 + fttrctl（Rust 包）
: "${ADD_FMCS_FW:=true}"    # h3c-fmcs-firmware：FPGA 比特流 FTTR_TOP.sbit
                            # （以上三个都来自 openwrt-fttr 私有仓库，bitstream 由驱动加载）

# 这四个包只对 HM2004-DU 有意义：驱动按 @(TARGET_airoha_an7581) 限定了
# target，界面和后端都围着重型 FTTR 主从设备转。workflow 会把 PROFILE
# 导出成环境变量，非 2004 机型直接跳过，不白花 clone 时间；本地手工跑
# （PROFILE 为空）按 2004 处理。
# ⚠ 不能默认成 h3c_hm2004-du：warm-cache.yml 也会调这个脚本，而它不设
#   PROFILE（缓存与机型无关），更没有私有仓库凭证那三步 —— 默认成 h3c 会让
#   它去 clone 私有仓库 openwrt-fttr，然后因 "could not read Username" 失败。
#   本地手工跑 h3c 机型时，显式 PROFILE=h3c_hm2004-du 即可。
FTTR_PROFILE="${PROFILE:-none}"

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  if [ -d "$dir" ]; then
    echo "✅ 克隆成功: $dir"
    return 0
  fi
  echo "::error::克隆失败: $url"
  return 1
}
# =========================================================
# qwe3017/luci-app —— 两个 LuCI 插件的来源
#
# 这是一个 monorepo，结构为：
#   luci-app/
#   ├── luci-app-natmode/
#   └── luci-app-pon-status/
# =========================================================
if [ "$ADD_LUCI_APP" = "true" ]; then
  LUCI_APP_URL="https://github.com/qwe-qaq/luci-app"
  LUCI_APP_TMP="$(mktemp -d)/luci-app"
  if ! clone "$LUCI_APP_URL" "$LUCI_APP_TMP" main; then
    echo "::error::qwe3017/luci-app 拉取失败，natmode / pon-status 会被 defconfig 剔除"
    exit 1
  fi
  for p in luci-app-natmode luci-app-pon-status; do
    if [ ! -f "$LUCI_APP_TMP/$p/Makefile" ]; then
      echo "::error::$LUCI_APP_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$LUCI_APP_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p  (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/$p/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  done
  rm -rf "$LUCI_APP_TMP"
fi

# =========================================================
# h3c-fmcs / h3c-fttr-tools / h3c-fmcs-firmware —— FTTR 后端三件套 ★HM2004-DU 专属
# 源：qwe-qaq/openwrt-fttr（私有仓库）
# ⚠ 这里必须用「裸 URL」：凭证由 workflow 的 GIT_ASKPASS 在认证时回调注入，
#   千万别拼 token —— clone 的 echo 会把它打进日志。
# ⚠ 该仓库是 feed 形态（根目录直接是三个包目录），按目录名拷进 package/custom/
#   即可；目录名必须等于包名（PKG_NAME ?= $(notdir $(CURDIR)）），否则 config
#   里的 CONFIG_PACKAGE_xxx 对不上。
#   h3c-fmcs           KernelPackage → 索引里叫 kmod-h3c-fmcs，DEPENDS 限定
#                      @(TARGET_airoha_an7581)，另依赖 +kmod-spi-gpio
#   h3c-fttr-tools     Rust 包，硬 include feeds/packages/lang/rust/rust-package.mk
#   h3c-fmcs-firmware  纯数据包，FPGA 比特流 → /lib/firmware/FTTR_TOP.sbit
# ⚠ h3c-fmcs 是 KernelPackage，索引里的名字是 kmod-h3c-fmcs。下面的包索引
#   校验内置了这层映射（pkgname_of），看到的是 ✅ h3c-fmcs → kmod-h3c-fmcs。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  # 仓库与分支由 workflow 注入，本地手工跑时回退到下面的默认值
  FTTR_FEED_URL="https://github.com/${PRIVATE_REPO:-qwe-qaq/openwrt-fttr}"
  FTTR_FEED_BRANCH="${PRIVATE_REPO_BRANCH:-main}"
  FTTR_FEED_TMP="$(mktemp -d)/openwrt-fttr"
  if ! clone "$FTTR_FEED_URL" "$FTTR_FEED_TMP" "$FTTR_FEED_BRANCH"; then
    echo "::error::openwrt-fttr 拉取失败：${FTTR_FEED_URL} (分支 ${FTTR_FEED_BRANCH})，kmod-h3c-fmcs / h3c-fttr-tools / h3c-fmcs-firmware 会被 defconfig 剔除"
    echo "        公开仓库失败=仓库/分支名不对；私有仓库缺凭证=优先查 GitHub App（PRIVATE_SOURCE_APP_ID / PRIVATE_SOURCE_APP_PRIVATE_KEY，App 要装到该仓库且 Contents: Read-only），回退才看 Secret PRIVATE_REPO_TOKEN 是否有效（PAT 需对该仓库有 Contents 读权限）"
    exit 1
  fi

  # h3c-fttr-tools 硬 include 了 feeds/packages/lang/rust/rust-package.mk，
  # 这个文件不在的话 dump 直接失败、包静默不进索引。
  # 与其等到 defconfig 把它剔掉才发现，不如在这里就报错退出。
  if [ "$ADD_FTTR_TOOLS" = "true" ] && [ ! -f feeds/packages/lang/rust/rust-package.mk ]; then
    echo "::error::未找到 feeds/packages/lang/rust/rust-package.mk，h3c-fttr-tools 无法索引"
    echo "        确认 packages feed 已 update + install；或把 ADD_FTTR_TOOLS 置为 false"
    exit 1
  fi

  FTTR_FEED_PKGS=""
  [ "$ADD_FMCS" = "true" ]       && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fmcs"
  [ "$ADD_FTTR_TOOLS" = "true" ] && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fttr-tools"
  [ "$ADD_FMCS_FW" = "true" ]    && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fmcs-firmware"

  for p in $FTTR_FEED_PKGS; do
    if [ ! -f "$FTTR_FEED_TMP/$p/Makefile" ]; then
      echo "::error::$FTTR_FEED_TMP/$p/Makefile 不存在（上游改结构了？）"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -a "$FTTR_FEED_TMP/$p" "$PKG_DIR/$p"
    echo "✅ 已拷贝: $p  (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/$p/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  done
  rm -rf "$FTTR_FEED_TMP"
fi

# =========================================================
# luci-app-fttr —— FTTR 管理界面（网络 → FTTR）★HM2004-DU 专属
# 源：LazuliKao/luci-app-fttr（monorepo，包在 package/luci-app-fttr/ 子目录）
# ⚠ 不能整仓丢进 package/custom：buildroot 只扫到 -maxdepth 5，整仓会把
#   src/、package/ 一起扫，包符号还对不上。必须拷子目录。
# 依赖 +luci-base +rpcd +ucode +ucode-mod-fs +h3c-fttr-tools，后者不在
# ImmortalWrt feeds —— 见下方硬校验。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  FTTR_TMP="$(mktemp -d)/fttr"
  if ! clone https://github.com/LazuliKao/luci-app-fttr "$FTTR_TMP" main; then
    echo "::error::luci-app-fttr 拉取失败，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
  if [ ! -f "$FTTR_TMP/package/luci-app-fttr/Makefile" ]; then
    echo "::error::$FTTR_TMP/package/luci-app-fttr/Makefile 不存在（上游改结构了？）"
    exit 1
  fi

  rm -rf "$PKG_DIR/luci-app-fttr"
  cp -a "$FTTR_TMP/package/luci-app-fttr" "$PKG_DIR/luci-app-fttr"

  # Windows 检出会丢 executable bit，rpcd 插件与 hl202 脚本执行不了 → 页面全空。
  # Makefile 里虽然有 Build/Prepare 的 chmod，这里先在源码树补一道更保险。
  chmod 0755 "$PKG_DIR/luci-app-fttr/root/usr/libexec/fttr-hl202" \
             "$PKG_DIR/luci-app-fttr/root/usr/libexec/rpcd/luci.fttr" 2>/dev/null || true

  # po/zh_Hans 已经是 fttr.po（LUCI_BASENAME 命名），不用像 airoha-npu 那样改名
  echo "✅ 已拷贝: luci-app-fttr (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-fttr/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  rm -rf "$FTTR_TMP"
fi


# --- Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）---
# 包名由目录名决定（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），
# 目录必须是 luci-app-airoha-npu，否则 config 里的符号对不上。
#
# 源用 luanmuc/luci-app-airoha-npu（rchen14b 的 fork 改进版）：
#   - 自带 po/zh_Hans 完整中文翻译（48 条）
#   - 无 rchen14b 那种「根目录 + 同名子目录」重复结构，feed 索引不会中断
#   - 修了 luci.mk 的 include 路径、加了独立 CPU 温度与 PLL 备用频率
if [ "$ADD_AIROHA_NPU" = "true" ]; then
  if ! clone https://github.com/luanmuc/luci-app-airoha-npu "$PKG_DIR/luci-app-airoha-npu" main; then
    echo "::error::luci-app-airoha-npu 拉取失败，后续 defconfig 会静默剔除该包"
    exit 1
  fi
  # 包名校验：Makefile 必须存在，否则 buildroot 扫不到这个包
  if [ ! -f "$PKG_DIR/luci-app-airoha-npu/Makefile" ]; then
    echo "::error::$PKG_DIR/luci-app-airoha-npu/Makefile 不存在，包无法被索引"
    exit 1
  fi
  echo "   版本: $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-airoha-npu/Makefile" 2>/dev/null)"
  # =========================================================
  # 关键：po 文件名必须改成 airoha-npu.po
  #   luci.mk 的 i18n 规则按 po 主名生成 lmo，运行时却按 LUCI_BASENAME
  #   （= airoha-npu）查找。上游两份 po 都叫 luci-app-airoha-npu.po，会生成
  #   luci-app-airoha-npu.zh-cn.lmo → 前端找不到 → 中文不生效。
  # =========================================================
  PODIR="$PKG_DIR/luci-app-airoha-npu/po"
  if [ -f "$PODIR/zh_Hans/luci-app-airoha-npu.po" ]; then
    # 确保 Language 头是 zh_Hans（上游头部缺该字段时 po2lmo 可能识别异常）
    grep -q '^"Language:' "$PODIR/zh_Hans/luci-app-airoha-npu.po" || \
      sed -i 's/^msgstr ""$/msgstr ""\n"Language: zh_Hans\\n"/' "$PODIR/zh_Hans/luci-app-airoha-npu.po"
    mv "$PODIR/zh_Hans/luci-app-airoha-npu.po" "$PODIR/zh_Hans/airoha-npu.po"
    echo "✅ po 改名: luci-app-airoha-npu.po -> airoha-npu.po（luci.mk 按 LUCI_BASENAME 查找）"
  fi
  if [ -f "$PODIR/es/luci-app-airoha-npu.po" ]; then
    mv "$PODIR/es/luci-app-airoha-npu.po" "$PODIR/es/airoha-npu.po"
  fi
  echo "   po/zh_Hans: $(ls -1 "$PODIR/zh_Hans/" 2>/dev/null | tr '\n' ' ')"
fi

# --- passwall ---
# 源已从 xiaorouji 迁到 Openwrt-Passwall 组织（旧地址 404）。
# ⚠ 只拷 luci-app-passwall 子目录：openwrt-passwall-packages 是 monorepo，
#   里面 xray-core / sing-box / hysteria / naiveproxy / shadowsocks-rust …
#   全部与 feeds 同名，整仓拷进来就是两份同名包。依赖一律用 feeds 的。
if [ "$ADD_PASSWALL" = "true" ]; then
  PW_TMP="$(mktemp -d)/pw"
  if clone https://github.com/Openwrt-Passwall/openwrt-passwall "$PW_TMP" main \
     && [ -f "$PW_TMP/luci-app-passwall/Makefile" ]; then
    rm -rf "$PKG_DIR/luci-app-passwall"
    cp -r "$PW_TMP/luci-app-passwall" "$PKG_DIR/"
    echo "✅ 已拷贝: luci-app-passwall"
  else
    echo "::error::luci-app-passwall 拉取失败或结构变化"
  fi
  rm -rf "$PW_TMP"
fi
# --- openclash ---
if [ "$ADD_OPENCLASH" = "true" ]; then
  echo "::warning::OpenClash 会触发 Ruby/Rust 编译，耗时极长"
  clone https://github.com/vernesong/OpenClash "$PKG_DIR/OpenClash" master
  mv "$PKG_DIR/OpenClash/luci-app-openclash" "$PKG_DIR/luci-app-openclash" 2>/dev/null
  rm -rf "$PKG_DIR/OpenClash"
fi
# --- mosdns ---
# ⚠ 只拷 luci-app-mosdns 子目录：仓库里还带 mosdns 本体与 v2ray-geodata，
#   两个都与 feeds 同名。本体用 feeds 的。
if [ "$ADD_MOSDNS" = "true" ]; then
  MD_TMP="$(mktemp -d)/mosdns"
  if clone https://github.com/sbwml/luci-app-mosdns "$MD_TMP" v5 \
     && [ -f "$MD_TMP/luci-app-mosdns/Makefile" ]; then
    rm -rf "$PKG_DIR/luci-app-mosdns" "$PKG_DIR/geo2txt"
    cp -r "$MD_TMP/luci-app-mosdns" "$PKG_DIR/"
    # geo2txt 是 luci-app-mosdns 的硬依赖（LUCI_DEPENDS 里 +geo2txt），
    # feeds 里没有同名包，必须一起拷进来，否则索引时报
    # "has a dependency on 'geo2txt', which does not exist"
    if [ -f "$MD_TMP/geo2txt/Makefile" ]; then
      cp -r "$MD_TMP/geo2txt" "$PKG_DIR/"
      echo "✅ 已拷贝: geo2txt（luci-app-mosdns 依赖）"
    else
      echo "::warning::mosdns 仓库里没有 geo2txt，luci-app-mosdns 会缺这个依赖"
    fi
    echo "✅ 已拷贝: luci-app-mosdns（本体用 feeds）"
  else
    echo "::error::luci-app-mosdns 拉取失败或结构变化"
  fi
  rm -rf "$MD_TMP"
fi
# --- lucky ---
if [ "$ADD_LUCKY" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-lucky "$PKG_DIR/luci-app-lucky" main
fi
# --- tailscale ---
if [ "$ADD_TAILSCALE" = "true" ]; then
  clone https://github.com/asvow/luci-app-tailscale "$PKG_DIR/luci-app-tailscale" main
fi
# --- openlist2 ---
if [ "$ADD_OPENLIST" = "true" ]; then
  clone https://github.com/sbwml/luci-app-openlist2 "$PKG_DIR/luci-app-openlist2" main
fi

# --- smartdns ---
# ⚠ 不拉 pymumu/smartdns 本体：与 feeds/packages/net/smartdns 同名。
if [ "$ADD_SMARTDNS" = "true" ]; then
  clone https://github.com/pymumu/luci-app-smartdns "$PKG_DIR/luci-app-smartdns" master
fi
# --- luci-theme-fluent ---
# ⚠ 包在仓库的 package/ 子目录下，不能直接 clone 到 package/custom，
#   必须把子目录拷出来，否则 buildroot 扫不到 Makefile
if [ "$ADD_FLUENT" = "true" ] || [ "$ADD_FLUENT_LITE" = "true" ] || [ "$ADD_FLUENT_DASH" = "true" ]; then
  FLUENT_TMP="$(mktemp -d)/fluent"
  clone https://github.com/LazuliKao/luci-theme-fluent "$FLUENT_TMP" main

  for p in luci-theme-fluent luci-theme-fluent-lite luci-mod-fluentdashboard; do
    case "$p" in
      luci-theme-fluent)        [ "$ADD_FLUENT" = "true" ] || continue ;;
      luci-theme-fluent-lite)   [ "$ADD_FLUENT_LITE" = "true" ] || continue ;;
      luci-mod-fluentdashboard) [ "$ADD_FLUENT_DASH" = "true" ] || continue ;;
    esac
    [ -d "$FLUENT_TMP/package/$p" ] || { echo "::error::$p 不存在"; continue; }
    rm -rf "$PKG_DIR/$p"
    cp -a "$FLUENT_TMP/package/$p" "$PKG_DIR/$p"
    echo "✅ 已拷贝: $p"
  done
  rm -rf "$FLUENT_TMP"
fi

if [ "$ADD_EASYTIER" = "true" ]; then
  clone https://github.com/EasyTier/luci-app-easytier "$PKG_DIR/luci-app-easytier" main
fi
if [ "$ADD_POWEROFF" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-poweroffdevice "$PKG_DIR/luci-app-poweroffdevice" master
fi
if [ "$ADD_OWQ_WOL" = "true" ]; then
  clone https://github.com/isalikai/luci-app-owq-wol "$PKG_DIR/luci-app-owq-wol" main
fi
if [ "$ADD_TASKPLAN" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-taskplan "$PKG_DIR/luci-app-taskplan" main
fi
# --- watchdog ---
# ⚠ 仓库是 monorepo：根目录无 Makefile，luci-app-watchdog/（前端）与
#   watchdog/（本体）是两个包，前者依赖 +watchdog，两个都要拷。
#   只拷前端时索引会报 "has a dependency on 'watchdog', which does not exist"。
if [ "$ADD_WATCHDOG" = "true" ]; then
  WD_TMP="$(mktemp -d)/wd"
  if clone https://github.com/sirpdboy/luci-app-watchdog "$WD_TMP" main; then
    for p in luci-app-watchdog watchdog; do
      [ -f "$WD_TMP/$p/Makefile" ] || { echo "::warning::$p 不存在（上游改结构了？）"; continue; }
      rm -rf "$PKG_DIR/$p"
      cp -r "$WD_TMP/$p" "$PKG_DIR/"
      echo "✅ 已拷贝: $p"
    done
  else
    echo "::error::luci-app-watchdog 拉取失败"
  fi
  rm -rf "$WD_TMP"
fi
if [ "$ADD_OAF" = "true" ]; then
  clone https://github.com/destan19/OpenAppFilter "$PKG_DIR/OpenAppFilter" master
  for p in luci-app-oaf open-app-filter oaf; do
    cp -r "$PKG_DIR/OpenAppFilter/$p" "$PKG_DIR/" 2>/dev/null
  done
  rm -rf "$PKG_DIR/OpenAppFilter"
fi
# ---------------------------------------------------------
# 校验：默认开启的两个插件必须拉到，否则 defconfig 会静默剔除，
#       编出来的固件缺少状态页还不易察觉
# ---------------------------------------------------------
if [ "$ADD_AIROHA_NPU" = "true" ] && [ ! -d "$PKG_DIR/luci-app-airoha-npu" ]; then
  echo "::error::luci-app-airoha-npu 未拉到，config 里的 =y 会被 defconfig 剔除"
  exit 1
fi
# natmode / pon-status 来自 qwe3017/luci-app（config 里也是 =y）
for p in luci-app-natmode luci-app-pon-status; do
  if [ "$ADD_LUCI_APP" = "true" ] && [ ! -d "$PKG_DIR/$p" ]; then
    echo "::error::$p 未拉到，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
done
# ---------------------------------------------------------
# 补回 libffi —— python3(3.14) 的 _ctypes 硬性需要
#   CPython 自 3.11 起删掉了 --with-system-ffi，_ctypes 永远 #include <ffi.h>；
#   而 ponwrt 与 immortalwrt/packages 的 libffi 目录都已不存在，整棵树里没有
#   ffi.h / libffi.pc，于是编到 _ctypes.c 才炸：
#     ./Modules/_ctypes/_ctypes.c:119:10: fatal error: ffi.h: No such file...
#   处理：从 immortalwrt 基座取现成的包定义（自带 Build/InstallDev，会把
#   ffi.h / libffi.pc 装进 staging_dir），再给 python3 补一条构建依赖。
# ⚠ 必须放在 prepare-tmpinfo 之前：目录要被扫进索引，PKG_BUILD_DEPENDS 也要生效。
# ---------------------------------------------------------
FFI_DIR="package/custom/libffi"
if [ ! -d "$FFI_DIR" ]; then
  echo "--- 补回 libffi（python3 _ctypes 依赖，源码树中缺失）---"
  mkdir -p "$FFI_DIR"
  if curl -fsSL --retry 3 --max-time 60 \
       https://raw.githubusercontent.com/immortalwrt/immortalwrt/master/package/libs/libffi/Makefile \
       -o "$FFI_DIR/Makefile"; then
    echo "✅ 已补回 libffi ($(grep -m1 '^PKG_VERSION' "$FFI_DIR/Makefile" 2>/dev/null))"
  else
    echo "::error::libffi 包定义下载失败 —— python3 的 _ctypes 会因缺 ffi.h 编译失败"
    rm -rf "$FFI_DIR"
  fi
else
  echo "已存在，跳过: $FFI_DIR"
fi

# python3 只声明了 libffi/host，target 侧没声明，补一条确保 libffi 先编译
PY3MK="feeds/packages/lang/python/python3/Makefile"
if [ -f "$PY3MK" ] && ! grep -q 'PKG_BUILD_DEPENDS:=bluez libffi' "$PY3MK"; then
  sed -i 's|^PKG_BUILD_DEPENDS:=bluez|PKG_BUILD_DEPENDS:=bluez libffi|' "$PY3MK"
  echo "✅ python3 已补 libffi 构建依赖（PKG_BUILD_DEPENDS，保证先编 libffi）"
fi

# ---------------------------------------------------------
# 清理重复嵌套目录
# rchen14b/luci-app-airoha-npu 这个仓库有问题：包在根目录放了一份，
# 又在同名子目录 luci-app-airoha-npu/ 里放了完整一份（含 Makefile）。
# feeds 扫描会把两层都当成独立包，内层 dump 失败（报
# "feeds/custom/luci-app-airoha-npu/luci-app-airoha-npu"）会中断整个
# custom feed 的索引，导致 package/feeds/custom 压根不生成，
# 所有包符号都不存在。
# ---------------------------------------------------------
echo "--- 检查重复嵌套目录 ---"
# ⚠ 判据必须包含「根目录也有 Makefile」，否则会误删 monorepo 的真包：
#   lucky / openlist2 / easytier / taskplan / poweroffdevice 的仓库根目录【没有】
#   Makefile，同名子目录才是唯一的那份包 —— 只看「有同名子目录」就会把它们
#   当重复项删掉，包从索引里消失、config 的 =y 被 defconfig 静默剔除。
#   只有 rchen14b/luci-app-airoha-npu 那种「根目录一份 + 同名子目录又一份」
#   才是要清理的坏结构（内层 dump 失败会中断整个 custom feed 的索引）。
for d in "$PKG_DIR"/*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -f "$d/Makefile" ] && [ -d "$d/$n" ] && [ -f "$d/$n/Makefile" ]; then
    rm -rf "$d/$n"
    echo "✅ 已移除重复嵌套目录: $n/$n"
  fi
done
# ---------------------------------------------------------
# 让新包进入索引
#   ⚠ 判据是 tmp/.packageinfo，不是 package/feeds/custom
#   prepare-tmpinfo 直接扫 package/ 树（scan.mk: find -L package -maxdepth 5），
#   package/custom/<pkg>/Makefile 深度 3，本来就会被扫到，**不需要注册 feed**。
#   旧的 src-link custom feed 有两个坑：① 同一批 Makefile 被扫两遍，按 Override
#   挑一个、行为随扫描顺序漂移；② install_src() 看到 $installed 非空直接 return，
#   压根不建 package/feeds/custom/<pkg> —— 所以它不存在是正常的，拿它当判据必然误报。
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  # =========================================================
  # 强制重建索引
  #   只删 tmp/.packageinfo 是不够的：prepare-tmpinfo 有 scan_unchanged
  #   优化（拿 tmp/info/.scan-*.stamp 比 mtime），stamp 还在且没有更新的
  #   Makefile 时它会跳过扫描 —— 结果 .packageinfo 被删了却没人重建，
  #   索引反而空了。所以 stamp 也要一起删。
  # =========================================================
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/.config-package.in tmp/.config-target.in
  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true
  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  echo "package/custom 内容："
  INDEX_MISS=""
  # 目录名 ≠ 包名的情况（Makefile 里显式写了 PKG_NAME / KernelPackage）：
  #   open-app-filter 的包是 appfilter、oaf 的 KernelPackage 是 kmod-oaf，
  #   按目录名去索引里查必然查不到 —— 那是误报，不是索引失败。
  pkgname_of() {
    case "$1" in
      open-app-filter) echo "appfilter" ;;
      oaf)             echo "kmod-oaf" ;;
      h3c-fmcs)        echo "kmod-h3c-fmcs" ;;
      *)               echo "$1" ;;
    esac
  }

  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")

    # 无根 Makefile = monorepo 容器（lucky / openlist2 / easytier / taskplan /
    # poweroffdevice / watchdog），真正的包在同名子目录里，逐个查
    if [ ! -f "$d/Makefile" ]; then
      found=0
      # 直接对 glob 迭代，不拼字符串再分词 —— 拼了就得依赖 IFS 分词，
      # 换个 shell（zsh 默认不拆）行为就变
      for sd in "$d"/*/Makefile; do
        [ -f "$sd" ] || continue
        found=1
        sn="$(basename "$(dirname "$sd")")"
        if grep -qx "Package: $sn" tmp/.packageinfo 2>/dev/null; then
          echo "  ✅ $n → $sn"
        else
          echo "  ❌ $n → $sn —— tmp/.packageinfo 里查不到"
          INDEX_MISS="$INDEX_MISS $sn"
          for f in "logs/package/$sn/dump.txt" "logs/package/custom/$sn/dump.txt"; do
            [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
          done
        fi
      done
      [ "$found" = 1 ] || echo "  -  $n（无 Makefile，跳过）"
      continue
    fi

    pn="$(pkgname_of "$n")"
    if grep -qx "Package: $pn" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n${pn:+$([ "$pn" != "$n" ] && echo " → $pn")}"
    else
      echo "  ❌ $n（包名 $pn）—— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $pn"
      # 真实错误在这里（scan.mk 落盘路径 logs/<SCAN_DIR>/<相对目录>/dump.txt）
      for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
        [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
      done
    fi
  done
  echo "------------------------------------------"
  echo "luci.mk: $([ -f feeds/luci/luci.mk ] && echo '✓' || echo '✗ 缺失（luci app 无法解析）')"
  echo "tmp/.packageinfo 包总数: $(grep -c '^Package: ' tmp/.packageinfo 2>/dev/null || echo 0)"
  echo "=========================================="
  # 必装插件（config 里是 =y 的那几个）必须进索引，否则 defconfig 会静默剔除
  REQUIRED=""
  [ "$ADD_AIROHA_NPU" = "true" ] && REQUIRED="$REQUIRED luci-app-airoha-npu"
  if [ "$ADD_LUCI_APP" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status"
  fi

  # 与 configs/an7581.config / an7583.config 里 =y 的包一一对应。
  # 任一项没进索引，defconfig 都会把那个 =y 静默剔除 —— 编出来的固件少了菜单
  # 还不易察觉。所以这里和 config 必须同步改。
  [ "$ADD_FLUENT"    = "true" ] && REQUIRED="$REQUIRED luci-theme-fluent"
  [ "$ADD_OPENCLASH" = "true" ] && REQUIRED="$REQUIRED luci-app-openclash"
  [ "$ADD_PASSWALL"  = "true" ] && REQUIRED="$REQUIRED luci-app-passwall"
  [ "$ADD_MOSDNS"    = "true" ] && REQUIRED="$REQUIRED luci-app-mosdns"
  [ "$ADD_LUCKY"     = "true" ] && REQUIRED="$REQUIRED luci-app-lucky"
  [ "$ADD_TAILSCALE" = "true" ] && REQUIRED="$REQUIRED luci-app-tailscale"
  [ "$ADD_OPENLIST"  = "true" ] && REQUIRED="$REQUIRED luci-app-openlist2"
  [ "$ADD_SMARTDNS"  = "true" ] && REQUIRED="$REQUIRED luci-app-smartdns"
  [ "$ADD_EASYTIER"  = "true" ] && REQUIRED="$REQUIRED luci-app-easytier"
  [ "$ADD_POWEROFF"  = "true" ] && REQUIRED="$REQUIRED luci-app-poweroffdevice"
  [ "$ADD_OWQ_WOL"   = "true" ] && REQUIRED="$REQUIRED luci-app-owq-wol"
  [ "$ADD_WATCHDOG"  = "true" ] && REQUIRED="$REQUIRED luci-app-watchdog"
  [ "$ADD_TASKPLAN"  = "true" ] && REQUIRED="$REQUIRED luci-app-taskplan"
  [ "$ADD_OAF"       = "true" ] && REQUIRED="$REQUIRED luci-app-oaf"
  true
  if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
    # KernelPackage 生成的包名带 kmod- 前缀，索引里写的是 kmod-h3c-fmcs
    if [ "$ADD_FMCS" = "true" ]; then
      REQUIRED="$REQUIRED kmod-h3c-fmcs"
    fi
    if [ "$ADD_FMCS_FW" = "true" ]; then
      REQUIRED="$REQUIRED h3c-fmcs-firmware"
    fi
    if [ "$ADD_FTTR_TOOLS" = "true" ]; then
      REQUIRED="$REQUIRED h3c-fttr-tools"
    fi
    REQUIRED="$REQUIRED luci-app-fttr"
    # =========================================================
    # luci-app-fttr 依赖 +h3c-fttr-tools，后者依赖 +kmod-h3c-fmcs。
    # 链条上任一节不在树里，defconfig 都会静默把整条 FTTR 剔掉 —— 与其编出
    # 一个没有 FTTR 界面的固件还不易察觉，不如在这里直接报错。
    # 前者最常见原因是缺 rust-package.mk；后者受 @(TARGET_airoha_an7581) 限制。
    # =========================================================
    if [ "$ADD_FTTR_TOOLS" = "true" ] &&
       ! grep -qx "Package: h3c-fttr-tools" tmp/.packageinfo 2>/dev/null; then
      echo "::error::h3c-fttr-tools 不在包索引里（luci-app-fttr 的后端，Rust 包）"
      echo "        多半是缺 rust feed：确认 feeds.conf 里有 packages，且"
      echo "        ./scripts/feeds install 装到了 lang/rust。"
      echo "        不需要 FTTR 就把 diy-part1.sh 的 ADD_FTTR 改成 false。"
      exit 1
    fi
    if [ "$ADD_FMCS" = "true" ] &&
       ! grep -qx "Package: kmod-h3c-fmcs" tmp/.packageinfo 2>/dev/null; then
      echo "::error::kmod-h3c-fmcs 不在包索引里（h3c-fttr-tools 依赖它）"
      echo "        DEPENDS 是 @(TARGET_airoha_an7581)：非该 target 时包不会进索引。"
      echo "        不需要 FTTR 就把 diy-part1.sh 的 ADD_FTTR 改成 false。"
      exit 1
    fi
  fi
  HARD_MISS=""
  for r in $REQUIRED; do
    grep -qx "Package: $r" tmp/.packageinfo 2>/dev/null || HARD_MISS="$HARD_MISS $r"
  done
  if [ -n "$HARD_MISS" ]; then
    echo "::error::以下必装插件未进入 tmp/.packageinfo，defconfig 会把 .config 里的 =y 静默剔除:$HARD_MISS"
    echo "  已索引缺失清单:$INDEX_MISS"
    exit 1
  fi
  [ -n "$INDEX_MISS" ] && echo "::warning::部分可选包未进入索引（不影响必装插件）:$INDEX_MISS"
else
  echo "未启用任何第三方插件"
fi

# 安装所有自定义包到 feeds 索引
./scripts/feeds install -a 2>/dev/null || true

echo "🎉 diy-part1.sh 执行完毕"

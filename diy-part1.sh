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
# ---------------------------------------------------------
# 插件开关
# 默认开启：Airoha SoC 状态页（config 里已 =y，必须拉否则 defconfig 会剔除）
#
# 温度不再用 luci-app-temp-status —— 由 autocore 的 /sbin/tempinfo 提供，
# 见 files/sbin/tempinfo（概览页「温度」行：CPU / WiFi / PON 温度 + 光功率）
# ---------------------------------------------------------
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）
ADD_FLUENT=true       # luci-theme-fluent：Fluent 2 风格主题
ADD_FLUENT_LITE=false  # luci-theme-fluent-lite：轻量版（与 fluent 互斥，二选一）
ADD_FLUENT_DASH=false  # luci-mod-fluentdashboard：可选状态概览卡片
ADD_PASSWALL=false     # luci-app-passwall（含依赖源）
ADD_OPENCLASH=false    # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
ADD_MOSDNS=false       # luci-app-mosdns + v2ray-geodata
ADD_LUCKY=false        # luci-app-lucky（DDNS + socat）
ADD_TAILSCALE=false    # luci-app-tailscale
ADD_OPENLIST=false     # luci-app-openlist2（alist/openlist 挂载）
ADD_SMARTDNS=false     # luci-app-smartdns
ADD_EASYTIER=false     # luci-app-easytier（另需 kmod-tun + easytier 本体，Rust 编译较慢）
ADD_POWEROFF=false     # luci-app-poweroffdevice（关机）
ADD_OWQ_WOL=false      # luci-app-owq-wol（网络唤醒，依赖 etherwake）
ADD_WATCHDOG=false     # luci-app-watchdog（看门狗，包在子目录，需特殊处理）
ADD_TASKPLAN=false     # luci-app-taskplan（定时任务）
ADD_OAF=false          # luci-app-oaf（应用过滤，含内核模块，高风险）
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
FTTR_PROFILE="${PROFILE:-h3c_hm2004-du}"

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
    echo "::error::qwe3017/luci-app 拉取失败，natmode / pon-status / igmpproxy 会被 defconfig 剔除"
    exit 1
  fi
  for p in luci-app-natmode luci-app-pon-status luci-app-igmpproxy; do
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
#
# 源：qwe-qaq/openwrt-fttr（私有仓库）
#   凭证由 workflow 用 GIT_ASKPASS 注入（见 build-ponwrt.yml 的
#   Create private source token / Prepare private Git authentication /
#   Setup private repo credentials 三步）：git 被要求认证时才回调
#   scripts/git_askpass.sh 取令牌，所以这里照旧用「裸 URL」——
#   千万别在这里拼 token，clone 的 echo 会把它打进日志。
#   ⚠ 这个仓库是 feed 形态：根目录直接就是三个包目录，没有 package/ 子目录，
#     也没有顶层 Makefile。所以按目录名直接拷进 package/custom/ 即可 ——
#     目录名必须等于包名（package.mk: PKG_NAME ?= $(notdir ${CURDIR})），
#     否则 config 里的 CONFIG_PACKAGE_xxx 符号对不上。
#
#   h3c-fmcs           KernelPackage，索引里的名字带 kmod- 前缀 → kmod-h3c-fmcs
#                      DEPENDS 含 @(TARGET_airoha_an7581)，非 an7581 不进索引
#                      另依赖 +kmod-spi-gpio
#   h3c-fttr-tools     Rust 包，硬 include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk
#                      DEPENDS: +kmod-h3c-fmcs +mosquitto-client +mosquitto-ssl
#                               +uci +ubus +firewall4 +dnsmasq
#   h3c-fmcs-firmware  纯数据包，FPGA 比特流 → /lib/firmware/FTTR_TOP.sbit
#                      （仓库内是实文件 2.0MB，不是 Git LFS 指针，可直接 clone 拿到）
#
# ⚠ 下面索引校验循环里 h3c-fmcs 这一行会显示 ❌：循环按「目录名」查，
#   而 KernelPackage 在 tmp/.packageinfo 里记的是 kmod-h3c-fmcs。
#   INDEX_MISS 只会产生 ::warning::，真正的硬校验在后面按 kmod-h3c-fmcs 查，
#   不受影响 —— 看到 ❌ 不用慌。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  # 仓库与分支由 workflow 注入，本地手工跑时回退到下面的默认值
  FTTR_FEED_URL="https://github.com/${PRIVATE_REPO:-qwe-qaq/openwrt-fttr}"
  FTTR_FEED_BRANCH="${PRIVATE_REPO_BRANCH:-main}"
  FTTR_FEED_TMP="$(mktemp -d)/openwrt-fttr"
  if ! clone "$FTTR_FEED_URL" "$FTTR_FEED_TMP" "$FTTR_FEED_BRANCH"; then
    echo "::error::openwrt-fttr 拉取失败：${FTTR_REPO} (分支 ${FTTR_BRANCH})，kmod-h3c-fmcs / h3c-fttr-tools / h3c-fmcs-firmware 会被 defconfig 剔除"
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
#
# 源：LazuliKao/luci-app-fttr（monorepo，包在 package/luci-app-fttr/ 子目录）
#   ⚠ 和 fluent / qwe3017/luci-app 一样是「包在子目录」结构，不能整仓丢进
#     package/custom —— buildroot 扫 package/ 只到 -maxdepth 5，整仓进去
#     会把 src/、package/ 一起扫，包符号还对不上。必须拷子目录。
#
# 依赖（Makefile 里的 LUCI_DEPENDS）：
#   +luci-base +rpcd +ucode +ucode-mod-fs +h3c-fttr-tools
#   前四个 feeds 里有；h3c-fttr-tools（fttrctl 后端 + ucode 运行时）不在
#   ImmortalWrt feeds，也不在 pon_drivers / pon_userspace —— 见下方硬校验。
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
  #
  # luci.mk 的 i18n install 规则：
  #   po2lmo $(po) → $(LUCI_LIBRARYDIR)/i18n/$(basename $(notdir $(po))).$(lang).lmo
  # 即 lmo 名取自 po 文件主名。而运行时按
  #   LUCI_BASENAME = $(patsubst luci-app-%,%,luci-app-airoha-npu) = airoha-npu
  # 查找 lmo。上游两份 po 都叫 luci-app-airoha-npu.po，
  # 会生成 luci-app-airoha-npu.zh-cn.lmo，前端找不到 → 中文不生效。
  # 官方 app 都是 basename 命名（firewall.po / package-manager.po / pon.po）。
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
if [ "$ADD_PASSWALL" = "true" ]; then
  clone https://github.com/xiaorouji/openwrt-passwall-packages "$PKG_DIR/openwrt-passwall-packages" main
  clone https://github.com/xiaorouji/openwrt-passwall "$PKG_DIR/openwrt-passwall" main
  rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2" 2>/dev/null
fi
# --- openclash ---
if [ "$ADD_OPENCLASH" = "true" ]; then
  echo "::warning::OpenClash 会触发 Ruby/Rust 编译，耗时极长"
  clone https://github.com/vernesong/OpenClash "$PKG_DIR/OpenClash" master
  mv "$PKG_DIR/OpenClash/luci-app-openclash" "$PKG_DIR/luci-app-openclash" 2>/dev/null
  rm -rf "$PKG_DIR/OpenClash"
fi
# --- mosdns ---
if [ "$ADD_MOSDNS" = "true" ]; then
  clone https://github.com/sbwml/luci-app-mosdns "$PKG_DIR/luci-app-mosdns" v5
  clone https://github.com/sbwml/v2ray-geodata "$PKG_DIR/v2ray-geodata" master
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

if [ "$ADD_SMARTDNS" = "true" ]; then
  clone https://github.com/pymumu/luci-app-smartdns "$PKG_DIR/luci-app-smartdns" master
  clone https://github.com/pymumu/smartdns "$PKG_DIR/smartdns" master
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
  clone https://github.com/sirpdboy/luci-app-poweroffdevice "$PKG_DIR/luci-app-poweroffdevice" main
fi
if [ "$ADD_OWQ_WOL" = "true" ]; then
  clone https://github.com/isalikai/luci-app-owq-wol "$PKG_DIR/luci-app-owq-wol" main
fi
if [ "$ADD_TASKPLAN" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-taskplan "$PKG_DIR/luci-app-taskplan" main
fi
if [ "$ADD_WATCHDOG" = "true" ]; then   # 包在子目录，必须拷出子目录，不能整仓丢进去
  WD_TMP="$(mktemp -d)/wd"
  clone https://github.com/sirpdboy/luci-app-watchdog "$WD_TMP" main
  rm -rf "$PKG_DIR/luci-app-watchdog"
  cp -r "$WD_TMP/luci-app-watchdog" "$PKG_DIR/luci-app-watchdog"
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
# 校验：默认开启的三个插件必须拉到，否则 defconfig 会静默剔除，
#       编出来的固件缺少状态页还不易察觉
# ---------------------------------------------------------
if [ "$ADD_AIROHA_NPU" = "true" ] && [ ! -d "$PKG_DIR/luci-app-airoha-npu" ]; then
  echo "::error::luci-app-airoha-npu 未拉到，config 里的 =y 会被 defconfig 剔除"
  exit 1
fi
# natmode / pon-status / igmpproxy 来自 qwe3017/luci-app（config 里也是 =y）
for p in luci-app-natmode luci-app-pon-status luci-app-igmpproxy; do
  if [ "$ADD_LUCI_APP" = "true" ] && [ ! -d "$PKG_DIR/$p" ]; then
    echo "::error::$p 未拉到，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
done
# ---------------------------------------------------------
# 补回 libffi —— python3(3.14) 的 _ctypes 硬性需要
#
# 背景（2026-10-20 实测）：
#   1) CPython 自 3.11 起删除了 --with-system-ffi 选项，官方措辞是
#      "libffi must now always be supplied by the system on all
#      non-Windows platforms"。也就是说不管传不传这个参数，
#      _ctypes 都会 #include <ffi.h>。
#   2) 但 ponwrt 源码树的 package/libs/libffi/Makefile 不存在
#      （pbs05/ponwrt 与 qwe3017/ponwrt 都是 404），
#      packages feed 里也早已迁走（immortalwrt/packages 的
#      libs/libffi 同样是 404）。结果整棵树没有 libffi：
#      编译日志里一行 libffi 都没有，staging_dir 下没有
#      ffi.h / libffi.pc。
#   3) python3 的 Makefile 还只给 HOST_BUILD_DEPENDS 写了 libffi/host，
#      target 侧 python3-light 的 DEPENDS 里没有 +libffi，
#      python3-ctypes 子包才有 —— 依赖指向不存在的包会被 defconfig
#      静默丢弃，python3 照样进编译列表，编到 _ctypes.c 才炸：
#        ./Modules/_ctypes/_ctypes.c:119:10: fatal error: ffi.h:
#        No such file or directory
#      → make[5] Error 1 → package/feeds/packages/python3 failed to build
#        → world Error 2
#
# 处理：从 immortalwrt 基座取现成的包定义（3.4.7，自带 Build/InstallDev，
#       会把 ffi.h / ffitarget.h / fficonfig.h / libffi.pc 装进
#       staging_dir/target-*/usr/{include,lib/pkgconfig}），
#       再给 python3 补一条 target 侧构建依赖保证编译顺序。
#
# ⚠ 必须放在 prepare-tmpinfo 之前：目录要被扫进索引，
#    PKG_BUILD_DEPENDS 也要在 tmpinfo 里生效。
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
for d in "$PKG_DIR"/*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -d "$d/$n" ] && [ -f "$d/$n/Makefile" ]; then
    rm -rf "$d/$n"
    echo "✅ 已移除重复嵌套目录: $n/$n"
  fi
done
# ---------------------------------------------------------
# 让新包进入索引
#
#   ⚠️ 判据是 tmp/.packageinfo，不是 package/feeds/custom
#
#   OpenWrt 的 prepare-tmpinfo 直接扫 package/ 目录树：
#     include/scan.mk:  find -L package -mindepth 1 -maxdepth 5 -name Makefile
#   package/custom/<pkg>/Makefile 深度只有 3，本来就会被扫到，
#   **根本不需要注册 feed**。
#
#   以前那套 src-link custom feed 有两个问题：
#     ① feeds/custom 指向 package/custom，而 feeds/base 已经指向 ../package，
#        同一批 Makefile 被扫两遍，package-metadata.pl 按 Override 挑一个，
#        行为随扫描顺序漂移；
#     ② scripts/feeds 的 install_src() 里，$installed{$name} 已经非空
#        （就是 ① 扫出来的那份），于是直接 return 0，压根不建
#        package/feeds/custom/<pkg> 符号链接 ——
#        所以「package/feeds/custom 不存在」是**正常现象**，不是索引失败。
#        拿它当判据必然误报。
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
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if [ ! -f "$d/Makefile" ]; then
      echo "  -  $n（无根 Makefile，视为源仓库/子包容器，跳过）"
      continue
    fi
    # 目录名即包名：buildroot 约定 PKG_NAME ?= $(notdir ${CURDIR})
    if grep -qx "Package: $n" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n"
    else
      echo "  ❌ $n —— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $n"
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
    REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status luci-app-igmpproxy"
  fi
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
    # luci-app-fttr 的 LUCI_DEPENDS 里有 +h3c-fttr-tools（fttrctl 后端），
    # 而 h3c-fttr-tools 又依赖 +kmod-h3c-fmcs。链条上任何一节不在树里，
    # defconfig 都会静默把整条 FTTR 剔掉 —— 与其编出一个「没有 FTTR 界面」
    # 的固件还不易察觉，不如在这里直接报错。
    #
    # h3c-fttr-tools 进不了索引的最常见原因是缺 Rust 支持：它 include 了
    # feeds/packages/lang/rust/rust-package.mk，没有 packages feed（或没装
    # rust）时这个包根本不会被扫到。kmod-h3c-fmcs 则受
    # @(TARGET_airoha_an7581) 限制，非该 target 时同样不进索引。
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
echo "🎉 diy-part1.sh 执行完毕"

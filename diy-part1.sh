#!/bin/bash
# ================================================================
# diy-part1.sh —— 拉取可选插件到 package/custom
# 运行目录: ponwrt 源码根目录（feeds 装完之后、加载 .config 之前）
# 用法: 开关改 true，同时把 configs/<机型>.config 里对应的
#       "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
# ================================================================
echo "=========================================="
echo "拉取可选插件 (diy-part1.sh)"
echo "=========================================="
PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"
# ---------------------------------------------------------
# 插件开关
# ⚠ 关掉某个开关，defconfig 会把 config 里对应的 =y 静默剔除 —— 两处必须一起改。
# ⚠ 标「只用 feeds」的，是本体（mosdns/smartdns/xray-core/sing-box）feeds 已有
#   同名包；第三方源再拉一份会让索引出现两个同名 Package，行为不可预期。
#   故只拷 luci 前端，本体一律用 feeds 的。
# 温度不走插件：autocore 的 /sbin/tempinfo 提供（见 files/sbin/tempinfo）
# ---------------------------------------------------------
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）
ADD_FLUENT=true        # luci-theme-fluent：Fluent 2 风格主题
ADD_FLUENT_LITE=false  # luci-theme-fluent-lite：轻量版（与 fluent 互斥，二选一）
ADD_FLUENT_DASH=false  # luci-mod-fluentdashboard：可选状态概览卡片
ADD_PASSWALL=true      # luci-app-passwall（只用 feeds 的依赖包）
ADD_OPENCLASH=true     # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
ADD_MOSDNS=true        # luci-app-mosdns（本体只用 feeds 的 mosdns）
ADD_LUCKY=true         # luci-app-lucky（DDNS + socat）
ADD_TAILSCALE=true     # luci-app-tailscale（本体只用 feeds 的 tailscale）
ADD_OPENLIST=true      # luci-app-openlist2（alist/openlist 挂载）
ADD_SMARTDNS=true      # luci-app-smartdns（本体只用 feeds 的 smartdns）
ADD_EASYTIER=true      # luci-app-easytier（另需 kmod-tun + easytier 本体，Rust 编译较慢）
ADD_POWEROFF=true      # luci-app-poweroffdevice（关机）
ADD_OWQ_WOL=true       # luci-app-owq-wol（网络唤醒，依赖 etherwake）
ADD_WATCHDOG=true      # luci-app-watchdog（看门狗，包在子目录，需特殊处理）
ADD_TASKPLAN=true      # luci-app-taskplan（定时任务）
ADD_OAF=true           # luci-app-oaf（应用过滤，含内核模块，高风险）
ADD_LUCI_APP=true       # qwe-qaq/luci-app 仓库（monorepo）
                        #   ├─ luci-app-natmode     NAT 类型三选一（网络 → NAT 类型）
                        #   ├─ luci-app-pon-status  PON 光模块卡片（概览页「系统」下一格）
                        #   ├─ luci-app-igmpproxy    IGMP Proxy 组播代理 Web 界面
                        #   └─ luci-app-ledpanel    面板 LED 控制（系统 → 面板 LED）
                        #      ★仅 an4475-g2 的 config =y：灯位是这块板的 PCA9555 脚位
# 以下开关可被环境变量覆盖（: ${VAR:=默认}）；选「不拉私有仓库」时注入 ADD_FTTR=false
: "${ADD_FTTR:=true}"       # FTTR 全家桶总开关（下面的子开关都受它管）★仅 HM2004-DU
: "${ADD_FMCS:=true}"       # h3c-fmcs：Micro-OLT FPGA 内核驱动（kmod-h3c-fmcs）
: "${ADD_FTTR_TOOLS:=true}" # openwrt-fttr：fttrd 控制器 + fttrctl（Rust 包）
: "${ADD_FMCS_FW:=true}"    # h3c-fmcs-firmware：FPGA 比特流 FTTR_TOP.sbit
: "${ADD_FTTR_LUCI:=true}"  # luci-app-fttr：界面包（公开 CI 生成的 package 分支）
                            # （前三个来自 openwrt-fttr 私有仓库；界面包单独拉，见下方）

# FTTR 四件套只对 HM2004-DU 有意义（DEPENDS 带 @(TARGET_airoha_an7581)）。
# workflow 把 PROFILE 导出为环境变量，非 2004 机型直接跳过，不白花 clone 时间。
# ⚠ 不能默认成 h3c_hm2004-du：warm-cache.yml 也调本脚本却不设 PROFILE、也没有
#   私有仓库凭证，默认成 h3c 会去 clone 私有 feed 然后 "could not read Username"。
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
# qwe-qaq/luci-app —— monorepo，四个 LuCI 插件：
#   luci-app-natmode / luci-app-pon-status / luci-app-igmpproxy / luci-app-ledpanel
# =========================================================
if [ "$ADD_LUCI_APP" = "true" ]; then
  LUCI_APP_URL="https://github.com/qwe-qaq/luci-app"
  LUCI_APP_TMP="$(mktemp -d)/luci-app"
  if ! clone "$LUCI_APP_URL" "$LUCI_APP_TMP" main; then
    echo "::error::qwe-qaq/luci-app 拉取失败，natmode / pon-status / igmpproxy / ledpanel 会被 defconfig 剔除"
    exit 1
  fi
  for p in luci-app-natmode luci-app-pon-status luci-app-igmpproxy luci-app-ledpanel; do
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
# FTTR 后端三件套 ★HM2004-DU 专属，源 qwe-qaq/openwrt-fttr（私有）
# ⚠ 必须用裸 URL：凭证由 workflow 的 GIT_ASKPASS 注入，拼 token 会被 clone 打进日志。
# ⚠ 该仓库是 feed 形态（根目录即包目录）。用户态 Rust 包已改名 openwrt-fttr，
#   但源目录可能是 fttr / fttr-tools / h3c-fttr-tools，故按候选名探测后统一拷成
#   package/custom/openwrt-fttr/，保证索引包名与 config 的 =y 对得上。
# ⚠ h3c-fmcs 是 KernelPackage，索引里叫 kmod-h3c-fmcs（校验里由 pkgname_of 映射）。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  # 仓库与分支由 workflow 注入，本地手工跑时回退到下面的默认值
  FTTR_FEED_URL="https://github.com/${PRIVATE_REPO:-qwe-qaq/openwrt-fttr}"
  FTTR_FEED_BRANCH="${PRIVATE_REPO_BRANCH:-main}"
  FTTR_FEED_TMP="$(mktemp -d)/openwrt-fttr"
  if ! clone "$FTTR_FEED_URL" "$FTTR_FEED_TMP" "$FTTR_FEED_BRANCH"; then
    echo "::error::openwrt-fttr 拉取失败：${FTTR_FEED_URL} (分支 ${FTTR_FEED_BRANCH})，kmod-h3c-fmcs / openwrt-fttr / h3c-fmcs-firmware 会被 defconfig 剔除；luci-app-fttr 因依赖 +openwrt-fttr 也会被连带剔除"
    echo "        公开仓库失败=仓库/分支名不对；私有仓库缺凭证=优先查 GitHub App（PRIVATE_SOURCE_APP_ID / PRIVATE_SOURCE_APP_PRIVATE_KEY，App 要装到该仓库且 Contents: Read-only），回退才看 Secret PRIVATE_REPO_TOKEN 是否有效（PAT 需对该仓库有 Contents 读权限）"
    exit 1
  fi

  # openwrt-fttr 硬 include 了 feeds/packages/lang/rust/rust-package.mk，
  # 这个文件不在的话 dump 直接失败、包静默不进索引。
  # 与其等到 defconfig 把它剔掉才发现，不如在这里就报错退出。
  if [ "$ADD_FTTR_TOOLS" = "true" ] && [ ! -f feeds/packages/lang/rust/rust-package.mk ]; then
    echo "::error::未找到 feeds/packages/lang/rust/rust-package.mk，openwrt-fttr 无法索引"
    echo "        确认 packages feed 已 update + install；或把 ADD_FTTR_TOOLS 置为 false"
    exit 1
  fi

  # 用户态后端改名后源目录不稳定（fttr / fttr-tools / h3c-fttr-tools），
  # 逐个探测；拷进 package/custom 时统一用包名 openwrt-fttr。
  FTTR_TOOLS_SRC=""
  for cand in fttr fttr-tools h3c-fttr-tools openwrt-fttr; do
    if [ -f "$FTTR_FEED_TMP/$cand/Makefile" ]; then
      FTTR_TOOLS_SRC="$cand"
      break
    fi
  done
  if [ "$ADD_FTTR_TOOLS" = "true" ] && [ -z "$FTTR_TOOLS_SRC" ]; then
    echo "::error::openwrt-fttr 源目录未找到（依次试过 fttr / fttr-tools / h3c-fttr-tools / openwrt-fttr）"
    exit 1
  fi

  FTTR_FEED_PKGS=""
  [ "$ADD_FMCS" = "true" ]       && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fmcs"
  [ "$ADD_FTTR_TOOLS" = "true" ] && FTTR_FEED_PKGS="$FTTR_FEED_PKGS $FTTR_TOOLS_SRC"
  [ "$ADD_FMCS_FW" = "true" ]    && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fmcs-firmware"

  for p in $FTTR_FEED_PKGS; do
    if [ ! -f "$FTTR_FEED_TMP/$p/Makefile" ]; then
      echo "::error::$FTTR_FEED_TMP/$p/Makefile 不存在（上游改结构了？）"
      exit 1
    fi
    # 源目录名可能与包名不同，统一落到与 CONFIG_PACKAGE_ 一致的目录名
    case "$p" in
      fttr|fttr-tools|h3c-fttr-tools|openwrt-fttr) dst="openwrt-fttr" ;;
      *) dst="$p" ;;
    esac
    rm -rf "$PKG_DIR/$dst"
    cp -a "$FTTR_FEED_TMP/$p" "$PKG_DIR/$dst"
    echo "✅ 已拷贝: $p → $dst  (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/$dst/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  done
  rm -rf "$FTTR_FEED_TMP"
fi

# =========================================================
# luci-app-fttr —— FTTR 管理界面（网络 → FTTR）★HM2004-DU 专属
# 源 LazuliKao/luci-app-fttr 的 package 分支（CI 产物，前端 JS 随包提交，
# 编译期不联网、无 hash 失效问题）。后端仍由上面的私有 feed 提供。
# ⚠ 该分支 orphan + force-push（每次只 1 个 commit），必须 --depth 1 重拉。
# ⚠ 上游 Makefile 漏了 "# call BuildPackage" 标记行。scan.mk 用文本 grep 找它
#   决定哪些 Makefile 进 FILELIST（不展开 include），缺了就不 DUMP、不进
#   tmp/.packageinfo，表现为「别的包全 ✅ 唯独它 ❌ 且无 dump.txt」。故下方幂等补。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$ADD_FTTR_LUCI" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  # 用独立变量名，不与 workflow 里指向「源码仓 main 分支」的 FTTR_LUCI_* 冲突
  FTTR_PKG_REPO="${FTTR_PKG_REPO:-LazuliKao/luci-app-fttr}"
  FTTR_PKG_BRANCH="${FTTR_PKG_BRANCH:-package}"
  FTTR_TMP="$(mktemp -d)/fttr"
  if ! clone "https://github.com/${FTTR_PKG_REPO}" "$FTTR_TMP" "$FTTR_PKG_BRANCH"; then
    echo "::error::luci-app-fttr 的 ${FTTR_PKG_BRANCH} 分支拉取失败，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
  # 分支根目录就该是完整包；顺手确认前端产物在，防止 CI 生成了空壳
  if [ ! -f "$FTTR_TMP/Makefile" ] || \
     [ ! -d "$FTTR_TMP/htdocs/luci-static/resources/view/fttr" ]; then
    echo "::error::$FTTR_TMP 不是完整 OpenWrt 包（缺 Makefile 或 htdocs/view/fttr）"
    exit 1
  fi

  rm -rf "$PKG_DIR/luci-app-fttr"
  cp -a "$FTTR_TMP" "$PKG_DIR/luci-app-fttr"
  rm -rf "$PKG_DIR/luci-app-fttr/.git"   # 别把克隆元数据带进源码树

  # scan.mk 只按文本 grep 'call BuildPackage' 收录 Makefile，luci.mk 里的真实
  # 调用不算（grep 不展开 include）。上游 CI 模板漏了这行标准注释，补回来：
  # 注释行对 make 无害，但缺了它整个包不会被索引。上游修好后自动跳过。
  FTTR_MK="$PKG_DIR/luci-app-fttr/Makefile"
  if ! grep -qE 'call[[:space:]]+(Build/DefaultTargets|BuildPackage|BuildContainer|BuildCompose|KernelPackage)' "$FTTR_MK"; then
    printf '\n# call BuildPackage - OpenWrt buildroot signature\n' >> "$FTTR_MK"
    echo "⚠ 已补 BuildPackage 扫描标记（上游 package 分支 Makefile 缺失）"
  fi

  echo "✅ 已拷贝: luci-app-fttr (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-fttr/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  rm -rf "$FTTR_TMP"
fi


# --- Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）---
# 目录名决定包名（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），必须是
# luci-app-airoha-npu，否则 config 里的符号对不上。
# 源 luanmuc/luci-app-airoha-npu：自带 zh_Hans 翻译，无「根目录+同名子目录」坏结构。
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
  # po 必须改名 airoha-npu.po：luci.mk 按 po 主名生成 lmo，运行时按
  # LUCI_BASENAME(=airoha-npu) 查找，不改名则中文不生效。
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
# 源已从 xiaorouji 迁到 Openwrt-Passwall（旧地址 404）。
# ⚠ 只拷 luci-app-passwall 子目录：同仓的 xray-core/sing-box 等全与 feeds 同名。
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
# ⚠ 只拷 luci-app-mosdns：仓库还带 mosdns 本体与 v2ray-geodata，均与 feeds 同名。
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
# 校验：开关为 true 的包必须拉到，否则 defconfig 会静默剔除
# ---------------------------------------------------------
if [ "$ADD_AIROHA_NPU" = "true" ] && [ ! -d "$PKG_DIR/luci-app-airoha-npu" ]; then
  echo "::error::luci-app-airoha-npu 未拉到，config 里的 =y 会被 defconfig 剔除"
  exit 1
fi
# natmode / pon-status / igmpproxy 来自 qwe-qaq/luci-app（config 里也是 =y）
for p in luci-app-natmode luci-app-pon-status luci-app-igmpproxy; do
  if [ "$ADD_LUCI_APP" = "true" ] && [ ! -d "$PKG_DIR/$p" ]; then
    echo "::error::$p 未拉到，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
done
# ---------------------------------------------------------
# 补回 libffi —— python3 的 _ctypes 硬性需要 ffi.h
# CPython 3.11 起删了 --with-system-ffi，_ctypes 永远 #include <ffi.h>，而
# ponwrt 与 immortalwrt/packages 的 libffi 目录都已不存在，编到 _ctypes.c 才报
# "ffi.h: No such file"。这里从 immortalwrt 基座取现成包定义（自带 InstallDev，
# 会把 ffi.h / libffi.pc 装进 staging_dir），再给 python3 补构建依赖。
# ⚠ 必须放在 prepare-tmpinfo 之前，目录才能被扫进索引、PKG_BUILD_DEPENDS 才生效。
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
# 清理重复嵌套目录：根目录一份 + 同名子目录又一份时，feeds 会把两层都当独立包，
# 内层 dump 失败会中断整个 custom feed 的索引，导致所有包符号都不存在。
# ---------------------------------------------------------
echo "--- 检查重复嵌套目录 ---"
# ⚠ 判据必须含「根目录也有 Makefile」：lucky / openlist2 / easytier / taskplan /
#   poweroffdevice 的根目录没有 Makefile，同名子目录才是唯一那份包，只看
#   「有同名子目录」会把真包删掉。
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
# ⚠ 判据是 tmp/.packageinfo，不是 package/feeds/custom。
# prepare-tmpinfo 直接扫 package/ 树（scan.mk: find -L package -maxdepth 5），
# custom/<pkg>/Makefile 深度 3 本来就会被扫到，不需要注册 feed；旧 src-link
# custom feed 反而会让同一批 Makefile 被扫两遍、行为随扫描顺序漂移。
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  # 强制重建索引：只删 tmp/.packageinfo 不够，scan_unchanged 会拿
  # tmp/info/.scan-*.stamp 比 mtime 跳过扫描，故 stamp 与 .files* 清单一起删。
  # cache 恢复的 tmp/ 与 cp -a 都保留旧 mtime，新 Makefile 可能比 stamp 还旧，
  # 故删完再统一 touch 一遍 package/custom（否则表现为「别的包都 ✅ 唯独它缺席」）。
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/info/.files* 2>/dev/null
  rm -f tmp/.config-package.in tmp/.config-target.in
  find "$PKG_DIR" -type f -exec touch {} + 2>/dev/null || true
  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make prepare-tmpinfo OPENWRT_BUILD= V=s 2>&1 | tail -60
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "::error::prepare-tmpinfo 执行失败，索引不会更新（见上方输出）"
    exit 1
  fi
  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  echo "package/custom 内容："
  INDEX_MISS=""
  # 目录名 ≠ 包名（Makefile 显式写了 PKG_NAME / KernelPackage）：
  # open-app-filter→appfilter、oaf→kmod-oaf，按目录名查必然查不到，属误报。
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
      DUMP_SHOWN=0
      for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
        [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; DUMP_SHOWN=1; }
      done
      # scan.mk 压根没落 dump.txt（缓存跳过扫描时常见）：直接单包 dump 一次，
      # 把 Makefile 解析错误打出来，避免「查不到但日志里没有任何线索」。
      if [ "$DUMP_SHOWN" -eq 0 ]; then
        echo "===== 直接 dump: make $d/dump V=s ====="
        make "$d/dump" V=s 2>&1 | tail -40
      fi
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

  # 与 configs/*.config 里 =y 的包一一对应；没进索引的会被 defconfig 静默剔除。
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
      REQUIRED="$REQUIRED openwrt-fttr"
    fi
    if [ "$ADD_FTTR_LUCI" = "true" ]; then
      REQUIRED="$REQUIRED luci-app-fttr"
    fi
    # luci-app-fttr → openwrt-fttr → kmod-h3c-fmcs，链条上任一节缺失，
    # defconfig 都会静默剔掉整条 FTTR。前者多为缺 rust-package.mk，
    # 后者受 @(TARGET_airoha_an7581) 限制。
    if [ "$ADD_FTTR_TOOLS" = "true" ] &&
       ! grep -qx "Package: openwrt-fttr" tmp/.packageinfo 2>/dev/null; then
      echo "::error::openwrt-fttr 不在包索引里（luci-app-fttr 的后端，Rust 包）"
      echo "        多半是缺 rust feed：确认 feeds.conf 里有 packages，且"
      echo "        ./scripts/feeds install 装到了 lang/rust。"
      echo "        不需要 FTTR 就把 diy-part1.sh 的 ADD_FTTR 改成 false。"
      exit 1
    fi
    if [ "$ADD_FMCS" = "true" ] &&
       ! grep -qx "Package: kmod-h3c-fmcs" tmp/.packageinfo 2>/dev/null; then
      echo "::error::kmod-h3c-fmcs 不在包索引里（openwrt-fttr 依赖它）"
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

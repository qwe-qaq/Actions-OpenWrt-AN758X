#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default

echo "=========================================="
echo "diy-part1.sh: 拉取第三方插件与定制包"
echo "=========================================="

set -euo pipefail

# =========================================================
# 配置区：插件开关
# =========================================================
# 说明：这些开关控制是否拉取对应的第三方插件。
#   大部分插件的本体（守护进程、内核模块）在 feeds 里已经有了，
#   这里只拉 LuCI 前端（菜单、配置界面）。
#   只拷前端而不拉本体，可以避免与 feeds 里同名包冲突，
#   同时保持索引里只有一个同名 Package，行为可预期。
# =========================================================
ADD_LUCI_APP=true     # luci-app-natmode + luci-app-pon-status（qwe-qaq/luci-app monorepo）
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
ADD_POWEROFF=false     # 关机按钮
ADD_WOL=false          # 网络唤醒
ADD_WATCHDOG=false     # 看门狗
ADD_TASKPLAN=false     # 定时任务
ADD_OAF=false          # 应用过滤
ADD_UPNP=false         # UPnP

# =========================================================
# FTTR（H3C HM2004-DU）相关
# =========================================================
# 默认关闭：FTTR 是 H3C 私有协议，需要额外的 FPGA 驱动和 Rust 工具链，
#   普通 PON 网关用不到，编进去会大幅增加编译时间和镜像大小。
ADD_FTTR=false         # FTTR 全套（kmod-h3c-fmcs + h3c-fmcs-firmware + h3c-fttr-tools + luci-app-fttr）
FTTR_PROFILE="${PROFILE:-none}"  # h3c_hm2004-du 即可。

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
# -----------------

# =========================================================
# qwe-qaq/luci-app —— 两个 LuCI 插件的来源
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
    echo "::error::qwe-qaq/luci-app 拉取失败，natmode / pon-status 会被 defconfig 剔除"
    exit 1
  fi
  for p in luci-app-natmode luci-app-pon-status; do
    if [ ! -f "$LUCI_APP_TMP/$p/Makefile" ]; then
      echo "::error::$LUCI_APP_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$LUCI_APP_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p"
  done
  rm -rf "$LUCI_APP_TMP"
fi

# =========================================================
# Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）
# 包名由目录名决定（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），
# 目录必须是 luci-app-airoha-npu，否则 config 里的符号对不上。
#
# 源用 luanmuc/luci-app-airoha-npu（rchen14b 的 fork 改进版）：
#   - 自带 po/zh_Hans 完整中文翻译（48 条）
#   - 无 rchen14b 那种「根目录 + 同名子目录」重复结构，feed 索引不会中断
#   - 修了 luci.mk 的 include 路径、加了独立 CPU 温度与 PLL 备用频率
# =========================================================
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
  #   luci.mk 的 find 是按 LUCI_BASENAME 找的，默认 basename 是目录名
  #   （luci-app-airoha-npu），但 po 文件名叫 luci-app-airoha-npu.po，
  #   会找不到，导致中文包不被安装。
  # =========================================================
  if [ -f "$PKG_DIR/luci-app-airoha-npu/po/zh_Hans/luci-app-airoha-npu.po" ]; then
    mv "$PKG_DIR/luci-app-airoha-npu/po/zh_Hans/luci-app-airoha-npu.po" \
       "$PKG_DIR/luci-app-airoha-npu/po/zh_Hans/airoha-npu.po"
    echo "  ✅ po 文件已改名: airoha-npu.po"
  fi
  # =========================================================
  # 健壮性补丁（rpcd 后端 luci.airoha_npu）：
  #   ① devmem 空值保护：避免 $(($(devmem ...))) 读取失败返回空时，
  #      dash/busybox ash 报算术错误中断、bash 静默归零；
  #   ② PLL 等待增强：保留 20ms 经验等待，等待前后读回已知 PCW/CHG
  #      做一致性确认，异常即 rollback（无 lock 位手册，不臆造寄存器地址）。
  #   补丁脚本 patch-airoha-npu.py 随仓库分发，幂等可重复执行。
  # =========================================================
  NPU_RPCD="$PKG_DIR/luci-app-airoha-npu/root/usr/libexec/rpcd/luci.airoha_npu"
  if [ -f "$GITHUB_WORKSPACE/patch-airoha-npu.py" ]; then
    python3 "$GITHUB_WORKSPACE/patch-airoha-npu.py" "$NPU_RPCD"
  else
    echo "::warning::未找到 patch-airoha-npu.py，跳过 NPU 健壮性补丁"
  fi
fi

# =========================================================
# 修复状态插件依赖：去掉缺失的依赖，防止 defconfig 剔除
# =========================================================
echo "--- 修复状态插件依赖（去掉缺失的依赖）---"

# luci-app-airoha-npu: 去掉 @TARGET_airoha 条件
if [ -f "$PKG_DIR/luci-app-airoha-npu/Makefile" ]; then
  sed -i 's/LUCI_DEPENDS:=+luci-base @TARGET_airoha/LUCI_DEPENDS:=+luci-base/' "$PKG_DIR/luci-app-airoha-npu/Makefile"
  echo "  ✅ luci-app-airoha-npu: 已去掉 @TARGET_airoha"
fi

# luci-app-natmode: 去掉 +firewall4 +kmod-nft-fullcone
if [ -f "$PKG_DIR/luci-app-natmode/Makefile" ]; then
  sed -i 's/LUCI_DEPENDS:=+luci-base +firewall4 +kmod-nft-fullcone/LUCI_DEPENDS:=+luci-base/' "$PKG_DIR/luci-app-natmode/Makefile"
  echo "  ✅ luci-app-natmode: 已去掉 firewall4 + kmod-nft-fullcone"
fi

# luci-app-pon-status: 去掉 +luci-mod-status +airoha-ponctl +jsonfilter +rpcd-mod-file
if [ -f "$PKG_DIR/luci-app-pon-status/Makefile" ]; then
  sed -i 's/LUCI_DEPENDS:=+luci-base +luci-mod-status +airoha-ponctl +jsonfilter +rpcd-mod-file/LUCI_DEPENDS:=+luci-base/' "$PKG_DIR/luci-app-pon-status/Makefile"
  echo "  ✅ luci-app-pon-status: 已去掉所有额外依赖"
fi

# =========================================================
# Feeds install：把所有自定义包装入 feeds 索引
# =========================================================
echo "--- feeds install -a ---"
./scripts/feeds install -a

# =========================================================
# 包索引校验：确认必装插件都进入了 tmp/.packageinfo
# =========================================================
echo "=========================================="
echo "包索引校验（判据：tmp/.packageinfo）"
echo "=========================================="

# 先跑一次 prepare-tmpinfo，让 package/ 树重新扫一遍，生成 tmp/.packageinfo
echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1

REQUIRED=""
if [ "$ADD_AIROHA_NPU" = "true" ]; then
  REQUIRED="$REQUIRED luci-app-airoha-npu"
fi
if [ "$ADD_LUCI_APP" = "true" ]; then
  REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status"
fi
if [ "$ADD_FTTR" = "true" ]; then
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

echo "🎉 diy-part1.sh 执行完毕"

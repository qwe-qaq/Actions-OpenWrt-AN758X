#!/bin/bash
set -euo pipefail
WS="${GITHUB_WORKSPACE:-.}"
PROFILE="${PROFILE:-fiberhome_hg5585f-ct}"

case "$PROFILE" in
  fiberhome_hg5382a)
    DEVICE="fiberhome_hg5382a"
    CFG="configs/fiberhome_hg5382a.config"
    ;;
  fiberhome_hg5585f-ct|*)
    DEVICE="fiberhome_hg5585f-ct"
    CFG="configs/fiberhome_hg5585f-ct.config"
    ;;
esac

echo "== 生成配置: $DEVICE =="

# 先清除所有机型配置，只保留目标机型（避免全机型编译）
sed -i '/CONFIG_TARGET_DEVICE_/d; /^CONFIG_TARGET_MULTI_PROFILE=/d' .config

{
  echo "CONFIG_TARGET_MULTI_PROFILE=y"
  echo "CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y"
  echo "CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_${DEVICE}=\"\""
} >> .config

if [ -f "$WS/$CFG" ]; then
  cat "$WS/$CFG" >> .config
  echo "✅ 已追加 $CFG"
else
  echo "::warning::未找到 $WS/$CFG"
fi

#!/bin/bash
set -euo pipefail
WS="${GITHUB_WORKSPACE:-.}"

echo "== 生成 HG5585F-CT 配置 =="
{
  echo "CONFIG_TARGET_MULTI_PROFILE=y"
  echo "CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_fiberhome_hg5585f-ct=y"
  echo 'CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_fiberhome_hg5585f-ct=""'
} >> .config

if [ -f "$WS/configs/fiberhome_hg5585f-ct.config" ]; then
  cat "$WS/configs/fiberhome_hg5585f-ct.config" >> .config
  echo "✅ 已追加 configs/fiberhome_hg5585f-ct.config"
else
  echo "::warning::未找到 $WS/configs/fiberhome_hg5585f-ct.config"
fi

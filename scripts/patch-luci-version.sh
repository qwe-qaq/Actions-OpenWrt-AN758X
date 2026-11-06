!/bin/bash
set -euo pipefail

echo "== 隐藏 LuCI 概览页固件版本行 =="
LUCI_SYS_JS="package/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
patch_system_js() {
  local f="$1"
  [ -f "$f" ] || return 0
  perl -0pi -e "s/^\s*_\('"'"'Firmware Version'"'"'\),[^\n]*\n//mg" "$f" || true
  perl -0pi -e "s/\s*\+\s*'"'"' / '"'"'\s*\+\s*\(luciversion\s*\|\|\s*''\)//g" "$f" || true
  perl -0pi -e "s/\s*\+\s*\(luciversion\s*\|\|\s*''\)//g" "$f" || true
}
patch_system_js "$LUCI_SYS_JS"

find package/feeds/luci -path "*status/include/10_system.js" -type f 2>/dev/null | while read -r f; do
  patch_system_js "$f"
done || true

echo "== 删除 Argon 主题配置入口 =="
find package/feeds/luci -path "*luci-app-argon-config*" -type f 2>/dev/null | while read -r f; do
  rm -f "$f" || true
done || true

echo "== WiFi 温度标签：2.4G / 5G =="
find package/feeds/luci -path "*temp*" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e 's/["'"'"']wifi["'"'"']/"2.4G WiFi"/i' "$f" && break
done || true
find package/feeds/luci -path "*temp*" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e 's/["'"'"']wifi["'"'"']/"5G WiFi"/i' "$f" && break
done || true

echo "== LuCI 版本补丁完成 =="

!/bin/bash
set -euo pipefail

echo "== WiFi 温度标签：2.4G / 5G =="
find package/feeds/luci -path "*temp*" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e 's/["'"'"']wifi["'"'"']/"2.4G WiFi"/i' "$f" && break
done || true
find package/feeds/luci -path "*temp*" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e 's/["'"'"']wifi["'"'"']/"5G WiFi"/i' "$f" && break
done || true

echo "== LuCI 版本补丁完成 =="

#!/bin/bash
set -euo pipefail

echo "== WiFi 温度标签：2.4G / 5G =="
find package/feeds/luci -path "*temp*" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e 's/["'"'"']wifi["'"'"']/"2.4G WiFi"/i' "$f" && break
done || true
find package/feeds/luci -path "*temp*" -type f 2>/dev/null | while read -r f; do
  perl -0pi -e 's/["'"'"']wifi["'"'"']/"5G WiFi"/i' "$f" && break
done || true

echo "== 隐藏状态概览固件版本行（整行含标签一起删除）=="
# 注意：LuCI 版本是运行时通过 RPC 动态拼接的（luciversion.branch/revision），
# 源码里没有 "LuCI Master" 字面量，删除含该文本的行永远无效；
# 这里直接把固件版本这一整行（label+value 成对）从 fields 数组中删除，
# 数组仍为成对结构，渲染循环不会错位。
SYS_JS="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
if [ -f "$SYS_JS" ]; then
  perl -i -ne "print unless /_\('Firmware Version'\)/" "$SYS_JS"
  echo "  OK 10_system.js 固件版本整行已删除"
else
  echo "  WARN 未找到 $SYS_JS，跳过"
fi

echo "== LuCI 版本补丁完成 =="

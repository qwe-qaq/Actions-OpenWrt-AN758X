#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
健壮性补丁 for luci-app-airoha-npu 的 rpcd 后端
  修复点 1: devmem 空值保护
    原写法 $(($(devmem ...))) 在 devmem 失败返回空时：
      busybox ash/dash 报算术错误（中断），bash 静默变 0（计数器静默归零）。
    引入 dm_read：先读 raw、判空再算术，失败返回 0 且返回码非 0。
  修复点 2: PLL 等待增强
    原 Step6 仅固定 usleep 20000。无该 PLL lock 状态位手册信息，不臆造寄存器地址；
    保留经验值 20ms 等待，并在等待前后读回已知 PCW/CHG 做一致性确认，异常即 rollback。
用法: patch-airoha-npu.py <rpcd 后端文件路径>
幂等: 已含 dm_read 则直接跳过。
"""
import sys
import re

path = sys.argv[1] if len(sys.argv) > 1 else ""
if not path:
    sys.exit("usage: patch-airoha-npu.py <rpcd file>")
try:
    src = open(path, encoding="utf-8").read()
except FileNotFoundError:
    sys.exit("target not found: %s" % path)

if "dm_read()" in src:
    print("already patched, skip: %s" % path)
    sys.exit(0)

# --- 1. 替换 Step6 固定等待为：读回确认 + 20ms 等待 + 读回确认 ---
step6_re = re.compile(
    r"\t# Step 6: Wait for PLL lock.*?\n"
    r"\tif command -v usleep > /dev/null 2>&1; then\n"
    r"\t\tusleep 20000\n"
    r"\telse\n"
    r"\t\tsleep 1\n"
    r"\tfi\n",
    re.S,
)
step6_new = (
    "\t# Step 6: Wait for PLL stable.\n"
    "\t# 无 PLL lock 状态位手册信息，不臆造寄存器地址；保留经验值 20ms 等待，\n"
    "\t# 等待前后读回已知 PCW/CHG 做一致性确认，异常则 rollback。\n"
    "\tif [ \"$(dm_read 0x1fa202b4)\" != \"$new_pcw_val\" ] || \\\n"
    "\t   [ \"$(dm_read 0x1fa202b8)\" != \"$new_chg_val\" ]; then\n"
    "\t\trollback_oc\n"
    "\t\techo '{\"error\":\"PLL config readback mismatch before wait\"}'\n"
    "\t\treturn\n"
    "\tfi\n"
    "\tif command -v usleep > /dev/null 2>&1; then\n"
    "\t\tusleep 20000\n"
    "\telse\n"
    "\t\tsleep 1\n"
    "\tfi\n"
    "\tif [ \"$(dm_read 0x1fa202b4)\" != \"$new_pcw_val\" ] || \\\n"
    "\t   [ \"$(dm_read 0x1fa202b8)\" != \"$new_chg_val\" ]; then\n"
    "\t\trollback_oc\n"
    "\t\techo '{\"error\":\"PLL config readback mismatch after wait\"}'\n"
    "\t\treturn\n"
    "\tfi\n"
)
src, k = step6_re.subn(step6_new, src)
if k != 1:
    sys.exit("Step6 block matched %d times, expected 1" % k)
print("replaced Step6 block: 1")

# --- 2. 批量替换 $(($(devmem ADDR [2>/dev/null]))) -> $(dm_read ADDR) ---
devmem_re = re.compile(
    r"\$\(\(\$\(devmem\s+([^)\s]+)(?:\s+2>/dev/null)?\)\)\)"
)
src, n = devmem_re.subn(r"$(dm_read \1)", src)
if n == 0:
    sys.exit("no $(($(devmem ...))) site matched")
print("replaced devmem arithmetic sites: %d" % n)

# --- 3. 最后在 json_escape 函数后插入 dm_read（放最后，避免注释被第 2 步替换）---
dm_read_block = (
    "\n"
    "# Safe devmem read: dm_read <addr> -> decimal; empty/error -> 0 (return 1)\n"
    "# 避免 $(($(devmem ...))) 在 devmem 失败返回空时：\n"
    "#   busybox ash/dash 报算术错误、bash 静默变 0（计数器静默归零或中断）。\n"
    "dm_read() {\n"
    "\tlocal raw\n"
    "\traw=$(devmem \"$1\" 2>/dev/null)\n"
    "\tif [ -z \"$raw\" ]; then echo 0; return 1; fi\n"
    "\techo $((raw))\n"
    "}\n"
)
anchor = re.search(r"json_escape\(\) \{.*?\n\}\n", src, re.S)
if not anchor:
    sys.exit("anchor json_escape not found")
src = src[:anchor.end()] + dm_read_block + src[anchor.end():]

open(path, "w", encoding="utf-8", newline="\n").write(src)
print("patched OK: %s" % path)

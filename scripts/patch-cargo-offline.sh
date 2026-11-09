#!/usr/bin/env bash
# =============================================================
# patch-cargo-offline.sh —— 放宽 rust 包的「禁止联网」限制
#
#   背景：openwrt-fttr 的 Makefile 用 cargo install --locked --frozen。
#   --frozen = 锁版本 + 禁止联网，只认 CARGO_HOME(dl/cargo) 里已有的 crate；
#   而 dl/cargo 从缓存继承（只增不减），上游在 Cargo.lock 加新依赖时缓存里没有：
#     Caused by: failed to download `core_detect v1.0.0`
#     Caused by: attempting to make an HTTP request, but --frozen was specified
#   现象是编到一半某个 rust 包必挂，换机型、换缓存都复现。
#
#   这里只摘掉 --frozen / --offline，--locked 保留（版本仍锁死，结果可复现）。
# ⚠ 这是 CI 侧兜底。更正统的做法在包侧：Build/Prepare 里 cargo fetch --locked
#   把 crate 拉进 CARGO_HOME，编译阶段再用 --frozen。
#   用法: bash patch-cargo-offline.sh <openwrt_dir>
# =============================================================

set -u

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

# 只看构建脚本本身：build_dir / staging_dir 里是解压出来的副本，改了没用
LIST=$(grep -rlE -- '--frozen|--offline' \
         --include=Makefile --include='*.mk' \
         package feeds 2>/dev/null \
       | grep -v -e '/build_dir/' -e '/staging_dir/' || true)

if [ -z "$LIST" ]; then
  echo "树里没有 Makefile 使用 --frozen / --offline，跳过"
  exit 0
fi

echo "===== 以下文件包含离线参数 ====="
printf '%s\n' "$LIST" | sed 's/^/  /'

CHANGED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # 只有真的改了才计数：sed 后比对一下
  BEFORE=$(md5sum "$f" | cut -d' ' -f1)
  sed -i 's/--frozen//g; s/--offline//g' "$f"
  AFTER=$(md5sum "$f" | cut -d' ' -f1)
  if [ "$BEFORE" != "$AFTER" ]; then
    CHANGED=$((CHANGED + 1))
    echo "已放宽: $f"
    # 把改完的那几行打出来，方便核对没把别的参数一起吃掉
    grep -nE 'cargo (install|build|fetch)' "$f" | head -3 | sed 's/^/    /'
  fi
done <<< "$LIST"

echo "共处理 $CHANGED 个文件（--locked 保留，仅去掉禁止联网的部分）"

# 复核：还有没有漏网的（比如参数被拼在变量里、跨行续行）
LEFT=$(grep -rlE -- '--frozen|--offline' \
         --include=Makefile --include='*.mk' \
         package feeds 2>/dev/null \
       | grep -v -e '/build_dir/' -e '/staging_dir/' || true)
if [ -n "$LEFT" ]; then
  echo "::warning::仍有文件包含离线参数（可能是跨行拼接，需人工确认）："
  printf '%s\n' "$LEFT" | sed 's/^/  /'
fi

exit 0

#!/usr/bin/env bash
# =============================================================
# patch-cargo-offline.sh —— 按包放宽 rust 包的「禁止联网」限制
#
#   背景：h3c-fttr-tools 的 Makefile 用 cargo install --locked --frozen。
#   --frozen = 锁版本 + 禁止联网，只认 CARGO_HOME(dl/cargo) 里已有的 crate；
#   而 dl/cargo 从缓存继承（只增不减），上游在 Cargo.lock 加新依赖时缓存里没有：
#     Caused by: failed to download `core_detect v1.0.0`
#     Caused by: attempting to make an HTTP request, but --frozen was specified
#
#   ⚠ 只对白名单内的包摘除 --frozen / --offline，--locked 保留（版本仍锁死）；
#     白名单外的包保持离线参数原样，避免全局放宽可复现约束。
#   白名单可用环境变量 CARGO_OFFLINE_ALLOWLIST 覆盖（空格分隔的路径子串）。
#   更正统的做法在包侧：Build/Prepare 里 cargo fetch --locked 把 crate 拉进
#   CARGO_HOME，编译阶段再用 --frozen。
#   用法: bash patch-cargo-offline.sh <openwrt_dir>
# =============================================================

set -u

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

# 默认白名单：脚本头注释里确认过缺 crate 的包
ALLOWLIST="${CARGO_OFFLINE_ALLOWLIST:-h3c-fttr-tools}"

# 只看构建脚本本身：build_dir / staging_dir 里是解压出来的副本，改了没用。
# 正则只认独立令牌 --frozen / --offline（后接空白或行尾），避免前缀误报：
#   --frozen-lockfile（pnpm）、--offline-root（opkg）、Lua/HTML 注释里的 --offline。
# 注意：--include/--exclude 是 grep 选项，必须排在模式之前；不能放在 `--` 之后，
# 否则会被当成文件路径，include 过滤整体失效（本次误报的根因）。
LIST=$(grep -rlE \
         --include=Makefile --include='*.mk' \
         --exclude='*.sh' --exclude='*.lua' --exclude='*.htm' --exclude='*.html' --exclude='*.js' \
         -e '--(frozen|offline)([[:space:]]|$)' \
         package feeds 2>/dev/null \
       | grep -v -e '/build_dir/' -e '/staging_dir/' || true)

if [ -z "$LIST" ]; then
  echo "树里没有 Makefile 使用 --frozen / --offline，跳过"
  exit 0
fi

echo "===== 以下文件包含离线参数 ====="
printf '%s\n' "$LIST" | sed 's/^/  /'

in_allowlist() {
  local f="$1" kw
  for kw in $ALLOWLIST; do
    case "$f" in
      *"$kw"*) return 0 ;;
    esac
  done
  return 1
}

CHANGED=0
REVIEW=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue

  if ! in_allowlist "$f"; then
    REVIEW="${REVIEW}${f}"$'\n'
    continue
  fi

  # 只有真的改了才计数：sed 后比对一下
  BEFORE=$(md5sum "$f" | cut -d' ' -f1)
  sed -i 's/--frozen//g; s/--offline//g' "$f"
  AFTER=$(md5sum "$f" | cut -d' ' -f1)
  if [ "$BEFORE" != "$AFTER" ]; then
    CHANGED=$((CHANGED + 1))
    echo "已放宽（白名单内）: $f"
    # 把改完的那几行打出来，方便核对没把别的参数一起吃掉
    grep -nE 'cargo (install|build|fetch)' "$f" | head -3 | sed 's/^/    /'
  fi
done <<< "$LIST"

if [ -n "$REVIEW" ]; then
  echo "::warning::以下包未在白名单，离线参数（--frozen/--offline）保留，需人工确认是否缺 crate："
  printf '%s' "$REVIEW" | sed 's/^/  /'
fi

echo "共放宽 $CHANGED 个文件（--locked 保留，仅去掉禁止联网的部分）"

# 复核：还有没有漏网的（比如参数被拼在变量里、跨行续行）
LEFT=$(grep -rlE \
         --include=Makefile --include='*.mk' \
         --exclude='*.sh' --exclude='*.lua' --exclude='*.htm' --exclude='*.html' --exclude='*.js' \
         -e '--(frozen|offline)([[:space:]]|$)' \
         package feeds 2>/dev/null \
       | grep -v -e '/build_dir/' -e '/staging_dir/' || true)
if [ -n "$LEFT" ]; then
  echo "::warning::仍有文件包含离线参数（可能是跨行拼接，需人工确认）："
  printf '%s\n' "$LEFT" | sed 's/^/  /'
fi

exit 0

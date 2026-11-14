#!/usr/bin/env bash
# =============================================================
# prepare-build-host.sh —— 用 runner 预装的工具替代从源码编译
#   思路不是「让缓存更快」，而是「让需要编译的东西更少」：
#     1. Go     external bootstrap，跳过五段自举   省 40~70 分钟
#     2. BPF    用 host LLVM，不编 LLVM
#     3. Python 关掉 host 侧 PGO
#     4. Rust   由 prepare-rust.sh 单独处理        省 30~60 分钟
# ★ 全部软失败：ponwrt 不一定支持每个配置项，检测不到就 warning 跳过，
#   绝不让构建死在这里。用法: bash prepare-build-host.sh <openwrt_dir>
# =============================================================

set -uo pipefail

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

REPORT_DIR="${GITHUB_WORKSPACE:-$OW}/build-reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/host-toolchains.txt"

# 写入报告 + 控制台
log() { echo "$1" | tee -a "$REPORT"; }
warn() { echo "::warning::$1"; echo "跳过: $1" >> "$REPORT"; }

: > "$REPORT"
log "===== host 工具链加速（OpenWRT-CI 思路）====="

# ---------------------------------------------------------------
# .config 行操作：先删旧值再追加，保证幂等（脚本可能被调用多次）
# ---------------------------------------------------------------
set_cfg() { # $1=KEY  $2=值（空表示 is not set）
  local key="$1" val="$2"
  sed -i "/^${key}=/d; /^# ${key} is not set$/d" .config
  if [ -n "$val" ]; then
    printf '%s=%s\n' "$key" "$val" >> .config
  else
    printf '# %s is not set\n' "$key" >> .config
  fi
}

# ===============================================================
# 1. Go —— external bootstrap
#
#    OpenWrt 的 golang 默认从 go1.4 起五段自举（40~70 分钟）。
#    若 feed 提供 GOLANG_EXTERNAL_BOOTSTRAP_ROOT，可直接用
#    runner 预装的 Go 作为 bootstrap，一步跳过全部自举。
# ===============================================================
GO_DONE=0
# runner 的 Go 在 /opt/hostedtoolcache/go/<ver>/x64/bin 里，默认不进 PATH
GO_BIN=$(command -v go 2>/dev/null || true)
if [ -z "$GO_BIN" ]; then
  for c in /opt/hostedtoolcache/go/*/x64/bin/go /opt/hostedtoolcache/go/*/arm64/bin/go \
           /usr/local/go/bin/go /opt/go/bin/go "$HOME/go/bin/go"; do
    [ -x "$c" ] && { GO_BIN="$c"; break; }
  done
fi
GO_ROOT=$([ -n "$GO_BIN" ] && "$GO_BIN" env GOROOT 2>/dev/null || true)

if [ -z "$GO_ROOT" ] || [ ! -x "$GO_ROOT/bin/go" ]; then
  warn "Go: runner 没有可用的 go（PATH 与 toolcache 都没有），跳过 external bootstrap"
else
  # 能力检测：feed 的 Config.in 里必须真的有这几个符号
  #
  #   ⚠ 不能写死几个固定路径 —— 各版本 feed 的目录结构不一样：
  #     feeds/packages/lang/golang/Config.in
  #     feeds/packages/lang/golang/golang/Config.in
  #     feeds/packages/lang/golang/golang-values/Config.in …
  #   写死就会出现「找不到 golang 的 Config.in」而白白错过加速。
  #   这里在整个源码树里搜任何含该符号的 Config.in。
  GO_CFG=$(grep -rl 'GOLANG_BUILD_BOOTSTRAP' --include='Config.in' . 2>/dev/null | head -1)

  if [ -z "$GO_CFG" ]; then
    # 再退一步：Makefile 里定义也算（有些 feed 不用 Kconfig）
    GO_CFG=$(grep -rl 'GOLANG_EXTERNAL_BOOTSTRAP_ROOT' \
             --include='*.mk' --include='Makefile' . 2>/dev/null | head -1)
  fi

  if [ -z "$GO_CFG" ]; then
    warn "Go: 全树搜不到 GOLANG_BUILD_BOOTSTRAP 符号，跳过（将走源码自举）"
    echo "  提示: 可手动确认 ls feeds/packages/lang/golang/"
  elif ! grep -q 'GOLANG_EXTERNAL_BOOTSTRAP_ROOT' "$GO_CFG"; then
    warn "Go: $GO_CFG 有 BUILD_BOOTSTRAP 但没有 EXTERNAL_BOOTSTRAP_ROOT，仍会走五段自举"
  else
    log "Go     : 符号定义于 $GO_CFG"
    set_cfg CONFIG_GOLANG_BUILD_BOOTSTRAP ""
    set_cfg CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT "\"$GO_ROOT\""
    GO_DONE=1
    log "Go     : ✅ external bootstrap → $GO_ROOT"
    log "         $("$GO_ROOT/bin/go" version 2>&1 | head -1)"
    log "         省掉 go1.4→…→1.24 五段自举（约 40~70 分钟）"
  fi
fi
[ "$GO_DONE" = "0" ] && log "Go     : 未启用（将走源码自举）"

# ===============================================================
# 2. BPF —— 用 host LLVM
#
#    默认会为 BPF 单独编一份 LLVM（很慢）。
#    CONFIG_BPF_TOOLCHAIN_HOST 让它直接用系统的。
# ===============================================================
BPF_DONE=0
if command -v llvm-config >/dev/null 2>&1; then
  LLVM_ROOT=$(llvm-config --prefix 2>/dev/null || true)
  if [ -n "$LLVM_ROOT" ] && [ -x "$LLVM_ROOT/bin/clang" ] \
     && [ -x "$LLVM_ROOT/bin/llc" ]; then
    if grep -rq 'BPF_TOOLCHAIN_HOST' include/ 2>/dev/null; then
      set_cfg CONFIG_BPF_TOOLCHAIN_HOST "y"
      set_cfg CONFIG_BPF_TOOLCHAIN_HOST_PATH "\"$LLVM_ROOT\""
      BPF_DONE=1
      log "BPF    : ✅ host LLVM → $LLVM_ROOT"
    else
      warn "BPF: 该源码树没有 CONFIG_BPF_TOOLCHAIN_HOST，跳过"
    fi
  else
    warn "BPF: llvm-config 给出的前缀不可用，跳过"
  fi
else
  warn "BPF: runner 没有 llvm-config，跳过（需 apt 安装 llvm）"
fi
[ "$BPF_DONE" = "0" ] && log "BPF    : 未启用"

# ===============================================================
# 3. Python —— 关掉 host 侧 PGO
#
#    --enable-optimizations 会让 host python 跑一遍 PGO
#    profile，纯属浪费（host python 只是构建工具）。
# ===============================================================
PY_DONE=0
PY_MK=""
for m in feeds/packages/lang/python/python3/Makefile \
         package/feeds/packages/python/python3/Makefile; do
  [ -f "$m" ] && { PY_MK="$m"; break; }
done

if [ -n "$PY_MK" ] && grep -q 'enable-optimizations' "$PY_MK"; then
  # 只改 HOST_CONFIGURE_ARGS 那一段，别动 target 侧的
  sed -i '/^HOST_CONFIGURE_ARGS[[:space:]]*+=/,/^$/s/--enable-optimizations/--disable-optimizations/' "$PY_MK"
  if grep -q 'disable-optimizations' "$PY_MK"; then
    PY_DONE=1
    log "Python : ✅ host 侧 PGO 已关闭"
  else
    warn "Python: 替换失败，保持原样"
  fi
else
  log "Python : 未启用（该树没有 --enable-optimizations）"
fi

# ===============================================================
# 4. ccache —— 长期累计
# ===============================================================
if grep -q 'CONFIG_CCACHE' .config 2>/dev/null; then
  set_cfg CONFIG_CCACHE "y"
  log "ccache : ✅ 已启用"
fi

log ""
log "===== 汇总 ====="
log "Go     : $([ "$GO_DONE" = 1 ] && echo 生效 || echo 未启用)"
log "BPF    : $([ "$BPF_DONE" = 1 ] && echo 生效 || echo 未启用)"
log "Python : $([ "$PY_DONE" = 1 ] && echo 生效 || echo 未启用)"

exit 0

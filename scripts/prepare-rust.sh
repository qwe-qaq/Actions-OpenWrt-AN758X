#!/usr/bin/env bash
# =============================================================
# prepare-rust.sh —— 用 runner 的 rustup 替代 rustc 源码自举（省 30~60 分钟）
#
#   关键：target triple 必须向 feed 要、不能自己拼 —— 读
#   feeds/packages/lang/rust/rust-values.mk 的 RUSTC_TARGET_ARCH，
#   才能保证 CI 装的 target 与 OpenWrt 期望的一致。
# ★ 全部软失败：rustup 缺失 / feed 结构不同 / 目标装不上，都只 warning 并
#   退回源码自举。用法: bash prepare-rust.sh <openwrt_dir>
# =============================================================

set -uo pipefail

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPORT_DIR="${GITHUB_WORKSPACE:-$OW}/build-reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/rust-toolchain.txt"

log() { echo "$1" | tee -a "$REPORT"; }
warn() { echo "::warning::$1"; echo "跳过: $1" >> "$REPORT"; }

# 「退回源码自举」必须真的让 OpenWrt 重编 rust：缓存恢复的 staging_dir 常带着
# 上一轮的 .rust_installed 戳，只打一行 warning 什么都不做的话，package/compile
# 认为 rust 已就绪、0.03 秒跳过 —— 于是拿着一个没有目标 std 的旧 rustc 去编
# Rust 包，报 error[E0463]: can't find crate for `std`（run #292 就是这么挂的）。
clear_rust_stamps() {
  for d in "$PWD"/staging_dir/host/stamp "$PWD"/staging_dir/hostpkg/stamp; do
    [ -d "$d" ] && rm -f "$d"/.rust_* 2>/dev/null
  done
  return 0
}
# 报告落到 build-logs（成功/退回复源都做）：失败时随 artifact 上传，
# 下次不用再猜「到底用的哪个 rustc、有没有目标 std」。
save_report() {
  local d="${GITHUB_WORKSPACE:-$PWD}/build-logs"
  mkdir -p "$d" 2>/dev/null && cp -f "$REPORT" "$d/rust-toolchain.txt" 2>/dev/null
  return 0
}
bail() { warn "$1"; clear_rust_stamps; save_report; exit 0; }

: > "$REPORT"
log "===== Rust 预编译工具链 ====="

# ---------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------
RUST_FEED="$PWD/feeds/packages/lang/rust"
if [ ! -f "$RUST_FEED/Makefile" ]; then
  warn "Rust: 树里没有 feeds/packages/lang/rust，跳过"
  exit 0
fi

if [ ! -f "$RUST_FEED/rust-values.mk" ]; then
  bail "Rust: 缺 rust-values.mk（拿不到 RUSTC_TARGET_ARCH），退回源码自举"
fi

# ---------------------------------------------------------------
# 1. 向 feed 要 target triple
#
#   REAL_GNU_TARGET_NAME 依赖 ARCH，而 ARCH 不在 .config 里 —— 它由
#   target/linux/<board>[/<subtarget>]/target.mk 赋值。只 include rules.mk 时
#   ARCH 为空，算出来是 "-unknown-linux"，rustup 把开头的 '-' 当选项拆：
#     error: unexpected argument '-u' found
#   所以必须带 BOARD/SUBTARGET 让 target.mk 一起展开；万一还是拿不到，
#   就从 target.mk 里直接读 ARCH 兜底（rust-values.mk 也是拿它拼的）。
# ---------------------------------------------------------------
BOARD=""
for b in $(sed -n 's/^CONFIG_TARGET_\([a-zA-Z0-9_]*\)=y$/\1/p' .config 2>/dev/null); do
  [ -f "target/linux/$b/Makefile" ] && { BOARD="$b"; break; }
done

SUBTARGET=""
if [ -n "$BOARD" ]; then
  SUBTARGET=$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"$/\1/p' .config 2>/dev/null | head -1)
  if [ -z "$SUBTARGET" ]; then
    for s in $(sed -n "s/^CONFIG_TARGET_${BOARD}_\([a-zA-Z0-9_]*\)=y$/\1/p" .config 2>/dev/null); do
      [ -f "target/linux/$BOARD/$s/target.mk" ] && { SUBTARGET="$s"; break; }
    done
  fi
fi

LIBC=gnu
grep -q '^CONFIG_USE_MUSL=y' .config 2>/dev/null && LIBC=musl

RUST_TARGET=""
if [ -n "$BOARD" ]; then
  RUST_TARGET=$(make --no-print-directory -s -f - \
    TOPDIR="$PWD" BOARD="$BOARD" SUBTARGET="$SUBTARGET" ci-rust-target 2>/dev/null <<'MAKE'
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/target.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: ci-rust-target
ci-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
)
  RUST_TARGET=$(printf '%s' "$RUST_TARGET" | tr -d '\r' | head -1)
fi

# 部分树 TARGET_SUFFIX 为空，算出来停在 <arch>-unknown-linux，补上 libc 段
case "$RUST_TARGET" in
  *-linux) RUST_TARGET="${RUST_TARGET}-${LIBC}" ;;
esac

if ! printf '%s' "$RUST_TARGET" | grep -qE '^[a-z0-9_]+-[a-z0-9_]+-linux-[a-z]+$'; then
  ARCH_SRC="target/linux/$BOARD/$SUBTARGET/target.mk"
  [ -f "$ARCH_SRC" ] || ARCH_SRC="target/linux/$BOARD/Makefile"
  A=$(sed -n 's/^ARCH[[:space:]]*:*=[[:space:]]*\([a-zA-Z0-9_]*\).*/\1/p' "$ARCH_SRC" 2>/dev/null | tail -1)
  case "$A" in
    "")      RUST_TARGET="" ;;
    riscv64) RUST_TARGET="riscv64gc-unknown-linux-${LIBC}" ;;
    i386)    RUST_TARGET="i586-unknown-linux-${LIBC}" ;;
    *)       RUST_TARGET="${A}-unknown-linux-${LIBC}" ;;
  esac
  [ -n "$RUST_TARGET" ] && log "Rust: make 没给出 triple，按 $ARCH_SRC 的 ARCH 推导: $RUST_TARGET"
fi

if [ -z "$RUST_TARGET" ]; then
  bail "Rust: 拿不到 target triple（BOARD='$BOARD' SUBTARGET='$SUBTARGET'），退回源码自举"
fi
log "Rust target: $RUST_TARGET"

# ---------------------------------------------------------------
# 2. 找 rustup（runner 预装，但 PATH 未必包含 ~/.cargo/bin）
# ---------------------------------------------------------------
RUSTUP_BIN=$(command -v rustup || true)
if [ -z "$RUSTUP_BIN" ]; then
  for c in "$HOME/.cargo/bin/rustup" /usr/bin/rustup /usr/local/bin/rustup; do
    [ -x "$c" ] && { RUSTUP_BIN=$c; break; }
  done
fi
if [ -z "$RUSTUP_BIN" ]; then
  bail "Rust: runner 没有 rustup（需 apt 安装 rustup），退回源码自举"
fi
PATH="$(dirname "$RUSTUP_BIN"):$PATH"; export PATH

RUST_TOOLCHAIN=$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')
[ -n "$RUST_TOOLCHAIN" ] || RUST_TOOLCHAIN=stable
log "Rust toolchain: $RUST_TOOLCHAIN"

# ---------------------------------------------------------------
# 3. 装对应的 target
# ---------------------------------------------------------------
if ! rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET" 2>&1 | tee -a "$REPORT"; then
  bail "Rust: rustup target add $RUST_TARGET 失败，退回源码自举"
fi

RUST_ROOT=$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot 2>/dev/null)
if [ -z "$RUST_ROOT" ] || [ ! -d "$RUST_ROOT" ]; then
  bail "Rust: rustc --print sysroot 失败，退回源码自举"
fi

# ---------------------------------------------------------------
# 4. 校验：target 的 std 与三个工具必须真的在
#    否则后面编译会因为缺 std 而失败，不如现在就退回
# ---------------------------------------------------------------
if [ ! -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib" ]; then
  bail "Rust: 缺 $RUST_TARGET 的 std（$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib），退回源码自举"
fi
for t in cargo rustc rustdoc; do
  if [ ! -x "$RUST_ROOT/bin/$t" ]; then
    bail "Rust: 缺 $RUST_ROOT/bin/$t，退回源码自举"
  fi
done

# ---------------------------------------------------------------
# 4.4 可选：按 feed 的版本另装一个 toolchain（RUST_PIN_FEED=1）
#
#   默认用 runner 的 stable —— 0 秒，够用。但 stable 会随镜像升级，
#   同一个 commit 隔几周编出来的 rust 二进制 codegen 可能不同。
#   要求「产物可复现 / 与官方构建逐字节接近」时打开这个开关：
#   它读 feeds/packages/lang/rust/Makefile 的 PKG_VERSION，
#   装一个同版本 toolchain（约 1~3 分钟），失败就退回 runner 的。
# ---------------------------------------------------------------
if [ "${RUST_PIN_FEED:-0}" = "1" ]; then
  FEED_VER=$(sed -n 's/^PKG_VERSION:=//p' "$RUST_FEED/Makefile" 2>/dev/null | head -1 | tr -d ' \r')
  PIN_OK=0
  if [ -z "$FEED_VER" ]; then
    warn "Rust: 读不到 feed 的 PKG_VERSION，继续用 runner 的 $RUST_TOOLCHAIN"
  else
    if ! rustup run "$FEED_VER" rustc --version >/dev/null 2>&1; then
      log "按 feed 版本安装 toolchain: $FEED_VER"
      rustup toolchain install "$FEED_VER" --profile minimal >>"$REPORT" 2>&1 || true
    fi
    # 无论是不是刚装的，都要确认这个 toolchain 上有目标平台的 std
    rustup target add --toolchain "$FEED_VER" "$RUST_TARGET" >>"$REPORT" 2>&1 || true
    PIN_ROOT=$(rustup run "$FEED_VER" rustc --print sysroot 2>/dev/null || true)
    if [ -n "$PIN_ROOT" ] && [ -d "$PIN_ROOT/lib/rustlib/$RUST_TARGET/lib" ] \
       && [ -x "$PIN_ROOT/bin/rustc" ]; then
      RUST_TOOLCHAIN=$FEED_VER
      RUST_ROOT=$PIN_ROOT
      PIN_OK=1
      log "已切到 feed 版本: rustc $("$RUST_ROOT/bin/rustc" --version 2>&1)"
    fi
    [ "$PIN_OK" = 1 ] || warn "Rust: $FEED_VER 不可用（或没有 $RUST_TARGET 的 std），继续用 runner 的 $RUST_TOOLCHAIN"
  fi
fi

# ---------------------------------------------------------------
# 4.5 把 staging_dir 里那三个 rust 入口无条件改指向刚验证过的 toolchain
#   缓存命中时 host/bin/rustc 是上次构建留下的东西：可能是指向别的 toolchain
#   的符号链接，也可能是自举出来的真二进制（sysroot = staging_dir/host，里面
#   没有目标 std）。两种情况都会让 Rust 包报 E0463。Host/Install 只在 stamp
#   失效时才重跑、不会自己修，所以这里直接改写，并把 .rust_installed 清掉让
#   OpenWrt 也认这个新链接。
# ---------------------------------------------------------------
HOSTBIN="$PWD/staging_dir/host/bin"
mkdir -p "$HOSTBIN"
for t in cargo rustc rustdoc; do
  ln -sfn "$RUST_ROOT/bin/$t" "$HOSTBIN/$t"
done
# 戳不清掉，Host/Install 不重跑，链接就还是缓存里那个（指向上一个 toolchain）
rm -f "$PWD"/staging_dir/host/stamp/.rust_installed "$PWD"/staging_dir/hostpkg/stamp/.rust_installed 2>/dev/null

EFF="$HOSTBIN/rustc"
SYSROOT=$("$EFF" --print sysroot 2>/dev/null || true)
log "实际使用的 rustc: $("$EFF" --version 2>&1 | head -1)"
log "其 sysroot: ${SYSROOT:-未知}"

# 冒烟：--emit=metadata 不链接，2 秒就能证伪 —— 缺 std 在这儿暴露，
# 而不是等 45 分钟后在 airoha-ponctl 里报 E0463
if printf 'pub fn ci_probe() {}\n' > "$REPORT_DIR/stdprobe.rs" 2>/dev/null; then
  if "$EFF" --target "$RUST_TARGET" --crate-type lib --emit=metadata \
       -o "$REPORT_DIR/stdprobe.rmeta" "$REPORT_DIR/stdprobe.rs" >>"$REPORT" 2>&1; then
    log "✅ std 冒烟通过：$RUST_TARGET 可编译"
  else
    bail "Rust: $RUST_TARGET 冒烟失败（$SYSROOT 里没有可用的 std），退回源码自举"
  fi
fi

# ---------------------------------------------------------------
# 4.6 版本对照：feed 期望的 rustc vs runner 实际提供的
#   runner 的 stable 省 30~60 分钟，但不一定等于 feed pin 的版本 —— codegen
#   随版本变，产物不完全相同；极少数 crate 在新版上会报错（版本相关，不是
#   静默错误）。两个版本号并排打出来，出问题时一眼能判断是不是版本引起的。
# ---------------------------------------------------------------
FEED_RUST_VER=$(sed -n 's/^PKG_VERSION:=//p' "$RUST_FEED/Makefile" 2>/dev/null | head -1 | tr -d ' \r')
RUNNER_RUST_VER=$("$RUST_ROOT/bin/rustc" --version 2>/dev/null | awk '{print $2}')
log "rustc 版本：feed 期望 ${FEED_RUST_VER:-未知} ｜ 实际使用 ${RUNNER_RUST_VER:-未知}"
if [ -n "${FEED_RUST_VER:-}" ] && [ -n "${RUNNER_RUST_VER:-}" ] \
   && [ "$FEED_RUST_VER" != "$RUNNER_RUST_VER" ]; then
  log "  两者不同属正常（这就是省下 30~60 分钟的原因）；若 rust 包编译报版本相关错误，"
  log "  把 workflow 的 RUST_PIN_FEED 设为 1，会按 feed 的版本另装一个 toolchain。"
fi

# ---------------------------------------------------------------
# 5. 注入 ci-prebuilt.mk，替换源码自举
#
#    必须在 OpenWrt 展开 HostBuild 规则【之前】插入，
#    所以 sed 插到 $(eval $(call HostBuild)) 之前。
# ---------------------------------------------------------------
{
  printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
  cat "$SCRIPT_DIR/rust-prebuilt.mk"
} > "$RUST_FEED/ci-prebuilt.mk"

RUST_MAKEFILE="$RUST_FEED/Makefile"
# perl 需要从环境里拿这两个字面量（避免 shell 转义把 $ 吃掉）
export CI_MARKER='include ./ci-prebuilt.mk'
export CI_HOSTBUILD='$(eval $(call HostBuild))'

# ⚠ 必须用 perl，不能用 sed -i：
#   GNU sed 处理含 `$` 的模式（$(eval $(call HostBuild))）时，
#   -i 原地模式下 i\ 命令会静默失效 —— 实测插入不进去且不报错。
#   perl 的 \Q...\E 把整串当字面量，可靠得多。
MARKER='include ./ci-prebuilt.mk'
HOSTBUILD='$(eval $(call HostBuild))'

perl -i -pe '
  BEGIN { $m = quotemeta($ENV{"CI_MARKER"}); $h = quotemeta($ENV{"CI_HOSTBUILD"}); }
  if ($_ =~ /^$m$/) { $_ = ""; }                 # 先删掉旧的（幂等）
  elsif ($_ =~ /^$h$/) { $_ = "$ENV{CI_MARKER}\n" . $_; }   # 再插到 HostBuild 之前
' "$RUST_MAKEFILE"

if ! grep -Fxq "$MARKER" "$RUST_MAKEFILE"; then
  bail "Rust: 注入 ci-prebuilt.mk 失败，退回源码自举"
fi
# ⚠ 别把 $HOSTBUILD 直接放进带 $(...) 的字符串：
#   它的内容是字面量 $(eval $(call HostBuild))，
#   双引号里的 $(...) 会被 shell 当命令替换执行，
#   直接报 "意外令牌附近语法错误 '('"（第147行就是这么炸的）。
log "注入: $MARKER（在 HostBuild 求值之前）"

"$RUST_ROOT/bin/rustc" --version | tee -a "$REPORT"
log "✅ 使用 runner 的 Rust（$RUST_TOOLCHAIN），跳过源码自举（省 30~60 分钟）"
sha256sum "$RUST_MAKEFILE" >> "$REPORT"

save_report
exit 0

# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`）。
产出 AN7581 / AN7583 PON 光猫的 OpenWrt 固件，带机型选择、磁盘释放和滚动构建缓存。

## 快速开始

免费 runner 单次上限 6 小时（job 350 分钟），首次全量编译（工具链 + 内核 + 全包）大概率超时，按这个顺序跑：

1. **Warm Build Cache** → `soc=an7581和an7583`、`prebuilt_host=预编译`，把工具链缓存建起来
2. **Build PonWrt** → 选 `soc` / `profile` → `scope=firmware` 出固件
3. 仍然超时：把 `configs/*.config` 里不需要的 luci-app / 语言包删掉再提交

> 不预热也能直接跑 `firmware`——缓存是滚动式的，第一次跑完会自动存下工具链。预热只是给怕超时的人用的。

## 输入项

### `build-ponwrt.yml`

| 输入 | 取值 | 说明 |
|---|---|---|
| `source` | `pbs05/ponwrt` / `fork` | 编译哪个源码仓库。**必须和缓存预热时选的一致**，否则前缀对不上 |
| `branch` | 默认 `master` | |
| `soc` | `an7581` / `an7583` | |
| `profile` | 见下方机型表，`all` = 全机型 | 写错会在 `Validate configuration` 直接报错退出，不会静默全编 |
| `scope` | `firmware` / `toolchain-only` | 后者只建工具链缓存，不出固件、不发 Release |
| `prebuilt_host` | `true`（默认）/ `false` | `true` 用 runner 的 Go/Rust/LLVM，快 1.5~2.5 小时；`false` 全部从源码编，产物可复现 |
| `ignore_cache` | `false` / `true` | 跳过缓存恢复强制重编（仍会存新一代） |
| `upload_release` | `true` / `false` | `false` 只留 Artifact |
| `opt_arm64ce` / `opt_chacha` / `opt_eip93` | `0` / `1` | 加密加速，见文末 |

### 四个工作流

| 工作流 | 触发 | 作用 |
|---|---|---|
| `build-ponwrt.yml` | 手动 | 恢复缓存 → 编译 → 存缓存 → 轮换旧代 |
| `warm-cache.yml` | 手动 / 每周一 03:17 | 预热。`soc` 和 `prebuilt_host` 都是三选一，两个都选「和」的选项 = 4 个 job 并行 |
| `cache-keepalive.yml` | 每 3 天 | 逐条真实恢复，避开 `actions/cache` 的 7 天未访问回收 |
| `cache-clean.yml` | 手动 / 每周一 04:20 | `rollover` 每族留最新一代 / `backup` 只清 Release 备份 / `all` 全删 |

## 支持的机型

| SoC | profile |
|---|---|
| AN7581 | `fiberhome_hg5382a` `fiberhome_an4475-g2`† `fiberhome_hg5585f-ct` `fiberhome_hg5585f-cu` `gemtek_xg2010g` `nokia_xg-040g-md-ubi` `nokia_xg-040g-tf-ubi` `unionman_ung00a` `znxt_zn504xg-d` `znxt_zn515xg-d` `h3c_hm2004-du`※ |
| AN7583 | `nokia_xg-040g-mf` `nokia_xg-040g-mf-ubi` |

※ `h3c_hm2004-du` 额外依赖私有仓库 `openwrt-fttr`（FTTR 驱动 / 控制端 / FPGA 固件）与 `luci-app-fttr`，缺凭证时 `diy-part1.sh` 会直接报错退出。

† `fiberhome_an4475-g2` 的板级 DTS / profile 在 **`qwe-qaq/ponwrt@master`**，构建时 `source` 必须选 `fork`（`pbs05/ponwrt` 尚未合入，会在 `Validate configuration` 阶段因机型符号不存在而失败）。`factory` UBI 卷为 **2 MiB**（AN4-2MiB 容器）。FTTR 后端三件套（`h3c-fmcs` / `openwrt-fttr` / FPGA 固件）是 HM2004-DU 专属，本机用 SoC 内置下行 PON，**不启用** `ADD_FTTR`。

## 插件开关（`diy-part1.sh`）

全部默认开启，开关与 `configs/an7581.config` / `an7583.config` 里的 `=y` 一一对应：

| 开关 | 包 | 备注 |
|---|---|---|
| `ADD_AIROHA_NPU` | `luci-app-airoha-npu` | NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表 |
| `ADD_LUCI_APP` | `luci-app-natmode`、`luci-app-pon-status`、`luci-app-igmpproxy` | NAT 类型三选一、PON 光模块卡片、IGMP Proxy 组播代理 Web 界面 |
| `ADD_FLUENT` | `luci-theme-fluent` | 与 `argon` / `bootstrap` 可共存 |
| `ADD_PASSWALL` | `luci-app-passwall` + `xray-core` / `sing-box` | 新版 passwall 把内核做成按需安装，config 里另开了两个 feeds 现成的 |
| `ADD_OPENCLASH` | `luci-app-openclash` | ⚠ 拖 Ruby 进构建，首次 +20~40 分钟 |
| `ADD_MOSDNS` | `luci-app-mosdns` | 本体用 feeds 的 `mosdns` |
| `ADD_SMARTDNS` | `luci-app-smartdns` | 本体用 feeds 的 `smartdns` |
| `ADD_TAILSCALE` | `luci-app-tailscale` | 本体用 feeds 的 `tailscale` |
| `ADD_LUCKY` | `luci-app-lucky` | 含 `lucky` 本体 |
| `ADD_OPENLIST` | `luci-app-openlist2` | 含 `openlist2` 本体 |
| `ADD_EASYTIER` | `luci-app-easytier` + `easytier` | 本体是 Rust 包，编译较慢 |
| `ADD_POWEROFF` / `ADD_OWQ_WOL` / `ADD_WATCHDOG` / `ADD_TASKPLAN` | 同名 `luci-app-*` | |
| `ADD_OAF` | `luci-app-oaf` + `appfilter` / `kmod-oaf` | 含内核模块 |

**要关掉某个插件，改两处**：脚本里 `ADD_xxx=false`，**并且**把两个通用 config 里对应的
`CONFIG_PACKAGE_xxx=y` 删掉（或改成 `# ...is not set`）。只改一处会不一致：
只关脚本 → `make defconfig` 把 `=y` 静默剔除；只关 config → 白 clone 一个仓库。

**四个「只用 feeds」的包**（`MOSDNS` / `SMARTDNS` / `PASSWALL` / `TAILSCALE`）：它们的本体
（`mosdns` / `smartdns` / `xray-core` / `sing-box` / `tailscale`）feeds 里已有同名包，
第三方源再拉一份会让索引里出现两个同名 `Package`，`package-metadata` 按扫描顺序挑一个、
行为不可预期。所以脚本只拷 luci 前端，本体一律用 feeds 的。

`ADD_FTTR` 及其子开关只在 `h3c_hm2004-du` 下生效，其余机型自动跳过。

## 构建缓存（移植自 VIKINGYFY/OpenWRT-CI）

一份缓存 = 三个目录：

```
staging_dir/host*      host 工具 + hostpkg（go / python 在这）
staging_dir/tool*      交叉编译器
.ccache                编译对象缓存
```

**tools / toolchain 会不会重编，取决于 `staging_dir` 里的 compile 戳，不取决于缓存里
有没有 `build_dir`。** `make world` 的 `prepare` 依赖
`staging_dir/host/stamp/.tools_compile_<flags>` 和 `staging_dir/toolchain-*/stamp/.toolchain_compile`，
这两个戳存在且比源码树新，`tools/compile` 与 `toolchain/compile` 就整段跳过。

**但 host 包（golang / rust / python3）是另一回事。** 它们有四个戳，被拆在两处：
`staging_dir/hostpkg/stamp/.<pkg>_installed` 跟着缓存走，而
`build_dir/host/<pkg>/.built`、`.configured`、`.prepared_<md5>` 不在缓存路径里。
依赖链是 `installed ← built ← configured ← prepared`，缺了 built 这一层，make 就认为没编过，
整条链重做。**这就是 source 模式比 prebuilt 慢 20~40 分钟、多写 13~14 GB 的原因**——
golang 和 rust 每轮都在从源码自举。

所以 source 模式在编译结束时会把这三个戳单独冻一份到
`staging_dir/host/.builddir-stamps/`（只冻戳，不冻内容：100 来个包 × 3 个空文件，
压缩后不到 10 KB），下一轮 `prepare` 原样还原，mtime 保持不变。
**prebuilt 模式不冻**——那里的 go/rust 是指向 runner 的符号链接，换镜像后可能悬空，
宁可让同一条链重跑一遍自愈（`rust-prebuilt.mk` 已把 Prepare/Configure/Compile 置空，只花几秒）。

**精确命中 = 这份缓存就是当前这个提交编出来的**，两条通道都算：`actions/cache` 的
`cache-hit=true`，或 Release 资产名去掉 `.tzst` 后与本次 key 完全相同。只有精确命中时
`prepare` 才保留这两个戳；前缀回退、或 Release 取到的是旧代，都说明源码已变，脚本会删掉
它们迫使 make 重编（约 26 分钟，ccache 会加速）。当前提交通常在第一次构建时付这 26 分钟，
之后同提交重跑都是 0 分钟。

> 冻进去的 `build_dir` 戳不会误跳编译：`.prepared` 的文件名里带着包源码目录的内容 MD5
> （`PKG_FILES_MD5`），上游一改源码戳名就对不上，make 自然重建。target 侧的戳则完全不在
> 缓存里，所以固件包每轮照常重编。

| 通道 | 介质 | 特点 |
|---|---|---|
| ① 快通道 | `actions/cache` | 秒级，但 **7 天无访问即回收** |
| ② 备份通道 | Release `cache-backup` 资产 | 慢（~1 GB），**永不过期** |

恢复 ①→②，保存时两条都写（② 失败只 warning）。key 规则：

| | key |
|---|---|
| 写入 | `ponwrt-<源站>-<分支>-<SoC>-<prebuilt\|source>-<上游提交号>` |
| 恢复 | 同上前缀 + `-`（**前缀回退**） |

前缀不含配置、机型、diy 脚本——改这些不会让缓存失效；上游一提交就换一代，靠 `restore-keys` 回退到最近一代。旧代由 `cache-rollover` job 删掉，保证每个前缀只留一份。

**恢复后必须做三件事**（`scripts/pwrt-cache.sh prepare`），少一件就等于白命中：touch 非 target 的 stamp、写 `tmp/.build`、touch 目录本身。

**dl 缓存**（源码包，2~5 GB）单独一条，key 按周滚动 `ponwrt-dl-<源站 slug>-<分支>-<YYYYWW>`（`pbs05/ponwrt` → `pbs05-ponwrt`，与工具链 key 同一套规则）。保存在 `make download` 之后、编译之前——350 分钟一到 job 直接 cancel，放最后用 `always()` 也来不及跑。

**两种 host 模式不共用缓存**：`HOST_MODE` 进前缀。prebuilt 在 `staging_dir` 里留的是指向 runner 的符号链接，source 留的是真二进制，混用会让 make 误判「已安装」并在编译期报一个完全对不上的错。**warm-cache 必须和主流程选同一个模式**，否则预热白跑。

**rust 包的离线限制**：`openwrt-fttr` 的 Makefile 用 `cargo install --locked --frozen`，`--frozen` 禁止联网、只认 `dl/cargo` 里已有的 crate。`scripts/patch-cargo-offline.sh` 把 `--frozen` / `--offline` 摘掉，`--locked` 保留（版本仍锁死）。

## 客制化

| 位置 | 做了什么 |
|---|---|
| `files/sbin/cpuusage` + `scripts/patch-luci-cpuusage.sh` | 概览页 CPU 行改为 `USR: 2% SYS: 1% · CPU0 3% CPU1 0%…`（两次 `/proc/stat` 采差值，USR=`user+nice`、SYS=`system+irq+softirq`）。补丁只换 `popen()` 里一个命令字符串，前端和 ACL 都不动；任一环节失败只 warning，构建不受影响 |
| `files/sbin/tempinfo` | 概览页温度行：CPU / WiFi / PON 三个温度。顶部 `SHOW_PON_OPTICS=1` 可附带收发光/电流/电压（默认 0，因为 `luci-app-pon-status` 卡片已经完整展示，重复） |
| `diy-part2.sh` | 默认时区 `Asia/Shanghai`、5G 国家码 `CN` / 信道 `auto` / 频宽 `HE160`（不支持时回落到 `HE80`）、固件版本后缀追加作者与构建时间 |
| `files/etc/uci-defaults/` | 首启强制刷时区与无线参数的兜底脚本 |

## NPU 固件

NPU 是 Airoha SoC 里的 RISC-V 核，host 侧驱动随内核编出，按固定名字找两个镜像：

| 镜像 | 文件名 | 上限 |
|---|---|---|
| rv32（text+rodata） | `airoha/en7581_npu_rv32.bin`（AN7583 为 `an7583_*`） | 2 MiB |
| data | `airoha/en7581_npu_data.bin` | 64 KiB |

由 ponwrt 自带的 linux-firmware 提供，在 `configs/<机型>.config` 写 `CONFIG_PACKAGE_airoha-en7581-npu-firmware=y` 即装进 rootfs。工作流不介入固件生成——要换就改这一行。

```sh
dmesg | grep -i npu           # probe 时打 fw version
ls -l /lib/firmware/airoha/   # 两个 bin 在位
```

缺文件或名字不符 → `-ENOENT` → 映射成 `-EPROBE_DEFER`，NPU 一直不绑定（`deferred probe pending` 里能看到具体文件名）；超限 → `-E2BIG`。

## 加密加速（可选）

| 开关 | 建议 | 适用 |
|---|---|---|
| `opt_arm64ce` | 改 `1` | IPSec / OpenVPN / TLS / dm-crypt，几乎总是开 |
| `opt_chacha` | 改 `1` | 跑 Xray / sing-box / WireGuard |
| `opt_eip93` | 保持 `0` | 只有大块 IPSec / 大文件 TLS 才有收益 |

**AN7581 和 AN7583 不一样**：AN7581 的 `/proc/cpuinfo` 里没有 `aes`，`/proc/crypto` 只有 `aes-generic`，单核 AES-128-GCM 约 32 MB/s，只能走 NEON 位切片（`AES_ARM64_BS`）；AN7583 有 `aes pmull sha1 sha2`，同样测试约 548 MB/s，可以走 Crypto Extensions。脚本读 `.config` 自动判断，不用手动切。

**EIP93 是个陷阱**：AN7581 确实内置（`crypto@1e004000`），但实测 AES 要 ≥512 字节才快过软件，MD5/SHA1/SHA2 在所有尺寸下都是软件更快，代理流量开着只会更慢。

验证：

```sh
grep -ao 'aes\|pmull\|sha1\|sha2' /proc/cpuinfo | sort -u   # AN7581 不会有 aes
cat /proc/crypto | grep -E '^name|^driver|^priority'
openssl speed -evp aes-128-gcm
openssl speed -evp chacha20-poly1305
```

> `CONFIG_CRYPTO_*` 是**内核编译符号**，必须写进 `target/linux/airoha/an7581/config-<kver>`。写进顶层 `.config` 会被 target config 覆盖——看起来配上了，实际不生效。

## 排错

| 症状 | 先看哪里 |
|---|---|
| `defconfig` 失败 | 日志里 `make defconfig` 那段的尾部 60 行 + 根因提示（`scripts/defconfig.sh` 输出） |
| 关键包「未启用，检查 feeds」 | 多数是上一步 defconfig 失败的连带；独立出现时查 `tmp/.packageinfo` 里有没有该包 |
| `Failed to download` / 编译期报缺 crate | `make download` 三次都失败会直接 error 退出，去那段输出搜 `ERROR:` |
| 缓存「命中」却仍然全量重编 | `prepare` 那步的三件事是否都做了；`Build host go/rust from source` 的 warning |
| 缓存永远 miss | `source` / `branch` / `soc` / `prebuilt_host` 四项是否和预热时一致 |
| `artifacts` 上传失败 | Artifact 存储配额（默认保留 90 天，几份固件就可能超） |
| NPU 不绑定 | `dmesg \| grep -i npu`、`/lib/firmware/airoha/` 里的文件名和大小 |

## 已知限制

- 只有 `scope=firmware` 且编译成功才发 Release；`toolchain-only` 不发，空固件目录会跳过。
- Release tag 固定为 `<机型>-<分支>`，每次覆盖，所以每个机型只有一份固件，不是「保留最近 N 份」。
- NPU 只在三层路由模式生效，纯 AP 桥接时整机吞吐会掉到 2000 Mbps 左右。
- `repository_dispatch` 触发时所有 choice 输入都是空，走的是各 env 的回退值。

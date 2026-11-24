#!/usr/bin/env bash
# ================================================================
# marble 内核功能补丁应用器
#
# 在调用上游 build_bouquet.sh 之前执行。marble.yml 改为不使用
# build_bouquet.sh 的 --ksu/--susfs 选项（那两个会安装
# kernel_tree_cleanup trap，退出时 git checkout 还原 fs/ drivers/
# include/ kernel/ security/ mm/），因此本脚本只需在首轮编译前
# 应用一次，补丁即可跨三轮编译存活。
#
# 设计约束：
#   - 幂等：重复执行不产生副作用
#   - 不依赖 GKI 的 common/ 前缀（marble 内核树根即 common）
#   - 任一功能失败时按 --skip-incompatible 决定跳过或中断
#
# 不在此脚本内的功能：
#   - KernelSU / SUSFS 变体集成 -> ksu_variant.sh
#   - CVE-2026-43499            -> 由 marble.yml 直接调用 apply_cve_2026_43499.sh
#   - build_time                -> 由 marble.yml 直接改 scripts/mkcompile_h
# ================================================================
set -uo pipefail

KROOT=""
DEFCONFIG_NAME="marble_defconfig"
KVER="5.10"
AVER="android12"
SKIP_INCOMPATIBLE="true"
PATCHES_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

DO_BBG=0
DO_REKERNEL=0
DO_NOMOUNT=0
DO_ZRAM=0
DO_NET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel-root)       KROOT="$2"; shift 2 ;;
    --defconfig)         DEFCONFIG_NAME="$2"; shift 2 ;;
    --kernel-version)    KVER="$2"; shift 2 ;;
    --android-version)   AVER="$2"; shift 2 ;;
    --skip-incompatible) SKIP_INCOMPATIBLE="$2"; shift 2 ;;
    --patches-root)      PATCHES_ROOT="$2"; shift 2 ;;
    --bbg)               DO_BBG=1; shift ;;
    --rekernel)          DO_REKERNEL=1; shift ;;
    --nomount)           DO_NOMOUNT=1; shift ;;
    --zram)              DO_ZRAM=1; shift ;;
    --net-enhance)       DO_NET=1; shift ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KROOT" ] || { echo "--kernel-root 必填" >&2; exit 2; }
[ -d "$KROOT" ] || { echo "内核树不存在: $KROOT" >&2; exit 2; }

DEFCONFIG="$KROOT/arch/arm64/configs/$DEFCONFIG_NAME"
[ -f "$DEFCONFIG" ] || { echo "defconfig 不存在: $DEFCONFIG" >&2; exit 2; }

FAILED=0

# 功能失败处理：可跳过时写摘要并返回 0，否则记失败
feat_fail() {
  local feat="$1" msg="$2"
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=${feat} 已跳过::${msg}（构建未中断）"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **${feat}** 已自动跳过：${msg}（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi
  echo "::error::${feat}: ${msg}" >&2
  FAILED=$((FAILED + 1))
  return 1
}

# 在 defconfig 中写入一个配置项（幂等）
set_config() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$DEFCONFIG"; then
    [ "$(grep -m1 "^${key}=" "$DEFCONFIG" | cut -d= -f2-)" = "$val" ] \
      || sed -i "s|^${key}=.*|${key}=${val}|" "$DEFCONFIG"
  elif grep -q "^# ${key} is not set" "$DEFCONFIG"; then
    sed -i "s|^# ${key} is not set|${key}=${val}|" "$DEFCONFIG"
  else
    echo "${key}=${val}" >> "$DEFCONFIG"
  fi
}

# 关闭一个配置项（幂等）
unset_config() {
  local key="$1"
  if grep -q "^${key}=" "$DEFCONFIG"; then
    sed -i "s|^${key}=.*|# ${key} is not set|" "$DEFCONFIG"
  elif ! grep -q "^# ${key} is not set" "$DEFCONFIG"; then
    echo "# ${key} is not set" >> "$DEFCONFIG"
  fi
}

# 只有当 Kconfig 中确实声明了该符号时才写入，避免 config 校验失败
config_defined() {
  local name="${1#CONFIG_}"
  grep -RqsE --include='Kconfig*' \
    "^[[:space:]]*(menuconfig|config)[[:space:]]+${name}$" "$KROOT"
}

enable_if_defined() {
  local cfg="$1"
  if config_defined "$cfg"; then
    set_config "$cfg" y
  else
    echo "  [跳过] 当前内核未定义 $cfg"
  fi
}

# ================================================================
# 1. BBG 基带保护
# ================================================================
feature_bbg() {
  echo "=== [BBG] 基带保护 ==="

  # marble 内核树根即 GKI 的 common/，setup.sh 以 cwd 为基准写入 security/
  local setup=/tmp/marble_bbg_setup.sh
  if ! wget -qO "$setup" https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh; then
    feat_fail "BBG" "安装脚本下载失败"
    return 0
  fi

  local prev_cwd="$PWD"
  cd "$KROOT" || { feat_fail "BBG" "无法进入内核树"; return 0; }
  if ! sh "$setup"; then
    sh "$setup" --cleanup >/dev/null 2>&1 || true
    cd "$prev_cwd"
    feat_fail "BBG" "安装脚本执行失败"
    return 0
  fi

  # 上游脚本可能按 GKI 布局落到了 common/security 下，搬回 security/
  if [ ! -d "security/baseband-guard" ] && [ -d "common/security/baseband-guard" ]; then
    echo "  上游脚本落入 common/security，迁移到 security/"
    mkdir -p security
    mv common/security/baseband-guard security/
    [ -f common/security/Makefile ] && sed -i '\|baseband-guard|d' common/security/Makefile 2>/dev/null || true
    [ -f common/security/Kconfig ] && sed -i '\|baseband-guard|d' common/security/Kconfig 2>/dev/null || true
  fi

  if [ ! -f "security/baseband-guard/Kconfig" ]; then
    cd "$prev_cwd"
    feat_fail "BBG" "安装结果校验失败（security/baseband-guard/Kconfig 缺失，目录结构不适配）"
    return 0
  fi
  if ! grep -q 'baseband-guard' security/Makefile; then
    echo 'obj-$(CONFIG_BBG) += baseband-guard/' >> security/Makefile
  fi

  set_config CONFIG_BBG y

  # 把 baseband_guard 追加到 LSM 默认顺序（幂等）
  if grep -q '^config LSM$' security/Kconfig; then
    if ! grep -q 'baseband_guard' security/Kconfig; then
      sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
    fi
  else
    echo "  [警告] security/Kconfig 无 config LSM 锚点，BBG 的 LSM 注册需人工确认"
  fi

  cd "$prev_cwd"
  grep -q '^CONFIG_BBG=y$' "$DEFCONFIG" || { feat_fail "BBG" "CONFIG_BBG 写入校验失败"; return 0; }
  echo "  [OK] BBG 已集成"
}

# ================================================================
# 2. Re-Kernel 驱动
# ================================================================
feature_rekernel() {
  echo "=== [Re-Kernel] 驱动集成 ==="
  local tmp=/tmp/marble_rekernel
  rm -rf "$tmp"
  if ! git clone --depth 1 https://github.com/Sakion-Team/Re-Kernel.git "$tmp"; then
    feat_fail "Re-Kernel" "仓库克隆失败"
    return 0
  fi

  rm -rf "$KROOT/drivers/rekernel"
  mkdir -p "$KROOT/drivers/rekernel"
  cp -a "$tmp/LKM-Source/." "$KROOT/drivers/rekernel/"

  local mk="$KROOT/drivers/rekernel/Makefile"
  [ -f "$mk" ] || { feat_fail "Re-Kernel" "LKM-Source/Makefile 缺失"; return 0; }
  sed -i 's/^obj-m := rekernel\.o$/obj-$(CONFIG_REKERNEL) += rekernel.o/' "$mk"
  grep -qF 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK)' "$mk" \
    || echo 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' >> "$mk"
  sed -i '/^[[:space:]]*depends on MODULES[[:space:]]*$/d' "$KROOT/drivers/rekernel/Kconfig"

  # 挂载到驱动树（drivers/ 无 common/ 前缀）
  grep -qF 'source "drivers/rekernel/Kconfig"' "$KROOT/drivers/Kconfig" \
    || sed -i '/^endmenu$/i source "drivers/rekernel/Kconfig"' "$KROOT/drivers/Kconfig"
  grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel/' "$KROOT/drivers/Makefile" \
    || echo 'obj-$(CONFIG_REKERNEL) += rekernel/' >> "$KROOT/drivers/Makefile"

  # in-tree 头文件路径修正
  local rb="$KROOT/drivers/rekernel/rekernel_binder.c"
  if [ -f "$rb" ]; then
    sed -i 's|#include <../android/binder_internal.h>|#include "../android/binder_internal.h"|g' "$rb"
    grep -qF '#include <linux/seq_file.h>' "$rb" \
      || sed -i '/#include <linux\/kprobes.h>/a #include <linux/seq_file.h>' "$rb"
  fi

  set_config CONFIG_REKERNEL y
  set_config CONFIG_REKERNEL_NETWORK y

  grep -q '^CONFIG_REKERNEL=y$' "$DEFCONFIG" || { feat_fail "Re-Kernel" "CONFIG_REKERNEL 写入校验失败"; return 0; }
  echo "  [OK] Re-Kernel 已集成"
}

# ================================================================
# 3. NoMount 挂载元模块
# ================================================================
feature_nomount() {
  echo "=== [NoMount] 挂载元模块 ==="
  local url="https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh"

  local prev_cwd="$PWD"
  cd "$KROOT" || { feat_fail "NoMount" "无法进入内核树"; return 0; }

  if ! curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "$url" | bash -s -- dev; then
    curl -fsSL "$url" | bash -s -- --cleanup >/dev/null 2>&1 || true
    cd "$prev_cwd"
    feat_fail "NoMount" "上游集成脚本执行失败（可能不适配非 GKI 目录结构）"
    return 0
  fi

  if [ ! -L "fs/nomount" ] && [ ! -d "fs/nomount" ]; then
    curl -fsSL "$url" | bash -s -- --cleanup >/dev/null 2>&1 || true
    cd "$prev_cwd"
    feat_fail "NoMount" "集成后 fs/nomount 缺失"
    return 0
  fi
  if ! grep -q 'source "fs/nomount/Kconfig"' fs/Kconfig; then
    cd "$prev_cwd"
    feat_fail "NoMount" "fs/Kconfig 未注册 NoMount"
    return 0
  fi

  cd "$prev_cwd"
  set_config CONFIG_NOMOUNT y
  echo "  [OK] NoMount 已集成"
}

# ================================================================
# 4. ZRAM 压缩算法（LZ4K / LZ4KD / NEON）
#
# 注意：marble 把 zram 作为可加载模块打包进 vendor_boot
# （build_bouquet.sh 的 both_need_modules 含 drivers/block/zram/zram.ko），
# 因此这里保持 CONFIG_ZRAM=m，只增强压缩后端，避免 .ko 消失导致
# 打包缺件。
# ================================================================
feature_zram() {
  echo "=== [ZRAM] 压缩算法增强 ==="

  local zsrc="$PATCHES_ROOT/zram"
  [ -d "$zsrc/lz4" ] || { feat_fail "ZRAM" "本仓库 zram/lz4 资源缺失"; return 0; }

  # ---- 前置校验：先把所有外部资源准备齐，再动内核源码 ----
  # 顺序原则：任何可能失败的步骤都在修改内核树之前完成，
  # 否则失败跳过会留下半应用状态，直接导致编译失败
  # （上一版就因此在 lib/lz4 与 zram 之间留下不一致）。

  local sp=/tmp/marble_sukisu_patch
  if [ ! -d "$sp" ]; then
    if ! git clone --depth 1 https://github.com/ShirkNeko/SukiSU_patch.git "$sp"; then
      feat_fail "ZRAM" "SukiSU_patch 仓库克隆失败"
      return 0
    fi
  fi

  local vpatch_dir="$sp/other/zram/zram_patch/$KVER"
  local -a PATCHES=()
  local p
  for p in lz4kd.patch lz4k_oplus.patch; do
    if [ -f "$vpatch_dir/$p" ]; then
      PATCHES+=("$vpatch_dir/$p")
    else
      echo "  [警告] 缺少 $vpatch_dir/$p"
    fi
  done
  if [ ${#PATCHES[@]} -eq 0 ]; then
    feat_fail "ZRAM" "SukiSU_patch 中没有 $KVER 的 zram 版本补丁"
    return 0
  fi

  # 在干净副本上预演一遍：确认补丁能落到当前内核源码
  local dry=/tmp/marble_zram_dry
  rm -rf "$dry"
  mkdir -p "$dry"
  local need_files="drivers/block/zram/zram_drv.c drivers/block/zram/zram_drv.h"
  for f in $need_files; do
    if [ -f "$KROOT/$f" ]; then
      mkdir -p "$dry/$(dirname "$f")"
      cp "$KROOT/$f" "$dry/$f"
    fi
  done
  if [ ! -f "$dry/drivers/block/zram/zram_drv.c" ]; then
    rm -rf "$dry"
    feat_fail "ZRAM" "内核树缺少 drivers/block/zram/zram_drv.c（zram 布局与补丁不匹配）"
    return 0
  fi
  local dryok=0
  for p in "${PATCHES[@]}"; do
    if ( cd "$dry" && patch -p1 -F 3 --forward --dry-run < "$p" >/dev/null 2>&1 ); then
      dryok=$((dryok + 1))
    fi
  done
  rm -rf "$dry"
  if [ "$dryok" -eq 0 ]; then
    feat_fail "ZRAM" "zram 版本补丁在当前内核源码上无法应用（上下文不匹配）"
    return 0
  fi
  echo "  前置校验通过：$dryok/${#PATCHES[@]} 个版本补丁可应用"

  # ---- 资源齐备，开始修改内核树 ----
  local prev_cwd="$PWD"

  # 4.1 升级 lib/lz4 + ARM64 NEON 解压加速
  #
  # 关键：必须注册 lz4armv8 子目录的构建，否则 LZ4_arm64_decompress_safe
  # 成为未定义符号（crypto/lz4.c 与 fs/f2fs/compress.c 会调用它），
  # 链接阶段直接失败。不能整份覆盖上游 Makefile——marble 用
  # CONFIG_LZ4_COMPRESS / CONFIG_LZ4_DECOMPRESS / CONFIG_LZ4HC_COMPRESS
  # 条件编译，整份替换会导致 LZ4 模块编不出来，因此只做增量追加。
  echo "  升级 LZ4 源码..."
  rm -f "$KROOT"/lib/lz4/lz4_compress.c "$KROOT"/lib/lz4/lz4_decompress.c \
        "$KROOT"/lib/lz4/lz4defs.h "$KROOT"/lib/lz4/lz4hc_compress.c
  # 只复制源码与头文件，绝不覆盖 Makefile——zram/lz4/Makefile 用的是
  # 无条件 obj-y，与 marble 的 CONFIG_LZ4_* 条件编译模型不兼容，
  # 整份覆盖会让 LZ4 模块在 CONFIG_LZ4_COMPRESS=m 时编不出来。
  cp -f "$zsrc"/lz4/lz4.c      "$KROOT/lib/lz4/" 2>/dev/null || true
  cp -f "$zsrc"/lz4/lz4.h      "$KROOT/lib/lz4/" 2>/dev/null || true
  cp -f "$zsrc"/lz4/lz4hc.c    "$KROOT/lib/lz4/" 2>/dev/null || true
  cp -f "$zsrc"/lz4/lz4hc.h    "$KROOT/lib/lz4/" 2>/dev/null || true
  cp -r "$zsrc"/lz4/lz4armv8   "$KROOT/lib/lz4/" 2>/dev/null || true
  cp -r "$zsrc"/include/linux/* "$KROOT/include/linux/" 2>/dev/null || true

  # 新版 lz4.c 在 !LZ4_FREESTANDING 时依赖 ALLOC / ALLOC_AND_ZERO / FREEMEM
  # 三个宏，由 marble 私有的 lib/lz4/lz4_kern.h 提供（走 kmalloc）。
  # 仓库里的 lz4.c 对应 FREESTANDING=1 场景，没有这行 include，
  # 直接替换会因宏未定义而编译失败。这里补回去。
  local lz4src="$KROOT/lib/lz4/lz4.c"
  if [ -f "$KROOT/lib/lz4/lz4_kern.h" ] && [ -f "$lz4src" ]; then
    if ! grep -q '#include "lz4_kern.h"' "$lz4src"; then
      sed -i 's|^#include "lz4.h"$|#include "lz4_kern.h"\n#include "lz4.h"|' "$lz4src"
      if grep -q '#include "lz4_kern.h"' "$lz4src"; then
        echo "  已为 lz4.c 补回 lz4_kern.h 引用（提供 ALLOC/FREEMEM）"
      else
        feat_fail "ZRAM" "lz4.c 补回 lz4_kern.h 失败（锚点 #include \"lz4.h\" 未找到）"
        return 0
      fi
    fi
  elif [ ! -f "$KROOT/lib/lz4/lz4_kern.h" ]; then
    feat_fail "ZRAM" "内核树缺少 lib/lz4/lz4_kern.h，新版 lz4.c 的 ALLOC 宏无处定义"
    return 0
  fi

  # lz4hc.c 同理
  local lz4hcsrc="$KROOT/lib/lz4/lz4hc.c"
  if [ -f "$lz4hcsrc" ] && ! grep -q '#include "lz4_kern.h"' "$lz4hcsrc"; then
    if grep -q '#include "lz4hc.h"' "$lz4hcsrc"; then
      sed -i 's|^#include "lz4hc.h"$|#include "lz4_kern.h"\n#include "lz4hc.h"|' "$lz4hcsrc"
      grep -q '#include "lz4_kern.h"' "$lz4hcsrc" \
        && echo "  已为 lz4hc.c 补回 lz4_kern.h 引用" \
        || echo "  [警告] lz4hc.c 补回 lz4_kern.h 失败"
    fi
  fi

  # 增量接线 lz4armv8（幂等）。放在复制之后、编译之前。
  local lz4mk="$KROOT/lib/lz4/Makefile"
  if [ -f "$lz4mk" ]; then
    if ! grep -q 'lz4armv8' "$lz4mk"; then
      {
        echo ''
        echo '# ARM64 NEON 加速（marble_features 追加）'
        echo 'obj-$(CONFIG_ARM64) += $(addprefix lz4armv8/, lz4accel.o lz4armv8.o)'
      } >> "$lz4mk"
      echo "  已为 lib/lz4/Makefile 追加 lz4armv8 构建规则"
    fi
    # 上游 Makefile 的 -DLZ4_FREESTANDING=0 需要与新版源码匹配，
    # 但保留上游取值不动，避免影响 LZ4 模块的符号可见性。
    if ! grep -q 'LZ4_FAST_DEC_LOOP' "$lz4mk"; then
      sed -i '1a ccflags-y += -DLZ4_FAST_DEC_LOOP=1' "$lz4mk"
    fi
  else
    feat_fail "ZRAM" "lib/lz4/Makefile 缺失，无法注册 NEON 加速"
    return 0
  fi

  # lz4_kern.h 是 marble 私有头，新版 lz4.c 若引用需保留；
  # 复制时未覆盖它（zram/lz4 中不含该文件），此处仅做存在性提示。
  [ -f "$KROOT/lib/lz4/lz4_kern.h" ] || echo "  [提示] lib/lz4/lz4_kern.h 不存在（上游无此文件）"

  cd "$KROOT" || { feat_fail "ZRAM" "无法进入内核树"; return 0; }
  if ! bash "$zsrc/apply_lz4_neon.sh"; then
    cd "$prev_cwd"
    feat_fail "ZRAM" "apply_lz4_neon.sh 执行失败"
    return 0
  fi

  # f2fs iostat 目标
  if [ -f fs/f2fs/Makefile ] && ! grep -qF 'f2fs-$(CONFIG_F2FS_IOSTAT) += iostat.o' fs/f2fs/Makefile; then
    echo 'f2fs-$(CONFIG_F2FS_IOSTAT) += iostat.o' >> fs/f2fs/Makefile
  fi

  # 4.2 LZ4K / LZ4KD 压缩后端源码
  local lz4k="$sp/other/zram/lz4k"
  if [ -d "$lz4k" ]; then
    cp -r "$lz4k"/include/linux/* "$KROOT/include/linux/" 2>/dev/null || true
    cp -r "$lz4k"/lib/* "$KROOT/lib/" 2>/dev/null || true
    cp -r "$lz4k"/crypto/* "$KROOT/crypto/" 2>/dev/null || true
    [ -d "$sp/other/zram/lz4k_oplus" ] && cp -r "$sp/other/zram/lz4k_oplus" "$KROOT/lib/"
  else
    echo "  [警告] SukiSU_patch 中缺少 zram/lz4k，LZ4K 后端不可用"
  fi

  # 4.3 版本补丁
  local applied=0
  for p in "${PATCHES[@]}"; do
    if patch -p1 -F 3 --forward < "$p" >/dev/null 2>&1; then
      echo "  已应用 $(basename "$p")"
      applied=$((applied + 1))
    else
      echo "  [警告] $(basename "$p") 应用失败（上下文漂移）"
    fi
  done
  cd "$prev_cwd"

  if [ "$applied" -eq 0 ]; then
    # 预演成功但实打失败：极不寻常，仍按失败处理
    feat_fail "ZRAM" "版本补丁实际应用失败（预演与实打结果不一致）"
    return 0
  fi
  echo "  已应用 $applied/${#PATCHES[@]} 个版本补丁"

  # 4.4 压缩后端 crypto 配置（保持 ZRAM=m）
  #
  # 只写补丁/源码确实提供、且 Kconfig 中存在对应符号的配置项。
  # marble 原树的 drivers/block/zram/Kconfig 没有 ZRAM_DEF_COMP_LZ4KD
  # 这类条目——它们由 lz4kd 补丁动态生成；补丁没打上就写这个 config
  # 会让 defconfig 校验失败（符号未定义），直接导致编译中断。
  local wrote=0
  for _kv in CRYPTO_LZ4HC:y CRYPTO_LZ4K:y CRYPTO_LZ4KD:y CRYPTO_842:y CRYPTO_LZO:y; do
    local _k="${_kv%%:*}" _v="${_kv##*:}"
    if config_defined "CONFIG_$_k"; then
      set_config "CONFIG_$_k" "$_v"
      wrote=$((wrote + 1))
    else
      echo "  [跳过] 当前内核未声明 CONFIG_$_k"
    fi
  done

  # 默认压缩算法只在对应后端确实可用时才指定
  if config_defined CONFIG_ZRAM_DEF_COMP_LZ4KD; then
    set_config CONFIG_ZRAM_DEF_COMP_LZ4KD y
    wrote=$((wrote + 1))
  else
    echo "  [跳过] 当前内核未声明 CONFIG_ZRAM_DEF_COMP_LZ4KD（lz4kd 补丁未提供该选项）"
  fi

  unset _kv _k _v
  echo "  [OK] ZRAM 压缩后端已增强（写入 $wrote 项配置；ZRAM 仍为模块）"
}

# ================================================================
# 5. 网络增强（仅 CONFIG 部分；BBRv3 内核补丁未接入）
#
# BBRv3 backport 补丁面向 AOSP common 5.10，marble 的 net/ipv4
# 与之有差异，强行应用成功率未知，故不纳入本脚本。
# ================================================================
feature_net() {
  echo "=== [网络增强] IPSet / Qdisc / WireGuard / CIFS ==="

  local cfg
  for cfg in IP_SET IP_SET_BITMAP_IP IP_SET_BITMAP_IPMAC IP_SET_BITMAP_PORT \
    IP_SET_HASH_IP IP_SET_HASH_IPMARK IP_SET_HASH_IPPORT IP_SET_HASH_IPPORTIP \
    IP_SET_HASH_IPPORTNET IP_SET_HASH_IPMAC IP_SET_HASH_MAC \
    IP_SET_HASH_NETPORTNET IP_SET_HASH_NET IP_SET_HASH_NETNET \
    IP_SET_HASH_NETPORT IP_SET_HASH_NETIFACE IP_SET_LIST_SET \
    NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_SET NETFILTER_XT_TARGET_LOG \
    NETFILTER_XT_MATCH_RECENT IP6_NF_NAT IP6_NF_TARGET_MASQUERADE; do
    enable_if_defined "CONFIG_$cfg"
  done
  config_defined CONFIG_IP_SET_MAX && set_config CONFIG_IP_SET_MAX 65534

  for cfg in TCP_CONG_ADVANCED TCP_CONG_BBR TCP_CONG_CUBIC \
    TCP_CONG_BIC TCP_CONG_WESTWOOD TCP_CONG_HTCP; do
    enable_if_defined "CONFIG_$cfg"
  done
  # DEFAULT_BBR 是 choice 成员，需要其所在 choice 也存在
  if config_defined CONFIG_DEFAULT_BBR; then
    set_config CONFIG_DEFAULT_BBR y
    set_config CONFIG_DEFAULT_TCP_CONG '"bbr"'
  fi

  for cfg in NET_SCH_FQ NET_SCH_FQ_CODEL NET_SCH_CAKE NET_ACT_CONNMARK \
    IP_NF_TARGET_TTL IP6_NF_TARGET_HL IP6_NF_MATCH_HL WIREGUARD; do
    enable_if_defined "CONFIG_$cfg"
  done

  for cfg in CIFS NETWORK_FILESYSTEMS KEYS CIFS_XATTR CIFS_POSIX; do
    enable_if_defined "CONFIG_$cfg"
  done

  # 写后校验：只在 Kconfig 确实声明了该符号时才要求落盘，
  # 否则「跳过」被误判成「写入失败」。
  if config_defined CONFIG_IP_SET; then
    grep -q '^CONFIG_IP_SET=y$' "$DEFCONFIG" || { feat_fail "网络增强" "IPSet 写入校验失败"; return 0; }
  fi
  if config_defined CONFIG_NET_SCH_FQ; then
    grep -q '^CONFIG_NET_SCH_FQ=y$' "$DEFCONFIG" || { feat_fail "网络增强" "FQ qdisc 写入校验失败"; return 0; }
  fi
  echo "  [OK] 网络增强配置已写入（BBRv3 未接入，默认 bbr v1）"
}

# ================================================================
# 主流程
# ================================================================
echo "=============================================="
echo " marble 功能补丁应用"
echo "   内核树 : $KROOT"
echo "   defconfig: $DEFCONFIG_NAME"
echo "   内核版本: $KVER / $AVER"
echo "   兼容跳过: $SKIP_INCOMPATIBLE"
echo "=============================================="

[ "$DO_BBG" = "1" ]      && feature_bbg
[ "$DO_REKERNEL" = "1" ] && feature_rekernel
[ "$DO_NOMOUNT" = "1" ]  && feature_nomount
[ "$DO_ZRAM" = "1" ]     && feature_zram
[ "$DO_NET" = "1" ]      && feature_net

echo "=============================================="
if [ "$FAILED" -gt 0 ]; then
  echo "::error::$FAILED 项功能补丁应用失败（skip_incompatible=false）"
  exit 1
fi
echo " 功能补丁应用完成"
echo "=============================================="

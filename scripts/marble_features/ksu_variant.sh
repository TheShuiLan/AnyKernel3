#!/usr/bin/env bash
# ================================================================
# marble 内核 KernelSU 变体集成
#
# 替代 build_bouquet.sh 的 --ksu / --susfs 选项。上游脚本硬编码
# tiann/KernelSU 并一律应用已废弃的 10_enable_susfs_for_ksu.patch
# （该补丁面向上游 KernelSU 手动钩子模型，SukiSU-Nova/BakaSU/FinaSU
# 三者均已树内原生集成 SUSFS，驱动侧再打会导致 vmlinux 链接失败）。
#
# 本脚本按变体分派：
#   tiann        : 上游 KernelSU + 50_add + 10_enable（唯一需要 10_enable 的）
#   bakasu       : BakaSU 内建 SUSFS，只打 50_add
#   sukisu-nova  : SukiSU-Nova builtin 分支，内建 SUSFS，只打 50_add
#   finasu       : FinaSU 树内原生 SUSFS，只打 50_add；额外注入管理器证书
#
# 布局对齐 build_bouquet.sh：
#   drivers/kernelsu/{.git,kernel,uapi}
#   drivers/Kconfig / drivers/Makefile 接线
# ================================================================
set -uo pipefail

KROOT=""
VARIANT="tiann"
WITH_SUSFS="false"
KVER="5.10"
AVER="android12"
KSU_COMMIT=""
KSU_CERT_SIZE=""
KSU_CERT_HASH=""
SKIP_INCOMPATIBLE="true"
PATCHES_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel-root)    KROOT="$2"; shift 2 ;;
    --variant)        VARIANT="$2"; shift 2 ;;
    --with-susfs)     WITH_SUSFS="$2"; shift 2 ;;
    --kernel-version) KVER="$2"; shift 2 ;;
    --android-version) AVER="$2"; shift 2 ;;
    --ksu-commit)     KSU_COMMIT="$2"; shift 2 ;;
    --cert-size)      KSU_CERT_SIZE="$2"; shift 2 ;;
    --cert-hash)      KSU_CERT_HASH="$2"; shift 2 ;;
    --skip-incompatible) SKIP_INCOMPATIBLE="$2"; shift 2 ;;
    --patches-root)   PATCHES_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KROOT" ] || { echo "--kernel-root 必填" >&2; exit 2; }
[ -d "$KROOT" ] || { echo "内核树不存在: $KROOT" >&2; exit 2; }

def_fail() {
  local msg="$1"
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=KernelSU 已跳过::${msg}（构建未中断）"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **KernelSU(${VARIANT})** 已自动跳过：${msg}（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::KernelSU(${VARIANT}): ${msg}" >&2
  exit 1
}

# ---- 1. 按变体确定仓库与分支 ----
case "$VARIANT" in
  tiann)
    KSU_URL="https://github.com/tiann/KernelSU.git"
    KSU_REF="main"
    NEED_10_ENABLE=1
    HAS_BUILTIN_SUSFS=0
    ;;
  bakasu)
    KSU_URL="https://github.com/Baka-SU/BakaSU.git"
    KSU_REF="main"
    NEED_10_ENABLE=0
    HAS_BUILTIN_SUSFS=1
    ;;
  sukisu-nova)
    KSU_URL="https://git.zako.shirkneko.top:20004/shirkneko/SukiSU.git"
    KSU_REF="builtin"
    NEED_10_ENABLE=0
    HAS_BUILTIN_SUSFS=1
    ;;
  finasu)
    KSU_URL="https://github.com/LyraVoid/FinaSU.git"
    KSU_REF="master"
    NEED_10_ENABLE=0
    HAS_BUILTIN_SUSFS=1
    ;;
  *)
    echo "未知变体: $VARIANT（可选 tiann/bakasu/sukisu-nova/finasu）" >&2
    exit 2
    ;;
esac

echo "=== KernelSU 变体集成: $VARIANT (ref=$KSU_REF) ==="

# ---- 2. 克隆 KernelSU ----
KSU_DIR="$KROOT/../KernelSU"
rm -rf "$KSU_DIR"
if ! git clone --depth=1 -b "$KSU_REF" "$KSU_URL" "$KSU_DIR" 2>/dev/null; then
  echo "  分支 $KSU_REF 克隆失败，回退到默认分支"
  if ! git clone --depth=1 "$KSU_URL" "$KSU_DIR"; then
    def_fail "克隆 $KSU_URL 失败"
  fi
fi

# 可选：检出指定提交（版本对齐用）
if [ -n "$KSU_COMMIT" ]; then
  if ! git -C "$KSU_DIR" fetch --depth=1 origin "$KSU_COMMIT" 2>/dev/null; then
    echo "  提交 $KSU_COMMIT 已在本地，跳过 fetch"
  fi
  if git -C "$KSU_DIR" checkout --detach "$KSU_COMMIT" 2>/dev/null; then
    echo "  KernelSU 已检出到 $KSU_COMMIT"
  else
    def_fail "检出提交 $KSU_COMMIT 失败"
  fi
fi

echo "  KSU commit: $(git -C "$KSU_DIR" rev-parse --short HEAD)"
[ -d "$KSU_DIR/kernel" ] || def_fail "KernelSU 仓库缺少 kernel/ 目录"

# ---- 2.5 清理源码树里预置的 KernelSU（避免符号重复定义） ----
#
# melt-rebase-hyperos 等分支把 tiann 版 KernelSU 直接内建在
# drivers/staging/kernelsu/（staging/Kconfig:123 引用其 Kconfig）。
# 若不清掉，我们的接入会与之共存，链接期报大量重复符号：
#   ld.lld: error: duplicate symbol: ksu_set_app_profile
#   >>> defined in drivers/built-in.a(staging/kernelsu/allowlist.o)
#   >>> defined in drivers/built-in.a(kernelsu/ksu_main.o)
#   make[1]: *** [Makefile:1399: vmlinux] Error 1
#
# 这里是"替换"而非"叠加"：先解除 wiring，再删目录/软链。
PRESET_DIRS=""
for d in drivers/staging/kernelsu drivers/kernelsu; do
  if [ -e "$KROOT/$d" ]; then
    PRESET_DIRS="$PRESET_DIRS $d"
  fi
done

if [ -n "$PRESET_DIRS" ]; then
  echo "  检测到源码树预置的 KernelSU:$PRESET_DIRS，先清理"
  for d in $PRESET_DIRS; do
    # 解除 Kconfig 引用（幂等）
    for kc in drivers/staging/Kconfig drivers/Kconfig; do
      [ -f "$KROOT/$kc" ] || continue
      sed -i "\|source \"$d/Kconfig\"|d" "$KROOT/$kc"
    done
    # 解除 Makefile 引用（幂等）。
    # 注意 Makefile 里写的是相对父目录的末级名，不是完整路径：
    #   drivers/staging/Makefile: obj-$(CONFIG_KSU)		+= kernelsu/
    #   drivers/Makefile:         obj-y += kernelsu/
    # 因此按 "+= kernelsu/" 或 "+= kernelsu" 匹配，并容忍 tab/空格分隔。
    for mk in drivers/staging/Makefile drivers/Makefile; do
      [ -f "$KROOT/$mk" ] || continue
      sed -i '/obj-.*+=[[:space:]]*kernelsu\/\{0,1\}[[:space:]]*$/d' "$KROOT/$mk"
    done
    # 软链用 rm 只删链接本身；实体目录整棵删除
    if [ -L "$KROOT/$d" ]; then rm -f "$KROOT/$d"; else rm -rf "$KROOT/$d"; fi
    echo "    已移除 $d"
  done
  # 同名 CONFIG_KSU 会被新接入复用，无需改 defconfig
fi

# ---- 3. 接入 drivers/kernelsu（按变体选择正确布局） ----
#
# 上游各变体的集成布局并不一致，混用会导致头文件找不到：
#
#   tiann        build_bouquet.sh 布局：cp kernel/ -> drivers/kernelsu/kernel/
#                其 Makefile 用 $(srctree)/$(src)/include，多一层无妨。
#
#   bakasu       官方 setup.sh 布局：软链 KernelSU/kernel -> drivers/kernelsu
#   sukisu-nova  同上。注意 SukiSU-Nova 的 Makefile 在 CONFIG_KSU_SUSFS=y 时
#   finasu       硬编码 -I$(srctree)/drivers/kernelsu/include，多一层就会
#                报 'arch.h' file not found（本仓库此前的实际故障）。
#
# 因此官方三家用软链布局，与各自 setup.sh 完全一致；tiann 保持原布局。
rm -rf "$KROOT/drivers/kernelsu"

if [ "$VARIANT" = "tiann" ]; then
  mkdir -p "$KROOT/drivers/kernelsu"
  cp -r "$KSU_DIR/kernel" "$KROOT/drivers/kernelsu/kernel"
  [ -d "$KSU_DIR/uapi" ] && cp -r "$KSU_DIR/uapi" "$KROOT/drivers/kernelsu/uapi" || true
  KSU_KCONFIG_REL="drivers/kernelsu/kernel/Kconfig"
  KSU_MAKE_LINE='obj-y += kernelsu/kernel/'
  echo "  布局: drivers/kernelsu/kernel/（build_bouquet 风格）"
else
  # 软链：drivers/kernelsu -> KernelSU/kernel
  ln -sfn "$(realpath --relative-to="$KROOT/drivers" "$KSU_DIR/kernel")" \
    "$KROOT/drivers/kernelsu"
  KSU_KCONFIG_REL="drivers/kernelsu/Kconfig"
  KSU_MAKE_LINE='obj-$(CONFIG_KSU) += kernelsu/'
  echo "  布局: drivers/kernelsu -> KernelSU/kernel（官方 setup.sh 风格）"
  [ -d "$KROOT/drivers/kernelsu" ] || def_fail "drivers/kernelsu 软链创建失败（KernelSU/kernel 不存在？）"
  [ -f "$KROOT/drivers/kernelsu/Kconfig" ] || def_fail "软链后 drivers/kernelsu/Kconfig 不可达"
fi

# 接线（幂等）
# 锚点优先用 drivers/most/Kconfig（build_bouquet.sh 的原写法，
# marble melt-rebase 的 drivers/Kconfig:239 存在该行）；
# 缺失时退到该 menu 的 endmenu 前插入，避免静默漏接。
if ! grep -qF "source \"$KSU_KCONFIG_REL\"" "$KROOT/drivers/Kconfig"; then
  if grep -qF 'source "drivers/most/Kconfig"' "$KROOT/drivers/Kconfig"; then
    sed -i "\|source \"drivers/most/Kconfig\"|a source \"$KSU_KCONFIG_REL\"" "$KROOT/drivers/Kconfig"
  else
    sed -i "/^endmenu\$/i source \"$KSU_KCONFIG_REL\"" "$KROOT/drivers/Kconfig"
    echo "  [警告] drivers/Kconfig 无 most/Kconfig 锚点，改在 endmenu 前插入"
  fi
fi
grep -qF "source \"$KSU_KCONFIG_REL\"" "$KROOT/drivers/Kconfig" \
  || def_fail "drivers/Kconfig 接线失败"
grep -qF "$KSU_MAKE_LINE" "$KROOT/drivers/Makefile" \
  || echo "$KSU_MAKE_LINE" >> "$KROOT/drivers/Makefile"

# ---- 4. FinaSU 管理器证书注入（第二信任槽） ----
if [ "$VARIANT" = "finasu" ]; then
  KBUILD="$KROOT/drivers/kernelsu/Kbuild"
  if [ -n "$KSU_CERT_SIZE" ] && [ -n "$KSU_CERT_HASH" ]; then
    if grep -q '^KSU_EXPECTED_SIZE2 := ' "$KBUILD" 2>/dev/null; then
      echo "  FinaSU 证书槽已存在，跳过注入"
    elif grep -q '^ccflags-y += -DEXPECTED_HASH=' "$KBUILD"; then
      awk -v size="$KSU_CERT_SIZE" -v hash="$KSU_CERT_HASH" '
        !done && /^ccflags-y \+= -DEXPECTED_HASH=/ {
          print
          print "# injected by marble: trust the official FinaSU manager via the second signature slot"
          print "KSU_EXPECTED_SIZE2 := " size
          print "KSU_EXPECTED_HASH2 := " hash
          print "KSU_SECOND_SIGNATURE_RELEASE := 1"
          done = 1
          next
        }
        { print }
      ' "$KBUILD" > "$KBUILD.new" && mv "$KBUILD.new" "$KBUILD"
      grep -q '^KSU_EXPECTED_SIZE2 := ' "$KBUILD" || def_fail "FinaSU Kbuild 证书注入失败（锚点缺失）"
      echo "  FinaSU 证书已注入: size=$KSU_CERT_SIZE"
    else
      echo "  [警告] FinaSU Kbuild 缺少 EXPECTED_HASH 锚点，跳过证书注入（管理器可能无法被识别）"
    fi
  else
    echo "  [警告] 未提供 FinaSU 证书参数，跳过注入（官方管理器可能显示未安装）"
  fi
fi

# ---- 5. SUSFS ----
if [ "$WITH_SUSFS" = "true" ]; then
  SUSFS_PATCH="50_add_susfs_in_gki-${AVER}-${KVER}.patch"
  echo "=== SUSFS 集成（补丁: $SUSFS_PATCH） ==="

  SUSFS_DIR=/tmp/marble_susfs4ksu
  if [ ! -d "$SUSFS_DIR" ]; then
    if ! git clone --depth=1 -b "gki-${AVER}-${KVER}" \
         https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS_DIR"; then
      rm -rf "$SUSFS_DIR"
      def_fail "SUSFS 仓库克隆失败（无 gki-${AVER}-${KVER} 分支）"
    fi
  fi

  [ -f "$SUSFS_DIR/kernel_patches/$SUSFS_PATCH" ] \
    || def_fail "SUSFS 补丁不存在: $SUSFS_PATCH"

  cp "$SUSFS_DIR"/kernel_patches/fs/* "$KROOT/fs/"
  cp "$SUSFS_DIR"/kernel_patches/include/linux/* "$KROOT/include/linux/"

  prev="$PWD"
  cd "$KROOT" || def_fail "无法进入内核树"

  # 主补丁
  if patch -p1 --forward --dry-run < "$SUSFS_DIR/kernel_patches/$SUSFS_PATCH" >/dev/null 2>&1; then
    patch -p1 --forward --no-backup-if-mismatch < "$SUSFS_DIR/kernel_patches/$SUSFS_PATCH" || true
    echo "  50_add 主补丁已应用"
  elif grep -q 'susfs_init' fs/susfs.c 2>/dev/null; then
    echo "  50_add 主补丁此前已应用"
  else
    cd "$prev"
    def_fail "SUSFS 50_add 主补丁应用失败"
  fi

  # 驱动侧：仅上游 tiann 需要 10_enable（路径需重写到 drivers/kernelsu/kernel/）
  if [ "$NEED_10_ENABLE" = "1" ]; then
    EN10="$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
    if [ -f "$EN10" ]; then
      sed -e 's|a/kernel/|a/drivers/kernelsu/kernel/|g' \
          -e 's|b/kernel/|b/drivers/kernelsu/kernel/|g' \
          "$EN10" > /tmp/10_enable_rewritten.patch
      if patch -p1 --forward --no-backup-if-mismatch < /tmp/10_enable_rewritten.patch >/dev/null 2>&1; then
        echo "  10_enable 驱动侧补丁已应用（tiann）"
      else
        echo "  [警告] 10_enable 应用失败，tiann 变体的 SUSFS 钩子可能不完整"
      fi
    else
      echo "  [警告] 缺少 $EN10"
    fi
  else
    echo "  $VARIANT 树内原生集成 SUSFS，跳过 10_enable（与 susfs_fixes/apply.sh 一致）"
  fi

  cd "$prev"
fi

echo "=== KernelSU 集成完成: $VARIANT$( [ "$WITH_SUSFS" = "true" ] && echo ' + SUSFS' ) ==="

#!/bin/sh
# SPDX-License-Identifier: MIT
#
# 把云编译产物里的 *.itb 生成 byte-identical 的 *.bin 别名。
#
# 目的：部分 U-Boot 恢复网页的上传框按扩展名过滤（只让选 .bin）。
#       lyq1996 FIT U-Boot 的 rtk_boot / fit_check_format 按「内容」识别
#       FIT magic (d0 0d fe ed)，不看文件名，所以改后缀不会影响引导。
#
# ⚠️ 重要边界（务必读 FLASH-FORMAT-NOTES.txt）：
#   这个 .bin 只是同一个 FIT 镜像换了名字，**不是** LeoooChen 原生 U-Boot
#   所需的 sysupgrade-tar 格式 sysupgrade.bin。刷进原生 U-Boot 会失败/变砖。
#
# 用法：
#   sh scripts/make-bin-alias.sh <artifact目录>       # 处理目录内所有 .itb
#   sh scripts/make-bin-alias.sh <某文件.itb>          # 只处理单个文件
#
set -eu

TARGET="${1:-.}"
[ -e "$TARGET" ] || { echo "ERROR: 路径不存在: $TARGET" >&2; exit 1; }

if [ -d "$TARGET" ]; then
  DIR="$TARGET"
  set -- "$DIR"/*.itb
  [ -e "$1" ] || { echo "ERROR: $DIR 下没有 *.itb" >&2; exit 1; }
else
  DIR=$(dirname "$TARGET")
  set -- "$TARGET"
fi

n=0
for itb in "$@"; do
  [ -f "$itb" ] || continue
  # FIT (Flattened Image Tree) 魔数，与 platform.sh 的 get_magic_long 一致
  magic=$(head -c 4 "$itb" | od -An -tx1 | tr -d ' \n')
  if [ "$magic" != "d00dfeed" ]; then
    echo "::error::$itb 前 4 字节是 $magic，不是 FIT 魔数 d00dfeed，跳过" >&2
    exit 1
  fi
  bin="${itb%.itb}.bin"
  cp -f "$itb" "$bin"
  cmp -s "$itb" "$bin" || { echo "::error::$bin 与 $itb 不一致" >&2; exit 1; }
  echo "  $(basename "$bin")  <=  $(basename "$itb")  ($(wc -c < "$bin") bytes, FIT magic OK, byte-identical)"
  n=$((n + 1))
done

[ "$n" -gt 0 ] || { echo "::error::没有生成任何 .bin 别名" >&2; exit 1; }

cat > "$DIR/FLASH-FORMAT-NOTES.txt" <<'EOF'
固件格式说明（刷机前必读）
================================================================

本次产物同时提供 *.itb 与 *.bin，两者逐字节相同，只是文件扩展名不同，
内容都是 FIT (Flattened Image Tree) 镜像，魔数 d0 0d fe ed。

【适用】lyq1996 / refactor FIT U-Boot（rtk_boot，UBI 卷：
        factory(8MiB static) + fit + rootfs_data）
  - 恢复网页 /api/write 写 fit 卷，或串口 rtk_boot 引导；
  - 若网页上传框按扩展名过滤、只让选 .bin，用这里的 .bin 即可，
    引导时按内容识别，与 .itb 完全等价。

【不适用】LeoooChen「原生 U-Boot」(U-Boot 1.6，恢复网页 192.168.0.1，
        「OpenWrt 启动配置」「刷机 → 刷写系统」，原厂 A/B 双槽
        ubi_k0/ubi_r0/ubi_k1/ubi_r1 + factory-v1)
  - 它要的是 sysupgrade-tar 归档格式的 sysupgrade.bin，卷布局、
    内核封装（签名 FIT boot script）与本产物完全不同；
  - 把本 .bin 刷进去会被拒绝或写入错误卷，可能变砖。
  - 该 U-Boot 请用 LeoooChen/PonWRT-TYFZA1 的固件 / 云编译产物。

【30 秒确认你刷的是哪个 U-Boot】
  - 恢复网页显示 "U-Boot 1.6"、有「OpenWrt 启动配置」下拉选机型、
    「刷机 → 刷写系统」      -> LeoooChen 原生 U-Boot -> 本产物不可用
  - 恢复网页是 /api/job + /api/write（ubi-rebuild / env-default），
    或串口日志出现 2026.07-g9abafc0572b2 / bootmenu_0=rtk_boot
                                       -> lyq1996 FIT U-Boot -> 可用
  - 已进系统时执行 ubinfo -a：只有 fit / factory / rootfs_data 三卷
    -> lyq1996 布局；出现 ubi_k0/ubi_r0 等 -> 原厂/PonWRT 布局

本产物是 lyq1996/rtl9617c-openwrt 源码树的编译结果，ABI 与
LeoooChen/PonWRT-TYFZA1 互不兼容，无法通过改文件名互相转换。
EOF

echo ""
echo "⚠️  已写 $DIR/FLASH-FORMAT-NOTES.txt —— 刷机前务必先按其中方法确认 U-Boot 类型"
echo "✅ BIN_ALIAS_OK=$n"

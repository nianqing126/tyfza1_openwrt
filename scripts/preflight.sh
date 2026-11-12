#!/bin/bash
# test_only 模式下的静态预检：不编译，只检查源码树与配置是否自洽。
# 用法： ASSETS=<资产目录> WRT=<源码树> bash scripts/preflight.sh

set -euo pipefail
ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
PROFILE="${PROFILE:-tianyi_tyfza1_2p5g}"
BOARD_NAME="${BOARD_NAME:-tianyi,tyfza1-2p5g}"
DTS="${DTS:-rtl9617c-tyfza1-2p5g}"

ok()   { printf '  OK   %s\n' "$1"; }
fail() { printf 'FAIL   %s\n' "$1" >&2; exit 1; }

echo "=== assets ==="
[ -d "$ASSETS/.github/workflows" ] || fail "缺 .github/workflows"
for f in Config-TYFZA1-FIT.txt Config-EXTRA.txt customize.sh \
         scripts/patch-upstream.sh scripts/render-wan-vlan.sh \
         scripts/preflight.sh scripts/verify-fit-boot.py \
         files/etc/uci-defaults/95-tyfza1-offload \
         files/etc/uci-defaults/99-tyfza1-fit; do
  [ -f "$ASSETS/$f" ] || fail "缺资产 $f"; ok "$f"
done
for f in customize.sh scripts/*.sh files/etc/uci-defaults/*; do
  bash -n "$ASSETS/$f" || fail "$f shell 语法错误"
done
ok "shell 语法"
python3 -m py_compile "$ASSETS/scripts/verify-fit-boot.py" || fail "verify-fit-boot.py 语法错误"
ok "python 语法"

echo "=== firmware blobs (7) ==="
n=$(find "$ASSETS/files/lib/firmware/realtek/tyfza1" -maxdepth 1 -name '*.bin' | wc -l)
[ "$n" = 7 ] || fail "固件数量 $n != 7"; ok "7 个 WiFi 固件"

echo "=== source tree ==="
[ -d "$WRT/target/linux/rtl9617c" ] || fail "缺 target/linux/rtl9617c"
for f in target/linux/rtl9617c/image/Makefile \
         "target/linux/rtl9617c/dts/${DTS}.dts" \
         target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi \
         target/linux/rtl9617c/pe/Makefile \
         target/linux/rtl9617c/config-6.18 \
         package/utils/fitblk/files/fit.sh; do
  [ -f "$WRT/$f" ] || fail "源码缺 $f"; ok "$f"
done
grep -q "^TARGET_DEVICES += ${PROFILE}$" "$WRT/target/linux/rtl9617c/image/Makefile" \
  || fail "image/Makefile 缺 Device $PROFILE"; ok "Device $PROFILE"
grep -q "${BOARD_NAME}" "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
  || fail "platform.sh 白名单缺 $BOARD_NAME"; ok "platform.sh 白名单"
grep -q "\"${BOARD_NAME}\"" "$WRT/target/linux/rtl9617c/dts/${DTS}.dts" \
  || fail "DTS compatible 不符"; ok "DTS compatible"
grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' "$WRT/target/linux/rtl9617c/config-6.18" \
  || fail "config-6.18 缺 UIMAGE_FIT_BLK"; ok "FIT 内核符号"

echo "=== .config ==="
CFG="$WRT/.config"
[ -f "$CFG" ] || fail "缺 .config"
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" "$CFG" \
  || fail "profile 未启用"; ok "profile"
grep -q '^# CONFIG_PACKAGE_uboot-envtools is not set$' "$CFG" \
  || fail "uboot-envtools 未关闭"; ok "uboot-envtools disabled"
for bad in kmod-mac80211 kmod-cfg80211 kmod-mt7915e kmod-mt76-core; do
  ! grep -qE "^CONFIG_PACKAGE_${bad}=(y|m)$" "$CFG" || fail "污染包 $bad"
done
ok "无 mediatek 残留"
for good in fitblk tyfza1-pon-control luci-app-tyfza1-pon kmod-rtl-ax-ap; do
  grep -q "^CONFIG_PACKAGE_${good}=y$" "$CFG" || fail "缺包 $good"
done
ok "关键包齐全"

echo "=== patch-upstream 效果 ==="
grep -q 'mv "\$tmp" "\$3"' "$WRT/package/tyfza1-pon-control/files/tyfza1-factory" \
  || fail "factory_blob 未修补"; ok "factory_blob"

echo
echo "PREFLIGHT_OK=True profile=$PROFILE board_name=$BOARD_NAME dts=$DTS"

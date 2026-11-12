#!/bin/bash
# 修补上游源码树里与 TYFZA1 相关的缺陷（幂等，可重复执行）。
#
# 用法：
#   ASSETS=<资产目录> WRT=<源码树> bash scripts/patch-upstream.sh
#
# 修三件事：
#   1. package/tyfza1-pon-control/files/tyfza1-factory 的 factory_blob() 参数错位：
#      函数签名是 factory_blob <offset> <size> <dest>，但结尾写的是
#        mv "$tmp" "$2"
#      $2 是「长度」而不是目标路径，临时文件被 mv 成名为 4096 的文件，
#      目标目录永远为空 → flash-calibration.bin / bosa-calibration.bin /
#      a2h.bin 全是悬空软链接，WiFi 与 BOSA 校准拿不到数据，直接表现为
#      无线协商异常 / 信号弱。修法：mkdir -p 目标目录 + mv "$tmp" "$3"。
#   2. base-files/etc/uci-defaults/91-tyfza1-pon-offload 的「键存在即退出」：
#      原脚本 uci -q get flow_offloading_hw >/dev/null && exit 0，
#      只要该键存在（哪怕值是 0）就跳过，永远不会把 offload 打开。
#      这正是 PON FE 未启用、吞吐卡在 400~500 Mbps 的编译期根因之一。
#      改成「值为 1 才退出」，值为 0 时纠正为 1。
#   3. 校验 rootfs overlay 里的 7 个 WiFi AP 固件齐全且大小正确
#      （上游没有任何包安装它们，只能由 files/ 提供）。

set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
FACTORY="$WRT/package/tyfza1-pon-control/files/tyfza1-factory"
OFFLOAD_UCD="$WRT/target/linux/rtl9617c/base-files/etc/uci-defaults/91-tyfza1-pon-offload"
FW_DIR="$ASSETS/files/lib/firmware/realtek/tyfza1"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------- 1. tyfza1-factory: factory_blob 目标参数 ----------
[ -f "$FACTORY" ] || fail "找不到 $FACTORY（上游目录结构变了？）"

if grep -q 'mv "\$tmp" "\$2"' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tmv "$tmp" "$2"'
new = '\t\tmkdir -p "${3%/*}"\n\t\tmv "$tmp" "$3"'
if old not in text:
    raise SystemExit('ERROR: 未找到预期的 mv "$tmp" "$2" 行（缩进不符）')
p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
print('patched tyfza1-factory: factory_blob -> mv "$tmp" "$3"')
PY
else
  echo "tyfza1-factory: 已是修好的版本（本次或上游已修），跳过参数修补"
fi

grep -q 'mv "\$tmp" "\$3"' "$FACTORY" \
  || fail 'tyfza1-factory 修补失败：没有 mv "$tmp" "$3"'
! grep -q 'mv "\$tmp" "\$2"' "$FACTORY" \
  || fail 'tyfza1-factory 仍残留 mv "$tmp" "$2"'

# 空块（校准区整段 0xFF）会静默跳过，加日志便于真机排查悬空软链接
if ! grep -q 'is empty, skipped' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old_else = '\telse\n\t\trm -f "$tmp"\n\t\treturn 1\n'
new_else = '\telse\n\t\tlogger -t tyfza1-factory "$3 is empty, skipped"\n\t\trm -f "$tmp"\n\t\treturn 1\n'
if old_else in text:
    p.write_text(text.replace(old_else, new_else, 1), encoding='utf-8', newline='\n')
    print('patched tyfza1-factory: log skipped blobs')
else:
    print('tyfza1-factory: else 分支格式不同，跳过日志增强（非致命）')
PY
fi

# ---------- 2. 91-tyfza1-pon-offload: 键存在即退出 ----------
# 仅在 enable_offload=true 时修上游 91 脚本，保证该开关 false 时真的
# 「保留上游原始行为」，而不是被修补后间接又打开了 offload。
if [ "${ENABLE_OFFLOAD:-true}" != "true" ]; then
  echo "91-tyfza1-pon-offload: enable_offload=false，保留上游原始行为，跳过修补"
elif [ -f "$OFFLOAD_UCD" ]; then
  if grep -q "uci -q get 'firewall.@defaults\[0\].flow_offloading_hw' >/dev/null && exit 0" "$OFFLOAD_UCD"; then
    python3 - "$OFFLOAD_UCD" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = "uci -q get 'firewall.@defaults[0].flow_offloading_hw' >/dev/null && exit 0"
new = "[ \"$(uci -q get 'firewall.@defaults[0].flow_offloading_hw')\" = 1 ] && exit 0"
if old not in text:
    raise SystemExit('ERROR: 未找到预期的 offload 早退行')
p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
print('patched 91-tyfza1-pon-offload: 只在值为 1 时退出')
PY
  else
    echo "91-tyfza1-pon-offload: 已是修好的版本（本次或上游已修），跳过"
  fi
  grep -q 'flow_offloading_hw.*= 1' "$OFFLOAD_UCD" \
    || fail '91-tyfza1-pon-offload 修补后仍未见值判断'
else
  echo "WARN: 未找到 $OFFLOAD_UCD，跳过（rootfs 的 95-tyfza1-offload 仍会兜底）" >&2
fi

# ---------- 3. WiFi AP 固件齐全性 ----------
# 上游没有任何包提供这些 bin，缺一个驱动就 request_firmware -2 直接失败。
EXPECTED="
rtl8852c-u1-ap.bin 406448
rtl8852c-u2-ap.bin 369160
rtl8192xb-u1-ap.bin 387680
rtl8192xb-u2-ap.bin 387752
array_mp_8852c_nctl_reg.bin 14256
array_mp_8852c_nctl_reg_a.bin 14152
array_mp_8192xb_nctl_reg.bin 11368
"

count=0
while read -r name size; do
  [ -n "${name:-}" ] || continue
  f="$FW_DIR/$name"
  [ -f "$f" ] || fail "缺少 WiFi 固件 $f"
  actual=$(stat -c %s "$f")
  [ "$actual" = "$size" ] \
    || fail "$name 大小不符：期望 $size，实际 $actual（文件被截断？）"
  count=$((count + 1))
done <<EOF
$EXPECTED
EOF

[ "$count" = 7 ] || fail "WiFi 固件数量异常：$count != 7"
extra=$(find "$FW_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)
[ "$extra" = 7 ] || fail "WiFi 固件目录里有 $extra 个 .bin，期望 7 个"

echo "patch-upstream OK: factory_blob / offload 早退已修，WiFi 固件 7/7 校验通过"

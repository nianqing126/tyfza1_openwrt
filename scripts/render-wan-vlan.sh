#!/bin/bash
# 生成 96-tyfza1-wan-vlan uci-defaults（按本次云编译输入渲染）。
#
# 独立成脚本的原因：GitHub Actions 的 YAML 块标量对内嵌 heredoc 的缩进很敏感，
# 顶格内容行会终止块标量并让后续行被当成 YAML 解析。放在独立 .sh 里既避免
# 该问题，也方便本地 bash -n / 直接运行验证。
#
# 用法：
#   bash scripts/render-wan-vlan.sh <输出路径> <vlan_id> <pon_mode> <board_name>
#
# 不硬编码任何省份 / 运营商参数；PPPoE 凭据一律不写，由用户首次开机填写。

set -euo pipefail

OUT="${1:?usage: render-wan-vlan.sh <output> <vlan> <mode> <board_name>}"
VLAN="${2:?missing vlan}"
MODE="${3:-xgpon}"
BOARD="${4:?missing board_name}"

fail() { echo "ERROR: $*" >&2; exit 1; }

case "$VLAN" in
  ''|*[!0-9]*) fail "wan_vlan 必须是纯数字（收到 '$VLAN'）" ;;
esac
[ "$VLAN" -ge 1 ] && [ "$VLAN" -le 4094 ] \
  || fail "wan_vlan 超出 1..4094（收到 '$VLAN'）"
case "$MODE" in
  xgpon|gpon|epon) ;;
  *) fail "wan_vlan_mode 必须是 xgpon/gpon/epon（收到 '$MODE'）" ;;
esac

mkdir -p "${OUT%/*}"

# heredoc 需要展开 VLAN/MODE/BOARD，其余 $ 全部转义为字面量写入产物脚本。
cat > "$OUT" <<EOF
#!/bin/sh
# 由 tyfza1-cloudbuild 按本次构建输入生成。
# 执行序：90(上游WAN) -> 91(上游offload) -> 95(offload) -> 96(VLAN)
[ "\$(board_name)" = "$BOARD" ] || exit 0

vlan_dev="pon0.$VLAN"
uci -q set pon.pon.wan_vlan='$VLAN'
uci -q set pon.pon.mode='$MODE'

# 找到或新建 8021q 子设备；PPPoE 底层口 MTU 必须 >= 1500
idx=0
found=0
while uci -q get "network.@device[\$idx]" >/dev/null; do
  if [ "\$(uci -q get "network.@device[\$idx].name")" = "\$vlan_dev" ]; then
    found=1
    break
  fi
  idx=\$((idx + 1))
done
if [ "\$found" = "0" ]; then
  uci -q add network device >/dev/null
  # uci 值里不能夹单引号：否则 netifd 会把 '8021q' 当字面量，VLAN 设备建不出来
  uci -q set "network.@device[\$idx].type=8021q"
  uci -q set "network.@device[\$idx].ifname=pon0"
  uci -q set "network.@device[\$idx].vid=$VLAN"
  uci -q set "network.@device[\$idx].name=\$vlan_dev"
  uci -q set "network.@device[\$idx].mtu=1500"
fi

uci -q set network.wan='interface'
uci -q set network.wan.device="\$vlan_dev"
uci -q delete network.wan.ifname
uci -q set network.wan.proto='pppoe'
uci -q set network.wan.mtu='1492'
uci -q set network.wan.ipv6='1'
uci -q commit network
uci -q commit pon
logger -t tyfza1-wan "default WAN -> \$vlan_dev (pppoe), mode=$MODE"
exit 0
EOF

chmod +x "$OUT"
bash -n "$OUT"
echo "render-wan-vlan OK: $OUT (vlan=$VLAN mode=$MODE board=$BOARD)"

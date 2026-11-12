#!/bin/bash
# 在源码根目录执行（workflow 的 Configure 步骤，make defconfig 之前）。
#
# 做四件事：
#   1. 按 board 写机型专属 profile / 主机名 / 默认 IP / SSID
#   2. 默认时区 UTC+8（Asia/Shanghai）与国内 NTP
#   3. 生成 files/etc/apk/repositories.d/distfeeds.list
#   4. 追加仓库根 Config-EXTRA.txt（可选额外软件包）
#
# 与 PT1570 版本的差异：不注入弱口令 WiFi 密码（WRT_WORD 留空即跳过），
# 首次开机请自行在 LuCI 里设置无线密码。
#
# ⚠️ 本 target 的 CPU_TYPE=cortex-a55，架构包目录是 aarch64_cortex-a55。
#    国内 immortalwrt 镜像一般只有 aarch64_cortex-a53，直接照抄会
#    导致 apk architecture mismatch / 404。因此 distfeeds.list 默认不启用
#    任何外部源，配套包一律由「同批 packages」提供。

set -euo pipefail

# ---- 定位源码根目录 ----
if [ ! -f package/base-files/files/bin/config_generate ]; then
  for d in wrt "${GITHUB_WORKSPACE:-}/wrt" "${GITHUB_WORKSPACE:-}"; do
    [ -n "$d" ] || continue
    if [ -f "$d/package/base-files/files/bin/config_generate" ]; then cd "$d"; break; fi
  done
fi
if [ ! -f package/base-files/files/bin/config_generate ]; then
  echo "ERROR: 未找到 OpenWrt 源码根目录" >&2
  exit 1
fi

BOARD="${TYFZA1_BOARD:-2p5g}"
case "$BOARD" in
  2p5g) PROFILE="tianyi_tyfza1_2p5g"; MODEL="TYFZA1-2.5G" ;;
  4ge)  PROFILE="tianyi_tyfza1_4ge";  MODEL="TYFZA1-4GE"  ;;
  *) echo "ERROR: TYFZA1_BOARD must be 2p5g or 4ge (got '$BOARD')" >&2; exit 1 ;;
esac

WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-$MODEL}"
WRT_SSID="${WRT_SSID:-$MODEL}"
WRT_WORD="${WRT_WORD:-}"          # 留空 = 不改写 WiFi 密码
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
WRT_NTP="${WRT_NTP:-1}"
WRT_TARGET_SUBTARGET="${WRT_TARGET_SUBTARGET:-rtl9617c/generic}"
WRT_ARCH_PACKAGES="${WRT_ARCH_PACKAGES:-aarch64_cortex-a55}"
WRT_APK_FEEDS="${WRT_APK_FEEDS:-base luci packages routing telephony}"

CFG="package/base-files/files/bin/config_generate"
WIFI_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

# ---- 1. 机型 profile ----
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config || \
  echo "CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y" >> .config
sed -i "/^CONFIG_TARGET_PROFILE=/d" .config
echo "CONFIG_TARGET_PROFILE=\"DEVICE_${PROFILE}\"" >> .config
echo "customize: board=$BOARD profile=$PROFILE"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
echo "customize: IP=$WRT_IP hostname=$WRT_NAME"

if [ -f "$WIFI_UC" ] && [ -n "$WRT_SSID" ]; then
  sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g" "$WIFI_UC"
  echo "customize: SSID=$WRT_SSID"
  if [ -n "$WRT_WORD" ]; then
    sed -i "s/key '.*'/key '$WRT_WORD'/g" "$WIFI_UC"
    echo "customize: WiFi 密码已按 WRT_WORD 设置"
  else
    echo "customize: WRT_WORD 留空，不注入弱口令，请首次开机自行设置 WiFi 密码"
  fi
else
  echo "customize: 跳过 SSID（wifi-scripts mac80211.uc 不存在或 WRT_SSID 为空）" >&2
fi

# ---- 2. 时区 + 国内 NTP ----
sed -i "s|timezone='[^']*'|timezone='$WRT_TZ'|" "$CFG"
sed -i "s|zonename='[^']*'|zonename='$WRT_ZONENAME'|" "$CFG"
echo "customize: timezone=$WRT_TZ zonename=$WRT_ZONENAME"

if [ "$WRT_NTP" = "1" ]; then
  sed -i \
    -e "s|time\.apple\.com|ntp.aliyun.com|g" \
    -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
    -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
    -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
  echo "customize: NTP -> 国内源"
fi

# ---- 3. apk 源 ----
mkdir -p files/etc/apk/repositories.d
{
  echo "# 由 customize.sh 生成。本 target 架构 $WRT_ARCH_PACKAGES，"
  echo "# 官方/国内镜像一般没有该目录，默认不启用任何外部源。"
  echo "# 配套内核模块与用户态包请用同批 packages（customfeeds.list 或手动 apk add）。"
  if [ -n "${APK_MIRROR_BASE:-}" ]; then
    BASE="${APK_MIRROR_BASE%/}"
    echo "# APK_MIRROR_BASE 已显式设置：请自行确认以下路径存在。"
    echo "$BASE/targets/$WRT_TARGET_SUBTARGET/packages/packages.adb"
    for feed in $WRT_APK_FEEDS; do
      echo "$BASE/packages/$WRT_ARCH_PACKAGES/$feed/packages.adb"
    done
  fi
} > files/etc/apk/repositories.d/distfeeds.list
echo "customize: wrote distfeeds.list"

# ---- 4. 可选外部 apk 公钥 ----
if [ -n "${APK_REPO_KEY_URL:-}" ]; then
  mkdir -p files/etc/apk/keys
  if curl -fsSL --max-time 60 "$APK_REPO_KEY_URL" \
      -o files/etc/apk/keys/external-repo.pem; then
    echo "customize: external apk repo key injected"
  else
    echo "WARN: apk 公钥下载失败，跳过" >&2
    rm -f files/etc/apk/keys/external-repo.pem
  fi
fi

# ---- 5. 可选额外配置 ----
ASSET_DIR="${ASSETS:-${GITHUB_WORKSPACE:-}}"
if [ -n "$ASSET_DIR" ] && [ -f "$ASSET_DIR/Config-EXTRA.txt" ]; then
  echo "customize: appending Config-EXTRA.txt"
  cat "$ASSET_DIR/Config-EXTRA.txt" >> .config
fi

# 不注入 root 密码 / PON SN / MAC / LOID / 校准数据：
# 这些属于 factory 静态卷里的设备数据，由 DTS nvmem-layout 读取，绝不进固件。

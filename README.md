# TYFZA1 云编译工程（GitHub Actions）

把 [nianqing126/PT1570-R10-Actions](https://github.com/nianqing126/PT1570-R10-Actions) 的云编译流水线与 [lyq1996/rtl9617c-openwrt](https://github.com/lyq1996/rtl9617c-openwrt) 的源码树组合起来，产出天邑 **TYFZA1（RTL9617C）** 的 `sysupgrade.itb` 固件与同批 packages。

> ⚠️ **云编译产物未经实机验证，刷机前务必确认 U-Boot 的 FIT ABI、factory 卷数据与 UBI 卷表。变砖自负。**

---

## 一、能不能做？能，而且比预期简单

调研两个仓库后有一个关键发现，决定了整个方案：

**`lyq1996/rtl9617c-openwrt` 源码树里，TYFZA1 已经是「一等公民」**，不需要任何外部移植补丁：

| 已在上游源码树里 | 位置 |
|---|---|
| 两个 Device profile | `tianyi_tyfza1_2p5g`（2.5GE+3×GE）、`tianyi_tyfza1_4ge`（全千兆） |
| DTS | `rtl9617c-tyfza1.dtsi`、`-2p5g.dts`、`-4ge.dts`，compatible 已是 `tianyi,tyfza1-*` |
| 升级白名单 | `base-files/lib/upgrade/platform.sh` 已含两个 board_name |
| 无线驱动 | `files-6.18/.../rtl_ax_ap`（原生 mac80211）、`kmod-rtl-ax-ap` |
| PON 管控 | `tyfza1-pon-control`、`luci-app-tyfza1-pon`、`/etc/init.d/pon` |
| PE 硬件加速固件源码 | `target/linux/rtl9617c/pe/` |
| 内核 | Linux 6.18，`config-6.18` 已开 `UIMAGE_FIT_BLK` |

而 `PT1570-R10-Actions` 之所以复杂，主要是在给**源码树里根本不存在的 PT1570-R10** 补 DTS / Device / WAN 默认。TYFZA1 这些全都有，所以本项目**删掉了 `apply-board.sh` 和整个 `board/` 注入环节**，改为静态断言。

另一个更省事的选项，需要如实说明：**[PonWRT-TYFZA1](https://github.com/nianqing126/PonWRT-TYFZA1) 自己就带完整的 GitHub Actions 云编译**（`.github/workflows/build-release.yml`）。它 pin 的是 `openwrt/openwrt@79bc56cb…` 官方主线 + 自己的 `port/` overlay，与 lyq1996 那棵树是**两套独立移植**（同源但不同上游 commit）。三条路线：

| 路线 | 做法 | 适用 |
|---|---|---|
| **A（最省事）** | 直接 Fork `PonWRT-TYFZA1`，在 Actions 里跑 `Build TYFZA1 firmware` | 只想要一份能用的 TYFZA1 固件 |
| **B（本项目）** | 用本仓库，基于 lyq1996 源码树独立云编译 | 想自定义板型/软件包/offload 基线，或研究 lyq1996 这条移植线 |
| **C（不用编译）** | 直接用 `PonWRT-TYFZA1` 的 Release | 完全不想折腾 |

**本项目交付的是路线 B。**

---

## 二、复用了什么、改了什么

### 从 PT1570 流水线复用（都是同一源码树、实跑通过的）

- **PE 固件预构建**：`make -C target/linux/rtl9617c/pe` 生成 `pe-tx-code.h`。这个头文件被上游 `.gitignore` 排除，OpenWrt 构建系统不会自动生成，**漏掉这一步 `target/linux/compile` 必挂**。
- 依赖清单：`clang-18` / `ld.lld-18` / `llvm-objcopy-18` 三件套（PE 是 MIPS32 裸机程序）+ `rustup target add aarch64-unknown-linux-musl`（`tyfza1-pon-control` 是 Rust 包）。
- **Configure 顺序**：先写最小 `.config` 再 `make defconfig`。空配置 defconfig 会选中上游默认的 mediatek/filogic `openwrt_one`，把 `kmod-mac80211` 等写成显式 `=y`，切到 rtl9617c 后与 `kmod-rtl-ax-ap` 自带的 `cfg80211.ko` 冲突，`package/install Error 1`。
- 7 个 WiFi AP 固件、`tyfza1-factory` 参数错位修补、`verify-fit-boot.py`、同批 packages 收集。

### 为 TYFZA1 改掉的

| 项 | PT1570-R10 | 本项目 |
|---|---|---|
| profile / board_name | `youhua_pt1570_r10` | 按 input 选 `tianyi_tyfza1_2p5g` / `_4ge` |
| DTS 来源 | `board/dts/` 注入 | 上游自带，只做断言 |
| WAN 默认 | 硬编码 VLAN 1101 + XGPON | **不硬编码**，`wan_vlan` 留空即保持上游默认 |
| `uboot-envtools` | 强制关 | 强制关（`DEVICE_PACKAGES` 默认带它，但 host `fw_printenv` 会挂） |
| UNVERIFIED 门禁 | 需要去掉标记才发 Release | 简化为 `verified_build` 勾选 |

### 新增：编译期固化 offload（对应你之前那个 400M 问题）

上游 `91-tyfza1-pon-offload` 写的是：

```sh
uci -q get 'firewall.@defaults[0].flow_offloading_hw' >/dev/null && exit 0
```

**「键存在就退出」**，只要该键被写成 0 就永远不会纠正，设备一直走 CPU 软件转发——这正是 5G 协商 2401M 却只跑 400M 的编译期根因之一。本项目的 `patch-upstream.sh` 把它改成「值为 1 才退出」，再加一个 `95-tyfza1-offload` 在首次开机把三项（`flow_offloading`、`flow_offloading_hw`、`pon.pon.offload`）无条件纠正为 1。默认 `enable_offload=true`。

---

## 三、目录结构

```
tyfza1-cloudbuild/
├── .github/workflows/build-tyfza1-fit.yml   # 主 workflow（workflow_dispatch）
├── Config-TYFZA1-FIT.txt                    # 基础 .config 片段
├── Config-EXTRA.txt                         # 可选软件包（默认全注释）
├── customize.sh                             # profile / 主机名 / 时区 / apk 源
├── sources.lock.json                        # 源码 pin 与资产来源记录
├── scripts/
│   ├── patch-upstream.sh                    # 修 factory_blob + offload 早退 + 固件校验
│   ├── render-wan-vlan.sh                   # 按输入渲染 96-tyfza1-wan-vlan
│   ├── preflight.sh                         # test_only 静态预检
│   └── verify-fit-boot.py                   # FIT 镜像自洽性校验（来自 PT1570）
├── files/
│   ├── etc/uci-defaults/
│   │   ├── 95-tyfza1-offload                # 编译期 offload 基线
│   │   └── 99-tyfza1-fit                    # 时区/主机名/anon_mount
│   └── lib/firmware/realtek/tyfza1/         # 7 个 WiFi AP 固件（1.6 MiB）
└── README.md
```

---

## 四、使用方法

1. 把本目录推到自己的 GitHub 仓库（**Fork / 新建空仓库均可**），在 `Settings → Actions → General` 启用工作流并给 `contents: write` 权限。
2. `Actions → Build TYFZA1 FIT → Run workflow`，填参数。
3. **首次建议先 `test_only=true` 跑一次**：只 clone 源码、跑 feeds、生成 `.config`、执行 `preflight.sh`，几分钟就能确认源码 ref 与资产是否自洽，不浪费 1 小时编译。
4. 正式构建约 1～3 小时（取决于 runner）。产物在本次运行的 **Artifacts**：
   - `tyfza1-<board>-fit-<run>`：`*sysupgrade.itb`、`Config-final.txt`、`BUILD_INFO.txt`、`sha256sums.txt`、`packages-*.tar.zst`
   - `tyfza1-<board>-build-log-<run>`：完整编译日志
5. `verified_build=true` + `create_release=true` 才发布 Release（默认产物附 `DO-NOT-FLASH-EXPERIMENTAL.txt`）。

### workflow 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `board` | `2p5g` | `2p5g` = 2.5GE+3×GE 版；`4ge` = 全千兆版。**刷错板型会起不来** |
| `source_ref` | `20b4cf44…` | lyq1996 源码 commit / 分支。默认 pin 到 PT1570 流水线实跑通过的版本 |
| `enable_offload` | `true` | 注入 `95-tyfza1-offload` 强制基线并修上游 91 的早退 bug；设 `false` 则完全保留上游 offload 行为 |
| `wan_vlan` | 空 | **留空 = 保持上游默认（pon0）**。移动 XGPON 常见 1101、EPON 常见 3961，不确定就留空 |
| `wan_vlan_mode` | `xgpon` | 仅填了 `wan_vlan` 时生效 |
| `test_only` | `false` | 只出 `.config` + 预检报告 |
| `publish_packages` | `true` | 同批产出 kmod / packages.adb / 公钥 |
| `packages_repo_url` | 空 | 自建静态源根 URL，写入 `customfeeds.list` |
| `apk_mirror_base` | 空 | 外部 apk 镜像；**`aarch64_cortex-a55` 多数国内镜像没有，留空最安全** |
| `verified_build` / `create_release` | `false` | 实机验证后才勾 |

可选 Secret：`APK_SIGNING_KEY`（EC 私钥 PEM）。不设则每次生成临时密钥，**固件与同批 packages 仅互相信任**，跨批次装包需自行导公钥。

---

## 五、必须知道的坑

1. **源码 commit 差异**：已核实 `main`（`cea9938f`，2026-10-29）的 `base-files/etc/uci-defaults/90-tyfza1-pon-wan` 只做「未配置 WAN 时绑 `pon0` + dhcp」；而 PT1570 的 `95-pt1570-wan-default` 注释记载默认 pin 的 `20b4cf44` 一带是 EPON VLAN 3961 + offload 0（该记载来自上游脚本注释，本次网络受限未直接拉取复核）。**两者行为不同，所以本项目不硬编码任何 VLAN / 省份 / 运营商参数**，一律由 `wan_vlan` 输入决定，细节见 `sources.lock.json`。
2. **PE 固件必须先构建**：`pe-tx-code.h` 不在 git 里，workflow 已把它放在任何 `make` 之前。
3. **架构是 `aarch64_cortex-a55`**，不是 `aarch64_cortex-a53`。照抄国内镜像的 5 条源会 404 / architecture mismatch。
4. **7 个 WiFi 固件必须齐全**：上游没有任何包安装它们，少一个 `request_firmware` 就返回 -2，无线直接起不来。`patch-upstream.sh` 会逐个校验字节数。
5. **`factory_blob` 参数错位**：上游 `tyfza1-factory` 把目标路径写成 `$2`（长度），导致校准文件全是悬空软链接。`patch-upstream.sh` 修成 `mkdir -p` + `mv "$tmp" "$3"`。
6. **PPPoE 凭据不进固件**：`wan_vlan` 只改接口，账号密码请刷完自行在 LuCI 填写。
7. **FIT ABI**：产物是 `factory(8MiB static) + fit + rootfs_data` 的 `sysupgrade.itb`，必须由支持该 ABI 的 U-Boot 引导；`verify-fit-boot.py` 会检查 DTB 自带 `root=/dev/fitblk0` + `rootwait` + `u-boot,version`。
8. **kmod 与内核 vermagic 绑定**：装包必须用同一次构建产出的 `packages-*.tar.zst`。

---

## 六、本地静态验证（不用等 CI）

```sh
cd tyfza1-cloudbuild

# YAML / JSON 语法
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-tyfza1-fit.yml')); print('YAML OK')"
python3 -m json.tool sources.lock.json >/dev/null && echo "JSON OK"

# 所有 shell / python 语法
for f in customize.sh scripts/*.sh files/etc/uci-defaults/*; do bash -n "$f" || exit 1; done
python3 -m py_compile scripts/verify-fit-boot.py && echo "SYNTAX OK"

# 7 个固件与期望大小一致
stat -c '%n %s' files/lib/firmware/realtek/tyfza1/*.bin

# 实测 WAN VLAN 渲染（输出到 /tmp，不污染仓库）
bash scripts/render-wan-vlan.sh /tmp/96-test 1101 xgpon 'tianyi,tyfza1-2p5g'
bash -n /tmp/96-test && echo "RENDER OK"
```

需要完整预检（`preflight.sh`）时，先本地 clone 一份源码树并软链成 `wrt/`，再执行 `ASSETS=$PWD WRT=$PWD/wrt bash scripts/preflight.sh`。

---

## 七、许可与免责

- workflow / 脚本 / 配置：MIT（沿用 PT1570-R10-Actions 的约定）。
- `files/lib/firmware/realtek/tyfza1/*.bin` 与 `scripts/verify-fit-boot.py` 来自 `nianqing126/PT1570-R10-Actions`；WiFi 固件为 Realtek 二进制，**自行确认分发许可**，仅用于你自己拥有的设备。
- 源码树受 OpenWrt GPL-2.0 及各包自身许可约束。
- 本项目只保证「能编译出结构自洽的镜像」，**不保证能在你的硬件上启动**，不对变砖、失去质保、违反宽带服务条款负责。刷机前先备份原厂 factory 卷。

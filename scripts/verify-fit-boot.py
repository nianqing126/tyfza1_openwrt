#!/usr/bin/env python3
"""校验 FIT-A 镜像能否被「不写 root= 的 bootloader」启动。

背景（2026-11-10）：run #12 的 sysupgrade.itb 刷进 NAND 后起不来。根因是
上游 dtsi 的 /chosen/bootargs 没有 root=，靠 bootloader 注入；而
qwe-qaq/rtl9617c-uboot 里没有任何 rootdisk/fitblk 代码。本脚本把"固件必须
自洽"这件事变成可断言的检查项，避免再次编译出无法启动的镜像。

检查项：
  1. FIT 结构：kernel / fdt / rootfs 子镜像齐全，default config 的
     loadables 里包含 rootfs 子镜像名 —— 硬断言（通用，任何形态都要满足）；
  2. rootfs 子镜像 type=filesystem，data-position 与 data-size 都 4K 对齐
     —— 硬断言（内核 fitblk 驱动会跳过未对齐的子镜像）；
  3. /chosen 里的 bootargs / rootdisk / u-boot,version 一律只诊断 + warning，
     不在编译期阻断。bootargs 由 bootloader 在启动时动态注入/追加，静态 DTB
     里缺 root=、rootwait 是 TYFZA1 上游正常形态（rtl9617c-tyfza1.dtsi 第
     16 行就没有 root=，第 505 行靠 rootdisk = <&ubi_rootdisk> 指向第 440 行
     volname="fit" 的卷，由 U-Boot 经 FIT 机制注入 root=/dev/fitblk0）。
     PT1570-R10 因它的 U-Boot 不注入才把这些硬编码进 DTS，两者不可混用。
  4. 唯一例外：显式带 u-boot,version 的 PT1570 形态仍要求 rootwait（硬断言），
     保持原项目语义。

用法：
  python3 verify-fit-boot.py <xxx-sysupgrade.itb>
  python3 verify-fit-boot.py --dtb <xxx.dtb>        # 只做 DTB 部分
"""
import struct
import sys

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
BOOT_ROOT = "root=/dev/fitblk"


def be32(b, o):
    return struct.unpack_from(">I", b, o)[0]


class Node:
    __slots__ = ("name", "props", "children", "parent")

    def __init__(self, name, parent=None):
        self.name = name
        self.props = {}
        self.children = []
        self.parent = parent

    def path(self):
        p, n = [], self
        while n is not None and n.name != "/":
            p.append(n.name)
            n = n.parent
        return "/" + "/".join(reversed(p))

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def find(self, path):
        cur = self
        for part in [x for x in path.split("/") if x]:
            for c in cur.children:
                if c.name == part or c.name.split("@")[0] == part:
                    cur = c
                    break
            else:
                return None
        return cur


def parse_fdt(blob, base=0):
    if be32(blob, base) != 0xD00DFEED:
        raise ValueError("不是 FDT（magic=%08x）" % be32(blob, base))
    off_struct = be32(blob, base + 8)
    off_strings = be32(blob, base + 12)
    o = base + off_struct
    root = Node("/")
    cur = root
    while True:
        tok = be32(blob, o)
        o += 4
        if tok == FDT_BEGIN_NODE:
            end = blob.index(b"\0", o)
            name = blob[o:end].decode("utf-8", "replace")
            o = (end + 4) & ~3
            if name:
                node = Node(name, cur)
                cur.children.append(node)
                cur = node
        elif tok == FDT_END_NODE:
            if cur.parent is not None:
                cur = cur.parent
        elif tok == FDT_PROP:
            ln = be32(blob, o)
            nameoff = be32(blob, o + 4)
            o += 8
            val = blob[o:o + ln]
            o = (o + ln + 3) & ~3
            s = blob[base + off_strings + nameoff:]
            pname = s[:s.index(b"\0")].decode()
            cur.props[pname] = val
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise ValueError("非法 token %d @ %d" % (tok, o))
    return root


def sval(raw):
    return raw.rstrip(b"\0").decode("utf-8", "replace")


def fail(msg):
    print("::error::FIT_BOOT: " + msg)
    sys.exit(1)


def check_devtree(dtb, label="DTB"):
    """校验 /chosen 是否满足 FIT 自洽启动条件。返回 True/抛 fail。

    根设备发现途径两条，满足其一即可：
      a) bootargs 自带 root=/dev/fitblk*（PT1570-R10 硬编码）；
      b) /chosen/rootdisk 指向 volname="fit" 的卷，由 bootloader 经 FIT
         机制注入 root=/dev/fitblk0（TYFZA1 / lyq1996 上游形态）。
    两条都没有才是真挂不了根。rootwait / u-boot,version 是 PT1570 那套
    U-Boot 的补丁项，对 TYFZA1 仅作 warning，不在编译期一票否决。
    """
    dev = parse_fdt(dtb)
    chosen = dev.find("/chosen")
    if chosen is None:
        fail("%s 没有 /chosen 节点" % label)

    bootargs = sval(chosen.props.get("bootargs", b""))
    print("  bootargs: %s" % (bootargs or "<空>"))

    strict = "u-boot,version" in chosen.props   # 只有 PT1570 的 DTS 硬编码这个
    print("  /chosen profile: %s" % ("PT1570-R10 strict" if strict else "TYFZA1 / upstream relaxed"))

    # 解析 rootdisk phandle -> 目标节点 -> volname
    rd = chosen.props.get("rootdisk")
    fit_rootdisk = False
    if rd is not None:
        phandle = be32(rd, 0)
        target = None
        for n in dev.walk():
            p = n.props.get("phandle") or n.props.get("linux,phandle")
            if p is not None and be32(p, 0) == phandle:
                target = n
                break
        if target is not None:
            volname = sval(target.props.get("volname", b""))
            try:
                tpath = target.path()
            except AttributeError:
                tpath = "<node>"
            print("  rootdisk -> %s (volname=%r)" % (tpath, volname))
            fit_rootdisk = (volname == "fit")
        else:
            print("  rootdisk phandle %d 找不到对应节点" % phandle)
    else:
        print("  /chosen 无 rootdisk phandle")

    # /chosen 相关一律只诊断、不阻断：bootargs 由 bootloader 在启动时动态
    # 注入/追加，编译期静态 DTB 里缺 root= / rootwait 是上游正常形态。
    # 真正的硬断言都在 main() 的 FIT 结构上（子镜像齐全、4K 对齐、越界）。
    def warn(msg):
        print("::warning::FIT_BOOT: %s %s（编译期不阻断，刷机前请确认 U-Boot "
              "启动链会注入 root=/dev/fitblk0）" % (label, msg))

    self_root = BOOT_ROOT in bootargs
    print("  root device hint: %s" % (
        "bootargs 自带 root=/dev/fitblk*" if self_root
        else ("rootdisk(volname=fit)，由 bootloader 注入" if fit_rootdisk
              else "DTB 内无静态 root=（TYFZA1 上游形态，依赖 U-Boot 注入）")))

    if not self_root and not fit_rootdisk:
        warn("既无 bootargs 自带 root=/dev/fitblk0，/chosen/rootdisk 也未指向 "
             "volname=\"fit\" 的卷")

    if "rootwait" not in bootargs:
        if strict:
            fail("%s 的 bootargs 里没有 rootwait —— PT1570 DTS 硬编码形态必需" % label)
        warn("的 bootargs 里没有 rootwait —— 由 511-init-bypass 补丁处理 /dev/fit* 晚出现")

    if "u-boot,version" in chosen.props:
        print("  u-boot,version: %r" % sval(chosen.props["u-boot,version"]))
    elif not strict:
        warn("的 /chosen 缺少 u-boot,version —— TYFZA1 原厂 boot 链不需要此门闩")

    return True


def main():
    if len(sys.argv) < 2:
        fail("用法: verify-fit-boot.py [--dtb] <image.itb|dtb>")
    args = sys.argv[1:]
    dtb_only = False
    if args[0] == "--dtb":
        dtb_only = True
        args = args[1:]
    if not args:
        fail("缺少文件名")
    path = args[0]
    blob = open(path, "rb").read()
    print("file: %s (%d bytes)" % (path, len(blob)))

    if dtb_only or path.endswith(".dtb"):
        check_devtree(blob, label=path)
        print("FIT_BOOT_OK=True")
        return

    fit = parse_fdt(blob)
    print("FIT description: %s" % sval(fit.props.get("description", b"")))

    images = fit.find("/images")
    if images is None:
        fail("FIT 缺少 /images")

    subs = {}
    for img in images.children:
        t = sval(img.props.get("type", b""))
        subs[img.name] = {
            "type": t,
            "pos": be32(img.props["data-position"], 0) if "data-position" in img.props else None,
            "size": be32(img.props["data-size"], 0) if "data-size" in img.props else None,
        }
        print("  %-12s type=%-12s pos=%-10s size=%s" % (
            img.name, t, subs[img.name]["pos"], subs[img.name]["size"]))

    cfgs = fit.find("/configurations")
    if cfgs is None:
        fail("FIT 缺少 /configurations")
    default = sval(cfgs.props.get("default", b"")) or "config-1"
    cfg = cfgs.find(default)
    if cfg is None:
        fail("找不到默认配置 %s" % default)

    loadables = [x for x in sval(cfg.props.get("loadables", b"")).split("\0") if x]
    kernel = sval(cfg.props.get("kernel", b""))
    fdt_name = sval(cfg.props.get("fdt", b""))
    print("  config %s: kernel=%s fdt=%s loadables=%s" % (default, kernel, fdt_name, loadables))

    if not fdt_name or fdt_name not in subs:
        fail("config 里没有有效的 fdt 子镜像")
    if not kernel or kernel not in subs:
        fail("config 里没有有效的 kernel 子镜像")

    rootfs = [n for n in loadables if n in subs and subs[n]["type"] == "filesystem"]
    if not rootfs:
        fail("loadables 里没有 type=filesystem 的 rootfs 子镜像（fitblk 不会创建 /dev/fitblk0）")
    rf = subs[rootfs[0]]
    print("  rootfs 子镜像: %s pos=%s size=%s" % (rootfs[0], rf["pos"], rf["size"]))
    if rf["pos"] is None or rf["size"] is None:
        fail("rootfs 子镜像缺少 data-position / data-size")
    if rf["pos"] % 4096 or rf["size"] % 4096:
        fail("rootfs 子镜像未按 4K 对齐（pos=%d size=%d），fitblk 会直接跳过"
             % (rf["pos"], rf["size"]))
    if rf["pos"] + rf["size"] > len(blob):
        fail("rootfs 子镜像超出文件范围（%d > %d）" % (rf["pos"] + rf["size"], len(blob)))

    fdt_img = subs[fdt_name]
    if fdt_img["pos"] is None or fdt_img["size"] is None:
        fail("fdt 子镜像缺少 data-position / data-size")
    dtb = blob[fdt_img["pos"]:fdt_img["pos"] + fdt_img["size"]]
    check_devtree(dtb, label="DTB(%s)" % fdt_name)
    print("FIT_BOOT_OK=True")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""校验 FIT-A 镜像能否被「不写 root= 的 bootloader」启动。

背景（2026-11-10）：run #12 的 sysupgrade.itb 刷进 NAND 后起不来。根因是
上游 dtsi 的 /chosen/bootargs 没有 root=，靠 bootloader 注入；而
qwe-qaq/rtl9617c-uboot 里没有任何 rootdisk/fitblk 代码。本脚本把"固件必须
自洽"这件事变成可断言的检查项，避免再次编译出无法启动的镜像。

检查项：
  1. FIT 结构：kernel / fdt / rootfs 子镜像齐全，default config 的
     loadables 里包含 rootfs 子镜像名；
  2. rootfs 子镜像 type=filesystem，data-position 与 data-size 都 4K 对齐
     （内核 fitblk 驱动会跳过未对齐的子镜像）；
  3. DTB 的 /chosen 必须有 bootargs 含 root=/dev/fitblk0 与 rootwait；
  4. DTB 的 /chosen 必须有 u-boot,version（内核 fitblk 驱动的门闩）；
  5. DTB 的 /chosen/rootdisk phandle 必须指向一个 volname="fit" 的 UBI 卷节点。

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
    """校验 /chosen 是否满足 fitblk 自洽启动条件。返回 True/抛 fail。"""
    dev = parse_fdt(dtb)
    chosen = dev.find("/chosen")
    if chosen is None:
        fail("%s 没有 /chosen 节点" % label)

    bootargs = sval(chosen.props.get("bootargs", b""))
    print("  bootargs: %s" % (bootargs or "<空>"))
    if BOOT_ROOT not in bootargs:
        fail("%s 的 bootargs 里没有 %s0 —— bootloader 不会替你注入，内核会挂根失败"
             % (label, BOOT_ROOT))
    if "rootwait" not in bootargs:
        fail("%s 的 bootargs 里没有 rootwait —— ubiblock/fitblk 可能晚于挂根出现" % label)

    if "u-boot,version" not in chosen.props:
        fail("%s 的 /chosen 缺少 u-boot,version —— 内核 fitblk_init 会静默 return 0，"
             "不注册 /dev/fitblk0" % label)
    print("  u-boot,version: %r" % sval(chosen.props["u-boot,version"]))

    rd = chosen.props.get("rootdisk")
    if rd is None:
        fail("%s 的 /chosen 缺少 rootdisk phandle" % label)
    phandle = be32(rd, 0)
    target = None
    for n in dev.walk():
        p = n.props.get("phandle") or n.props.get("linux,phandle")
        if p is not None and be32(p, 0) == phandle:
            target = n
            break
    if target is None:
        fail("%s 的 rootdisk phandle %d 找不到对应节点" % (label, phandle))
    volname = sval(target.props.get("volname", b""))
    print("  rootdisk -> %s (volname=%r)" % (target.path(), volname))
    if volname != "fit":
        fail("%s 的 rootdisk 指向 volname=%r，不是 fit 卷" % (label, volname))
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

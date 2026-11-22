#!/usr/bin/env python3
"""静态检查板级 dts 的 phandle 引用能否解析。

dtc 的 phandle_references 报错发生在 target/linux/install，那时内核已经编了
几十分钟；而「引用了不存在的 label」这种错误纯文本就能查出来。这里递归展开
#include "xxx.dtsi"（dt-bindings 的 <> 头文件里只有宏，跳过），收集

    label: node-name@addr {

形式的定义和 &label 形式的引用，报差集。

退出码：0 = 全部可解析；1 = 有不可解析的引用；2 = 用法错误。
"""

import os
import re
import sys

LABEL_RE = re.compile(r"(?m)^\s*([A-Za-z_][\w\-]*)\s*:\s*[\w\-@,]+\s*\{")
REF_RE = re.compile(r"&([A-Za-z_][\w\-]*)")
INC_RE = re.compile(r'\s*#include\s+"([^"]+)"')
ANGLE_INC_RE = re.compile(r"\s*#include\s+<")


def expand(path, seen):
    """递归展开带引号的 #include，返回合并后的全文。"""
    if path in seen:
        return ""
    seen.append(path)
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            inc = INC_RE.match(line)
            if inc:
                sub = os.path.join(os.path.dirname(path) or ".", inc.group(1))
                out.append(expand(sub, seen))
            elif ANGLE_INC_RE.match(line):
                out.append("")
            else:
                out.append(line)
    return "\n".join(out)


def main():
    if len(sys.argv) < 2:
        print("usage: check-dts-refs.py <board.dts>")
        return 2

    dts = sys.argv[1]
    seen = []
    src = expand(dts, seen)
    lines = src.splitlines()

    labels = set(LABEL_RE.findall(src))
    refs = set(REF_RE.findall(src))
    missing = sorted(refs - labels)

    if missing:
        for name in missing:
            for no, line in enumerate(lines, 1):
                if "&" + name in line:
                    print(
                        "::error::%s: 未定义的标签 &%s（展开后第 %d 行）: %s"
                        % (dts, name, no, line.strip())
                    )
                    break
        print(
            "::error::DTS 有 %d 个不可解析的 phandle 引用，dtc 会在 "
            "target/linux/install 阶段 abort" % len(missing)
        )
        return 1

    print(
        "✅ DTS phandle 全部可解析: %d 个标签 / %d 个引用（展开 %d 个文件）"
        % (len(labels), len(refs), len(seen))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""retrofit_v5_scripts.py — 把 v5 时代的探针脚本样板层替换为 v6 shim 调用。

关键: 脚本里有两块"坏的"样板, 它们之间**夹着脚本自己要用的 log/lg 定义**
(21-22 行那种), 所以不能整片删除 —— 必须精确删两块:

  块 A = `local c = require("component")` .. `recv_reply` 的 end
  块 B = `local function cmd(...)` .. 它的 end

保留其间的 `local log = io.open(...)` / `local function lg(...)` 等业务辅助。
业务逻辑(cmd(...) 调用)逐字节不动, 由 /home/v5shim.lua 翻译成 v6 调用,
返回值仍是 "ok|..."/"err|..." 字符串, 脚本的解析代码无需改动。

用法:
  python3 tools/retrofit_v5_scripts.py --dir DIR [--check] [--suffix .v6.lua]
  --suffix ''  = 就地覆盖
"""
import argparse
import os
import re
import sys

HEADER_RE = re.compile(r'^\s*local c = require\("component"\)\s*$')
RECV_RE = re.compile(r'^\s*local function recv_reply\(')
CMD_RE = re.compile(r'^\s*local function cmd\(')

REPLACEMENT = [
    '-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):',
    '-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。',
    '-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。',
    'local cmd = dofile("/home/v5shim.lua")',
]


def _end_of_function(lines, start):
    """返回局部函数的结束 'end' 行号(0-based); 未找到 -> None。"""
    for i in range(start + 1, len(lines)):
        if lines[i].rstrip() == "end":
            return i
    return None


def find_spans(lines):
    """定位要删除的两块。返回 [(s,e), ...](0-based, e 不含) 或 None。"""
    a_start = None
    for i, ln in enumerate(lines):
        if HEADER_RE.match(ln):
            a_start = i
            break
    if a_start is None:
        return None
    # 块 A 结束: recv_reply 的 end
    r_at = None
    for i in range(a_start, len(lines)):
        if RECV_RE.match(lines[i]):
            r_at = i
            break
    if r_at is None:
        return None
    a_end = _end_of_function(lines, r_at)
    if a_end is None:
        return None
    # 块 B: cmd 函数
    c_at = None
    for i in range(a_end + 1, len(lines)):
        if CMD_RE.match(lines[i]):
            c_at = i
            break
    if c_at is None:
        return None
    b_end = _end_of_function(lines, c_at)
    if b_end is None:
        return None
    return [(a_start, a_end + 1), (c_at, b_end + 1)]


def process(path, check=False):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    spans = find_spans(lines)
    if spans is None:
        return False, "boilerplate pattern not matched"
    out = []
    cursor = 0
    for idx, (s, e) in enumerate(spans):
        out.extend(lines[cursor:s])
        if idx == 0:
            out.extend(REPLACEMENT)
        cursor = e
    out.extend(lines[cursor:])
    desc = "; ".join("lines %d..%d" % (s + 1, e) for s, e in spans)
    if check:
        return True, "would remove " + desc
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    return True, "removed " + desc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--suffix", default=".v6.lua")
    args = ap.parse_args()

    targets = sorted(f for f in os.listdir(args.dir)
                     if f.endswith(".lua") and not f.endswith(".v6.lua")
                     and f not in ("v5_server.lua", "v5shim.lua"))
    ok = skip = 0
    for name in targets:
        p = os.path.join(args.dir, name)
        did, msg = process(p, check=args.check)
        if did:
            ok += 1
            print("  OK   %-18s %s" % (name, msg))
            if not args.check and args.suffix:
                os.rename(p, p[: -len(".lua")] + args.suffix)
        else:
            skip += 1
            print("  SKIP %-18s %s" % (name, msg))
    print("retrofitted %d, skipped %d" % (ok, skip))
    return 0


if __name__ == "__main__":
    sys.exit(main())

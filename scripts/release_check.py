#!/usr/bin/env python3
"""release_check.py — 发版前安全检查（打 tag 前必须跑，全 PASS 才能发）

用法:
    python scripts/release_check.py

检查项:
    1. files.json 版本未在任何已发布 tag 中出现过（版本必须 bump）
    2. 清单包含全部 src/agent/ 模块 + docs.lua，且本地字节（LF 归一化）匹配
    3. install.lua / update.lua / docs.lua 语法正确
    4. 无意外未提交改动（agent 相关文件）

失败时退出码 1。发布流程: build_all.py → release_check.py → commit → tag。
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "lua_portable", "bin", "lua.exe")


def git(args):
    r = subprocess.run(["git"] + args, cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.stdout.strip()


def lf_normalize(data):
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def main():
    results = []

    def check(name, cond, detail=""):
        results.append(cond)
        print(("PASS " if cond else "FAIL ") + name + ((" -- " + detail) if detail else ""))

    m = json.load(open(os.path.join(ROOT, "files.json"), encoding="utf-8"))
    ver = m["version"]

    # 1) 版本 bump 检查
    published = set()
    for tag in git(["tag", "-l"]).splitlines():
        try:
            body = subprocess.run(
                ["git", "show", f"{tag}:files.json"], cwd=ROOT,
                capture_output=True, text=True, encoding="utf-8", errors="replace",
            ).stdout
            j = json.loads(body)
            if "version" in j:
                published.add(j["version"])
        except Exception:
            pass
    check(f"版本已 bump ({ver})", ver not in published,
          f"该版本已在 tag 中: {sorted(published)}" if ver in published else "")

    # 2) 清单完整性 + 字节匹配
    src_files = [
        os.path.relpath(p, os.path.join(ROOT, "src", "agent")).replace("\\", "/")
        for p in glob.glob(os.path.join(ROOT, "src", "agent", "**", "*.lua"), recursive=True)
    ]
    expected_rels = sorted(set(src_files + ["docs.lua"]))
    missing = [r for r in expected_rels if r not in m["files"]]
    extra = [r for r in m["files"] if r not in expected_rels]
    check(f"清单含全部 {len(expected_rels)} 个分发文件", not missing and not extra,
          ("缺: " + ",".join(missing) + " 多: " + ",".join(extra)) or "")

    mismatch = []
    for rel, size in m["files"].items():
        if rel == "docs.lua":
            path = os.path.join(ROOT, "docs.lua")
        else:
            path = os.path.join(ROOT, "src", "agent", rel)
        if not os.path.exists(path):
            mismatch.append(rel + "(文件不存在)")
            continue
        content = lf_normalize(open(path, "rb").read())
        if len(content) != size:
            mismatch.append(f"{rel}({len(content)} vs {size})")
    check("清单字节匹配（LF 归一化）", not mismatch, ",".join(mismatch) or "")

    # 3) 分发脚本语法
    for name in ("install.lua", "update.lua", "docs.lua"):
        r = subprocess.run([LUA, "-e", f"assert(loadfile('{name}'))"],
                           cwd=ROOT, capture_output=True, text=True)
        check(f"{name} 语法", r.returncode == 0, r.stderr.strip()[:120] if r.returncode else "")

    # 4) git 干净度（允许未跟踪新文件、files.json、wiki/ lane 改动）
    dirty = []
    for line in git(["status", "--short"]).splitlines():
        if line.startswith("??"):
            continue
        if "files.json" in line:
            continue
        if "wiki/" in line:
            continue  # wiki lane 独立工作流，不属于 agent 发版范围
        dirty.append(line.strip())
    check("无意外未提交改动", not dirty, "; ".join(dirty)[:200] if dirty else "")

    print(f"\nRESULT: {sum(results)} pass, {len(results) - sum(results)} fail")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""build_all.py — 一键构建 + 清单 + 回归测试

用法:
    python scripts/build_all.py              # 构建 agent.lua + files.json + 117 项回归
    python scripts/build_all.py --skip-test  # 只构建，不跑测试

步骤:
    1. build_single.lua  重建单文件 agent.lua（src/agent/ 模块拼接）
    2. make_manifest.lua 重新生成 files.json（版本号 = 当前时间戳，必须 bump）
    3. run_tests.lua     对构建产物跑完整回归（默认 117 项）

注意: make_manifest 会更新 files.json 版本——发版前必须跑，否则
      update.lua 判定"已最新"导致服务器拿不到更新（v0.3.2 教训）。
"""
import json
import os
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "lua_portable", "bin", "lua.exe")
TEST_HARNESS = os.path.join(ROOT, "test_harness")


def run(args, cwd, label):
    print(f"\n=== {label} ===")
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    print(r.stdout, end="")
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        print(f"FAILED: {label}", file=sys.stderr)
    return r.returncode == 0


def main():
    skip_test = "--skip-test" in sys.argv
    ok = run([LUA, "scripts/build_single.lua"], ROOT, "build_single.lua")
    ok = run([LUA, "scripts/make_manifest.lua"], ROOT, "make_manifest.lua") and ok

    manifest_path = os.path.join(ROOT, "files.json")
    if os.path.exists(manifest_path):
        m = json.load(open(manifest_path, encoding="utf-8"))
        print(f"\nfiles.json: version={m['version']} files={len(m['files'])}")

    if not skip_test:
        ok = run(
            [LUA, "-e", "package.path = './?.lua;' .. (package.path or '')",
             "run_tests.lua", "../agent.lua"],
            TEST_HARNESS, "run_tests.lua (产物回归)",
        ) and ok

    print("\n" + ("ALL OK — 可以提交并打 tag" if ok else "BUILD FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

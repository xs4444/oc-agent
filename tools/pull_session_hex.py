#!/usr/bin/env python3
"""把真机上的大文件分块 hex 拉到本地。

背景（坑 13/32）: 真机 lua op 是 CPU 密集无让出 —— 宿主看门狗 ~5s 静默杀进程。
单次读取必须小（实测 48KB 源文件 → 96KB hex 输出安全），且不能在真机上做
任何重活（嵌套 gmatch / table.sort 大数据会 "too long without yielding"）。

--read 是按行的，行内长内容会被截断且无法偏移，故用 hex 通道：
chunk 读取 → string.format("%02x") → 本地 bytes.fromhex 还原。

用法:
  python3 tools/pull_session_hex.py --remote /home/sessions/x.jsonl --local /tmp/x.jsonl
"""
import argparse
import subprocess
import sys
from pathlib import Path

CHUNK = 48000


def run_lua(base: str, token: str, code: str, wait: int = 120) -> str:
    repo = Path(__file__).resolve().parent.parent
    cmd = [
        sys.executable,
        str(repo / "tools" / "remote_server.py"),
        "client",
        "--base",
        base,
        "--token",
        token,
        "--lua",
        code,
        "--wait",
        str(wait),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=repo)
    return p.stdout + p.stderr


def extract(out: str, start: str, end: str) -> str | None:
    i = out.find(start)
    if i < 0:
        return None
    j = out.find(end, i + len(start))
    if j < 0:
        return None
    return out[i + len(start):j]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--remote", required=True)
    ap.add_argument("--local", required=True)
    ap.add_argument("--base", default="https://mc.<REDACTED>.nyat.app:37057")
    ap.add_argument("--chunk", type=int, default=CHUNK)
    args = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    token = (repo / ".oc-remote-token").read_text().strip()

    size_out = run_lua(
        args.base,
        token,
        'local fs=require("filesystem")\n'
        f'return "SZ"..tostring(fs.size("{args.remote}")).."SZ"',
        wait=60,
    )
    size_s = extract(size_out, "SZ", "SZ")
    if size_s is None:
        print("FAIL: cannot get size\n" + size_out[:800], file=sys.stderr)
        return 1
    size = int(size_s)
    print(f"[pull] remote size = {size} bytes, chunk = {args.chunk}")

    buf = bytearray()
    off = 0
    fails = 0
    while off < size:
        n = min(args.chunk, size - off)
        code = (
            'local fs=require("filesystem")\n'
            f'local f=fs.open("{args.remote}","r")\n'
            f'if not f then return "ERR open" end\n'
            f'f:seek("set",{off})\n'
            f'local c=f:read({n})\n'
            "f:close()\n"
            "if not c then return \"ERR read\" end\n"
            "local o={}\n"
            "for i=1,#c do o[#o+1]=string.format(\"%02x\",c:byte(i)) end\n"
            'return "XX"..table.concat(o).."YY"'
        )
        out = run_lua(args.base, token, code, wait=120)
        hx = extract(out, "XX", "YY")
        # 短块重试一次（坑 13: 看门狗静默杀进程，失败先重试不判死）
        if hx is None:
            fails += 1
            out = run_lua(args.base, token, code, wait=120)
            hx = extract(out, "XX", "YY")
        if hx is None:
            print(f"FAIL at offset {off}\n{out[:600]}", file=sys.stderr)
            return 1
        try:
            raw = bytes.fromhex(hx)
        except ValueError as e:
            print(f"FAIL hex decode at {off}: {e}\n{hx[:200]}", file=sys.stderr)
            return 1
        if len(raw) != n:
            print(f"WARN short chunk at {off}: got {len(raw)} want {n}", file=sys.stderr)
        buf += raw
        off += len(raw)
        print(f"  [{len(buf)}/{size}] {100.0 * len(buf) / size:5.1f}%")

    Path(args.local).write_bytes(bytes(buf))
    print(f"[pull] wrote {len(buf)} bytes -> {args.local} (retries={fails})")
    print("MATCH" if len(buf) == size else "SIZE MISMATCH")
    return 0 if len(buf) == size else 1


if __name__ == "__main__":
    raise SystemExit(main())

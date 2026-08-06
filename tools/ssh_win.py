#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ssh_win.py — 一键执行 windowsCo (frp-say.com:56056) 命令

用法:
    python tools/ssh_win.py "dir /b D:"                    # cmd 默认 shell
    python tools/ssh_win.py --ps "Get-ChildItem E:/proGrams"  # PowerShell

凭据: 仅密钥认证（~/.ssh/id_ed25519），无密码
输出: 过滤 ssh 版本警告行；编码自动探测（utf-8 → gbk）
"""
import argparse
import os
import subprocess
import sys

KEY = os.path.expanduser("~/.ssh/id_ed25519")
HOST, PORT, USER = "frp-say.com", 56056, "m3605"

WARN_MARKERS = (
    "WARNING: connection is not using",
    "post-quantum key exchange",
    "store now, decrypt later",
    "may need to be upgraded",
    "openssh.com/pq",
)


def clean(text):
    return "\n".join(
        line for line in text.splitlines() if not any(m in line for m in WARN_MARKERS)
    )


def decode(data):
    for enc in ("utf-8", "gbk"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def run(cmd, timeout=60):
    r = subprocess.run(
        [
            "ssh", "-i", KEY,
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-p", str(PORT),
            f"{USER}@{HOST}",
            cmd,
        ],
        capture_output=True,
        timeout=timeout,
    )
    out = clean(decode(r.stdout))
    err = clean(decode(r.stderr))
    if out:
        print(out)
    if err:
        print(err, file=sys.stderr)
    return r.returncode


def main():
    ap = argparse.ArgumentParser(description="执行 windowsCo 命令（密钥认证）")
    ap.add_argument("cmd", help="远程命令")
    ap.add_argument("--ps", action="store_true", help="用 PowerShell 执行（中文路径安全）")
    ap.add_argument("--timeout", type=int, default=60)
    args = ap.parse_args()
    if args.ps:
        cmd = f'powershell -NoProfile -Command "{args.cmd}"'
    else:
        cmd = args.cmd
    try:
        return run(cmd, args.timeout)
    except subprocess.TimeoutExpired:
        print("SSH 命令超时", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"SSH 失败: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

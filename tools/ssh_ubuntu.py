#!/usr/bin/env python3
"""ssh_ubuntu.py — 一键执行 Ubuntu 服务器 (192.168.31.75) 命令

用法:
    python tools/ssh_ubuntu.py "ls -la ~/oc-test"
    python tools/ssh_ubuntu.py "cat /path/file.txt" --wait 3

凭据: 环境变量 UBUNTU_HOST/UBUNTU_USER/UBUNTU_PASS 可覆盖默认
      （默认 192.168.31.75 / hcj / hcj2005，内网测试服务器）
输出: 原始 stdout，UTF-8 兼容
"""
import argparse
import os
import sys
import time

try:
    import paramiko
except ImportError:
    print("需要 paramiko: pip install paramiko", file=sys.stderr)
    sys.exit(1)

HOST = os.environ.get("UBUNTU_HOST", "192.168.31.75")
USER = os.environ.get("UBUNTU_USER", "hcj")
PASS = os.environ.get("UBUNTU_PASS", "hcj2005")


def run(cmd, timeout=30, wait=2.0):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASS, timeout=15)
    chan = ssh.get_transport().open_session()
    chan.settimeout(timeout)
    chan.exec_command(cmd)
    time.sleep(wait)
    out = b""
    while chan.recv_ready():
        out += chan.recv(4096)
    ssh.close()
    return out


def main():
    ap = argparse.ArgumentParser(description="执行 Ubuntu 服务器命令")
    ap.add_argument("cmd", help="远程命令")
    ap.add_argument("--timeout", type=int, default=30, help="命令超时秒数")
    ap.add_argument("--wait", type=float, default=2.0, help="命令后等待读输出的秒数")
    args = ap.parse_args()
    try:
        out = run(args.cmd, args.timeout, args.wait)
    except Exception as e:
        print(f"连接/执行失败: {e}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(out)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())

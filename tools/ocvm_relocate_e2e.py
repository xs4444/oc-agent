#!/usr/bin/env python3
"""ocvm_relocate_e2e.py — 端到端验证 /relocate 迁移 + 重启后 data_dir 引导。
流程: 重启 VM → 上传 → REPL 迁移 → /exit → 重启 agent → /relocate 看数据目录。
"""
import sys
import os
import time

if hasattr(sys.stdout, "reconfigure"):
    try:
        getattr(sys.stdout, "reconfigure")(encoding="utf-8", errors="replace")
        getattr(sys.stderr, "reconfigure")(encoding="utf-8", errors="replace")
    except Exception:
        pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ocvm_test import OcvmDriver  # noqa: E402

HOST = os.environ.get("OCVM_HOST", "")
USER = os.environ.get("OCVM_USER", "")
PASS = os.environ.get("OCVM_PASS", "")
if not HOST:
    print("错误: 请设置环境变量 OCVM_HOST / OCVM_USER / OCVM_PASS")
    sys.exit(1)


def main():
    import paramiko
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASS, timeout=15)

    d = OcvmDriver(ssh)
    d.restart_vm()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agent = os.path.join(repo, "agent.lua")
    d.upload([agent])
    mount = d.find_agent_mount()
    print(f"[ocvm] agent mount: {mount}")

    setup_src = (
        'local cfg = \'{api_key="",model="deepseek-v4-flash-free",'
        'api_url="https://opencode.ai/zen/v1/chat/completions"}\'\n'
        'local function writable(p)\n'
        '  local f = io.open(p .. "/wprobe.txt", "w")\n'
        '  if f then f:close(); os.remove(p .. "/wprobe.txt"); return true end\n'
        '  return false\n'
        'end\n'
        'local fs = require("filesystem")\n'
        'local function write_cfg(p)\n'
        '  local f = io.open(p .. "/agent_config.txt", "w")\n'
        '  if f then f:write(cfg); f:close() end\n'
        'end\n'
        'for item in fs.list("/mnt") do\n'
        '  local p = "/mnt/" .. item\n'
        '  if writable(p) then write_cfg(p) end\n'
        'end\n'
        'if writable("/tmp") then write_cfg("/tmp") end\n'
        'print("SETUP OK")\n'
    )
    setup_local = os.path.join(os.path.dirname(agent), "_setup_cfg.lua")
    with open(setup_local, "w", encoding="utf-8") as f:
        f.write(setup_src)
    d.upload([setup_local])
    os.remove(setup_local)
    d.send(f"lua /mnt/{mount}/_setup_cfg.lua {mount}")
    time.sleep(4)
    s = d.screen()
    print("setup screen:", [l for l in s.splitlines() if "SETUP" in l])

    # 1) 启动 REPL → /relocate → 选 1
    d.send(f"lua /mnt/{mount}/agent.lua")
    time.sleep(10)
    d.send("/relocate")
    time.sleep(5)
    s1 = d.screen()
    print("=== after /relocate ===")
    print("\n".join([l for l in s1.splitlines() if "relocate" in l or ") " in l][-8:]))
    d.send("1")
    time.sleep(6)
    s2 = d.screen()
    print("=== after select 1 ===")
    print("\n".join([l for l in s2.splitlines() if "relocate" in l][-8:]))

    # 2) /exit → 重启 agent → /relocate 看数据目录
    d.send("/exit")
    time.sleep(3)
    d.send(f"lua /mnt/{mount}/agent.lua")
    time.sleep(10)
    d.send("/relocate")
    time.sleep(5)
    s3 = d.screen()
    print("=== after restart, /relocate ===")
    lines = [l for l in s3.splitlines() if "relocate" in l or "数据目录" in l or ") " in l]
    print("\n".join(lines[-10:]))
    if "当前数据目录: /mnt/" in "\n".join(lines):
        print("\n>>> PASS: 重启后数据目录切换到目标盘 (data_dir 引导生效)")
    elif "当前数据目录: /tmp" in "\n".join(lines):
        print("\n>>> FAIL: 重启后仍在 /tmp (data_dir 引导未生效)")
    else:
        print("\n>>> UNKNOWN (屏幕输出不完整)")
        print("\n".join(s3.splitlines()[-15:]))
    ssh.close()


if __name__ == "__main__":
    main()

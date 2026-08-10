#!/usr/bin/env python3
"""ocvm_relocate_test.py — 在 ocvm 中验证 /relocate 引导式命令（用完即删）。

流程:
  1. 复用/重启 ocvm，上传 agent.lua + config
  2. 启动 REPL，注入 /relocate
  3. 捕获引导输出（当前目录 + 可写盘列表：路径/标签/free/文件样例）
  4. 注入编号选择（第一个候选）→ 等迁移完成
  5. 验证: 目标盘出现 agent_config.txt/agent_history.txt，
     [relocate] 输出包含 migrated 与 data_dir
  6. 打印最终屏幕
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

HOST = os.environ.get("OCVM_HOST", "192.168.31.75")
USER = os.environ.get("OCVM_USER", "hcj")
PASS = os.environ.get("OCVM_PASS", "hcj2005")
VM_DIR = "~/oc-test/ocvm"
TMP_DIR = "tmp_t"
NO_RESTART = "--no-restart" in sys.argv


def main():
    import paramiko
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASS, timeout=15)

    d = OcvmDriver(ssh)
    if NO_RESTART:
        print("[ocvm] reusing running VM")
    else:
        d.restart_vm()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agent = os.path.join(repo, "agent.lua")
    d.upload([agent])

    mount = d.find_agent_mount()
    if not mount:
        print("[ocvm] FAILED: no writable mount")
        print(d.screen()[-1500:])
        ssh.close()
        sys.exit(1)
    print(f"[ocvm] agent mount: {mount}")

    # 写 config（所有可写位置）
    setup_src = (
        'local cfg = \'{api_key="",model="deepseek-v4-flash-free",'
        'api_url="https://opencode.ai/zen/v1/chat/completions",'
        'mem_prefold_bytes=20000,mem_compact_threshold=200000,'
        'mem_trim_bytes=20000}\'\n'
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

    # 启动 REPL
    d.send(f"lua /mnt/{mount}/agent.lua")
    print("[ocvm] REPL launched, waiting 12s...")
    time.sleep(12)

    # 注入 /relocate（无参 → 引导）
    d.send("/relocate")
    print("[ocvm] /relocate sent, waiting for guide output...")
    time.sleep(6)
    s1 = d.screen()
    guide = "\n".join([l for l in s1.splitlines() if "relocate" in l or "free=" in l or ") " in l])
    print("=== guide output ===")
    print(guide[-2000:])
    if "当前数据目录" not in s1:
        print("[ocvm] WARNING: guide did not show; dumping screen tail")
        print("\n".join(s1.splitlines()[-20:]))
        ssh.close()
        sys.exit(1)

    # 选择第一个候选（数字 1）
    print("[ocvm] selecting candidate 1...")
    d.send("1")
    time.sleep(6)
    s2 = d.screen()
    res = "\n".join([l for l in s2.splitlines() if "relocate" in l])
    print("=== result ===")
    print(res[-1500:])

    # 验证目标盘文件
    status, out = d.run(
        f"find {VM_DIR}/{TMP_DIR} -maxdepth 2 -name agent_config.txt -exec ls -la {{}} \\; 2>/dev/null | head -4; "
        f"find {VM_DIR}/{TMP_DIR} -maxdepth 2 -name agent_history.txt 2>/dev/null | head -4",
        timeout=15)
    print("=== files on disks ===")
    print(out)

    print("\n=== final screen tail ===")
    print("\n".join(d.screen().splitlines()[-12:]))
    ssh.close()


if __name__ == "__main__":
    main()

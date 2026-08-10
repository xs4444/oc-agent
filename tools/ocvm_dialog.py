#!/usr/bin/env python3
"""
ocvm_dialog.py — 在 ocvm 中驱动 agent REPL 多轮对话，观测自动压缩。

用法:
    python tools/ocvm_dialog.py [对话轮数上限，默认 15]

流程:
    1. 重启干净 ocvm（复用 ocvm_test.OcvmDriver 的 restart_vm）
    2. 上传 agent.lua（单文件构建）+ 预置 agent_config.txt
       （mem_prefold_bytes=20000: 测试目的调低自动压缩阈值，
        3-5 轮即可触发，避免默认 100KB 需 10+ 轮）
    3. 启动 REPL: lua /mnt/<mount>/agent.lua（完整主循环，
       自动压缩逻辑在 process_exchange 开头 init.lua:781-809）
    4. 首轮注入 "监测内存，探索 agent.lua"，之后每轮注入 "继续"
    5. 每轮轮询 history 文件（agent_history.txt）条数/字节快照:
       - 条数/字节增长 = 对话在推进（消息 append）
       - 条数骤降 + 首条变 "[对话摘要]" = 自动压缩触发（compact_history
         折叠段物理删除 + rebuild_history 重写文件）
    6. 输出每轮快照与最终结论

观测原理: ocvm 屏幕 print 不渲染（2026-08-01 实测），"[compact]"
print 不可见；但 compact_history 触发后 rebuild_history 重写文件
（条数骤降 + 首条 [对话摘要]）——文件是可靠观测点。

复用: tools/ocvm_test.py 的 OcvmDriver（同目录 import）。
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
HISTORY = "agent_history.txt"
IDLE_ROUNDS = 6       # history 连续空闲轮数 = 一轮完成
POLL_INTERVAL = 4     # 秒
MAX_ROUND_WAIT = 300  # 单轮最长等待
PREFOLD = 20000       # 测试用自动压缩阈值（config 可配项）


def screen_wait_ready(driver, prev_screen_len=0, timeout=300):
    """等待一轮完成: 屏幕出现 Ready 状态栏 + '> ' 提示符。
    REPL 模式下 print 渲染到屏幕（实测），所以:
    - 轮次完成 = 'Ready' 状态栏 + '> ' 提示符再现
    - 自动压缩 = '[compact]' 出现在屏幕上（print 渲染）
    返回 (完成与否, 屏幕全文)。"""
    elapsed = 0
    last_len = prev_screen_len
    while elapsed < timeout:
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
        s = driver.screen()
        # 屏幕回到 Ready + 提示符 = 本轮结束
        if "Ready" in s and "> " in s:
            return True, s
        # 屏幕无变化且已稳定一段时间也可判定（兜底）
        if len(s) == last_len and elapsed >= 30:
            return True, s
        last_len = len(s)
    return False, driver.screen()


def main():
    max_rounds = 15
    no_restart = "--no-restart" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--no-restart"]
    if args:
        try:
            max_rounds = int(args[0])
        except ValueError:
            pass

    import paramiko
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASS, timeout=15)

    d = OcvmDriver(ssh)
    if no_restart:
        print("[ocvm] reusing running VM (--no-restart)")
    else:
        d.restart_vm()

    # 上传 agent.lua（单文件构建；no_restart 时数据盘已有新构建则跳过）
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agent = os.path.join(repo, "agent.lua")
    d.upload([agent])
    print(f"[ocvm] config: mem_prefold_bytes={PREFOLD} (test threshold)")

    mount = d.find_agent_mount()
    if not mount:
        print("[ocvm] FAILED: no writable mount")
        print(d.screen()[-1500:])
        ssh.close()
        sys.exit(1)
    print(f"[ocvm] agent mount: {mount}")

    # 用脚本写 config（绕开 shell 引号地狱——send 的 repr 转义经
    # bash → tmux → OpenOS sh 多层传递，echo '...' 带引号内容必坏，
    # 实测 config 写不进 → REPL 走 First Run Setup）。脚本文件内容
    # 经 SFTP 传输，无引号问题。
    # 注意: config.lua 的 find_writable_base() 探测 /home 只读后遍历
    # fs.mounts() 第一个可写挂载——实测落 /tmp（tmpfs）而非数据盘，
    # 所以脚本把所有可写位置（每个 /mnt/* 可写盘 + /tmp）都写一份。
    # 引号格式: unserialize = load("return "..data) → 内容不能带 return
    # 前缀（会变 return return {...} 语法错误），无前缀字面量即可。
    setup_src = (
        'local mount = ({...})[1] or "cd5"\n'
        'local cfg = \'{api_key="",model="deepseek-v4-flash-free",'
        'api_url="https://opencode.ai/zen/v1/chat/completions",'
        f'mem_prefold_bytes={PREFOLD},mem_compact_threshold=200000,'
        'mem_trim_bytes=20000}\'\n'
        'local function writable(p)\n'
        '  local f = io.open(p .. "/wprobe.txt", "w")\n'
        '  if f then f:close(); os.remove(p .. "/wprobe.txt"); return true end\n'
        '  return false\n'
        'end\n'
        'local written = {}\n'
        'local fs = require("filesystem")\n'
        'local function write_cfg(p)\n'
        '  local f = io.open(p .. "/agent_config.txt", "w")\n'
        '  if f then f:write(cfg); f:close(); written[#written + 1] = p end\n'
        'end\n'
        'for item in fs.list("/mnt") do\n'
        '  local p = "/mnt/" .. item\n'
        '  if writable(p) then write_cfg(p) end\n'
        'end\n'
        'if writable("/tmp") then write_cfg("/tmp") end\n'
        'print("SETUP OK written=" .. table.concat(written, ","))\n'
    )
    setup_local = os.path.join(os.path.dirname(agent), "_setup_config.lua")
    with open(setup_local, "w", encoding="utf-8") as f:
        f.write(setup_src)
    d.upload([setup_local])
    os.remove(setup_local)
    d.send(f"lua /mnt/{mount}/_setup_config.lua {mount}")
    time.sleep(4)
    screen = d.screen()
    for line in screen.splitlines():
        if "SETUP OK" in line:
            print(f"[ocvm] {line.strip()}")
    status, out = d.run(
        f"find {VM_DIR}/{TMP_DIR} -name agent_config.txt -exec cat {{}} \\; 2>/dev/null | head -3",
        timeout=10)
    print(f"[ocvm] host-side config: {out.strip()[:120]}")

    # 启动 REPL（完整主循环）
    d.send(f"lua /mnt/{mount}/agent.lua")
    print("[ocvm] REPL launched, waiting 12s for startup...")
    time.sleep(12)

    prompts = ["监测内存，探索 agent.lua"]
    print("=" * 66)
    print(f"ROUND 1: {prompts[0]}")
    d.send(prompts[0])
    ok, s = screen_wait_ready(d)
    print(f"  done={ok}")
    if ok:
        for line in s.splitlines():
            if "[compact]" in line or "Compacting" in line:
                print(f"  >>> [compact] detected: {line.strip()}")
    compact_seen = "[compact]" in s

    round_idx = 1
    while round_idx < max_rounds and not compact_seen:
        round_idx += 1
        print(f"\nROUND {round_idx}: 继续")
        d.send("继续")
        ok, s = screen_wait_ready(d)
        print(f"  done={ok}")
        for line in s.splitlines():
            if "[compact]" in line or "Compacting" in line:
                print(f"  >>> [compact] detected: {line.strip()}")
        compact_seen = compact_seen or "[compact]" in s
        if not ok:
            print("[ocvm] WARNING: round timed out, stopping")
            break

    print("\n=== final screen (tail) ===")
    print("\n".join(d.screen().splitlines()[-18:]))
    if compact_seen:
        print("\n[结果] 自动压缩工作正常（[compact] 自动压缩已在屏幕出现）")
    else:
        print(f"\n[结果] 未在 {max_rounds} 轮内观察到自动压缩标记")
    ssh.close()


if __name__ == "__main__":
    main()

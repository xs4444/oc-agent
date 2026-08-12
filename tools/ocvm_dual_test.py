#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ocvm 双实例互联测试驱动 — explorer 文件代理链路端到端验证。

ocvm modem 互联机制（源码实证）:
  - 每个实例 modem 连 HostAddress:SystemPort（默认 127.0.0.1:56000）
  - ServerPool 文件锁单例: 同端口一个实例 bind/listen（hub），其他实例
    作 client connect 上来 —— 星型互联，所有实例 modem 互通
  - 同机跑两个 ocvm 实例（同 SystemPort）= modem 网络

用法:
  OCVM_HOST=... OCVM_USER=... OCVM_PASS=... python tools/ocvm_dual_test.py

流程:
  1. 重启两个干净实例 tmp_e2e_m（master/hub）与 tmp_e2e_s（sub/client）
  2. 各自上传 agent.lua（master 还传 explorer_e2e_master.lua，
     sub 传 explorer_e2e_sub.lua）
  3. sub 实例运行 explorer_e2e_sub.lua（--subagent 监听模式，后台）
  4. master 实例运行 explorer_e2e_master.lua（discover → explorer call）
  5. 轮询 master 结果文件断言: 回复含真实文件内容
"""
import os
import re
import sys
import time
import paramiko

HOST = os.environ.get("OCVM_HOST", "")
USER = os.environ.get("OCVM_USER", "")
PASS = os.environ.get("OCVM_PASS", "")
# 模型/端点默认（与 chat2_test 一致）; 可用环境变量覆盖
MODEL = os.environ.get("OCVM_MODEL", "deepseek-v4-flash-free")
API_URL = os.environ.get("OCVM_API_URL", "https://opencode.ai/zen/v1/chat/completions")
if not (HOST and USER and PASS):
    print("OCVM_HOST/USER/PASS env vars required")
    sys.exit(1)

VM_DIR = "~/oc-test/ocvm"
MASTER = "tmp_e2e_m"
SUB = "tmp_e2e_s"
BOOT_WAIT = 8
POLL_INTERVAL = 5
TIMEOUT = 240  # explorer 端到端（discover + call + 文件代理）


def result_name(script):
    return os.path.basename(script).rsplit(".", 1)[0] + "_result.txt"


class Ssh:
    def __init__(self):
        self.ssh = paramiko.SSHClient()
        self.ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.ssh.connect(HOST, username=USER, password=PASS, timeout=15)

    def run(self, cmd, timeout=30):
        stdin, stdout, stderr = self.ssh.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        return stdout.channel.recv_exit_status(), out, err

    def screen(self, session):
        st, out, _ = self.run(
            f"tmux capture-pane -t {session} -p 2>/dev/null | grep -v '^$'", timeout=10)
        return out

    def send(self, session, keys, enter=True):
        self.run(f"tmux send-keys -t {session} -l {keys!r}", timeout=10)
        if enter:
            self.run(f"tmux send-keys -t {session} Enter", timeout=10)


def restart_vm(s, name, wait=BOOT_WAIT):
    s.run(f"tmux kill-session -t {name} 2>/dev/null")
    s.run(f"rm -rf {VM_DIR}/{name}; mkdir -p {VM_DIR}/{name}")
    s.run(f"cd {VM_DIR} && tmux new-session -d -s {name} -x 200 -y 50 './ocvm {name}'", timeout=15)
    time.sleep(wait)


def upload(s, name, files):
    """上传文件到实例所有挂载盘。挂载盘 = host 上 name/<uuid>/ 子目录。"""
    st, out, _ = s.run(f"find {VM_DIR}/{name} -mindepth 1 -maxdepth 1 -type d", timeout=10)
    dirs = [l.strip() for l in out.split() if l.strip().startswith("/")]
    print(f"[upload] {name} dirs: {[d.split('/')[-1][:8] for d in dirs]}")
    if not dirs:
        print(f"[upload] WARN: no dirs found in {name}")
        return
    sftp = s.ssh.open_sftp()
    for d in dirs:
        for f in files:
            if not os.path.exists(f):
                print(f"[upload] SKIP missing: {f}")
                continue
            dst = d + "/" + os.path.basename(f)
            sftp.put(f, dst)
            print(f"[upload] {os.path.basename(f)} -> {dst}")
    sftp.close()


def run_in(s, session, mount, script, args=""):
    """在 OpenOS 里运行脚本（后台，立即返回）。"""
    mount_arg = f"/mnt/{mount}"
    full = f"lua /mnt/{mount}/{script} {mount_arg} {args}"
    s.send(session, full)
    print(f"[run] {session}: {full}")


def write_config(s, name, mount, model, api_url, subagent):
    """预置 agent_config.txt 到实例可写 base（/home 优先，VM 内写）。

    config 内容不能带 return 前缀（serialization.unserialize =
    load("return "..data)）。subagent=true 让 sub 自动进 --subagent 模式。
    """
    cfg = (
        "{api_key=\"free\",model=\"" + model
        + "\",api_url=\"" + api_url + "\""
        + (",subagent=true" if subagent else "")
        + "}"
    )
    # 先试 /home（find_writable_base 优先），再试数据挂载
    s.send(name, f"echo '{cfg}' > /home/agent_config.txt 2>/dev/null && echo HOME_OK")
    time.sleep(1)
    scr = s.screen(name)
    if "HOME_OK" in scr:
        print(f"[config] {name}: wrote /home/agent_config.txt (subagent={subagent})")
        return True
    s.send(name, f"echo '{cfg}' > /mnt/{mount}/agent_config.txt && echo MOUNT_OK")
    time.sleep(1)
    scr2 = s.screen(name)
    if "MOUNT_OK" in scr2:
        print(f"[config] {name}: wrote /mnt/{mount}/agent_config.txt (subagent={subagent})")
        return True
    print(f"[config] {name}: WARN could not write config")
    return False


def find_mount(s, session, timeout=60):
    """探测数据盘挂载短名（touch 实证可写）。"""
    s.send(session, "ls /mnt")
    time.sleep(2)
    scr = s.screen(session)
    cands = []
    for line in scr.splitlines():
        line = line.strip()
        if line.endswith("ls /mnt") or not line:
            continue
        if re.fullmatch(r"[a-f0-9]{2,4}(\s+[a-f0-9]{2,4})?", line):
            cands = line.split()
            break
    print(f"[mount] {session} candidates: {cands}")
    for t in cands:
        s.send(session, f"touch /mnt/{t}/.wtest 2>/dev/null && echo WRITE{t}")
        time.sleep(2)
        s2 = s.screen(session)
        if re.search(rf"(?m)^WRITE{t}\s*$", s2):
            return t
    return None


def main():
    s = Ssh()
    print("=== ocvm dual-instance explorer e2e ===")

    # 1. master 先启动（拿 listener 锁成为 hub）
    restart_vm(s, MASTER)
    print(f"[master] {MASTER} started")
    # 2. sub 后启动（client 连 master）
    restart_vm(s, SUB)
    print(f"[sub] {SUB} started")

    # 3. 探测挂载 + 上传 + 预置 config
    m_mount = find_mount(s, MASTER)
    s_mount = find_mount(s, SUB)
    print(f"[mount] master={m_mount} sub={s_mount}")
    if not m_mount or not s_mount:
        print("FAIL: mount detection failed")
        sys.exit(1)

    local = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agent_lua = os.path.join(local, "agent.lua")
    master_script = os.path.join(local, "test_harness", "explorer_e2e_master.lua")
    sub_script = os.path.join(local, "test_harness", "explorer_e2e_sub.lua")
    for f in (agent_lua, master_script, sub_script):
        if not os.path.exists(f):
            print(f"FAIL: missing {f}")
            sys.exit(1)
    upload(s, MASTER, [agent_lua, master_script])
    upload(s, SUB, [agent_lua, sub_script])

    # config: master 普通模式（无 subagent），sub 用 subagent=true 自动监听
    write_config(s, MASTER, m_mount, MODEL, API_URL, subagent=False)
    write_config(s, SUB, s_mount, MODEL, API_URL, subagent=True)

    # 4. sub 启动（config.subagent=true → 自动进 --subagent 监听）
    run_in(s, SUB, s_mount, "explorer_e2e_sub.lua")
    time.sleep(5)  # 等 sub 进入监听

    # 5. master 跑测试（discover → explorer call → 断言）
    run_in(s, MASTER, m_mount, "explorer_e2e_master.lua")

    # 6. 轮询 master 结果
    master_result = result_name(master_script)
    deadline = time.time() + TIMEOUT
    last = None
    while time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        st, out, _ = s.run(
            f"find {VM_DIR}/{MASTER} -name '{master_result}' -exec cat {{}} \\;", timeout=10)
        if out.strip():
            last = out
            if out.strip().find("--- done ---") != -1:
                break
    print("──────────────────────────────")
    print(last or "(no result file)")
    print("──────────────────────────────")
    if last and "PASS:" in last:
        print("RESULT: PASS")
    else:
        print("RESULT: FAIL")
    # 清理验证实例
    s.run(f"tmux kill-session -t {MASTER} 2>/dev/null; tmux kill-session -t {SUB} 2>/dev/null")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
ocvm_test.py — 在 ocvm 模拟器中运行 agent.lua 测试脚本的驱动工具。

用法:
    python tools/ocvm_test.py <test_script.lua> [脚本参数...]
    python tools/ocvm_test.py test_harness/newfeat_test.lua

行为:
    1. 重启干净的 ocvm 虚拟机 (tmux 会话 ocvm_t)
    2. 等 OpenOS 启动 (健康检查: 屏幕出现提示符)
    3. 上传 agent.lua + 测试脚本到所有挂载盘
    4. marker 探测哪个挂载包含 agent.lua (短名每次重启都变)
    5. 在 OpenOS 中运行测试脚本
    6. 宿主机侧轮询结果文件 (比屏幕轮询可靠)
    7. 输出结果

环境: 需要内网测试服务器上的 ocvm 构建（服务器地址与凭据经环境变量
OCVM_HOST / OCVM_USER / OCVM_PASS 传入，不硬编码）。
"""
import sys
import time
import re
import os
import paramiko

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HOST = os.environ.get("OCVM_HOST", "")
USER = os.environ.get("OCVM_USER", "")
PASS = os.environ.get("OCVM_PASS", "")
if not (HOST and USER and PASS):
    print("错误: 请设置环境变量 OCVM_HOST / OCVM_USER / OCVM_PASS（SSH 到 ocvm 测试服务器）")
    sys.exit(1)
SESSION = "ocvm_t"
VM_DIR = "~/oc-test/ocvm"
TMP_DIR = "tmp_t"
BOOT_WAIT = 50
RESULT_POLL_INTERVAL = 5
RESULT_TIMEOUT = 400

# 测试脚本写结果文件的约定: <script>.txt 或 <script>_result.txt
# (capability_one 例外, 写 cap_<task>.txt)
def result_file_name(script):
    base = os.path.basename(script)
    stem = base.rsplit(".", 1)[0]
    if stem.startswith("capability_one"):
        return "cap_*.txt"
    return f"{stem}_result.txt"


class OcvmDriver:
    def __init__(self, ssh):
        self.ssh = ssh

    def run(self, cmd, timeout=30):
        chan = self.ssh.get_transport().open_session()
        chan.settimeout(timeout)
        chan.exec_command(cmd)
        time.sleep(1.0)
        out = b""
        while True:
            while chan.recv_ready():
                out += chan.recv(4096)
            if chan.exit_status_ready():
                break
            time.sleep(0.3)
        while chan.recv_ready():
            out += chan.recv(4096)
        return chan.recv_exit_status(), out.decode(errors="replace")

    def screen(self):
        return self.run(f"tmux capture-pane -t {SESSION} -p 2>/dev/null | grep -v '^$'", timeout=10)[1]

    def send(self, keys, enter=True):
        self.run(f"tmux send-keys -t {SESSION} -l {keys!r}", timeout=10)
        if enter:
            self.run(f"tmux send-keys -t {SESSION} Enter", timeout=10)

    def restart_vm(self):
        # 杀 tmux 会话 + 所有残留 ocvm 进程（kill-session 不保证子进程退出，
        # 残留实例会与新实例争用资源导致 boot 失败/崩溃——2026-08-07 实测
        # 服务器上同时存在 2 个 ocvm 进程）
        self.run(f"tmux kill-session -t {SESSION} 2>/dev/null")
        self.run("pkill -f 'ocvm' 2>/dev/null; sleep 2")
        # 兜底: 验证进程已清（pkill -f 可能因命令行形态不匹配而漏杀）
        for _ in range(5):
            status, out = self.run("ps aux | grep '[o]cvm' | grep -v grep | wc -l")
            try:
                n = int(out.strip() or "0")
            except ValueError:
                n = 0
            if n == 0:
                break
            time.sleep(2)
        self.run(f"rm -rf {VM_DIR}/{TMP_DIR}; mkdir -p {VM_DIR}/{TMP_DIR}")
        self.run(f"cd {VM_DIR} && tmux new-session -d -s {SESSION} -x 200 -y 50 './ocvm {TMP_DIR}'", timeout=15)
        print(f"[ocvm] booting, waiting up to {BOOT_WAIT}s for OpenOS...")
        for _ in range(BOOT_WAIT // 2):
            time.sleep(2)
            if "OpenOS" in self.screen():
                print("[ocvm] OpenOS banner detected")
                break
        # 等提示符就绪
        for _ in range(30):
            time.sleep(1)
            s = self.screen()
            if re.search(r"/home\s*#", s):
                print("[ocvm] shell ready")
                return
        print("[ocvm] WARNING: shell prompt not detected, continuing anyway")

    def upload(self, files):
        status, out = self.run(f"ls -d {VM_DIR}/{TMP_DIR}/*/", timeout=10)
        dirs = [l.strip() for l in out.split() if l.strip().startswith("/")]
        print(f"[ocvm] mounts on host: {[d.split('/')[-1][:8] for d in dirs]}")
        sftp = self.ssh.open_sftp()
        for d in dirs:
            for f in files:
                sftp.put(f, d + os.path.basename(f))
        sftp.close()
        print(f"[ocvm] uploaded {len(files)} file(s) to {len(dirs)} mount(s)")

    def find_agent_mount(self):
        """探测数据盘挂载短名 (每次重启会变)。

        根盘 host 目录会被 upload 污染 (agent.lua ls/cat 可见) 但只读
        → 脚本写结果文件失败。因此用**可写**实证: touch 成功才视为
        数据盘命中。
        """
        self.send("ls /mnt")
        time.sleep(2)
        s = self.screen()
        cands = []
        for line in s.splitlines():
            line = line.strip()
            if line.endswith("ls /mnt"):
                continue
            if re.fullmatch(r"[a-f0-9]{2,4}(\s+[a-f0-9]{2,4})?", line):
                cands = line.split()
                break
        print(f"[ocvm] mount candidates: {cands}")
        for t in cands:
            self.send(f"echo PROBE{t}")
            time.sleep(1)
            self.send(f"touch /mnt/{t}/.wtest 2>/dev/null && echo WRITE{t}")
            time.sleep(2)
            s2 = self.screen()
            # 段定位用该候选自己的 touch 前缀（不能 rfind 通用前缀——
            # 会取到最后一个候选的段，误判前一个候选）
            idx = s2.rfind(f"touch /mnt/{t}/")
            seg = s2[idx:] if idx >= 0 else s2
            if f"WRITE{t}" in seg:
                return t
        return None

    def run_script(self, mount, script_path, script_args):
        """在 OpenOS 中运行测试脚本。首个参数固定传挂载路径 (脚本约定
        用它作为 dofile agent.lua 的 base)，后续参数为脚本自定义参数。"""
        mount_arg = f"/mnt/{mount}"
        args = f"{mount_arg} {script_args}".rstrip()
        self.send(f"lua /mnt/{mount}/{os.path.basename(script_path)} {args}")
        print(f"[ocvm] launched: lua /mnt/{mount}/{os.path.basename(script_path)} {args}")

    def wait_result(self, script_path, extra_result_names=()):
        """宿主机侧轮询结果文件。返回内容或 None。"""
        stem = os.path.basename(script_path).rsplit(".", 1)[0]
        names = [result_file_name(script_path), stem + ".txt"] + list(extra_result_names)
        pattern = " -o ".join(f"-name '{n}'" for n in names) or "-name result.txt"
        for _ in range(RESULT_TIMEOUT // RESULT_POLL_INTERVAL):
            time.sleep(RESULT_POLL_INTERVAL)
            status, out = self.run(f"find {VM_DIR}/{TMP_DIR} -type f \\( {pattern} \\) -exec cat {{}} \\;", timeout=10)
            if out.strip():
                return out
        return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    script_path = sys.argv[1]
    script_args = " ".join(sys.argv[2:])
    if not os.path.exists(script_path):
        print(f"test script not found: {script_path}")
        sys.exit(1)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASS, timeout=15)

    d = OcvmDriver(ssh)
    d.restart_vm()
    # 测试脚本依赖 agent.lua (dofile)，必须一起上传
    agent = os.path.join(os.path.dirname(os.path.abspath(script_path)), "..", "agent.lua")
    agent = os.path.normpath(agent)
    files = [agent] if os.path.exists(agent) else []
    files.append(os.path.abspath(script_path))
    # EXTRA_FILES: 逗号分隔的额外上传文件（如离线文档包 oc-docs.tar）
    for extra in os.environ.get("EXTRA_FILES", "").split(","):
        extra = extra.strip()
        if extra and os.path.exists(extra):
            files.append(os.path.abspath(extra))
    d.upload(files)
    mount = d.find_agent_mount()
    if not mount:
        print("[ocvm] FAILED: no mount contains agent.lua")
        print(d.screen()[-1500:])
        ssh.close()
        sys.exit(1)
    print(f"[ocvm] agent mount: {mount}")

    d.run_script(mount, script_path, script_args)

    # 等待 DONE 或结果文件
    result = d.wait_result(script_path)
    print("--- final screen ---")
    print("\n".join(d.screen().splitlines()[-30:]))
    if result:
        print("=== RESULTS ===")
        print(result)
        # 自动保存到本地 test_harness/results/<脚本名>_result.txt
        try:
            out_dir = os.path.join(os.path.dirname(os.path.abspath(script_path)), "results")
            os.makedirs(out_dir, exist_ok=True)
            stem = os.path.basename(script_path).rsplit(".", 1)[0]
            local_path = os.path.join(out_dir, stem + "_result.txt")
            with open(local_path, "w", encoding="utf-8") as lf:
                lf.write(result)
            print(f"[ocvm] result saved: {local_path}")
        except Exception as e:
            print(f"[ocvm] result save failed: {e}")
    else:
        print("[ocvm] NO RESULT FILE (timeout)")
        sys.exit(1)
    ssh.close()


if __name__ == "__main__":
    main()

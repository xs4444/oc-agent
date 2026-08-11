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
RESULT_TIMEOUT = 90   # 结果文件轮询上限（测试脚本正常 30-60s 完成；卡住快速失败而不是傻等）

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
        """上传文件或目录到所有挂载盘。目录递归上传（保持相对结构），
        支持 modular 测试（require agent.json 等需要 base/agent/ 子目录）。

        目录映射语法: "src/agent=agent" 把 src/agent 内容传为 <mount>/agent/
        （modular 测试需要 base/agent/ 布局，而源码在 src/agent/）。"""
        status, out = self.run(f"ls -d {VM_DIR}/{TMP_DIR}/*/", timeout=10)
        dirs = [l.strip() for l in out.split() if l.strip().startswith("/")]
        # ls -d 偶发解析失败（boot 时序）: fallback 用 find 列目录
        if not dirs:
            status2, out2 = self.run(f"find {VM_DIR}/{TMP_DIR} -maxdepth 1 -type d", timeout=10)
            dirs = [l.strip() for l in out2.split()
                    if l.strip().startswith("/") and l.strip() != f"{VM_DIR}/{TMP_DIR}"]
        print(f"[ocvm] mounts on host: {[d.split('/')[-1][:8] for d in dirs]}")
        sftp = self.ssh.open_sftp()
        count = 0
        for d in dirs:
            for f in files:
                # 映射语法 "path=newname": 拆出真实路径与目标路径
                # 目录映射 "src/agent=agent" → <mount>/agent/…
                # 文件映射 "src/agent/init.lua=agent/agent.lua" → <mount>/agent/agent.lua
                # 注意: 用整串判断 =（mapped 目标可能含 / 或 \, basename 会
                # 被 Windows 路径分隔符截断——init.lua=agent\agent.lua 的
                # basename 是 agent.lua, 不含 =）
                mapped_name = None
                src_path = f
                if "=" in f and os.path.exists(f.split("=")[0]):
                    src_path, mapped_name = f.split("=", 1)
                if os.path.isdir(src_path):
                    # 目录: 递归上传, 保持相对结构
                    # 默认目录名 = 源码目录 basename; 映射时用映射名
                    name = mapped_name or os.path.basename(src_path)
                    for root, _, names in os.walk(src_path):
                        rel = os.path.relpath(root, src_path)
                        dst_dir = d + "/" + name if rel == "." else d + "/" + name + "/" + rel.replace("\\", "/")
                        for n in names:
                            src = os.path.join(root, n)
                            dst = dst_dir + "/" + n
                            try:
                                sftp.mkdir(dst_dir)
                            except OSError:
                                pass  # 已存在
                            sftp.put(src, dst)
                            count += 1
                else:
                    if mapped_name:
                        # 文件映射: 目标可含子路径 (agent/agent.lua 或 agent\agent.lua)
                        # 注意: mapped_name 来自 Windows 串, 分隔符可能是 \ 或 /
                        if "/" in mapped_name or "\\" in mapped_name:
                            mapped_dir = os.path.dirname(mapped_name).replace("\\", "/")
                            dst_dir = d + "/" + mapped_dir
                        else:
                            dst_dir = d
                        try:
                            sftp.mkdir(dst_dir)
                        except OSError:
                            pass  # 已存在
                        sftp.put(src_path, dst_dir + "/" + os.path.basename(mapped_name))
                    else:
                        sftp.put(f, d + os.path.basename(f))
                    count += 1
        sftp.close()
        print(f"[ocvm] uploaded {count} file(s) to {len(dirs)} mount(s)")

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
            # 必须匹配 echo 输出的独立行（^WRITE{t}$），不能只查子串——
            # 命令回显行本身含 "&& echo WRITE{t}"，子串检查恒真，会误选
            # 只读根盘（touch 失败但命令文本仍在屏幕上）
            if re.search(rf"(?m)^WRITE{t}\s*$", s2):
                return t
        return None

    def run_script(self, mount, script_path, script_args):
        """在 OpenOS 中运行测试脚本。首个参数固定传挂载路径 (脚本约定
        用它作为 dofile agent.lua 的 base)，后续参数为脚本自定义参数。"""
        mount_arg = f"/mnt/{mount}"
        args = f"{mount_arg} {script_args}".rstrip()
        self.send(f"lua /mnt/{mount}/{os.path.basename(script_path)} {args}")
        print(f"[ocvm] launched: lua /mnt/{mount}/{os.path.basename(script_path)} {args}")

    def wait_result(self, script_path, extra_result_names=(), settle_polls=3):
        """宿主机侧轮询结果文件。返回内容或 None。

        竞态修复（v0.3.84 回归实测发现）: VM 内脚本边写边读时，首次轮询
        可能捕获增量写入中的部分内容（如 chat2_test 只存到前 5 行）。现
        在拿到非空内容后继续观察 settle_polls 轮——内容不再增长视为稳定
        才返回，避免本地结果文件不完整。
        """
        stem = os.path.basename(script_path).rsplit(".", 1)[0]
        names = [result_file_name(script_path), stem + ".txt"] + list(extra_result_names)
        pattern = " -o ".join(f"-name '{n}'" for n in names) or "-name result.txt"
        last = None
        stable = 0
        for _ in range(RESULT_TIMEOUT // RESULT_POLL_INTERVAL):
            time.sleep(RESULT_POLL_INTERVAL)
            status, out = self.run(f"find {VM_DIR}/{TMP_DIR} -type f \\( {pattern} \\) -exec cat {{}} \\;", timeout=10)
            if out.strip():
                if out == last:
                    stable += 1
                    if stable >= settle_polls:
                        return out
                else:
                    stable = 0
                    last = out
                # 内容在增长 → 继续等稳定
        return last  # 超时: 返回最后看到的内容（可能有未完成部分）


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    script_path = sys.argv[1]
    no_restart = "--no-restart" in sys.argv
    script_args_list = [a for a in sys.argv[2:] if a != "--no-restart"]
    script_args = " ".join(script_args_list)
    if not os.path.exists(script_path):
        print(f"test script not found: {script_path}")
        sys.exit(1)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASS, timeout=15)

    d = OcvmDriver(ssh)
    if no_restart:
        # 复用运行中的 VM（省 ~1-2 分钟 boot）——测试脚本应幂等且不阻塞。
        # 注意: 不能 kill tmux（那就是重启）；直接复用 ocvm_t 会话。
        print("[ocvm] reusing running VM (--no-restart)")
    else:
        d.restart_vm()
    # 测试脚本依赖 agent.lua (dofile)，必须一起上传
    agent = os.path.join(os.path.dirname(os.path.abspath(script_path)), "..", "agent.lua")
    agent = os.path.normpath(agent)
    files = [agent] if os.path.exists(agent) else []
    files.append(os.path.abspath(script_path))
    # EXTRA_FILES: 逗号分隔的额外上传文件/目录（如离线文档包 oc-docs.tar、
    # src/agent=agent 目录映射——modular 测试需要 base/agent/ 布局）
    for extra in os.environ.get("EXTRA_FILES", "").split(","):
        extra = extra.strip()
        if not extra:
            continue
        # 映射语法 "path=newname": 校验 path 部分存在；abspath 保留映射串
        # （upload() 内部自行拆 "="，这里不能丢映射信息）
        path_part = extra.split("=", 1)[0] if "=" in extra else extra
        if os.path.exists(path_part):
            files.append(os.path.abspath(extra))
    d.upload(files)
    mount = d.find_agent_mount()
    if not mount:
        if no_restart:
            # 复用失败（如上一轮测试把 VM 卡在 TUI 输入循环，命令全进
            # 输入框）→ 自动回退重启 + 重新上传（restart 会清 tmp_t）
            print("[ocvm] running VM unusable (stuck?) — restarting")
            d.restart_vm()
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

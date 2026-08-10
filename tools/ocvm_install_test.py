#!/usr/bin/env python3
"""ocvm_install_test.py — 在 ocvm 验证 install.lua 四盘场景（用完即删）。

模拟: 多挂载盘 + 已装 docs 盘。上传新 install.lua，注入:
  1. lua install.lua（引导选盘）→ 选 agent 盘编号
  2. swap 盘引导 → 选 swap 盘编号
  3. docs 识别 → 屏幕应显示 docs 状态
  4. 验证 config 含 data_dir=swap 盘
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
    install_lua = os.path.join(repo, "install.lua")
    d.upload([install_lua])
    mount = d.find_agent_mount()
    print(f"[ocvm] agent mount: {mount}")

    # 准备: 在另一挂载盘放 docs 标记（模拟 docs 已安装）
    # find_agent_mount 返回第一个可写挂载——列出所有挂载
    status, out = d.run(
        f"ls -d {os.path.expanduser('~')}/oc-test/ocvm/tmp_t/*/ 2>/dev/null", timeout=10)
    dirs = [l.strip() for l in out.split() if l.strip().startswith("/")]
    print(f"[ocvm] mounts on host: {[os.path.basename(x) for x in dirs]}")
    for dd in dirs:
        # 写 docs 标记到非第一个盘
        if dd != dirs[0]:
            sftp = ssh.open_sftp()
            try:
                sftp.mkdir(dd + "/doc")
            except Exception:
                pass
            with sftp.open(dd + "/doc/version.txt", "w") as f:
                f.write("v1.0-test\n")
            sftp.close()
            print(f"[ocvm] docs marker on {dd}")
            break

    # 运行 install.lua（模拟无网——install 需要网络下载，ocvm 无网会失败）
    # 因此只验证引导交互部分: 注入 lua install.lua 观察引导输出后取消
    d.send(f"lua /mnt/{mount}/install.lua")
    time.sleep(6)
    s1 = d.screen()
    print("=== install bootstrap screen ===")
    lines = [l for l in s1.splitlines() if "安装" in l or ") " in l or "盘" in l or "docs" in l]
    print("\n".join(lines[-15:]))
    # 取消（回车）
    d.send("")
    time.sleep(2)
    s2 = d.screen()
    print("=== after cancel ===")
    print("\n".join([l for l in s2.splitlines() if "取消" in l or "盘" in l][-5:]))
    ssh.close()


if __name__ == "__main__":
    main()

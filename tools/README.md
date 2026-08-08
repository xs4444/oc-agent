# tools — 开发辅助工具

| 工具 | 用途 | 用法 |
|------|------|------|
| `ocvm_test.py` | ocvm 模拟器测试驱动（重启 VM → 上传 → 运行 → 拉结果）。`EXTRA_FILES` 环境变量上传额外文件；测试结果自动保存到 `test_harness/results/` | `python tools/ocvm_test.py <脚本.lua> [参数...]` |
| `ssh_ubuntu.py` | 一键执行 Ubuntu 服务器 (192.168.31.75) 命令（paramiko）。凭据可用 `UBUNTU_HOST/UBUNTU_USER/UBUNTU_PASS` 覆盖 | `python tools/ssh_ubuntu.py "cmd"` |
| `ssh_win.py` | 一键执行 windowsCo (frp-say.com:56056) 命令（SSH 密钥）。`--ps` 用 PowerShell（中文路径安全） | `python tools/ssh_win.py "cmd" [--ps]` |
| `gist.py` | GitHub gist 工具：列表 / 最新报告 / 指定 ID 拉取（`/debug` 报告用）。token 走 `GH_TOKEN` 环境变量 | `python tools/gist.py latest -o report.txt` |

## 典型组合

```bash
# 发版全流程
python scripts/build_all.py            # 构建 + 清单 + 234 项回归
python scripts/release_check.py        # 安全检查（全 PASS 才能发）
git commit ... && git tag v0.3.4 && git push origin master v0.3.4
python scripts/watch_release.py --tag v0.3.4   # 挂机等 jsDelivr 索引

# 模拟器测试 + 结果
EXTRA_FILES=../docs_pack/oc-docs.tar python tools/ocvm_test.py test_docs_lua.lua
# 结果自动存到 test_harness/results/test_docs_lua_result.txt

# 拉取最新 /debug 报告
export GH_TOKEN=ghp_xxx
python tools/gist.py latest -o debug_report.txt
```

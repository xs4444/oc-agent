# patches/ — 参考库本地修复补丁

## ocvm-local-fixes.patch

`repos/emulators/ocvm`（upstream payonel/ocvm @ 009c79d）的本地修复，
2026-09-05 从测试环境 `~/oc-test/ocvm` 的未提交改动导出（`git diff`，3 文件）：

| 文件 | 修复 |
|---|---|
| `Makefile` | OC 系统文件源改指 GTNH fork：`MightyPirates/OpenComputers` → `GTNewHorizons/OpenComputers` |
| `client.cfg` | 内存 1MB → 4MB（`{"computer", nil, 4194304}`）；`system.timeout` 5 → 120；`maxTcpConnections` 4 → 16（远控守护轮询+wget 子进程下 4 触顶太快） |
| `drivers/internet_http.cpp` | ① 去掉 shell 单引号转义（execvp 不需要，`escape()` 直接返回原文）② `PipedCommand::close()` 改 `SIGKILL` + 阻塞 `waitpid`（EINTR 续/ECHILD 退；`_child_id>0` 保护双 close）——旧版 WNOHANG 一次即放弃跟踪，留下 wget 孤儿（/exit 后 75% CPU 残留实证）③ wget `--post-data` → `--body-data` |

### 应用到干净的 upstream 克隆

```bash
cd repos/emulators/ocvm
git apply ../../../patches/ocvm-local-fixes.patch   # 已验证 --check 通过
make deps && make lua=lua5.3
```

## 测试环境位置（重要）

- **ocvm 测试环境在 `~/oc-test/ocvm`（本机，地址经 env `OCVM_HOST` 提供），原地运行，不要搬迁。**
- 该目录的 working tree 包含与上面相同的未提交修复（Makefile / client.cfg /
  drivers/internet_http.cpp），补丁即从那里导出，两边内容一致。
- 已知问题（2026-09-03 记录）：ocvm 二进制**不可 relocate**——把
  `{ocvm, client.cfg, system/, bin/}` 拷到新目录运行，VM 会在第二次 boot
  的 "lua env baseline" 后卡死（machine 线程用户态空转，不打开
  `system/loot/openos/init.lua`；原目录 A/B 对照正常，25MB 输出/12s）。
  原因未定位；如需在别处跑，从源码重建而非拷贝二进制。
- 已知上游残留（2026-09-05）：连接槽位随**进程中途死亡**的 internet 请求
  悬挂至 VM 重启（仅 `handle:close()` 或组件断连释放；无 per-process-death
  清理）。agent 侧已缓解：v0.3.125r4 起 `/exit` 先 shutdown 远控守护
  （close 活动 handle + 有界等待线程退出）再退出——A/B 实证 /exit 后零
  孤儿 wget、shell 正常、瞬时 CPU 0%。守护 active 时若 agent 直接崩溃
  （OOM 等）仍可能留槽位，重启 VM 恢复。

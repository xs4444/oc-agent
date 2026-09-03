# patches/ — 参考库本地修复补丁

## ocvm-local-fixes.patch

`repos/emulators/ocvm`（upstream payonel/ocvm @ 009c79d）的 3 处本地修复，
2026-09-03 从测试环境 `~/oc-test/ocvm` 的未提交改动导出（`git diff`，85 行）：

| 文件 | 修复 |
|---|---|
| `Makefile` | OC 系统文件源改指 GTNH fork：`MightyPirates/OpenComputers` → `GTNewHorizons/OpenComputers` |
| `client.cfg` | 内存 1MB → 4MB（`{"computer", nil, 4194304}`）；`system.timeout` 5 → 120 |
| `drivers/internet_http.cpp` | ① 去掉 shell 单引号转义（execvp 不需要，`escape()` 直接返回原文）② `PipedCommand::close()` 增加 `waitpid(WNOHANG)` 防子进程僵尸 ③ wget `--post-data` → `--body-data` |

### 应用到干净的 upstream 克隆

```bash
cd repos/emulators/ocvm
git apply ../../../patches/ocvm-local-fixes.patch   # 已验证 --check 通过
make deps && make lua=lua5.3
```

## 测试环境位置（重要）

- **ocvm 测试环境在 `~/oc-test/ocvm`（本机，192.168.31.7），原地运行，不要搬迁。**
- 该目录的 working tree 包含与上面相同的未提交修复（Makefile / client.cfg /
  drivers/internet_http.cpp），补丁即从那里导出，两边内容一致。
- 已知问题（2026-09-03 记录）：ocvm 二进制**不可 relocate**——把
  `{ocvm, client.cfg, system/, bin/}` 拷到新目录运行，VM 会在第二次 boot
  的 "lua env baseline" 后卡死（machine 线程用户态空转，不打开
  `system/loot/openos/init.lua`；原目录 A/B 对照正常，25MB 输出/12s）。
  原因未定位；如需在别处跑，从源码重建而非拷贝二进制。

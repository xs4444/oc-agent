# tools — Windows 辅助脚本

Windows 主机上的辅助工具：游戏交互截图/按键 + ocvm 测试驱动。

## 脚本说明

| 脚本 | 用途 | 用法 |
|------|------|------|
| `capture_minecraft.py` | 捕获指定 Minecraft 窗口（按标题匹配 "GT: New Horizons" 等），非全屏 | `python capture_minecraft.py [输出.png]` |
| `capture_screen.py` | 全屏截图 | `python capture_screen.py [输出.png]` |
| `type_to_oc.py` | 向游戏窗口模拟按键（向 OC 终端输入命令）| `python type_to_oc.py "<文本>"` |
| `ocvm_test.py` | **ocvm 测试驱动**：自动重启虚拟机 → 等 OpenOS 启动 → 上传 agent.lua+测试脚本 → 探测挂载 → 运行 → 拉取结果 | `python ocvm_test.py <测试脚本.lua> [参数...]`（需可 SSH 到测试服务器） |

## 典型工作流

1. `capture_minecraft.py game.png` — 看游戏/OC 终端当前状态
2. 根据截图决定下一步，用 `type_to_oc.py` 向 OC 终端输入命令
3. 再次截图验证结果
4. `python ocvm_test.py test_harness/newfeat_test.lua` — 模拟器内跑 agent 测试

## 注意

- 依赖 Pillow：`pip install Pillow`；`ocvm_test.py` 依赖 paramiko
- 窗口捕获用 Win32 API（ctypes），无需额外库
- `ocvm_test.py` 解决 ocvm 挂载短名每次重启变化的问题（marker 探测自动定位含 agent.lua 的挂载）

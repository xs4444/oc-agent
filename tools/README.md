# tools — Windows 辅助脚本

在 Windows 主机上辅助游戏内交互的 Python 脚本（依赖 `PIL/Pillow`）。

## 脚本说明

| 脚本 | 用途 | 用法 |
|------|------|------|
| `capture_minecraft.py` | 捕获指定 Minecraft 窗口（按标题匹配 "GT: New Horizons" 等），非全屏 | `python capture_minecraft.py [输出.png]` |
| `capture_screen.py` | 全屏截图 | `python capture_screen.py [输出.png]` |
| `type_to_oc.py` | 向游戏窗口模拟按键（向 OC 终端输入命令）| `python type_to_oc.py "<文本>"` |

## 典型工作流

1. `capture_minecraft.py game.png` — 看游戏/OC 终端当前状态
2. 根据截图决定下一步，用 `type_to_oc.py` 向 OC 终端输入命令
3. 再次截图验证结果

## 注意

- 依赖 Pillow：`pip install Pillow`
- 窗口捕获用 Win32 API（ctypes），无需额外库
- 开发期调试产物（历史截图）已清理，此目录保留工具本身

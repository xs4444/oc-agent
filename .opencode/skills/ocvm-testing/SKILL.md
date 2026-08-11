---
name: ocvm-testing
description: ocvm 模拟器测试（192.168.31.75 远程 Ubuntu）。Triggers on "ocvm", "ocvm 测试", "modular 测试", "模拟器测试", "真机测试"。涵盖 tools/ocvm_test.py 驱动的所有测试（基础对话/文件读写/组件链/插件自举/modular 多文件 require/relocate/联网对话），含目录上传映射语法与挂载盘布局。
---

# ocvm 模拟器测试（192.168.31.75）

> ocvm 是 OpenComputers 的 C++ 模拟器，运行在远程 Ubuntu 服务器（192.168.31.75，
> hcj/hcj2005 **密码认证仍有效**——ssh-connect skill 里"已禁密码"的记录过时）。
> 全部测试通过 `tools/ocvm_test.py` 驱动。ocvm 总内存 4MB（真机 2MB），数据目录 tmp_t 重启即清。

## 环境准备

```bash
# 三个环境变量必须显式 export（ocvm_test.py 要求非空）
export OCVM_HOST=192.168.31.75 OCVM_USER=hcj OCVM_PASS=hcj2005
```

## 标准测试跑法（单文件 + agent.lua）

```bash
cd "F:\mie agent"
export OCVM_HOST=192.168.31.75 OCVM_USER=hcj OCVM_PASS=hcj2005
python tools/ocvm_test.py test_harness/<test>.lua
```

驱动流程：重启 VM（tmux 会话 ocvm_t）→ 上传 agent.lua + 测试脚本到所有挂载盘
→ find_agent_mount（touch 实证可写盘）→ run_script（dofile agent.lua + 钩子）→
wait_result 轮询 `test_harness/results/<test>_result.txt`。

常用测试：
- `basic_test.lua` 基础对话
- `file_io_test.lua` 文件读写
- `component_chain_test.lua` 组件链（list→doc→invoke）
- `shell_timeout_test.lua` shell_execute 超时（9 项）
- `reasoning_e2e_test.lua` reasoning_content 传回（3/3）
- `json_ctrl_e2e_test.lua` JSON 控制字符（修复前 400）
- `modular_ocvm_test.lua` 模块化 e2e（22 项，见下）

## modular 测试（多文件 require 链 + 插件自举，22 项）

modular 测试**不是**单文件 agent.lua——它验证开发态 `src/agent/` 目录结构在真实
OpenOS 中可 require。需要 `<mount>/agent/` 布局（agent/agent.lua = 入口）：

```bash
EXTRA_FILES="src/agent=agent,src/agent/init.lua=agent/agent.lua" \
  OCVM_HOST=192.168.31.75 OCVM_USER=hcj OCVM_PASS=hcj2005 \
  python tools/ocvm_test.py test_harness/modular_ocvm_test.lua
```

- `src/agent=agent` → 整个 src/agent/ 树（42 个 .lua）上传为 `<mount>/agent/`
- `src/agent/init.lua=agent/agent.lua` → 入口 init.lua 以 agent.lua 部署名上传
- 上传 45 文件到 2 挂载；断言 require 链 9/9 + json roundtrip + init.lua 加载
  + agent_test 钩子 + TOOLS 19 项集合 + 插件自举闭环（写 zz_hello.lua→重扫 20
  →调用 HELLO_PLUGIN_OK→写坏模块跳过）

## EXTRA_FILES 映射语法（ocvm_test.py upload）

逗号分隔文件/目录，支持 `path=newname` 映射：

| 用法 | 效果 |
|------|------|
| `EXTRA_FILES=oc-docs.tar` | 单文件上传到挂载根 |
| `EXTRA_FILES=src/agent=agent` | 目录递归上传，内容落 `<mount>/agent/` |
| `EXTRA_FILES=src/agent/init.lua=agent/agent.lua` | 文件映射，落 `<mount>/agent/agent.lua` |

实现要点（踩过的坑）：
- main() 解析 `path=newname` 时**先拆 = 再 exists()** 校验（整串 exists 必 False）
- upload() 用**整串**判定 `=`（Windows basename 会被 `\` 截断——`init.lua=agent\agent.lua`
  的 basename 是 agent.lua 不含 =，会漏判）
- 文件映射目标含子路径时**同时查 `/` 和 `\`**（mapped_name 来自 Windows 串，反斜杠
  分支曾把文件传回挂载根覆盖单文件 agent.lua）
- 目录映射默认名 = 源码目录 basename；映射名显式指定

## 联网对话测试（REPL 完整主循环）

自动压缩在 process_exchange 开头（字节阈值触发）——**一次性测试脚本走不到**，
必须跑 REPL 完整主循环：

```bash
python tools/ocvm_dialog.py    # 交互式多轮对话（屏幕检测轮次完成）
```

- 上传 agent.lua + _setup_config.lua（OpenOS 内写 config 到所有可写挂载+tmp）
- config 内容**不能带 return 前缀**（serialization.unserialize = load("return "..data)，
  带前缀变 return return {...} 语法错误 → 走 First Run Setup）
- config 路径 = writable_base/agent_config.txt，writable_base 探测 /home 只读后落
  /tmp（tmpfs）
- history 文件在 /tmp（tmpfs），host 侧 find 不到 → 轮次检测用**屏幕检测**
  （Ready 状态栏 + "> " 提示符 + [compact] 标记），不是文件轮询
- 触发压缩示例：`mem_prefold_bytes=20000, mem_compact_threshold=200000` 等测试 config

## relocate 测试

```bash
python tools/ocvm_relocate_test.py   # 迁移流程（REPL 注入 /relocate → 选 1）
python tools/ocvm_relocate_e2e.py    # 端到端（重启→迁移→重启 agent→验证 data_dir）
```
注意：ocvm_relocate_e2e.py 的 PASS 判断曾有 bug（匹配 "/mnt/" 即 PASS），
真实验证要对比迁移前后 /relocate 显示的数据目录。

## 排查备忘

- 挂载短名每次重启变（如 /mnt/b2f）——脚本自动探测，无需硬编码
- `ls -d tmp_t/*/` 偶发 boot 时序失败 → upload 已加 find fallback
- 结果文件在 `test_harness/results/<name>_result.txt`（VM 内写入，host 轮询）
- 测试脚本首个参数固定传挂载路径（如 /mnt/xxxx）
- VM 内存 4MB，测试用 config 需显式传 api_key/model/api_url 绕过本地 config
- 真机（非 ocvm）测试另有工具链，ocvm 用于快速回归

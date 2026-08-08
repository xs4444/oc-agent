# scripts — 构建与工具脚本

## 构建脚本

| 脚本 | 用途 | 用法 |
|------|------|------|
| `build_single.lua` | **单文件构建**：将 `src/agent/` 模块树用 `package.preload` 拼接为单文件 `agent.lua`（分发用）。**模块清单硬编码**（9 核心 + 7 工具），新增模块必须登记 | `lua scripts/build_single.lua` |
| `make_manifest.lua` | **安装清单生成**：扫描 `src/agent/` 模块，生成 `files.json`（安装器校验用，按 LF 归一化字节数；版本号含时间戳 `YYYY-MM-DDTHHMM` 便于区分同日构建） | `lua scripts/make_manifest.lua` |
| `build_all.py` | **一键构建+测试**：build_single + make_manifest + 产物回归（234 项）。发版前必跑（否则版本不 bump，服务器嗅探不到——v0.3.2 教训） | `python scripts/build_all.py` |
| `release_check.py` | **发版安全检查**：版本 bump、清单完整性、字节匹配、脚本语法、git 干净度（wiki/ lane 忽略）。全 PASS 才能打 tag | `python scripts/release_check.py` |
| `watch_release.py` | **发版后监控**：轮询 jsDelivr data API 直到新 tag 索引，验证 CDN 内容后提示服务器可 `lua update.lua` | `python scripts/watch_release.py --tag v0.3.3` |
| `make_docs_pack.py` | **离线文档包生成**：收集 `wiki/markdown/**/*.md`（排除 media 图片）→ CRLF→LF 归一化 → ustar tar + docs.json（版本/大小），输出 `docs_pack/` | `python scripts/make_docs_pack.py` |

> ⚠️ 模块变更后**两个脚本都要运行**：`build_single.lua` 重建 agent.lua，`make_manifest.lua` 重新生成 files.json（字节数与版本同步，否则增量更新/字节校验会失败）。

## 一次性工具

| 脚本 | 用途 | 备注 |
|------|------|------|
| `doku2md.py` | DokuWiki 原始文本 → Markdown 转换 | 产物在 `wiki/markdown/` |
| `download_images.py` | 批量下载 wiki 页面中的图片 | 产物在 `wiki/markdown/media/` |

## 运行

```bash
lua scripts/build_single.lua            # 构建 agent.lua
lua scripts/make_manifest.lua           # 生成 files.json
python scripts/doku2md.py               # 转换 wiki/raw/ → wiki/markdown/
python scripts/download_images.py       # 下载 wiki 图片
```

构建脚本是日常开发的一部分（`build_single.lua` 每次模块变更后运行），一次性工具保留作参考。

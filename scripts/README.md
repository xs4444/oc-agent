# scripts — 一次性工具脚本

开发过程中使用的转换/下载工具。多为一次性运行，保留作参考。

## 脚本说明

| 脚本 | 用途 | 备注 |
|------|------|------|
| `doku2md.py` | DokuWiki 原始文本 → Markdown 转换 | 产物在 `wiki/markdown/` |
| `download_images.py` | 批量下载 wiki 页面中的图片 | 产物在 `wiki/markdown/media/` |

## 运行

```bash
python doku2md.py           # 转换 wiki/raw/ → wiki/markdown/
python download_images.py   # 下载 wiki 图片
```

两者均为一次性产物生成工具；日常 agent 开发查阅文档直接看 `wiki/reference/`（手工精选版，比机器转换版更精炼）。

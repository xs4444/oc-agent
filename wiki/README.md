# wiki — OpenComputers Wiki 离线镜像

从 https://ocdoc.cil.li/（DokuWiki）下载的 OC 文档，供 agent 开发与调试时离线查阅。

## 目录结构

| 目录 | 内容 | 来源 |
|------|------|------|
| `raw/` | DokuWiki 原始 wiki 文本（215 页，含 block/item/api/component/tutorial 命名空间）| `/_export/raw/<page>` |
| `markdown/` | 转换后的 Markdown（32 页，`scripts/doku2md.py` 产物）| raw 转换 |
| `reference/` | **agent 开发精选参考**（35 文件，核心 API 精炼版）| 手工整理 |

## reference/ 精选内容（agent 开发最常用）

```
reference/api/      internet / filesystem / component / computer / event /
                    serialization / term / shell / unicode / text / colors /
                    keyboard / buffer / thread / non-standard-lua-libs
reference/component/ internet / filesystem / signals / gpu / screen / drive /
                    eeprom / data / computer
reference/block/    computer_case
reference/item/     internet_card / apu / loot_disks
reference/tutorial/ autorun_options
reference/          lua_conventions / openos
```

## 重新下载

```bash
# 完整镜像（raw）
# DokuWiki 站点地图: https://ocdoc.cil.li/start?do=index
# 单页原始文本: https://ocdoc.cil.li/_export/raw/<page:id>

# 转 Markdown（如有需要）
python scripts/doku2md.py
```

## 注意

- 文档对应**原版 OC**；GTNH fork 实装以 `../opencomputers/` 源码为准
- 页面会更新，如需最新版重新抓取 raw/

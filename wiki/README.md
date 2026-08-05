# wiki — OpenComputers Wiki 离线镜像

从 https://ocdoc.cil.li/（DokuWiki）下载的 OC 文档，供 agent 开发与调试时离线查阅。

## 目录结构

| 目录 | 内容 | 来源 |
|------|------|------|
| `raw/` | DokuWiki 原始 wiki 文本（215 页，含 block/item/api/component/tutorial 命名空间）| `/_export/raw/<page>` |
| `markdown/` | 转换后的 Markdown（40+ 页，`scripts/doku2md.py` 产物 + GTNH 指南）| raw 转换 + GTNH wiki |
| `markdown/gtnh/` | **GTNH 专属指南**（8 页，从 GTNH wiki 转换）| GTNH Miraheze wiki |
| `media/gtnh/` | GTNH 指南配套图片（19 张）| GTNH wiki 图片 |
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

## GTNH 指南 (`markdown/gtnh/`)

从 GTNH Miraheze wiki 转换的 OpenComputers 相关指南，涵盖 GTNH 专属自动化教程和模组集成文档：

| 页面 | 内容 |
|------|------|
| `gtnh/contents.md` | GTNH 指南索引 |
| `gtnh/open_computers.md` | OC 与 GTNH 机器交互、ME 系统 API 参考 |
| `gtnh/crossmod_integration.md` | OC 与 GregTech/AE2/Draconic Evolution/Stargate 等模组联动 |
| `gtnh/ar_glasses.md` | OCGlasses AR 眼镜 HUD 组件 API |
| `gtnh/nidas.md` | NIDAS 多功能 HUD 与自动化软件 |
| `gtnh/power_display.md` | FoxHUD LSC 电量显示 |
| `gtnh/item_stocking.md` | AE2 level-maintainer 自动补货（⚠️ 2.5.0+ 失效）|
| `gtnh/crop_breeding.md` | IC2 作物自动育种（⚠️ 2.9+ 弃用）|
| `gtnh/space_pumping.md` | 太空电梯泵模块自动切换（GTNH 2.9）|

## 注意

- 文档对应**原版 OC**；GTNH fork 实装以 `../opencomputers/` 源码为准
- `markdown/gtnh/` 下的页面来自 GTNH wiki，反映 GTNH 整合包特有的行为与配置
- 页面会更新，如需最新版重新抓取 raw/ 或 GTNH wiki dump

# wiki — OpenComputers Wiki 离线镜像

从 https://ocdoc.cil.li/（DokuWiki）下载的 OC 文档，供 agent 开发与调试时离线查阅。
GTNH 专属内容从 [GTNH Miraheze Wiki](https://gtnh.miraheze.org/wiki/Main_Page) dump 转换并经源码验证。

## 目录结构

| 目录 | 文件数 | 内容 | 来源 |
|------|--------|------|------|
| `raw/` | 215 | DokuWiki 原始 wiki 文本（block/item/api/component/tutorial 命名空间）| `/_export/raw/<page>` |
| `markdown/` | 211 | 转换后的 Markdown（`scripts/doku2md.py` 产物）| raw 转换 |
| `markdown/gtnh/` | 9 | **GTNH 专属指南**（教程 + 跨模组联动，859 行联动文档）| GTNH wiki + 源码分析 |
| `media/gtnh/` | 21 | GTNH 指南配套图片 | GTNH wiki 图片 |
| `reference/` | 35 | **agent 开发精选参考**（核心 API 精炼版）| 手工整理 |

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

## GTNH 指南 (`markdown/gtnh/`)

从 GTNH wiki 转换 + 源码分析（`grep -rl "li.cil.oc.api"` 覆盖全部 329 个 GTNH 仓库，确认 19 个模组），涵盖 GTNH 专属自动化教程和模组集成文档：

| 页面 | 行数 | 内容 |
|------|------|------|
| `gtnh/contents.md` | 65 | GTNH 指南索引 + 13 页交叉引用 + 19 模组表 |
| `gtnh/open_computers.md` | 119 | OC 与 GTNH 机器交互、ME Controller/Interface API |
| `gtnh/crossmod_integration.md` | 859 | OC 与 19+ 模组联动（34 章节、40 表条目，含完整 API 方法表）|
| `gtnh/ar_glasses.md` | 117 | OCGlasses AR 眼镜 HUD 组件 API |
| `gtnh/nidas.md` | 84 | NIDAS 多功能 HUD 与自动化软件 |
| `gtnh/power_display.md` | 102 | FoxHUD LSC 电量显示 |
| `gtnh/item_stocking.md` | 70 | AE2 level-maintainer 自动补货（⚠️ 2.5.0+ 失效）|
| `gtnh/crop_breeding.md` | 181 | IC2 作物自动育种（⚠️ 2.9+ 弃用）|
| `gtnh/space_pumping.md` | 638 | 太空电梯泵模块自动切换 + 2 套完整 Lua 脚本 |

### crossmod_integration.md 覆盖范围

| 类别 | 模组 |
|------|------|
| OC 内置驱动 | GregTech (LSC/Energy/Machine/BEC)、AE2 (全部)、IC2 (Reactor/Crop)、Blood Magic、Thaumcraft、Thaumic Energistics、Forestry、Vanilla (Inventory/Fluid/Beacon...)、Railcraft、BuildCraft、CoFH、ComputerCraft、Galacticraft 等 |
| 模组自带驱动 | Computronics (40+)、ThaumicTinkerer、AE2FluidCraft、Display-Panels、OpenSecurity、OCGlasses、OpenPrinter、OpenModularTurrets |
| grep 发现 | EnderIO (OC Conduit)、GT5 (Data Server)、Random-Things (3组件)、AsieLib (扳手)、MatterManipulator (物品识别) |

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
- `markdown/gtnh/` 下的页面来自 GTNH wiki + 源码分析，反映 GTNH 整合包特有的行为与配置
- `crossmod_integration.md` 的 API 方法表从源码 `@Callback` 注解直接提取，确保准确
- 页面会更新，如需最新版重新抓取 raw/ 或 GTNH wiki dump

# remote_client — 主控侧远控客户端库（Phase 1）

游戏机（主控机）侧的远控客户端库，配合机器人侧 `remote_debug/remote_debug.lua`
（v5.2+）使用。设计文档：`docs/REMOTE_PROTOCOL.md`。

## 部署

主控机：`/home/remote_client.lua`（直接经 `tools/remote_server.py --lua`
hex 分块写入 + 回读校验 + 现场 `loadfile`，2026-09-14 已部署）。

## v6 状态

v6 服务器（`remote_debug/remote_host.lua`，端口 8100）已实现、部署于机器人
`/home/remote_host.lua`、真机验收通过（PASS 11/11，见 `docs/REMOTE_PROTOCOL.md`
§4）。本 README 描述 Phase 1 客户端（v5.2，端口 8001）。

## 用法

```lua
local remote = dofile("/home/remote_client.lua")
local h, err = remote.connect("84f13777-676d-4c8d-b608-6f5f1346b602",
                  {modem = "3272384f-0749-4530-8b60-73eaf963d3ed"})
assert(h, err)

local p = h:ping()              -- {ok=true} | {ok=false, offline=true, err=...}
local i = h:info()              -- {ok=true, info="id=..|uptime=..|components=.."}
local e = h:exec("lua /home/probe.lua", 120)
-- {ok=true, code=0, out=..., truncated=bool}
-- | {ok=false, code=1, err=...}            服务器 err 信封
-- | {ok=false, offline=true, err="REMOTE_OFFLINE (...)"}  超时无回复
local f = h:read("/home/probe_out.txt")   -- {ok=true, content=..., size=n}
local w = h:write("/home/x.lua", src)     -- {ok=true, bytes=n}（≤6000B）
local d = h:delete("/home/x.lua")         -- {ok=true} | {ok=false, err=...}
h:close()
```

## 硬规则（为什么这样写）

1. **deadline 一律墙钟 `computer.uptime()`**——`os.clock()` 是 CPU 时间，
   等 modem 回复时线程挂起、时间不走 → deadline 永不触发（2026-09-14 c110
   事故：机器人没电 + os.clock = 探测线程永久挂起）。
2. **无回复 = 显式 `offline=true`**，绝不返回 nil 让调用方猜（没电/超距
   对 modem 就是静默）。
3. **exec 管道守卫自适应**——命令含 `|` 时，仅当 `h:info()` 探测到
   服务器 `pd=5.2.1+` 放行；版本未知/过旧显式报错（v5.2 服务器会在
   第一个 `|` 处静默截断命令）。
4. **write ≤6000B**（modem 单包 8192B，serialization+转义膨胀后须留余量）；
   大文件 → v6 分块传输（已实现，端口 8100）。
5. 回复尾部 `...[TRUNCATED]`（服务器 REPLY_MAX=7680B 截断标记）→
   `truncated=true`。

真机 e2e（2026-09-14，对 BeeMaster 机器人 84f13777-...）：
ping/info/exec/write/read/delete/离线探测 全链路通过；delete 在软盘版
升级前报 `attempt to call a nil value`（旧 OpenOS `fs.delete` 问题，
v5.2.1 已修；软盘现为 v5.2.2，真机已验证 2026-09-14）。

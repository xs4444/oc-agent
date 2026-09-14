# remote_client — 主控侧远控客户端库（v6-only）

游戏机（主控机）侧的远控客户端库，配合机器人侧 `remote_debug/remote_host.lua`
（v6，端口 8100）使用。设计文档：`docs/REMOTE_PROTOCOL.md`。

## 部署

主控机：`/home/remote_client.lua`（直接经 `tools/remote_server.py --lua`
hex 分块写入 + 回读校验 + 现场 `loadfile`，2026-09-14 已部署）。

## v6 状态

v6 服务器（`remote_debug/remote_host.lua`，端口 8100）已实现、部署于机器人
`/home/remote_host.lua`、真机验收通过（PASS 11/11，见 `docs/REMOTE_PROTOCOL.md`
§4）。v5（端口 8001）已于 2026-09-14 废弃（见 `docs/REMOTE_PROTOCOL.md` 状态节），
本客户端现仅对接 v6。

## 用法

```lua
local remote = dofile("/home/remote_client.lua")
local h, err = remote.connect("84f13777-676d-4c8d-b608-6f5f1346b602",
                  {modem = "3272384f-0749-4530-8b60-73eaf963d3ed", port = 8100})
assert(h, err)

local p = h:ping()              -- {ok=true} | {ok=false, offline=true, err=...}
local i = h:info()              -- {ok=true, info="id=..|uptime=..|components=..|pd=6.0"}
local e = h:exec("lua /home/probe.lua", 120)
-- {ok=true, code=0, out=..., stderr=...}   流式，无截断
-- | {ok=false, code=1, err=..., out=..., stderr=...}   服务器 err 信封
-- | {ok=false, offline=true, err="REMOTE_OFFLINE (...)"}  超时无回复
local f = h:read("/home/probe_out.txt")   -- {ok=true, content=..., size=n}（≤1MB）
local w = h:write("/home/x.lua", src)     -- {ok=true, bytes=n}（分块，≤1MB）
local d = h:delete("/home/x.lua")         -- {ok=true} | {ok=false, err=...}
local c = h:cancel(id)                    -- {ok=true, cancelled=id}（杀指定 id 的 exec）
h:close()
```

## 硬规则（为什么这样写）

1. **deadline 一律墙钟 `computer.uptime()`**——`os.clock()` 是 CPU 时间，
   等 modem 回复时线程挂起、时间不走 → deadline 永不触发（2026-09-14 c110
   事故：机器人没电 + os.clock = 探测线程永久挂起）。
2. **无回复 = 显式 `offline=true`**，绝不返回 nil 让调用方猜（没电/超距
   对 modem 就是静默）。
3. **exec 管道恒放行**——v6 真流分离（`> out 2> err`），命令含 `|` 直接
   执行，无 `pd=` 版本守卫（v5 时代才需守卫）。
4. **write 分块 ≤1MB**（v6 `write_chunk` 分块传输，modem 单包 8192B 约束下
   每块 ≤7000B）；read 同样分块重组 ≤1MB。
5. **无 `truncated`**——v6 流式回传，无 7680B 截断（v5 时代才有
   `...[TRUNCATED]` 标记）。

真机 e2e（2026-09-14，对 BeeMaster 机器人 84f13777-...）：
`/home/e2e_v6.lua` → `PASS 11/11 | ALL GREEN`（T1 ping … T11 cancel，
见 `docs/REMOTE_PROTOCOL.md` §4）。

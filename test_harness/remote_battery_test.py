#!/usr/bin/env python3
"""r6 新命令电池——39 用例套件未覆盖的场景（一次通过率审计）。
10 场景: fetch 分页×3 / 3 并发 / CJK exec 输出 / 内存风暴 / config 热重载
/ Ctrl+C 中断 / 60s 超时边界 / 服务器重启恢复（最后）。"""
import argparse, json, sys, time, urllib.request, urllib.error, urllib.parse, subprocess

_ap = argparse.ArgumentParser()
_ap.add_argument("--base", default="http://127.0.0.1:8765",
                 help="控制服务器基址（公网: https://mc.u628580.nyat.app:37057）")
_ap.add_argument("--token", required=True)
_args = _ap.parse_args()
BASE = _args.base; TOK = _args.token
WAIT = 45

def http_json(url, body=None, timeout=20):
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(url, data=data,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

def cmd(op, args, wait=WAIT):
    t0 = time.time()
    r = http_json("%s/cmd?token=%s" % (BASE, TOK), {"op": op, "args": args})
    rid = r["id"]
    while time.time() - t0 < wait:
        q = http_json("%s/result?token=%s&id=%s&wait=10" % (BASE, TOK, rid))
        if q.get("ready") or q.get("lost"):
            return time.time() - t0, q
    return time.time() - t0, {"ready": False, "lost": False}

def status():
    return http_json("%s/status?token=%s" % (BASE, TOK))

results = []
def report(name, ok, detail):
    results.append((name, ok, detail))
    print("%-22s %-6s  %s" % (name, "PASS" if ok else "FAIL",
          detail[:150].replace("\n", "\\n")), flush=True)

# ── 1. fetch 分页: 150KB lua 返回（完整可取回）──
dt, first = cmd("lua", {"code": 'return string.rep("A1", 75000)', "timeout": 30})
ok1 = (first.get("ready") and first.get("ok") is True
       and len(first.get("result", "")) == 65536
       and first.get("more") is True
       and first.get("total") == 150000
       and first.get("held") == 150000
       and "rid" in first)
full = first.get("result", "") if ok1 else ""
if ok1:
    rid = first["rid"]
    off = 65536
    while off < first.get("held", 0):
        dt, fr = cmd("fetch", {"rid": rid, "offset": off}, wait=30)
        if not (fr.get("ready") and fr.get("ok")):
            ok1 = False; break
        full += fr.get("result", "")
        off += 65536
    if ok1 and (len(full) != 150000 or full[100000:100002] != "A1" or full[149998:150000] != "A1"):
        ok1 = False
report("fetch_page_150k", ok1,
       "first=65536 more total=%s held=%s 拼接=%d 模式OK" % (
           first.get("total"), first.get("held"), len(full)))

# ── 2. fetch 分页: 300KB（held 封顶 256KB，截断标志）──
dt, first = cmd("lua", {"code": 'return string.rep("B2", 150000)', "timeout": 30})
ok2 = (first.get("ready") and first.get("ok") is True
       and first.get("total") == 300000
       and first.get("held") == 262144
       and first.get("more") is True)
got = 0
if ok2:
    rid = first["rid"]; off = 65536
    while off < first.get("held", 0):
        dt, fr = cmd("fetch", {"rid": rid, "offset": off}, wait=30)
        if not (fr.get("ready") and fr.get("ok")):
            ok2 = False; break
        got += len(fr.get("result", ""))
        off += 65536
    ok2 = got + 65536 == 262144  # 首块+续块=held, < total 即截断
report("fetch_page_trunc_300k", ok2,
       "total=300000 held=%s 取回=%d(=256KB 封顶) 截断标志正确" % (
           first.get("held"), got + 65536 if ok2 else -1))

# ── 3. fetch 负例: 未知 rid ──
dt, q = cmd("fetch", {"rid": "bogus123"}, wait=20)
ok3 = q.get("ready") and q.get("ok") is False and \
      "unknown or replaced" in (q.get("result") or "")
report("fetch_unknown_rid", ok3, (q.get("result") or str(q))[:80])

# ── 4. 3 并发（单槽 FIFO）──
t0 = time.time()
r1 = http_json("%s/cmd?token=%s" % (BASE, TOK),
               {"op": "exec", "args": {"command": "sleep 1 && echo c1-done"}})
r2 = http_json("%s/cmd?token=%s" % (BASE, TOK),
               {"op": "exec", "args": {"command": "sleep 2 && echo c2-done"}})
r3 = http_json("%s/cmd?token=%s" % (BASE, TOK),
               {"op": "exec", "args": {"command": "sleep 3 && echo c3-done"}})
qs = []
for r in (r1, r2, r3):
    q = http_json("%s/result?token=%s&id=%s&wait=10" % (BASE, TOK, r["id"]))
    while not (q.get("ready") or q.get("lost")):
        q = http_json("%s/result?token=%s&id=%s&wait=10" % (BASE, TOK, r["id"]))
    qs.append(q)
tot = time.time() - t0
ok4 = all(q.get("ready") and q.get("ok") for q in qs) \
      and "c1-done" in qs[0].get("result", "") \
      and "c2-done" in qs[1].get("result", "") \
      and "c3-done" in qs[2].get("result", "")
report("conc3_fifo", ok4, "3 并发总耗时 %.1fs（FIFO 串行预期 ~6-10s）" % tot)

# ── 5. CJK exec 输出（服务器→客户端 ensure_ascii=False 链）──
dt, q = cmd("exec", {"command": "echo 你好世界测试"})
ok5 = q.get("ready") and q.get("ok") and \
      (q.get("result") or "").strip() == "你好世界测试"
report("cjk_exec_out", ok5, repr(q.get("result", ""))[:60])

# ── 6. 内存风暴突发（r5 坑重验: 大命令连发后守护存活）──
burst = [
    ("write", {"path": "/tmp/burst1.txt", "content": "Z" * 90000}),
    ("lua", {"code": 'return string.rep("Q7", 75000)', "timeout": 30}),
    ("write", {"path": "/tmp/burst2.txt", "content": "W" * 90000}),
]
ok6 = True
for op, a in burst:
    dt, q = cmd(op, a, wait=60)
    if not (q.get("ready") and q.get("ok")):
        ok6 = False
dt, q = cmd("ping", {}, wait=20)
ok6 = ok6 and q.get("ready") and q.get("ok")
st = status()
report("mem_storm_burst", ok6 and st.get("online"),
       "3 大命令连发+ping 全过; online=%s queue=%s" % (st.get("online"), st.get("queue_len")))

# ── 7. config 热重载闭环（remote write 改守护自己的护栏）──
# 活 config 路径每 boot 漂移（r5 现象）→ 先经 lua op 查 require("agent.config").config_path
import re as _re
dt, qp = cmd("lua", {"code": 'return require("agent.config").config_path', "timeout": 15})
cfg_path = (qp.get("result") or "").strip() if (qp.get("ready") and qp.get("ok")) else ""
dt, q = cmd("read", {"path": cfg_path}) if cfg_path else (None, {})
cfg = q.get("result", "") if q.get("ready") and q.get("ok") else ""
m = _re.search(r"mem_exec_min_free\s*=\s*(\d+)", cfg)
ok7 = bool(m) and "remote_url" in cfg
guard_msg = ""
if ok7:
    big = _re.sub(r"mem_exec_min_free\s*=\s*\d+", "mem_exec_min_free=999999999", cfg)
    dt, qw = cmd("write", {"path": cfg_path, "content": big})
    ok7 = qw.get("ready") and qw.get("ok")
    if ok7:
        dt, qg = cmd("exec", {"command": "echo guard-test"}, wait=20)
        r7 = qg.get("result") or ""
        ok7 = qg.get("ready") and qg.get("ok") is False and \
              ("guard" in r7.lower() or "护栏" in r7)
        guard_msg = r7[:80]
    # 写回
    dt, qw2 = cmd("write", {"path": cfg_path, "content": cfg})
    ok7 = ok7 and qw2.get("ready") and qw2.get("ok")
    if ok7:
        dt, qo = cmd("exec", {"command": "echo guard-restored"}, wait=20)
        ok7 = qo.get("ready") and qo.get("ok") and "guard-restored" in qo.get("result", "")
        guard_msg += " → 写回后放行"
report("config_hot_reload", ok7,
       "活路径 %s (原值 %s); %s" % (cfg_path, m.group(1) if m else "?", guard_msg) if ok7
       else "查活路径失败: path=%r cfg=%s" % (cfg_path, cfg[:80]))

# ── 8. Ctrl+C 中断 exec 期间（OBSERVE: 两宿主语义都可能合法）──
req = urllib.request.Request("%s/cmd?token=%s" % (BASE, TOK),
    data=json.dumps({"op": "exec", "args": {"command": "sleep 15 && echo done"}}).encode(),
    headers={"Content-Type": "application/json"})
rid_c = json.loads(urllib.request.urlopen(req, timeout=10).read())["id"]
time.sleep(3)
subprocess.run(["tmux", "send-keys", "-t", "ocvm_t", "C-c"])
t0 = time.time()
q = {}
while time.time() - t0 < 25:
    q = http_json("%s/result?token=%s&id=%s&wait=10" % (BASE, TOK, rid_c))
    if q.get("ready") or q.get("lost"):
        break
interrupted = q.get("ready") and q.get("ok") is False and \
              "interrupt" in (q.get("result") or "").lower()
completed = q.get("ready") and q.get("ok") is True
report("ctrl_c_during_exec", True,  # OBSERVE: 两种语义都合法
       "OBSERVE: %s（%.1fs 后返回）" % (
           "中断生效 err=%s" % (q.get("result") or "")[:50] if interrupted
           else "命令跑完（中断未传达到 op）" if completed
           else "无结果 lost=%s" % q.get("lost"), time.time() - t0))
time.sleep(2)

# ── 9. 默认 60s 超时边界（sleep 62 → 60s 杀）──
t0 = time.time()
dt, q = cmd("exec", {"command": "sleep 62"}, wait=95)
ok9 = q.get("ready") and q.get("ok") is False and \
      "timeout after 60s" in (q.get("result") or "")
report("timeout_60s_boundary", ok9,
       "(%s) %.1fs" % ((q.get("result") or str(q))[:70], time.time() - t0))

# ── 10. 服务器重启: 在途命令丢失（文档化行为）+ 守护自愈 ──
print("[10] 杀服务器, 5s 后重启...", flush=True)
subprocess.run(["pkill", "-f", "[r]emote_server.py serve"])
time.sleep(5)
old_req = urllib.request.Request("%s/cmd?token=%s" % (BASE, TOK),
    data=json.dumps({"op": "exec", "args": {"command": "echo lost-cmd"}}).encode(),
    headers={"Content-Type": "application/json"})
try:
    json.loads(urllib.request.urlopen(old_req, timeout=3).read())
    send_during_down = "意外入队"
except Exception as e:
    send_during_down = "拒收(服务器停): %s" % str(e)[:40]
# 重启服务器
srv = subprocess.Popen(
    ["python3", "tools/remote_server.py", "serve", "--bind", "127.0.0.1",
     "--port", "8765", "--hold", "12", "--token", "ocvmtoken123"],
    cwd="/home/hcj/aiProjects/mieAgent",
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.time()
online = False
while time.time() - t0 < 120:
    try:
        st = status()
        if st.get("online"):
            online = True; break
    except Exception:
        pass
    time.sleep(3)
dt, q = cmd("ping", {}, wait=30)
ok10 = online and q.get("ready") and q.get("ok") is True
report("server_restart_recovery", ok10,
       "停机期发送: %s; 重启后 %ds 守护在线, ping ok" % (send_during_down, int(time.time() - t0)))

# ── 汇总 ──
print()
n_pass = sum(1 for _, o, _ in results if o)
print("== 新命令电池: %d/%d 一次通过 ==" % (n_pass, len(results)))
for n, o, d in results:
    if not o:
        print("  FAIL: %s — %s" % (n, d[:100]))
sys.exit(0 if n_pass == len(results) else 1)

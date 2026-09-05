#!/usr/bin/env python3
"""remote_server.py — OC agent 远程控制守护的控制服务器（v0.3.125）。

agent 侧（src/agent/remote.lua）是 long-poll 客户端：经 internet 卡
主动轮询本服务器取命令（ping/exec/read/write/list/lua/fetch），
执行后经现有工具注册表回传结果。本服务器在宿主机（DSH 侧）运行，
提供命令入队与结果查询。

v0.3.125r5: 大结果分页——结果 > 64KB 时 agent 回传首块 + meta
{rid,total,held,more}（缓存前 256KB 可取回），客户端/驱动用
fetch op 按 offset 续取；client 模式自动分页。

v0.3.125r6: 坑位防护（对照实测坑清单）:
  - exec 单行强校验: OpenOS shell 把命令内换行拍平成空格（实证
    `echo a\necho b` → "a echo b" 静默错）→ 400 拒收，提示 &&/; 串联
  - exec 4 字节 UTF-8（emoji）默认拒收: ocvm C++ unicode.cpp 上游 bug
    原生崩溃（真机 OC Java codePoints 无此问题）→ 400 拒收，
    serve --allow-emoji 放开（write op 的 content 不受限——纯 Lua
    fs 写路径，实证无损）
  - 队列深度上限（默认 16，--queue-max）: 防离线积压无界 → 429
  - lost 判定按命令超时计算: queued_at + 命令 timeout + --lost-grace
    （默认 120s），不再一刀切 120s（长命令 timeout=600 不再假阳）
  - GET /status: 守护在线性（last_poll）+ 队列长度 + 最近命令状态
    ——离线/堵队列一眼可见（此前只能靠 /result 超时盲等推断）

serve 模式（常驻）:
    python3 tools/remote_server.py serve --port 8765 --token SECRET \
        [--bind 0.0.0.0] [--hold 12]

client 模式（一次性命令，需 serve 已在跑）:
    python3 tools/remote_server.py client --base http://127.0.0.1:8765 \
        --token SECRET --exec "ls /home" [--timeout 30]
    ... client --read /home/agent_config.txt
    ... client --write /tmp/hello.txt "hi"
    ... client --list /home
    ... client --ping
    [--wait 60]  结果等待上限（默认 60s）

端点（全部要求 token 参数，不匹配 403）:
    GET  /poll?token=T              long-poll（hold ≤ --hold 秒）
                                         → {"id","op","args"} | {"op":"noop"}
    POST /report?token=T&id=I       body {"ok":bool,"result":"..."}
    POST /cmd?token=T               body {"op":...,"args":{...}} → {"id":...}
    GET  /result?token=T&id=I&wait=N
                                         → {"ready":true,"ok":..,"result":..}
                                         | {"ready":false[, "lost":true]}

仅用 Python 标准库。
"""
import argparse
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HOLD_DEFAULT = 12        # /poll 无命令时最长 hold（秒）—— agent 侧读 deadline 30s
RESULT_TTL = 3600        # 结果保留（秒）
LOST_GRACE_DEFAULT = 120 # v0.3.125r6: lost 宽限（秒）——命令自身 timeout 到期后
                          # 再多等这么久才判 lost（迟到的 report 仍会 upsert
                          # 覆盖，lost 只是查询提示）。r5 前为固定 LOST_AFTER=120
                          # 一刀切（长命令 timeout=600 时 120s 就假阳）
QUEUE_MAX_DEFAULT = 16   # v0.3.125r6: 单 token 队列深度上限（防离线积压无界）
                         # → 判死（agent 崩溃/OOM/重启，或 report 通道断）；
                         # 迟到的 report 仍会 upsert 覆盖（lost 只是查询提示）
MAX_CMD_WIRE = 100000    # /cmd 入队的线上 JSON 字节上限（agent MAX_POLL_BODY=131072 之下留余量）
ALLOWED_OPS = {"ping", "exec", "read", "write", "list", "lua", "fetch"}


class State:
    def __init__(self, token, hold, allow_emoji=False, queue_max=QUEUE_MAX_DEFAULT,
                 lost_grace=LOST_GRACE_DEFAULT):
        self.token = token
        self.hold = hold
        # v0.3.125r6: 防护开关/参数
        self.allow_emoji = allow_emoji
        self.queue_max = queue_max
        self.lost_grace = lost_grace
        # v0.3.125r6: /status 在线性判据
        self.last_poll = 0.0
        self.lock = threading.Lock()
        self.queues = {}          # token -> deque of cmd dicts
        # id -> {"ready":.., "ok":.., "result":.., "at":.., "queued_at":..,
        #        "timeout":.. (v0.3.125r6: 按命令超时算 lost 窗口)}
        self.results = {}
        self.cond = threading.Condition(self.lock)
        self.counter = 0
        self.started = time.time()

    def new_id(self):
        self.counter += 1
        return "c%d" % self.counter


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print("[%s] %s" % (ts, msg), file=sys.stderr, flush=True)


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "OCRemoteServer/1.0"

        def log_message(self, fmt, *args):  # 静音默认访问日志
            pass

        def _check_token(self, qs):
            token = qs.get("token", [None])[0]
            if token != state.token:
                self._send(403, {"error": "bad token"})
                return False
            return True

        def _send(self, code, obj):
            # ensure_ascii=False（v0.3.125r2）: 默认 True 把 emoji 等非
            # BMP 字符编码成 \uD83C\uDF0D 代理对——agent json.lua 的
            # \u 解码无 surrogate 合并 → 孤立代理变无效 UTF-8 → 回传
            # decode(replace) 成 U+FFFD（实证: echo 你好🌍中文 回 "??????"；
            # 3 字节中文 <U+2048 走 \u handler 不受影响）。直接发 UTF-8
            # 原始字节（RFC 8259 合法，agent json 字节透明）。
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _read_body(self, limit=512 * 1024):
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0:
                return None
            if n > limit:
                return None
            return self.rfile.read(n).decode("utf-8", errors="replace")

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(u.query)
            if not self._check_token(qs):
                return
            if u.path == "/poll":
                state.last_poll = time.time()  # v0.3.125r6: /status 在线性
                deadline = time.time() + state.hold
                with state.cond:
                    state.queues.setdefault(state.token, deque())
                    q = state.queues[state.token]
                    while not q:
                        remaining = deadline - time.time()
                        if remaining <= 0:
                            break
                        state.cond.wait(min(remaining, 5.0))
                    if q:
                        cmd = q.popleft()
                        # v0.3.125r6: 派发时刻（lost 判定改以此为基准——
                        # 排队等待时间不算进执行窗口，FIFO 积压不再假阳）
                        rec = state.results.get(cmd.get("id"))
                        if rec is not None:
                            rec["dispatched_at"] = time.time()
                        log("poll → %s %s" % (cmd["op"],
                                              json.dumps(cmd.get("args", {}),
                                                         ensure_ascii=False)[:120]))
                        self._send(200, cmd)
                    else:
                        self._send(200, {"op": "noop"})
            elif u.path == "/result":
                rid = qs.get("id", [None])[0]
                wait = min(float(qs.get("wait", [state.hold])[0] or 0), 120.0)
                deadline = time.time() + wait
                lost = False
                with state.cond:
                    while True:
                        r = state.results.get(rid)
                        if r and r.get("ready"):
                            self._send(200, r)
                            return
                        # v0.3.125r3: lost 标记——命令超时窗口内无 report
                        # （agent 崩溃/OOM/重启，或 report 通道断），客户端
                        # 可判死不必等到自己 deadline。
                        # v0.3.125r6: 窗口 = 命令自身 timeout + 宽限
                        # （r5 前固定 120s 一刀切，长命令假阳）；基准=派发
                        # 时刻（排队等待不算——FIFO 积压不假阳）；仍未派发
                        # 且守护离线 = 队列永不消费，宽限后判 lost
                        if r:
                            dispatch = r.get("dispatched_at")
                            agent_offline = state.last_poll == 0 or \
                                time.time() - state.last_poll > \
                                max(state.hold * 3, 45)
                            if dispatch:
                                lost = time.time() - dispatch > \
                                    r.get("timeout", 60) + state.lost_grace
                            elif agent_offline:
                                lost = time.time() - r.get(
                                    "queued_at", time.time()) > state.lost_grace
                        remaining = deadline - time.time()
                        if remaining <= 0:
                            break
                        state.cond.wait(min(remaining, 2.0))
                    self._send(200, {"ready": False, "lost": lost})
            elif u.path == "/status":
                # v0.3.125r6: 健康快照——守护在线性/队列深度/最近命令状态。
                # 此前离线与堵队列只能靠 /result 超时盲等推断（10h 堵队列
                # 坑的伴生盲区）。
                with state.cond:
                    q = state.queues.get(state.token, deque())
                    pending_n = sum(1 for v in state.results.values()
                                    if not v.get("ready"))
                    online = state.last_poll > 0 and \
                        time.time() - state.last_poll < max(state.hold * 3, 45)
                    recent = []
                    for k in list(state.results)[-20:]:
                        v = state.results[k]
                        recent.append({
                            "id": k,
                            "ready": bool(v.get("ready")),
                            "ok": v.get("ok"),
                            "age": round(time.time() - v.get(
                                "at", v.get("queued_at", time.time())), 1),
                        })
                    self._send(200, {
                        "version": "r6",
                        "online": online,
                        "last_poll_age": (round(time.time() - state.last_poll, 1)
                                          if state.last_poll else None),
                        "queue_len": len(q),
                        "pending_results": pending_n,
                        "hold": state.hold,
                        "uptime": round(time.time() - state.started, 1),
                        "recent": recent,
                    })
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            u = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(u.query)
            if not self._check_token(qs):
                return
            if u.path == "/cmd":
                body = self._read_body()
                try:
                    req = json.loads(body)
                except Exception:
                    self._send(400, {"error": "bad json"})
                    return
                op = req.get("op")
                if op not in ALLOWED_OPS:
                    self._send(400, {"error": "unknown op: %s" % op})
                    return
                # v0.3.125r6 防护①: exec 单行强校验——实证坑: OpenOS shell
                # 把命令内换行拍平成空格（`echo a\necho b` → "a echo b"
                # 一条命令，静默错且不报错）。提前拒收，提示 &&/; 串联。
                # （lua op 的 code 允许多行——那是脚本，不是 shell 命令）
                if op == "exec":
                    command = (req.get("args") or {}).get("command")
                    if isinstance(command, str) and re.search(r"[\r\n]", command):
                        self._send(400, {
                            "error": "exec command must be a single line: "
                                     "OpenOS shell flattens newlines to "
                                     "spaces (silently becomes ONE command); "
                                     "chain with && or ;"})
                        return
                # v0.3.125r6 防护②: exec 4 字节 UTF-8（非 BMP/emoji）默认
                # 拒收——ocvm C++ unicode.cpp 上游 bug（4 字节按 3 字节解码
                # + 余字节终止迭代）原生崩溃/其后文本丢失，一条命令可把
                # 测试 VM 打崩（真机 OC 用 Java codePoints 无此问题，
                # serve --allow-emoji 放开）。write op 的 content 不受限
                # （纯 Lua fs 写路径，emoji 实证无损）。
                if op == "exec" and not state.allow_emoji:
                    command = (req.get("args") or {}).get("command")
                    if isinstance(command, str) and \
                            any(ord(c) > 0xFFFF for c in command):
                        self._send(400, {
                            "error": "exec command contains 4-byte UTF-8 "
                                     "(non-BMP/emoji): ocvm C++ unicode "
                                     "upstream bug crashes on it; real OC "
                                     "(Java) is fine — start server with "
                                     "--allow-emoji to permit"})
                        return
                cmd = {"id": None, "op": op, "args": req.get("args") or {}}
                # 线上大小拒收（v0.3.125r2）: agent poll 响应上限
                # MAX_POLL_BODY=131072——超限命令入队后 poll 响应整体被
                # agent 丢弃，命令永不执行永不报告（实证坑: 200KB write
                # 触发 10 次 "poll response too large"，命令 c48 失踪）。
                # 按重建后 cmd 的线上 JSON 字节数（含转义膨胀）判，
                # 留 ~28KB 余量防边界。
                wire = len(json.dumps(cmd, ensure_ascii=False).encode("utf-8"))
                if wire > MAX_CMD_WIRE:
                    self._send(413, {
                        "error": "command too large: %d bytes on the wire "
                                 "(max %d); split into smaller pieces"
                                 % (wire, MAX_CMD_WIRE)})
                    return
                with state.cond:
                    # v0.3.125r6 防护③: 队列深度上限——守护离线/堵队列时
                    # 命令无界积压没有意义（agent 单槽 FIFO，积压越深
                    # 越陈旧）。429 让发送方立刻知道该等。
                    q = state.queues.setdefault(state.token, deque())
                    if len(q) >= state.queue_max:
                        self._send(429, {
                            "error": "queue full: %d pending; agent offline "
                                     "or busy — check GET /status" % len(q)})
                        return
                    cmd["id"] = state.new_id()
                    # v0.3.125r3: 入队占位（/result 的 lost 判定基准；
                    # report 到达时 upsert 覆盖为 ready）
                    # v0.3.125r6: 记录命令自身超时（exec/lua 的 timeout
                    # 参数，缺省 60 与 shell 默认一致；其余 op 30s 足够）
                    # ——lost 窗口 = timeout + lost_grace，不再一刀切
                    args_tbl = req.get("args") or {}
                    if op in ("exec", "lua"):
                        try:
                            tmo = max(5, int(args_tbl.get("timeout") or 60))
                        except (TypeError, ValueError):
                            tmo = 60
                    else:
                        tmo = 30
                    state.results.setdefault(cmd["id"], {
                        "ready": False, "queued_at": time.time(),
                        "timeout": tmo})
                    q.append(cmd)
                    state.cond.notify_all()
                    # 顺带清过期结果（占位条目无 at 字段，回退 queued_at，
                    # 否则每次 /cmd 都会把占位立即清掉）
                    cutoff = time.time() - RESULT_TTL
                    for k in [k for k, v in state.results.items()
                              if v.get("at", v.get("queued_at", 0)) < cutoff]:
                        del state.results[k]
                log("cmd %s queued (%s)" % (cmd["id"], op))
                self._send(200, {"id": cmd["id"]})
            elif u.path == "/report":
                rid = qs.get("id", [None])[0]
                body = self._read_body()
                try:
                    rep = json.loads(body)
                except Exception:
                    self._send(400, {"error": "bad json"})
                    return
                with state.cond:
                    rec = {
                        "ready": True,
                        "ok": bool(rep.get("ok")),
                        "result": rep.get("result", ""),
                        "at": time.time(),
                    }
                    # v0.3.125r5: 大结果分页 meta 透传（agent report 附带
                    # rid/total/held/more 时）——客户端据此发 fetch 续取
                    for k in ("rid", "total", "held", "more"):
                        if k in rep:
                            rec[k] = rep[k]
                    state.results[rid] = rec
                    state.cond.notify_all()
                log("report %s ok=%s (%d chars)" % (
                    rid, rep.get("ok"), len(rep.get("result", ""))))
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})

    return Handler


def cmd_serve(args):
    state = State(args.token, args.hold, allow_emoji=args.allow_emoji,
                  queue_max=args.queue_max, lost_grace=args.lost_grace)
    httpd = ThreadingHTTPServer((args.bind, args.port), make_handler(state))
    httpd.daemon_threads = True
    log("serving on %s:%d (hold=%ds queue_max=%d lost_grace=%ds "
        "emoji=%s); Ctrl+C to stop" %
        (args.bind, args.port, args.hold, args.queue_max, args.lost_grace,
         "allowed" if args.allow_emoji else "rejected"))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    log("stopped")


def http_json(url, body=None, timeout=15):
    data = None
    headers = {"Content-Type": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def wait_result(base, tok, rid, deadline):
    """等一个已入队命令的 /result；ready/lost 即返回，超时返回 None。"""
    while time.time() < deadline:
        try:
            r = http_json("%s/result?token=%s&id=%s&wait=%.1f" %
                          (base, tok, rid, min(max(deadline - time.time(), 0.5), 15.0)),
                          timeout=20)
        except Exception:
            return None
        if r.get("ready") or r.get("lost"):
            return r
    return None


def fetch_all(base, tok, first, deadline):
    """v0.3.125r5: 大结果自动分页——first 为 /result 的 ready 记录
    （含 more/rid/held/total 时循环 fetch 续块）。返回完整文本。"""
    result = first.get("result", "")
    if not first.get("more"):
        return result
    offset = len(result)
    held = first.get("held") or 0
    for _ in range(32):  # 防御: 32 块 × 64KB = 2MB 足够
        if offset >= held:
            break
        try:
            rf = http_json("%s/cmd?token=%s" % (base, tok),
                           {"op": "fetch",
                            "args": {"rid": first["rid"], "offset": offset}})
            fr = wait_result(base, tok, rf.get("id"), deadline)
        except Exception as e:
            print("fetch 失败: %s（已取 %d 字符）" % (e, len(result)),
                  file=sys.stderr)
            break
        if not fr or not fr.get("ready"):
            print("fetch 结果丢失/超时（已取 %d 字符）" % len(result),
                  file=sys.stderr)
            break
        chunk = fr.get("result", "")
        if fr.get("ok") is False:
            print("fetch 错误: %s" % chunk, file=sys.stderr)
            break
        if not chunk:
            break
        result += chunk
        offset += len(chunk)
    total = first.get("total")
    if total and total > len(result):
        print("[remote: 结果被 agent 端截断，取回 %d/%d 字符]"
              % (len(result), total), file=sys.stderr)
    return result


def cmd_client(args):
    base = args.base.rstrip("/")
    tok = urllib.parse.quote(args.token)
    if args.status:
        # v0.3.125r6: 健康快照（在线性/队列/最近命令）
        try:
            r = http_json("%s/status?token=%s" % (base, tok))
        except urllib.error.HTTPError as e:
            print("error: server HTTP %d: %s" %
                  (e.code, e.read().decode("utf-8", "replace")[:300]),
                  file=sys.stderr)
            return 2
        except Exception as e:
            print("error: %s（服务器在跑吗）" % e, file=sys.stderr)
            return 2
        print(json.dumps(r, ensure_ascii=False, indent=1))
        return 0
    op_args = {}
    if args.exec is not None:
        op = "exec"
        op_args["command"] = args.exec
        if args.timeout:
            op_args["timeout"] = args.timeout
    elif args.read is not None:
        op = "read"
        op_args["path"] = args.read
        if args.offset is not None:
            op_args["offset"] = args.offset
        if args.limit is not None:
            op_args["limit"] = args.limit
    elif args.write is not None:
        op = "write"
        content = args.content if args.content is not None else ""
        if len(args.write) > 1:
            op_args = {"path": args.write[0], "content": args.write[1]}
        else:
            op_args = {"path": args.write[0], "content": content}
    elif args.list is not None:
        op = "list"
        op_args["path"] = args.list
    elif args.ping:
        op = "ping"
    elif args.lua is not None:
        # v0.3.125r5: 服务器下发 Lua 脚本执行（return 值即结果）
        # v0.3.125r6: 支持 --timeout（守护侧硬帽看门狗，默认 60s）
        op = "lua"
        op_args = {"code": args.lua}
        if args.timeout:
            op_args["timeout"] = args.timeout
    else:
        print("error: 需指定 --ping / --exec / --read / --write / --list / --lua",
              file=sys.stderr)
        return 2

    try:
        r = http_json("%s/cmd?token=%s" % (base, tok), {"op": op, "args": op_args})
    except urllib.error.HTTPError as e:
        # v0.3.125r6: 服务器拒收（400 单行/emoji、413 过大、429 队列满）
        # 把原因打全，而不是笼统"发送失败"
        print("error: server HTTP %d: %s" %
              (e.code, e.read().decode("utf-8", "replace")[:300]), file=sys.stderr)
        return 2
    except Exception as e:
        print("error: 发送命令失败（服务器在跑吗）: %s" % e, file=sys.stderr)
        return 2
    rid = r.get("id")
    print("[cmd %s] 已入队，等待结果（≤%ds）..." % (rid, args.wait),
          file=sys.stderr, flush=True)
    deadline = time.time() + args.wait
    while True:
        try:
            r = http_json("%s/result?token=%s&id=%s&wait=%.1f" %
                          (base, tok, rid, min(max(deadline - time.time(), 0.5), 15.0)),
                          timeout=20)
        except Exception as e:
            print("error: 查询结果失败: %s" % e, file=sys.stderr)
            return 2
        if r.get("ready"):
            ok = r.get("ok")
            # v0.3.125r5: 大结果自动分页（首块 64KB + fetch 续块）
            result = fetch_all(base, tok, r, time.time() + args.wait)
            print(result if result != "" else "(no output)")
            if not ok:
                print("[remote: 执行报错]", file=sys.stderr)
                return 1
            return 0
        if r.get("lost"):
            # v0.3.125r3: 服务器判死（命令超时窗口内无 report）
            # v0.3.125r6: 窗口 = 命令 timeout + --lost-grace，基准=派发时刻
            print("lost: 命令超时窗口内无 agent 报告（窗口=命令 timeout+%ds "
                  "宽限；agent 崩溃/OOM/重启，或 report 通道断，或命令仍在"
                  "队列排队？）——先 client --status 看在线性与队列"
                  % LOST_GRACE_DEFAULT, file=sys.stderr)
            return 4
        if time.time() >= deadline:
            print("timeout: %ds 内未收到结果（agent 在线？/remote 状态？）" %
                  args.wait, file=sys.stderr)
            return 3
        time.sleep(0.2)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="mode", required=True)

    ps = sub.add_parser("serve", help="常驻控制服务器")
    ps.add_argument("--port", type=int, default=8765)
    ps.add_argument("--bind", default="0.0.0.0",
                    help="监听地址（默认 0.0.0.0——真机 agent 需从局域网可达；"
                         "本机测试可用 127.0.0.1）")
    ps.add_argument("--token", required=True)
    ps.add_argument("--hold", type=int, default=HOLD_DEFAULT,
                    help="long-poll hold 秒数（默认 %d）" % HOLD_DEFAULT)
    ps.add_argument("--allow-emoji", action="store_true",
                    help="允许 exec 命令含 4 字节 UTF-8（emoji）。默认拒收"
                         "——ocvm C++ unicode 上游 bug 会崩；真机 OC(Java) 无此"
                         "问题，真机专用服务器建议放开")
    ps.add_argument("--queue-max", type=int, default=QUEUE_MAX_DEFAULT,
                    help="单 token 命令队列深度上限（默认 %d，满则 429）"
                         % QUEUE_MAX_DEFAULT)
    ps.add_argument("--lost-grace", type=int, default=LOST_GRACE_DEFAULT,
                    help="lost 宽限秒数（命令 timeout 到期后再等这么久才判"
                         " lost；默认 %d）" % LOST_GRACE_DEFAULT)
    ps.set_defaults(func=cmd_serve)

    pc = sub.add_parser("client", help="一次性命令")
    pc.add_argument("--base", default="http://127.0.0.1:8765")
    pc.add_argument("--token", required=True)
    pc.add_argument("--status", action="store_true",
                    help="打印守护健康快照（GET /status）后退出")
    pc.add_argument("--ping", action="store_true")
    pc.add_argument("--exec", metavar="CMD")
    pc.add_argument("--timeout", type=int, default=None,
                    help="exec/lua 的命令超时（秒，默认 60）")
    pc.add_argument("--read", metavar="PATH")
    pc.add_argument("--offset", type=int, default=None)
    pc.add_argument("--limit", type=int, default=None)
    pc.add_argument("--write", nargs="+", metavar="PATH [CONTENT]",
                    help="两参: PATH CONTENT；单参: PATH（内容取 --content）")
    pc.add_argument("--content", default=None)
    pc.add_argument("--list", metavar="PATH")
    pc.add_argument("--lua", metavar="CODE",
                    help="v0.3.125r5: 下发 Lua 脚本执行（return 值即结果，"
                         "大结果自动分页取回）")
    pc.add_argument("--wait", type=int, default=60, help="结果等待上限（秒）")
    pc.set_defaults(func=cmd_client)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

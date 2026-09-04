#!/usr/bin/env python3
"""remote_server.py — OC agent 远程控制守护的控制服务器（v0.3.125）。

agent 侧（src/agent/remote.lua）是 long-poll 客户端：经 internet 卡
主动轮询本服务器取命令（ping/exec/read/write/list），执行后经
现有工具注册表回传结果。本服务器在宿主机（DSH 侧）运行，提供命令
入队与结果查询。

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
                                         | {"ready":false}

仅用 Python 标准库。
"""
import argparse
import json
import sys
import threading
import time
import urllib.parse
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HOLD_DEFAULT = 12        # /poll 无命令时最长 hold（秒）—— agent 侧读 deadline 30s
RESULT_TTL = 3600        # 结果保留（秒）
MAX_CMD_WIRE = 100000    # /cmd 入队的线上 JSON 字节上限（agent MAX_POLL_BODY=131072 之下留余量）
ALLOWED_OPS = {"ping", "exec", "read", "write", "list"}


class State:
    def __init__(self, token, hold):
        self.token = token
        self.hold = hold
        self.lock = threading.Lock()
        self.queues = {}          # token -> deque of cmd dicts
        self.results = {}         # id -> {"ready":.., "ok":.., "result":.., "at":..}
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
                with state.cond:
                    while True:
                        r = state.results.get(rid)
                        if r and r.get("ready"):
                            self._send(200, r)
                            return
                        remaining = deadline - time.time()
                        if remaining <= 0:
                            break
                        state.cond.wait(min(remaining, 2.0))
                    self._send(200, {"ready": False})
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
                    cmd["id"] = state.new_id()
                    state.queues.setdefault(state.token, deque())
                    state.queues[state.token].append(cmd)
                    state.cond.notify_all()
                    # 顺带清过期结果
                    cutoff = time.time() - RESULT_TTL
                    for k in [k for k, v in state.results.items()
                              if v.get("at", 0) < cutoff]:
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
                    state.results[rid] = {
                        "ready": True,
                        "ok": bool(rep.get("ok")),
                        "result": rep.get("result", ""),
                        "at": time.time(),
                    }
                    state.cond.notify_all()
                log("report %s ok=%s (%d chars)" % (
                    rid, rep.get("ok"), len(rep.get("result", ""))))
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})

    return Handler


def cmd_serve(args):
    state = State(args.token, args.hold)
    httpd = ThreadingHTTPServer((args.bind, args.port), make_handler(state))
    httpd.daemon_threads = True
    log("serving on %s:%d (hold=%ds); Ctrl+C to stop" %
        (args.bind, args.port, args.hold))
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


def cmd_client(args):
    base = args.base.rstrip("/")
    tok = urllib.parse.quote(args.token)
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
    else:
        print("error: 需指定 --ping / --exec / --read / --write / --list",
              file=sys.stderr)
        return 2

    try:
        r = http_json("%s/cmd?token=%s" % (base, tok), {"op": op, "args": op_args})
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
            result = r.get("result", "")
            print(result if result != "" else "(no output)")
            if not ok:
                print("[remote: 执行报错]", file=sys.stderr)
                return 1
            return 0
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
    ps.set_defaults(func=cmd_serve)

    pc = sub.add_parser("client", help="一次性命令")
    pc.add_argument("--base", default="http://127.0.0.1:8765")
    pc.add_argument("--token", required=True)
    pc.add_argument("--ping", action="store_true")
    pc.add_argument("--exec", metavar="CMD")
    pc.add_argument("--timeout", type=int, default=None,
                    help="exec 的子命令超时（秒）")
    pc.add_argument("--read", metavar="PATH")
    pc.add_argument("--offset", type=int, default=None)
    pc.add_argument("--limit", type=int, default=None)
    pc.add_argument("--write", nargs="+", metavar="PATH [CONTENT]",
                    help="两参: PATH CONTENT；单参: PATH（内容取 --content）")
    pc.add_argument("--content", default=None)
    pc.add_argument("--list", metavar="PATH")
    pc.add_argument("--wait", type=int, default=60, help="结果等待上限（秒）")
    pc.set_defaults(func=cmd_client)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

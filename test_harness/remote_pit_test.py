#!/usr/bin/env python3
"""remote_pit_test.py — 远程通道系列命令执行挖坑测试（v0.3.125）。

前置: ① ocvm VM 里 agent 已启动且 /remote on（守护在轮询）
      ② 控制服务器在跑（serve 模式）
用法:
    python3 test_harness/remote_pit_test.py \
        --base http://127.0.0.1:8765 --token ocvmtoken123 [--only NAME... ]

每个用例: 发命令 → 等结果（≤45s）→ 比对期望 → 记 PASS/FAIL/OBSERVE。
OBSERVE = 行为不确定/需要人眼确认的用例，打印实际输出供记录。
退出码: FAIL 数。
"""
import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools")))
import remote_server as rs  # noqa: E402  (服务器自检段复用其 Handler)

WAIT = 45


def http_json(url, body=None, timeout=20):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def one_cmd(base, tok, op, args, wait=WAIT):
    """发一条命令等结果。返回 (ok, result, err_note)。
    err_note 非 None = 传输层/服务器层错误（非 agent 执行结果）。"""
    try:
        r = http_json("%s/cmd?token=%s" % (base, tok), {"op": op, "args": args})
    except urllib.error.HTTPError as e:
        return None, None, "server HTTP %d: %s" % (e.code, e.read()[:200])
    except Exception as e:
        return None, None, "send failed: %s" % e
    rid = r.get("id")
    deadline = time.time() + wait
    while time.time() < deadline:
        try:
            r = http_json("%s/result?token=%s&id=%s&wait=10" % (base, tok, rid))
        except Exception as e:
            return None, None, "result query failed: %s" % e
        if r.get("ready"):
            return r.get("ok"), r.get("result", ""), None
    return None, None, "timeout after %ds" % wait


# (name, op, args, expect)
# expect: ("ok", regex) | ("err", regex) | ("any",) | ("observe",)
CASES = [
    # ── exec: JSON 三层往返（client json → server json → agent json）──
    ("exec_quotes", "exec",
     {"command": "echo 'a \"b\" c\\ d'"},
     ("ok", r'a "b" c\\ d')),  # 单引号内: 引号原样, 反斜杠字面（OpenOS 字面引号语义）
    ("exec_unicode", "exec",
     {"command": "echo 你好🌍中文"},
     # v0.3.125r6 防护: 服务器默认 400 拒收 4 字节 UTF-8（非 BMP）——
     # 旧实证坑: ocvm C++ unicode.cpp 上游 bug（4 字节按 3 字节解码+余
     # 字节终止迭代）原生崩溃/其后文本丢失，一条命令可打崩测试 VM。
     # 真机 OC(Java codePoints) 无此问题，--allow-emoji 服务器可放开
     # （崩溃行为不可再经本通道触达，上游 bug 记录于注释）。
     ("http400", "4-byte UTF-8")),
    ("exec_var_expand", "exec",
     {"command": "echo home=$HOME"},
     ("ok", r"home=/home")),
    ("exec_meta_as_data", "exec",
     {"command": r"echo 'a; b | c & d $(x)'"},
     ("ok", r"a; b \| c & d \$\(x\)")),
    ("exec_multiline", "exec",
     {"command": "echo l1\necho l2"},
     # v0.3.125r6 防护: 服务器 400 拒收——旧实证坑是 OpenOS shell 把换行
     # 拍平成空格（"l1 echo l2" 一条命令，静默错）；现提前拒收并提示
     # &&/; 串联（r6 前本用例锁的是拍平行为）。
     ("http400", "single line")),
    ("exec_nonzero_exit", "exec",
     {"command": "false"},
     ("observe",)),  # 预期 (no output)——exit code 是否丢失待确认
    ("exec_stderr_merge", "exec",
     {"command": "lua /tmp/no_such_script_xyz.lua"},
     ("ok", "file not found")),  # 真 stderr 测试: lua 错误写 stderr, agent popen 追加 2>&1 后应捕获
    # (旧用例 `echo to-stderr 1>&2` 已删: 叠加 agent 的 2>&1 后, POSIX 语义下
    #  stdout 目标被改到 stderr(丢弃), 真 bash 同样无输出——测的不是合并)
    ("exec_error_prefix", "exec",
     {"command": "echo 'Error: not-a-real-error'"},
     # r3 结构化 is_err 已消除 ^Error 前缀误判（假阳回归由 run_tests
     # ex.run 用例覆盖）: 成功命令的输出即使以 Error 开头也是 ok。
     # 本用例现守护协议侧回归（若嗅探回退被误启用会退回 err）。
     ("ok", "not-a-real-error")),
    ("exec_chain", "exec",
     {"command": "echo a && echo b"},
     ("ok", r"a[\s\S]*b")),
    ("exec_slow_3s", "exec",
     {"command": "sleep 3 && echo slow-done"},
     ("ok", "slow-done")),
    ("exec_big_out_70k", "exec",
     {"command": "cat /tmp/big70k_out.txt"},
     ("observe",)),  # 预期 64KB 截断标记（脚本先写文件，cat 回取）
    # ── lua 包装器行为（OpenOS 1.8.9 实测坑区）──
    ("lua_e_broken", "exec",
     {"command": "lua -e 'print(42)'"},
     ("observe",)),  # 预期失败: 包装器把 args[1] 当文件名
    ("lua_script_leak", "exec",
     {"command": "lua /tmp/leak.lua"},
     ("observe",)),  # 预期 pipe 空输出, print 泄漏到终端
    ("lua_script_cat_control", "exec",
     {"command": "cat /tmp/leak.lua"},
     ("ok", "LEAKTEST")),  # 对照组: 文件命令捕获正常
    ("wc_guard_block", "exec",
     {"command": "wc -c /tmp/leak.txt_probe"},
     ("err", "guard")),  # wc 在护栏禁词表（OpenOS 无 wc）
    ("exec_bare_lua_guard", "exec",
     {"command": "lua"},
     ("err", "guard")),
    ("exec_timeout_param", "exec",
     {"command": "sleep 30", "timeout": 5},
     ("err", "timeout after 5")),
    ("exec_no_cmd", "exec",
     {},
     ("err", "args.command")),
    # ── read ──
    ("read_missing", "read", {"path": "/tmp/nope_not_exist.txt"},
     ("err", "file not found")),
    ("read_dir", "read", {"path": "/tmp"},
     ("observe",)),  # io.open(目录) 行为
    ("read_lines100", "read", {"path": "/tmp/lines100.txt"},
     ("ok", r"line-001[\s\S]*line-100")),
    ("read_slice", "read", {"path": "/tmp/lines100.txt", "offset": 50, "limit": 5},
     ("ok", r"^50\. line-050[\s\S]*54\. line-054")),
    ("read_neg_offset", "read", {"path": "/tmp/lines100.txt", "offset": -2},
     ("ok", r"line-099[\s\S]*line-100")),
    ("read_trunc_1000", "read", {"path": "/tmp/lines1000.txt"},
     ("ok", r"truncated: showing first 400 lines")),
    ("read_slice_too_big", "read", {"path": "/tmp/lines1000.txt", "limit": 2000},
     ("observe",)),  # 切片超 20KB 尾注
    ("read_binary", "read", {"path": "/tmp/bin.dat"},
     ("observe",)),  # \0 字节 JSON 往返
    # ── write ──
    ("write_bad_dir", "write",
     {"path": "/tmp/nodir_x/x.txt", "content": "x"},
     ("err", "cannot open for writing")),
    ("write_readonly", "write",
     {"path": "/home/remote_ro_test.txt", "content": "x"},
     ("err", "cannot open for writing|readonly|read-only")),
    ("write_special", "write",
     {"path": "/tmp/special.txt",
      "content": 'q="x"\n$HOME `cmd` 中文🌍\nback\\slash'},
     ("ok", "Written to")),
    ("write_special_verify", "read", {"path": "/tmp/special.txt"},
     ("ok", r'\$HOME `cmd` 中文🌍')),
    ("write_empty", "write", {"path": "/tmp/empty.txt", "content": ""},
     ("ok", "Written to")),
    ("write_90k", "write",
     {"path": "/tmp/big90k.txt", "content": "C" * 90000},
     ("ok", "Written to")),  # 413 边界下沿: 线上 ~90KB < MAX_CMD_WIRE=100000, 应成功
    ("write_120k", "write",
     {"path": "/tmp/big120k.txt", "content": "A" * 120000},
     # v0.3.125r2: 服务器 /cmd 拒收 >100KB 线上字节 → HTTP 413 明确报错
     ("http413", "too large")),
    ("write_200k", "write",
     {"path": "/tmp/big200k.txt", "content": "B" * 200000},
     ("http413", "too large")),  # 同上
    ("write_overwrite", "write",
     {"path": "/tmp/ow.txt", "content": "second"},
     ("ok", "Written to")),
    ("write_overwrite_verify", "read", {"path": "/tmp/ow.txt"},
     ("ok", "second")),
    # ── list ──
    ("list_missing", "list", {"path": "/tmp/nodir_y"},
     ("observe",)),
    ("list_root", "list", {"path": "/"},
     ("observe",)),
    ("list_many50", "list", {"path": "/tmp/many"},
     ("ok", r"f50\.txt")),
    # ── v0.3.125r6b 守护侧硬帽看门狗（deadline 注入版）──
    ("lua_watchdog_kill", "lua",
     {"code": "while true do os.sleep(0) end", "timeout": 3},
     # 坑防护: 死循环脚本必须在 timeout+30s 硬帽内被 deadline error
     # kill 并回传 err（ocvm+真机同路径: 内联执行+包装 os.sleep，
     # 子线程方案两次实证饿死全机后废弃 r6b）。watchdog 标签首分支
     # = ok False + 命中 "deadline exceeded"；次分支 = 冻结→恢复
     # 兜底（若 ocvm 另有行为）。
     ("watchdog", "deadline exceeded")),
    # ── ping 回归 ──
    ("ping", "ping", {}, ("ok", r'"os":"OpenOS')),
]

# 前置: 生成测试文件。注意 OpenOS 1.8.9 坑: `lua script.lua` 的 stdout
# 不进 popen 管道（泄漏到终端）——脚本一律写文件, 驱动用 cat 回取。
SETUP = '''local f = io.open("/tmp/lines100.txt", "w")
for i = 1, 100 do f:write(("line-%03d\\n"):format(i)) end
f:close()
f = io.open("/tmp/lines1000.txt", "w")
for i = 1, 1000 do f:write(("line-%03d\\n"):format(i)) end
f:close()
f = io.open("/tmp/bin.dat", "wb")
f:write(string.char(0, 1, 2, 255, 10))
f:close()
local fs = require("filesystem")
pcall(fs.makeDirectory, "/tmp/many")
for i = 1, 50 do
  local g = io.open("/tmp/many/f" .. i .. ".txt", "w")
  g:write("data" .. i)
  g:close()
end
f = io.open("/tmp/leak.lua", "w")
f:write('print("LEAKTEST")\\n')
f:close()
f = io.open("/tmp/big70k_out.txt", "w")
for i = 1, 700 do f:write(string.rep("x", 100)) end
f:close()
f = io.open("/tmp/setup_done", "w")
f:write("setup-done")
f:close()
'''


def start_helper(allow_emoji=False, queue_max=10 ** 9, lost_grace=120,
                 hold=2):
    """起一个独立控制服务器（临时端口，daemon 线程）——服务器侧防护自检
    不与主服务器/真机守护纠缠。"""
    st = rs.State("pittok", hold, allow_emoji=allow_emoji,
                  queue_max=queue_max, lost_grace=lost_grace)
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), rs.make_handler(st))
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return "http://127.0.0.1:%d" % port, httpd


def server_self_tests(base_main, tok_main):
    """v0.3.125r6 服务器侧防护自检（独立 helper 服务器，不需要 agent）:
    ① exec 单行拒收 ② exec emoji 默认拒收/--allow-emoji 放开
    ③ 队列满 429 ④ 按命令超时的 lost（派发基准+离线判死）
    ⑤ /status 在线性（离线 helper 判 false，主服务器守护在线判 true）"""
    results = []

    def run_case(name, fn):
        t0 = time.time()
        try:
            note = fn()
            verdict, actual = ("PASS", "(ok)") if note is None \
                else ("FAIL", note)
        except Exception as e:
            verdict, actual = "FAIL", "exception: %s" % e
        dt = time.time() - t0
        results.append((name, verdict, dt, actual))
        print("%-24s %-8s %5.1fs  %s" %
              (name, verdict, dt, actual), flush=True)

    def post(b, op, args):
        try:
            return http_json("%s/cmd?token=pittok" % b,
                             {"op": op, "args": args}), None
        except urllib.error.HTTPError as e:
            return None, "HTTP %d: %s" % (
                e.code, e.read().decode("utf-8", "replace")[:200])
        except Exception as e:
            return None, "send failed: %s" % e

    def expect_reject(name, b, op, args, frag):
        def fn():
            r, err = post(b, op, args)
            if r is not None:
                return "未被拒收（入队 %s）" % r
            if err and frag.lower() in err.lower():
                return None
            return "拒收但消息不符: %s" % err
        run_case(name, fn)

    b1, _ = start_helper()  # 默认参数（emoji 拒收）
    expect_reject("srv_reject_multiline", b1, "exec",
                  {"command": "echo a\necho b"}, "single line")
    expect_reject("srv_reject_emoji", b1, "exec",
                  {"command": "echo 你好🌍"}, "4-byte utf-8")
    # 中文（3 字节 BMP）不受 emoji 防护影响
    def fn_cjk():
        r, err = post(b1, "exec", {"command": "echo 你好"})
        if r is None:
            return "BMP 中文被误拒: %s" % err
        return None
    run_case("srv_allow_bmp_chinese", fn_cjk)
    # --allow-emoji 放开
    b2, _ = start_helper(allow_emoji=True)

    def fn_emoji_on():
        r, err = post(b2, "exec", {"command": "echo 你好🌍"})
        if r is None:
            return "allow_emoji 下仍被拒: %s" % err
        return None
    run_case("srv_allow_emoji_flag", fn_emoji_on)
    # 队列满 429
    b3, _ = start_helper(queue_max=3)

    def fn_queue_full():
        notes = []
        for i in range(3):
            r, err = post(b3, "ping", {})
            if r is None:
                return "第 %d 条意外被拒: %s" % (i + 1, err)
        r4, err4 = post(b3, "ping", {})
        if r4 is not None:
            return "队列满仍入队: %s" % r4
        if not (err4 and "429" in err4 and "queue full" in err4.lower()):
            return "429 消息不符: %s" % err4
        return None
    run_case("srv_queue_full_429", fn_queue_full)
    # 按命令超时的 lost（离线守护: 队列永不消费; 窗口=lost_grace）
    b4, _ = start_helper(lost_grace=3)

    def fn_lost_offline():
        r, err = post(b4, "exec", {"command": "sleep 30", "timeout": 2})
        if r is None:
            return "入队失败: %s" % err
        rid = r["id"]
        deadline = time.time() + 25
        while time.time() < deadline:
            res = http_json("%s/result?token=pittok&id=%s&wait=5" % (b4, rid))
            if res.get("lost"):
                return None
            if res.get("ready"):
                return "意外 ready（守护不该在轮询 helper）"
        return "25s 内未判 lost（期望 ~3s 宽限后）"
    run_case("srv_lost_offline", fn_lost_offline)
    # 已 ready 的命令不受 lost 影响（report 补发后查询）
    b5, _ = start_helper(lost_grace=1)

    def fn_late_report():
        r, err = post(b5, "ping", {})
        if r is None:
            return "入队失败: %s" % err
        rid = r["id"]
        http_json("%s/report?token=pittok&id=%s" % (b5, rid),
                  {"ok": True, "result": "late"})
        deadline = time.time() + 15
        while time.time() < deadline:
            res = http_json("%s/result?token=pittok&id=%s" % (b5, rid))
            if res.get("ready"):
                return None if res.get("ok") else "ready 但 ok=false"
        return "迟到的 report 未生效"
    run_case("srv_late_report_overrides_lost", fn_late_report)
    # /status: 离线 helper 判 false; 主服务器（真机守护在线）判 true
    def fn_status_offline():
        st = http_json("%s/status?token=pittok" % b1)
        if st.get("online") is False and "queue_len" in st \
                and "version" in st:
            return None
        return "status 结构/在线性不符: %s" % st
    run_case("srv_status_offline", fn_status_offline)

    def fn_status_online():
        try:
            st = http_json("%s/status?token=%s" % (base_main, tok_main))
        except Exception as e:
            return "主服务器查询失败: %s" % e
        if st.get("online") is True:
            return None
        return "主服务器守护应在线: %s" % st
    run_case("srv_status_online_main", fn_status_online)
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8765")
    ap.add_argument("--token", required=True)
    ap.add_argument("--only", nargs="*", default=None,
                    help="只跑指定用例名")
    ap.add_argument("--skip-setup", action="store_true")
    args = ap.parse_args()
    base, tok = args.base.rstrip("/"), urllib.parse.quote(args.token)

    names = [c[0] for c in CASES]
    if args.only:
        wanted = set(args.only)
        unknown = wanted - set(names)
        if unknown:
            print("unknown cases: %s" % sorted(unknown), file=sys.stderr)
            sys.exit(2)
        CASES_ = [c for c in CASES if c[0] in wanted]
    else:
        CASES_ = CASES

    if not args.skip_setup:
        ok, res, note = one_cmd(base, tok, "write",
                                {"path": "/tmp/pit_setup.lua", "content": SETUP})
        if not ok:
            print("SETUP write failed: %s %s" % (res, note), file=sys.stderr)
            sys.exit(2)
        ok, res, note = one_cmd(base, tok, "exec",
                                {"command": "lua /tmp/pit_setup.lua && cat /tmp/setup_done"})
        if not ok or "setup-done" not in res:
            print("SETUP exec failed: %s %s" % (res, note), file=sys.stderr)
            sys.exit(2)
        print("[setup] 测试文件就绪")

    # v0.3.125r6: 服务器侧防护自检（helper 服务器，不占真机队列）
    srv_results = server_self_tests(base, tok)
    results = []
    for name, op, op_args, expect in CASES_:
        t0 = time.time()
        ok, res, note = one_cmd(base, tok, op, op_args)
        dt = time.time() - t0
        # 服务器拒收类期望（v0.3.125r2 413 过大 / v0.3.125r6 400 单行
        # 与 emoji / 429 队列满）: note 带 HTTP 码 + 消息片段
        # （兼容无片段的 1 元组 http 期望: 只校验码）
        if expect[0].startswith("http") and len(expect[0]) == 7 and note \
                and ("server HTTP %s" % expect[0][4:]) in note \
                and (len(expect) < 2 or expect[1].lower() in note.lower()):
            verdict, actual = "PASS", note
            expected = "server HTTP %s + /%s/" % (expect[0][4:], expect[1])
        elif expect[0] == "watchdog":
            # 双路径（见用例注释）: 真机=cap 内 kill 回 err; ocvm=冻结
            # 限制（客户端等待超时）→ 必须验证守护恢复（≤300s ping 通）
            if ok is False and re.search(expect[1], res or "", re.M):
                verdict, expected = "PASS", "err + /%s/" % expect[1]
                actual = res
            elif note and note.startswith("timeout after"):
                t_rec = time.time()
                recovered = 0
                while time.time() - t_rec < 300:
                    okp, resp, notep = one_cmd(base, tok, "ping", {}, wait=15)
                    if okp:
                        recovered = int(time.time() - t_rec)
                        break
                if recovered:
                    verdict, expected = "PASS", \
                        "ocvm 冻结(已知限制) + %ds 恢复" % recovered
                    actual = note + " → 恢复 %ds" % recovered
                    dt = time.time() - t0
                else:
                    verdict, expected = "FAIL", \
                        "冻结后 300s 守护未恢复"
                    actual = note
            else:
                verdict, expected = "FAIL", \
                    "watchdog err 或 ocvm 冻结+恢复"
                actual = (res or note) or "(无)"
        elif note is not None:
            verdict, actual = "FAIL", note
            expected = ""
        else:
            actual = res
            if expect[0] == "observe":
                verdict, expected = "OBSERVE", "(观察)"
            elif expect[0] == "ok":
                m = re.search(expect[1], res or "", re.M)
                verdict = "PASS" if (ok and m) else "FAIL"
                expected = "ok + /%s/" % expect[1]
            else:  # err
                m = re.search(expect[1], res or "", re.M)
                verdict = "PASS" if (ok is False and m) else "FAIL"
                expected = "err + /%s/" % expect[1]
        results.append((name, verdict, dt, actual, expected))
        shown = (actual or "").replace("\n", "\\n")
        if len(shown) > 140:
            shown = shown[:140] + "…"
        print("%-22s %-8s %5.1fs  %s   # expect: %s" %
              (name, verdict, dt, shown, expected), flush=True)

    n_fail = sum(1 for r in results if r[1] == "FAIL") \
        + sum(1 for r in srv_results if r[1] == "FAIL")
    n_obs = sum(1 for r in results if r[1] == "OBSERVE")
    n_pass = sum(1 for r in results if r[1] == "PASS") \
        + sum(1 for r in srv_results if r[1] == "PASS")
    print("\n== 汇总: %d PASS / %d FAIL / %d OBSERVE ==" %
          (n_pass, n_fail, n_obs))
    sys.exit(n_fail)


if __name__ == "__main__":
    main()

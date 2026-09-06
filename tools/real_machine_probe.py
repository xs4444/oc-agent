#!/usr/bin/env python3
"""real_machine_probe.py — 真机（GTNH Java 宿主 / OpenOS 1.8.9）远控通道探针套件。

前置: ① 真机 agent 已升到 v0.3.125 且 /remote on（守护在轮询）
      ② 控制服务器可达（公网或局域网），token 正确
用法:
    python3 tools/real_machine_probe.py --base http://<server>:8765 --token <tok>
        [--with-stress] [--save-report /tmp/real_probe.json]

设计: 全程非破坏性（只写 /tmp/rp_* 并在最后清理）；2MB 机器安全
（内存压测默认关闭，--with-stress 开启）。
每个探针: 发命令 → 等结果（≤45s）→ 比对期望 → PASS/FAIL/OBSERVE。
OBSERVE = 信息型探针，打印实际值供人眼确认。
退出码: FAIL 数。

与 test_harness/remote_pit_test.py（ocvm 宿主）的期望差异（有意为之）:
  - emoji: 真机 Java UnicodeAPI（codePoints）正确 → 期望完整回显；
    ocvm C++ unicode.cpp 上游 bug → ocvm 驱动只期望中文前缀。
  - 其余协议层期望（is_err 三前缀/413/队列）两宿主相同。
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

WAIT = 45

ID_SCRIPT = '''local f = io.open("/tmp/rp_id.txt", "w")
f:write("os=" .. tostring(_G._OSVERSION) .. "\\n")
f:write("family=" .. tostring(os.family()) .. "\\n")
f:write("computer=" .. tostring(computer.getType()) .. "\\n")
f:write("mounts=" .. table.concat(fs.mounts(), ",") .. "\\n")
f:write("internet=" .. tostring(component.list("internet") ~= nil) .. "\\n")
f:close()
print("probe-id done")
'''

# OC Lua 环境无 collectgarbage 全局（GC 由宿主管理: Java 常开/ocvm
# client.cfg allowGC）——真机实测 p12b 曾因此 FAIL，勿调用。
STRESS_SCRIPT = '''local t = {}
for i = 1, 12000 do t[i] = string.rep("x", 32) end  -- ~400KB
local f = io.open("/tmp/rp_stress.txt", "w")
f:write("stress-ok n=" .. #t .. "\\n")
f:close()
print("probe-stress done")
'''


def http_json(url, body=None, timeout=20):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def one_cmd(base, tok, op, args, wait=WAIT):
    """发一条命令等结果。返回 (ok, result, err_note, meta)。
    err_note 非 None = 传输层/服务器层错误（非 agent 执行结果）。
    meta（v0.3.125r5）: 大结果分页 meta dict 或 None。"""
    try:
        r = http_json("%s/cmd?token=%s" % (base, tok), {"op": op, "args": args})
    except urllib.error.HTTPError as e:
        return None, None, "server HTTP %d: %s" % (e.code, e.read()[:200]), None
    except Exception as e:
        return None, None, "send failed: %s" % e, None
    rid = r.get("id")
    deadline = time.time() + wait
    while time.time() < deadline:
        try:
            r = http_json("%s/result?token=%s&id=%s&wait=10" % (base, tok, rid))
        except Exception as e:
            return None, None, "result query failed: %s" % e, None
        if r.get("ready"):
            meta = None
            if r.get("more"):
                meta = {k: r[k] for k in ("rid", "total", "held", "more")
                        if k in r}
            return r.get("ok"), r.get("result", ""), None, meta
    return None, None, "timeout after %ds" % wait, None


def fetch_all(base, tok, first, wait=WAIT):
    """v0.3.125r5: 大结果自动分页——first 为 ready 记录（含 more/rid/
    held 时循环 fetch 按 offset 续块，64KB/块，32 块防御上限）。
    返回 (累积文本, first)。"""
    result = first.get("result", "")
    if not first.get("more"):
        return result, first
    offset = len(result)
    held = first.get("held") or 0
    for _ in range(32):
        if offset >= held:
            break
        try:
            r = http_json("%s/cmd?token=%s" % (base, tok),
                          {"op": "fetch",
                           "args": {"rid": first["rid"], "offset": offset}})
            rid = r.get("id")
        except Exception:
            break
        dl = time.time() + wait
        fr = None
        while time.time() < dl:
            try:
                fr = http_json("%s/result?token=%s&id=%s&wait=10" %
                               (base, tok, rid))
            except Exception:
                fr = None
                break
            if fr.get("ready"):
                break
        if not fr:
            break
        chunk = fr.get("result", "")
        if fr.get("ok") is False or not chunk:
            break
        result += chunk
        offset += len(chunk)
    return result, first


# (name, op, args, expect, note)
# expect: ("ok", 子串) | ("err", 子串) | ("http413",) | ("observe",)
def build_cases(with_stress):
    c = [
        # ── P0 通道 ──
        ("p01_ping", "ping", {}, ("ok", "OpenOS"),
         "端到端 long-poll+report；带 uptime/os/memory"),
        # ── P1 身份（lua 脚本写文件 + read 回取，规避 print 泄漏管道）──
        ("p02_write_id_script", "write",
         {"path": "/tmp/rp_probe_id.lua", "content": ID_SCRIPT},
         ("ok", "Written to"), "探针脚本落盘"),
        ("p03_run_id_script", "exec",
         {"command": "lua /tmp/rp_probe_id.lua"},
         ("ok",), "脚本执行（print 走 TUI 不进管道，属已知行为）"),
        ("p04_read_id", "read", {"path": "/tmp/rp_id.txt"},
         ("ok", "OpenOS"), "os/family/computer/mounts/internet 身份"),
        # ── P2 shell 语义（真机）──
        ("p05_echo_quotes", "exec",
         {"command": 'echo \'a "b" c\\ d\''},
         ("ok", 'a "b" c\\ d'), "单引号字面量语义"),
        ("p06_emoji_roundtrip", "exec",
         {"command": "echo 你好🌍"},
         ("ok", "你好🌍"),
         "真机 Java codePoints 应完整回显（ocvm 宿主此处会 FAIL，上游 bug）"),
        ("p07_var_expand", "exec", {"command": "echo home=$HOME"},
         ("ok", "home=/home"), "$ 展开经 JSON 三层往返"),
        # ── P3 结构化 is_err（r3 修复）──
        ("p08_error_no_false_positive", "exec",
         {"command": "echo 'Error: not-a-real-error'"},
         ("ok", "Error: not-a-real-error"), "合法输出不得误判 err"),
        ("p09_guard_err", "exec", {"command": "wc /etc/rc.cfg"},
         ("err", "rejected by guard"), "护栏拒绝应 err"),
        ("p10_timeout_err", "exec",
         {"command": "sleep 8", "timeout": 5},
         ("err", "shell_execute timeout"), "超时应 err 且杀进程"),
        # ── P4 内存画像 ──
        ("p11_mem_profile", "ping", {}, ("observe",),
         "free/total 基线（2MB 机器留意守护+TUI 常驻占用）"),
    ]
    if with_stress:
        c += [
            ("p12a_write_stress", "write",
             {"path": "/tmp/rp_probe_stress.lua", "content": STRESS_SCRIPT},
             ("ok", "Written to"), "压测脚本落盘"),
            ("p12b_run_stress", "exec",
             {"command": "lua /tmp/rp_probe_stress.lua"},
             ("observe",),
             "~400KB 表分配：护栏放行则 ok（结果含 stress-ok），"
             "低内存拒则 err（rejected by guard）——两者都有信息量"),
        ]
    c += [
        # ── P5 网络出口 ──
        ("p13_wget", "exec",
         {"command": "wget --no-proxy http://example.com -O /tmp/rp_net.txt"},
         ("ok",), "agent internet 驱动 + 出口 IP 可用性"),
        ("p14_read_net", "read", {"path": "/tmp/rp_net.txt", "limit": 5},
         ("observe",), "出口回包内容（example.com 应为 HTML 头）"),
        # ── P6 边界 ──
        ("p15_write_90k", "write",
         {"path": "/tmp/rp_90k.txt", "content": "y" * 90000},
         ("ok", "Written to"), "线上 ~90KB < 100KB 限"),
        ("p16_write_120k", "write",
         {"path": "/tmp/rp_120k.txt", "content": "y" * 120000},
         ("http413",), "服务器拒收超大 payload（r2b 设计行为）"),
        # ── P7 队列（3 连发）──
        ("p17_queue_1", "exec", {"command": "echo qp1"}, ("ok", "qp1"), "连发 1/3"),
        ("p18_queue_2", "exec", {"command": "echo qp2"}, ("ok", "qp2"), "连发 2/3"),
        ("p19_queue_3", "exec", {"command": "echo qp3"}, ("ok", "qp3"), "连发 3/3"),
        # ── P8 错误路径 ──
        ("p20_read_missing", "read", {"path": "/tmp/rp_no_such_file_xyz"},
         ("err", "file not found"), "read 缺失应 err"),
        ("p21_list_missing", "list", {"path": "/tmp/rp_no_such_dir_xyz"},
         ("err", "cannot access"), "list 缺失应 err（filesystem.list 实现）"),
        # ── P10 op=lua + 大结果分页（v0.3.125r5）──
        ("p22_lua_value", "lua", {"code": "return 6*7"},
         ("ok", "42"), "op=lua return 值即结果"),
        ("p23_lua_error", "lua", {"code": 'error("boom")'},
         ("err", "boom"), "op=lua 运行错误应 err"),
        ("p24_lua_loaderr", "lua", {"code": "local x ="},
         ("err", "load failed"), "op=lua 语法错误应 err"),
        ("p25_paged_200k", "lua", {"code": 'return string.rep("x", 200000)'},
         ("paged", 200000, 200000), "200KB 结果分页全量取回（≤256KB 缓存）"),
        ("p26_paged_300k", "lua", {"code": 'return string.rep("y", 300000)'},
         ("paged", 262144, 300000),
         "超缓存上限: 取回 256KB, meta.total=300000 标志截断"),
        # ── P9 清理 ──
        ("p22_cleanup", "exec",
         {"command": "rm -f /tmp/rp_probe_id.lua /tmp/rp_id.txt "
                     "/tmp/rp_net.txt /tmp/rp_90k.txt /tmp/rp_probe_stress.lua "
                     "/tmp/rp_stress.txt; echo cleanup-done"},
         ("ok", "cleanup-done"), "临时文件清理"),
    ]
    return c


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", required=True, help="控制服务器，如 http://1.2.3.4:8765")
    ap.add_argument("--token", required=True)
    ap.add_argument("--with-stress", action="store_true",
                    help="开启 ~400KB 内存压测探针（2MB 机器谨慎）")
    ap.add_argument("--save-report", default=None,
                    help="JSON 报告落盘路径（默认 /tmp/real_machine_probe_<ts>.json）")
    a = ap.parse_args()

    results = []
    t0 = time.time()
    for i, (name, op, args, expect, note) in enumerate(build_cases(a.with_stress)):
        t1 = time.time()
        ok, result, err_note, meta = one_cmd(a.base, a.token, op, args)
        dt = time.time() - t1

        status, detail = None, ""
        if expect[0] == "paged":
            # v0.3.125r5: 大结果分页——自动 fetch 续块后比对总量
            want_len, want_total = expect[1], expect[2]
            first = dict(meta or {})
            first["result"] = result or ""
            first["more"] = bool(meta and meta.get("more"))
            acc, _ = fetch_all(a.base, a.token, first)
            got_total = (meta or {}).get("total")
            if err_note is None and len(acc) == want_len and got_total == want_total:
                status, detail = "PASS", "取回 %d 字符 (meta.total=%s)" % (
                    len(acc), got_total)
            else:
                status, detail = "FAIL", "期望 %d 字符 total=%s 实际 %d (total=%s, err=%s)" % (
                    want_len, want_total, len(acc), got_total, err_note)
        elif err_note:
            if expect[0] == "http413" and "413" in err_note:
                status, detail = "PASS", "服务器 413 拒收（设计行为）"
            else:
                status, detail = "FAIL", "传输/服务器错误: %s" % err_note
        elif expect[0] == "http413":
            status, detail = "FAIL", "期望 413 实际返回结果: %r" % (result[:120],)
        elif expect[0] == "observe":
            status = "OBSERVE"
            detail = "实际: %r" % (result[:200] if ok else err_note,)
        elif ok is True and expect[0] == "ok":
            sub = expect[1] if len(expect) > 1 else None
            if sub is None or sub in (result or ""):
                status, detail = "PASS", "命中 %r" % (sub or "(任意)")
            else:
                status, detail = "FAIL", "期望含 %r 实际: %r" % (sub, (result or "")[:200])
        elif ok is False and expect[0] == "err":
            sub = expect[1]
            if sub is None or sub in (result or ""):
                status, detail = "PASS", "err 命中 %r" % (sub or "(任意)")
            else:
                status, detail = "FAIL", "err 期望含 %r 实际: %r" % (sub, (result or "")[:200])
        else:
            status, detail = "FAIL", "ok=%r 期望 %s, 实际: %r" % (
                ok, expect, (result or "")[:200])

        results.append({"name": name, "op": op, "args": args,
                        "ok": ok, "result": (result or "")[:2000],
                        "err_note": err_note, "status": status,
                        "detail": detail, "note": note, "secs": round(dt, 1)})
        print("[%2d/%d] %-22s %-8s %s" % (i + 1, len(build_cases(a.with_stress)),
                                          name, status, detail[:150]))
        # P0 失败 = 通道没通，后续全免谈
        if name == "p01_ping" and status != "PASS":
            print("\n[p01] 通道未通——检查: /remote 是否 on？token 是否正确？"
                  "服务器是否可达？世界是否在 ticking？", file=sys.stderr)
            break

    n_pass = sum(1 for r in results if r["status"] == "PASS")
    n_fail = sum(1 for r in results if r["status"] == "FAIL")
    n_obs = sum(1 for r in results if r["status"] == "OBSERVE")
    total = time.time() - t0
    print("\n=== 汇总: %d PASS / %d FAIL / %d OBSERVE, 耗时 %.0fs ==="
          % (n_pass, n_fail, n_obs, total))
    for r in results:
        if r["status"] in ("FAIL", "OBSERVE"):
            print("  %-22s %s | 实际: %r | 备注: %s"
                  % (r["name"], r["status"], (r["result"] or r["err_note"] or "")[:200],
                     r["note"]))

    save = a.save_report or "/tmp/real_machine_probe_%s.json" % time.strftime("%Y%m%d_%H%M%S")
    with open(save, "w", encoding="utf-8") as f:
        json.dump({"base": a.base, "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "with_stress": a.with_stress,
                   "summary": [n_pass, n_fail, n_obs],
                   "results": results}, f, ensure_ascii=False, indent=1)
    print("JSON 报告: %s" % save)
    sys.exit(n_fail)


if __name__ == "__main__":
    main()

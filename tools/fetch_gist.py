#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fetch_gist.py — 拉取 GitHub gist 内容（调试专用，一次成功，规避三坑）

坑位规避（历史教训，压缩后常犯）：
  1) JSON 管道解析失败：gist 内容含特殊字符/大转义，curl|python 内联管道
     易被截断 → 本脚本落盘再解析
  2) /tmp 路径：Windows git-bash 下 /tmp 映射异常 → 用脚本同目录/系统临时目录
  3) GBK 控制台编码：print 中文/替换符崩 → stdout 强制 UTF-8

用法：
  GIST_TOKEN=<token> python tools/fetch_gist.py <gist_id>            # 打印全部文件
  GIST_TOKEN=<token> python tools/fetch_gist.py --list               # 最近 5 个 gist
  GIST_TOKEN=<token> python tools/fetch_gist.py --latest             # 最新一个 gist 全文
  GIST_TOKEN=<token> python tools/fetch_gist.py <gist_id> -o out.txt # 落盘 + 打印
  GIST_TOKEN=<token> python tools/fetch_gist.py <gist_id> --raw      # 只打印 raw 内容（无文件头）

token 来源优先级：环境变量 GIST_TOKEN > 参数 --token > ~/.gist_token 文件。
debug report gist 的 token 在用户真机 config（config.gist_token，40 字符），
由用户提供后 export GIST_TOKEN=xxx 使用。
"""
import json
import os
import sys
import tempfile
import urllib.request

API = "https://api.github.com"
HEAD = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}


def get_token():
    t = os.environ.get("GIST_TOKEN")
    if t:
        return t
    p = os.path.expanduser("~/.gist_token")
    if os.path.exists(p):
        return open(p).read().strip()
    return None


def req(url, token):
    h = dict(HEAD)
    if token:
        h["Authorization"] = "token " + token
    r = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(r, timeout=60) as resp:
        return resp.read().decode("utf-8", errors="replace")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--") or a in ("--raw", "--list", "--latest")]
    flags = set(a for a in sys.argv[1:] if a.startswith("--"))
    token = get_token()
    if not token:
        print("ERROR: no token (set GIST_TOKEN or ~/.gist_token)", file=sys.stderr)
        sys.exit(1)
    if "--list" in flags:
        data = json.loads(req(API + "/users/xs4444/gists?per_page=5", token))
        for g in data:
            print(g["id"], g["created_at"], "-", g.get("description") or "")
        return
    gid = args[0] if args else None
    if "--latest" in flags or gid is None:
        data = json.loads(req(API + "/users/xs4444/gists?per_page=1", token))
        if not data:
            print("no gists")
            return
        gid = data[0]["id"]
        print("# latest gist:", gid, data[0].get("description") or "")
    raw = req(API + "/gists/" + gid, token)
    # 临时文件落盘（规避管道截断）
    tmp = os.path.join(tempfile.gettempdir(), "gist_%s.json" % gid)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(raw)
    d = json.loads(raw)
    out = []
    for name, info in d["files"].items():
        content = info.get("content", "")
        if "--raw" in flags:
            out.append(content)
        else:
            out.append("=== FILE: %s %d bytes ===" % (name, len(content)))
            out.append(content)
    text = "\n".join(out)
    # stdout 强制 UTF-8（GBK 控制台不崩）
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    print(text)
    if "-o" in sys.argv:
        i = sys.argv.index("-o")
        with open(sys.argv[i + 1], "w", encoding="utf-8") as f:
            f.write(text)
        print("\n# saved to", sys.argv[i + 1], file=sys.stderr)


if __name__ == "__main__":
    main()

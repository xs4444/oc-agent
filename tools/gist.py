#!/usr/bin/env python3
"""gist.py — GitHub gist 工具（拉取 /debug 报告用）

用法:
    python tools/gist.py list                          # 列出最近 20 个
    python tools/gist.py latest                        # 最新一个，打印内容
    python tools/gist.py latest -o report.txt          # 最新一个，存文件
    python tools/gist.py fetch <gist_id> [-o out.txt]  # 指定 ID

Token: 环境变量 GH_TOKEN（gist scope），或 --token 参数
"""
import argparse
import json
import os
import sys
import urllib.request

API = "https://api.github.com"


def api(path, token):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
        },
    )
    return json.load(urllib.request.urlopen(req, timeout=30))


def fetch_raw(url):
    return urllib.request.urlopen(url, timeout=30).read()


def emit(data, out):
    if out:
        with open(out, "wb") as f:
            f.write(data)
        print(f"saved to {out} ({len(data)} bytes)")
    else:
        sys.stdout.buffer.write(data)
        sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser(description="GitHub gist 工具")
    ap.add_argument("action", choices=["list", "latest", "fetch"])
    ap.add_argument("gist_id", nargs="?", default=None)
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--token", default=os.environ.get("GH_TOKEN", ""))
    args = ap.parse_args()

    if not args.token:
        print("需要 token: 环境变量 GH_TOKEN 或 --token", file=sys.stderr)
        return 1

    if args.action == "list":
        for g in api("/gists?per_page=20", args.token):
            print(
                g["id"], "|", g["created_at"], "|",
                (g["description"] or "")[:50], "|",
                list(g["files"].keys()),
            )

    elif args.action == "latest":
        g = api("/gists?per_page=1", args.token)[0]
        print(f"latest: {g['id']} {g['created_at']} {(g['description'] or '')}")
        if g["files"]:
            name = list(g["files"].keys())[0]
            emit(fetch_raw(g["files"][name]["raw_url"]), args.out)
        else:
            print("(gist 无文件)")

    elif args.action == "fetch":
        gid = args.gist_id
        if not gid:
            print("fetch 需要 gist id", file=sys.stderr)
            return 1
        g = api("/gists/" + gid, args.token)
        for name, f in g["files"].items():
            print(f"== {name} ({f['size']} bytes, truncated: {f['truncated']}) ==")
            emit(fetch_raw(f["raw_url"]), args.out)
            if args.out:
                return 0
            break  # 多个文件只打第一个

    return 0


if __name__ == "__main__":
    sys.exit(main())

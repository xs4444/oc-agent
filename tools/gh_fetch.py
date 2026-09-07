#!/usr/bin/env python3
"""gh_fetch — 本机抓取 URL，经远控通道推到真机 OC 盘（方案 B：取件柜）。

用法:
  python3 tools/gh_fetch.py <url> [--name NAME] [--dir /home/cache] [--base URL]

抓取顺序（GitHub 系）: 直连 → gh-proxy.com 镜像 → Clash 7897；
非 GitHub: 直接走 Clash。内容 ≤99KB（通道线上限制），UTF-8 文本。
推到 <dir>/<name> 后提示 agent read_file。
"""
import argparse
import hashlib
import re
import subprocess
import sys
import urllib.request

TOK_FILE = ".oc-remote-token"
BASE_DEFAULT = "https://<server-endpoint>"
PROXY = "http://127.0.0.1:7897"
MIRROR = "https://gh-proxy.com/"
MAX = 99000
UA = {"User-Agent": "Mozilla/5.0 (gh_fetch/1.0)"}

GITHUB_SUFFIXES = ("github.com", "githubusercontent.com")


def is_github(url):
    host = url.split("/")[2].lower()
    return any(host == s or host.endswith("." + s) for s in GITHUB_SUFFIXES)


def fetch(url, via_proxy=False):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
        if via_proxy else urllib.request.ProxyHandler({})
    )
    req = urllib.request.Request(url, headers=UA)
    with opener.open(req, timeout=30) as r:
        return r.read()


def push(base, tok, remote, text):
    r = subprocess.run(
        ["python3", "tools/remote_server.py", "client", "--base", base, "--token", tok,
         "--timeout", "60", "--write", remote, text],
        capture_output=True, text=True, timeout=120)
    out = (r.stdout or "").strip()
    if r.returncode != 0 or "Written to" not in out:
        sys.exit("push failed: " + (out + " " + (r.stderr or "")).strip()[-300:])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("url")
    ap.add_argument("--name", help="目标文件名（默认取 URL 末段）")
    ap.add_argument("--dir", default="/home/cache", help="OC 盘目标目录（默认 /home/cache）")
    ap.add_argument("--base", default=BASE_DEFAULT)
    args = ap.parse_args()

    tok = open(TOK_FILE).read().strip()

    data, src = None, ""
    if is_github(args.url):
        try:
            data, src = fetch(args.url), "direct"
        except Exception:
            pass
        if data is None:
            try:
                data, src = fetch(MIRROR + args.url), "mirror gh-proxy.com"
            except Exception:
                pass
        if data is None:
            data, src = fetch(args.url, via_proxy=True), "clash"
    else:
        data, src = fetch(args.url, via_proxy=True), "clash"

    if len(data) > MAX:
        sys.exit("content %d bytes exceeds the %d-byte channel limit — "
                 "split the fetch or use the relay (option C)" % (len(data), MAX))
    text = data.decode("utf-8", "replace")

    name = args.name
    if not name:
        tail = args.url.rstrip("/").split("/")[-1]
        name = tail if re.match(r"^[\w.\-]{1,64}$", tail) else \
            "f_" + hashlib.sha1(args.url.encode()).hexdigest()[:12]
    remote = args.dir.rstrip("/") + "/" + name

    # 目录不存在时先建（已存在会报错，忽略）
    subprocess.run(
        ["python3", "tools/remote_server.py", "client", "--base", args.base, "--token", tok,
         "--timeout", "30", "--exec", "mkdir " + args.dir],
        capture_output=True, timeout=90)

    push(args.base, tok, remote, text)
    print("OK (%s) %d bytes -> %s" % (src, len(data), remote))
    print("agent: read_file " + remote)


if __name__ == "__main__":
    main()

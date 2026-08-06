#!/usr/bin/env python3
"""watch_release.py — 发版后监控 jsDelivr 索引状态

用法:
    python scripts/watch_release.py --tag v0.3.3
    python scripts/watch_release.py --tag v0.3.3 --interval 30 --timeout 3600

行为:
    1. 轮询 data.jsdelivr.com 直到新 tag 被索引（update.lua 依赖它发现新版本）
    2. 索引后验证 @tag CDN 内容（files.json 版本/文件数）
    3. 提示服务器执行 lua update.lua

注意: data API 索引滞后于 tag 推送（几分钟~几十分钟），这是唯一不可加速的环节。
"""
import argparse
import json
import sys
import time
import urllib.request

DATA_API = "https://data.jsdelivr.com/v1/packages/gh/xs4444/oc-agent"
CDN = "https://cdn.jsdelivr.net/gh/xs4444/oc-agent@"


def indexed(tag):
    d = json.load(urllib.request.urlopen(DATA_API, timeout=20))
    return any(v["version"] == tag for v in d.get("versions", []))


def main():
    ap = argparse.ArgumentParser(description="监控 jsDelivr 索引状态")
    ap.add_argument("--tag", required=True, help="要监控的 tag，如 v0.3.3")
    ap.add_argument("--interval", type=int, default=60, help="轮询间隔秒数")
    ap.add_argument("--timeout", type=int, default=7200, help="总超时秒数")
    args = ap.parse_args()

    t0 = time.time()
    while time.time() - t0 < args.timeout:
        try:
            if indexed(args.tag):
                print(f"\nINDEXED: {args.tag} — update.lua 现在可以嗅探到")
                body = urllib.request.urlopen(CDN + args.tag + "/files.json", timeout=30).read()
                m = json.loads(body)
                print(f"  @{args.tag}/files.json: version={m['version']}, files={len(m['files'])}")
                print("服务器执行: lua update.lua")
                return 0
        except Exception as e:
            print(f"  查询失败(重试): {e}")
        remain = int(args.timeout - (time.time() - t0))
        print(f"{time.strftime('%H:%M:%S')} 未索引，{remain}s 剩余...", flush=True)
        time.sleep(args.interval)

    print(f"TIMEOUT: {args.tag} 在 {args.timeout}s 内未被索引，稍后重试", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
make_docs_pack.py — 生成离线文档包（纯文本 markdown 全量）。

- 输入: wiki/markdown/**/*.md（排除 media/ 图片，LLM 读不了 PNG）
- 处理: CRLF → LF 归一化（与 files.json 一致，避免 OpenOS 行尾问题）
- tar 内路径: 去掉 markdown/ 前缀（api/robot.md、gtnh/... 等），
  解压后 /doc/api/robot.md 即为文档根
- 输出: docs_pack/oc-docs.tar（ustar 格式，OpenOS 自带 tar 可解压）
        docs_pack/docs.json（{"version","tar","size"}，docs.lua 版本对比用）

用法: python scripts/make_docs_pack.py
"""
import glob
import io
import json
import os
import tarfile
from datetime import datetime

ROOT = os.path.dirname(os.path.abspath(__file__)) + "/.."
SRC = os.path.join(ROOT, "wiki", "markdown")
OUT_DIR = os.path.join(ROOT, "docs_pack")
TAR_NAME = "oc-docs.tar"

os.makedirs(OUT_DIR, exist_ok=True)

files = sorted(
    p
    for p in glob.glob(os.path.join(SRC, "**", "*.md"), recursive=True)
    if "/media/" not in p.replace("\\", "/")
)
print(f"打包 {len(files)} 个 markdown 文件（已排除 media/ 图片）")

tar_path = os.path.join(OUT_DIR, TAR_NAME)
with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
    for p in files:
        rel = os.path.relpath(p, SRC).replace("\\", "/")
        with open(p, "rb") as f:
            data = f.read()
        if b"\r\n" in data:
            data = data.replace(b"\r\n", b"\n")
        info = tarfile.TarInfo(rel)
        info.size = len(data)
        info.mtime = int(datetime.now().timestamp())
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(data))

size = os.path.getsize(tar_path)
version = datetime.now().strftime("%Y-%m-%dT%H%M")
manifest = {"version": version, "tar": TAR_NAME, "size": size}
with open(os.path.join(OUT_DIR, "docs.json"), "w") as f:
    json.dump(manifest, f)

print(f"oc-docs.tar: {size} bytes ({size / 1024:.1f} KB)")
print(f"docs.json:   {json.dumps(manifest)}")

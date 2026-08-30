#!/usr/bin/env python3
"""
make_docs_pack.py — 生成离线文档包（纯文本 markdown 全量）。

- 输入: wiki/markdown/**/*.md（排除 media/ 图片，LLM 读不了 PNG）
- 处理: 图片链接剥离——![alt](url) → alt 文本；alt 为空或纯尺寸串
  （GTNH wiki 惯例如 "520x520px"）→ 整段删除。正文死链会诱使真机
  模型反复 read_file 不存在的图片路径（2026-08 gist 实证），wiki 源
  文件不动，仅打包时剥离；
  CRLF → LF 归一化（与 files.json 一致，避免 OpenOS 行尾问题）
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
import re
import tarfile
from datetime import datetime

ROOT = os.path.dirname(os.path.abspath(__file__)) + "/.."
SRC = os.path.join(ROOT, "wiki", "markdown")
OUT_DIR = os.path.join(ROOT, "docs_pack")
TAR_NAME = "oc-docs.tar"

# 字节级正则保持 UTF-8 透明：多字节序列不含 ASCII 括号/中括号，安全。
IMG_RE = re.compile(rb"!\[([^\]]*)\]\([^)]*\)")
DIM_ALT_RE = re.compile(rb"^\d+x\d+px$")


def strip_images(data):
    """剥离图片链接，返回 (新内容, 剥离数量)。alt 非空且有信息则保留
    alt 文本；alt 为空或纯尺寸串（如 "520x520px"，无语义）整段删除。"""
    count = 0

    def repl(m):
        nonlocal count
        count += 1
        alt = m.group(1)
        if alt and not DIM_ALT_RE.match(alt):
            return alt
        return b""

    return IMG_RE.sub(repl, data), count

os.makedirs(OUT_DIR, exist_ok=True)

files = sorted(
    p
    for p in glob.glob(os.path.join(SRC, "**", "*.md"), recursive=True)
    if "/media/" not in p.replace("\\", "/")
)
print(f"打包 {len(files)} 个 markdown 文件（已排除 media/ 图片）")

tar_path = os.path.join(OUT_DIR, TAR_NAME)
total_imgs = 0
with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
    for p in files:
        rel = os.path.relpath(p, SRC).replace("\\", "/")
        with open(p, "rb") as f:
            data = f.read()
        if b"\r\n" in data:
            data = data.replace(b"\r\n", b"\n")
        data, n_img = strip_images(data)
        total_imgs += n_img
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

print(f"剥离图片链接 {total_imgs} 个（有信息 alt 保留，空/尺寸 alt 删除）")
print(f"oc-docs.tar: {size} bytes ({size / 1024:.1f} KB)")
print(f"docs.json:   {json.dumps(manifest)}")

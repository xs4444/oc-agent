#!/usr/bin/env python3
"""oc_deploy.py — 真机文件安全部署（分块上传 → 校验 → 原子替换）

为什么需要它（oc-remote 技能「真机部署/恢复配方」的手工流程缺口）:
  · **勿用 write op** —— 运行中 agent 内存里的 json 可能是 %c bug 旧版，
    含 0xB1 字节的长串会被静默损坏。
  · **必须用 lua op 长字符串直写**，定界符 ≥ `[==[`（level-0 `--[[`
    实测会多出 1 个 `[`）。
  · **Lua 长串会剥掉紧跟定界符的第一个换行** → 分块时若某块以 `\\n` 开头，
    该字节静默丢失（481218B 文件少 1B、sum 差恰=10 才定位到）→ 本脚本
    把前导 `\\n` 并入上一块。
  · **>100KB 命令线上 JSON 被 413 拒收** → 按 **UTF-8 字节**（非字符）切块，
    且不用 hex 中转（多字节字符使字符数 < 字节数）。
  · **半截上传 = 砖机**：真机 `/init.lua` 自启动直接 dofile 目标文件，写坏
    则 agent 起不来 → 守护随进程消失 → 远控通道也断（唯一通道没了）。
    故本脚本写 `<target>.new` → 读回校验（字节和 size）→ 才 rename 覆盖，
    并先把原文件备份为 `<target>.<suffix>.bak`。

用法:
  python3 tools/oc_deploy.py <本地文件> <远端路径> [--base URL --token TOK]
                             [--chunk-bytes 45000] [--no-backup] [--dry-run]
示例:
  python3 tools/oc_deploy.py agent.lua /mnt/bb7/agent/agent.lua
  python3 tools/oc_deploy.py src/agent/tui.lua /mnt/bb7/agent/tui.lua

校验: 本地与远端各算 size + sum(bytes) mod 1000003（技能约定的弱校验，
足以抓住丢字节/截断/编码膨胀），不一致则**不替换**并退出码 2。
"""
import argparse
import os
import subprocess
import sys

CLIENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote_server.py")
MOD = 1000003


def checksum(data: bytes) -> int:
    return sum(data) % MOD


def run_lua(code: str, base: str, token: str, timeout: int = 90) -> str:
    """跑一次 lua op，返回结果文本（去掉客户端 '[cmd cNNN] 已入队…' 提示行）。"""
    cmd = [sys.executable, CLIENT, "client", "--base", base, "--token", token,
           "--lua", code]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise RuntimeError("lua op 失败 (%d): %s" % (r.returncode, r.stderr.strip()))
    out = r.stdout.rstrip("\n")
    lines = [ln for ln in out.split("\n") if not ln.startswith("[cmd ")]
    return "\n".join(lines).strip()


def lua_str(chunk: str) -> str:
    """按内容选择长串定界符（内容含 ]==] 就升级等级）。"""
    level = 2
    while ("]" + "=" * level + "]") in chunk:
        level += 1
    eq = "=" * level
    return "[" + eq + "[" + chunk + "]" + eq + "]"


def split_chunks(text: str, max_bytes: int):
    """按 UTF-8 字节数切块，且**不产生以 \\n 开头的块**（Lua 长串剥首换行）。

    返回 [(chunk_text, start_char_idx)]。
    """
    chunks = []
    cur = []
    cur_bytes = 0
    for ch in text:
        b = len(ch.encode("utf-8"))
        if cur and cur_bytes + b > max_bytes:
            # 本块以换行开头 → 把该换行留在上一块（否则远端丢 1 字节）
            if ch == "\n":
                cur.append(ch)
                cur_bytes += b
                ch = None  # 已并入，跳过
                chunks.append("".join(cur))
                cur, cur_bytes = [], 0
                continue
            chunks.append("".join(cur))
            cur, cur_bytes = [], 0
        if ch is not None:
            cur.append(ch)
            cur_bytes += b
    if cur:
        chunks.append("".join(cur))
    return chunks


def write_chunk(remote: str, chunk: str, mode: str) -> str:
    code = (
        "local c = " + lua_str(chunk) + "\n"
        "local f = io.open(" + repr(remote).replace("'", '"') + ", \"" + mode + "\")\n"
        "if not f then return \"ERR: open failed\" end\n"
        "f:write(c)\n"
        "f:close()\n"
        "return #c\n"
    )
    return run_lua(code, BASE, TOKEN)


def remote_stat(path: str) -> tuple:
    """远端 size + 字节和（mod MOD）。"""
    p = repr(path).replace("'", '"')
    code = (
        "local f = io.open(" + p + ", \"r\")\n"
        "if not f then return \"MISSING\" end\n"
        "local c = f:read(\"a\")\n"
        "f:close()\n"
        "local sum = 0\n"
        "for i = 1, #c do sum = (sum + c:byte(i)) % " + str(MOD) + " end\n"
        "return #c .. \":\" .. sum\n"
    )
    out = run_lua(code, BASE, TOKEN)
    if out == "MISSING" or ":" not in out:
        return None, None
    n, s = out.split(":", 1)
    return int(n), int(s)


def main():
    global BASE, TOKEN
    ap = argparse.ArgumentParser()
    ap.add_argument("local")
    ap.add_argument("remote")
    ap.add_argument("--base", default=os.environ.get("OC_REMOTE_BASE", ""))
    ap.add_argument("--token", default=os.environ.get("OC_REMOTE_TOKEN", ""))
    ap.add_argument("--chunk-bytes", type=int, default=45000)
    ap.add_argument("--suffix", default="v0327", help="备份后缀: <remote>.<suffix>.bak")
    ap.add_argument("--no-backup", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    BASE, TOKEN = args.base, args.token
    if not BASE or not TOKEN:
        print("error: 需 --base/--token（或 env OC_REMOTE_BASE/OC_REMOTE_TOKEN）",
              file=sys.stderr)
        return 1

    data = open(args.local, "rb").read()
    text = data.decode("utf-8")
    want_n, want_sum = len(data), checksum(data)
    print("本地 %s: %d bytes, sum=%d" % (args.local, want_n, want_sum))

    chunks = split_chunks(text, args.chunk_bytes)
    print("分块: %d 块（≤%d UTF-8 字节/块，无块以换行开头）"
          % (len(chunks), args.chunk_bytes))
    if args.dry_run:
        return 0

    tmp = args.remote + ".new"
    bak = args.remote + "." + args.suffix + ".bak"

    if not args.no_backup:
        cur = remote_stat(args.remote)
        if cur[0] is not None:
            code = (
                "local src = io.open(" + repr(args.remote).replace("'", '"') + ", \"r\")\n"
                "if not src then return \"ERR: no src\" end\n"
                "local c = src:read(\"a\")\n"
                "src:close()\n"
                "local dst = io.open(" + repr(bak).replace("'", '"') + ", \"w\")\n"
                "if not dst then return \"ERR: no dst\" end\n"
                "dst:write(c)\n"
                "dst:close()\n"
                "return #c\n"
            )
            print("备份 %s <- %s ..." % (bak, args.remote), run_lua(code, BASE, TOKEN))

    total = 0
    for i, ch in enumerate(chunks, 1):
        mode = "w" if i == 1 else "a"
        got = write_chunk(tmp, ch, mode)
        # Lua 的 #c 是**字节**数；Python 的 len(ch) 是**字符**数——必须比字节
        # （中文注释使两者差异巨大，曾是本工具首跑 5 连 FAIL 的原因）
        exp = len(ch.encode("utf-8"))
        if got.strip() != str(exp):
            print("FAIL 块 %d/%d: 远端返回 %r，期望 %d 字节 —— 中止（未替换）"
                  % (i, len(chunks), got, exp), file=sys.stderr)
            return 2
        total += exp
        print("  块 %d/%d ok (%d 字节, 累计 %d)" % (i, len(chunks), exp, total))

    got_n, got_sum = remote_stat(tmp)
    print("远端 %s: %s bytes, sum=%s" % (tmp, got_n, got_sum))
    if got_n != want_n or got_sum != want_sum:
        print("FAIL 校验不一致（size %s/%d, sum %s/%d）—— 中止，未替换；"
              "远端临时文件 %s 保留待查" % (got_n, want_n, got_sum, want_sum, tmp),
              file=sys.stderr)
        return 2
    print("PASS 校验一致（size + 字节和）")

    # 原子替换: 优先 os.rename（同目录），失败回退复制
    p_remote = repr(args.remote).replace("'", '"')
    p_tmp = repr(tmp).replace("'", '"')
    code = (
        "local ok, err = pcall(os.rename, " + p_tmp + ", " + p_remote + ")\n"
        "if ok then return \"renamed\" end\n"
        "local src = io.open(" + p_tmp + ", \"r\")\n"
        "if not src then return \"ERR: no tmp\" end\n"
        "local c = src:read(\"a\")\n"
        "src:close()\n"
        "local dst = io.open(" + p_remote + ", \"w\")\n"
        "if not dst then return \"ERR: no dst\" end\n"
        "dst:write(c)\n"
        "dst:close()\n"
        "return \"copied (rename failed: \" .. tostring(err) .. \")\"\n"
    )
    print("替换:", run_lua(code, BASE, TOKEN))

    fin_n, fin_sum = remote_stat(args.remote)
    if fin_n != want_n or fin_sum != want_sum:
        print("FAIL 替换后校验不一致（size %s/%d）—— 用 %s 回滚" % (fin_n, want_n, bak),
              file=sys.stderr)
        return 2
    print("PASS 部署完成并校验通过: %s (%d bytes)" % (args.remote, want_n))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Download all local DokuWiki media referenced by the wiki export."""
import os
import re
import glob
import urllib.request

BASE = 'https://ocdoc.cil.li/_media/'
WIKI_DIR = r'F:\mie agent\ocdoc_wiki'
OUT_DIR = r'F:\mie agent\ocdoc_md\media'

paths = set()
for f in glob.glob(os.path.join(WIKI_DIR, '*.txt')):
    with open(f, encoding='utf-8', errors='replace') as fh:
        txt = fh.read()
    for m in re.finditer(r'\{\{:([^}]+)\}\}', txt):
        inner = m.group(1)
        path = inner.split('?')[0]
        paths.add(path)

print(f'{len(paths)} unique images to fetch')
ok, fail = 0, []
for p in sorted(paths):
    dest = os.path.join(OUT_DIR, p.replace(':', os.sep))
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        ok += 1
        continue
    url = BASE + p
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = resp.read()
        if resp.status == 200 and data:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'wb') as fh:
                fh.write(data)
            ok += 1
        else:
            fail.append((p, f'HTTP {resp.status}'))
    except Exception as e:
        fail.append((p, str(e)[:80]))

print(f'downloaded/ok: {ok}')
if fail:
    print(f'FAILED ({len(fail)}):')
    for p, e in fail:
        print(f'  {p} -> {e}')

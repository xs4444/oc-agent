#!/usr/bin/env python3
"""Convert DokuWiki text exports to Markdown for agent-friendly reading."""

import os
import re
import sys
from pathlib import Path


def normalize_page_name(name: str) -> str:
    """Normalize a DokuWiki page name: replace spaces and + with underscores, lowercase."""
    return name.replace(' ', '_').replace('+', '_').lower()


def kebab_anchor(text: str) -> str:
    """Convert text to a Markdown-style kebab anchor: lowercase, spaces→hyphens,
    underscores→hyphens, and remove chars GFM slugger strips (slashes, backslashes,
    parens). GFM: 'a/b' → 'ab' (slash removed without a hyphen)."""
    return text.lower().replace(' ', '-').replace('_', '-') \
        .replace('/', '').replace('\\', '').replace('(', '').replace(')', '')


def resolve_internal_link(target: str, label: str, current_ns: str = '') -> str:
    """Resolve a DokuWiki internal link [[target|label]] to Markdown [label](path).
    current_ns: the namespace of the current file (e.g. 'api', 'component', 'tutorial')
    """
    target = target.strip()
    if not label or not label.strip():
        label = target.split(':')[-1].split('#')[0].replace('_', ' ')
    else:
        label = label.strip()

    # Handle pure anchor links [[#anchor|text]] or [[#anchor]]
    if target.startswith('#'):
        anchor = kebab_anchor(target[1:])
        if not label or label == target:
            label = target[1:]  # use anchor text as label
        return f'[{label}](#{anchor})'

    # Split off anchor if present: namespace:page#section
    anchor = ''
    if '#' in target:
        target, anchor = target.split('#', 1)
        anchor = kebab_anchor(anchor)

    # Handle leading colon (root namespace) [[:ns:page]]
    is_absolute = target.startswith(':')
    if is_absolute:
        target = target[1:]

    # Check if target had a namespace prefix (colon)
    has_namespace = ':' in target

    parts = [normalize_page_name(p) for p in target.split(':') if p]

    if not parts:
        if anchor:
            return f'[{label}](#{anchor})'
        return f'[{label}]()'

    ns_map = {
        'block': 'block',
        'item': 'item',
        'api': 'api',
        'component': 'component',
        'addon': 'addon',
        'tutorial': 'tutorial',
    }

    known_root_pages = {
        'openos', 'contents', 'apis', 'api', 'components', 'component',
        'addons', 'addon', 'tutorials', 'tutorial', 'blocks', 'items',
        'basic_commands', 'chinese_page', 'onethree', 'imc',
        'lua_conventions', 'computer_users', 'crossmod_interoperation',
        'start', 'test_event.listen',
    }

    if parts[0] in ns_map:
        subdir = ns_map[parts[0]]
        if len(parts) == 1:
            # [[api]] or [[:api]] → root page api.md
            md_path = f'{subdir}.md'
            if current_ns:
                md_path = '../' + md_path
        else:
            # Multi-level namespace (e.g. tutorial:program:oppm) flattens
            # to tutorial/program_oppm.md in the export. Join sub-parts with '_'.
            page_path = '_'.join(parts[1:]) + '.md'
            if current_ns == subdir:
                # Same-namespace: relative link in same directory
                md_path = page_path
            else:
                md_path = f'{subdir}/{page_path}'
                if current_ns:
                    md_path = '../' + md_path
    elif parts[0] == 'start':
        if len(parts) == 1:
            md_path = 'start.md'
        elif parts[1] == 'zh':
            md_path = 'start_zh.md'
        else:
            md_path = '_'.join(parts) + '.md'
        if current_ns and not md_path.startswith('../'):
            md_path = '../' + md_path
    elif parts[0] in known_root_pages:
        if len(parts) == 1:
            md_path = parts[0] + '.md'
        else:
            if parts[0] in ns_map:
                md_path = ns_map[parts[0]] + '/' + '_'.join(parts[1:]) + '.md'
            else:
                md_path = '_'.join(parts) + '.md'
        # Absolute or namespaced reference to a root page from a subdir needs ../
        if current_ns and (is_absolute or has_namespace) and not md_path.startswith('../'):
            md_path = '../' + md_path
    else:
        # Unknown page: relative link within current namespace
        md_path = '_'.join(parts) + '.md'
        # Absolute root reference from a subdirectory needs ../
        if current_ns and is_absolute and not md_path.startswith('../'):
            md_path = '../' + md_path

    if anchor:
        md_path = md_path + '#' + anchor

    return f'[{label}]({md_path})'


def local_image_md(inner: str, current_ns: str) -> str:
    """Convert a DokuWiki local image macro {{:path?params|alt}} (or {{path|alt}})
    to a Markdown image referencing the downloaded media file."""
    inner = inner.strip()
    alt = ''
    if '|' in inner:
        alt = inner.split('|', 1)[1].strip()
        inner = inner.split('|', 1)[0]
    path = inner.split('?')[0].strip()
    if not path:
        return ''
    # media dir is at out root: ../media/... from subdirs, media/... from root
    prefix = '../' if current_ns else ''
    media_path = prefix + 'media/' + path.replace(':', '/')
    return f'![{alt}]({media_path})'


def convert_inline(text: str, current_ns: str = '') -> str:
    """Convert inline DokuWiki markup to Markdown."""
    # Protect inline code spans so markup inside backticks is not mangled
    code_spans = []
    def protect_code(m):
        code_spans.append(m.group(0))
        return f'\x00CODE{len(code_spans)-1}\x00'
    text = re.sub(r'`[^`]*`', protect_code, text)

    # Remove {{page>...}} includes entirely
    text = re.sub(r'\{\{page>[^}]*\}\}', '', text)

    # Convert local image references {{:path?params|alt}} or {{:path?params}}
    def local_img(m):
        return local_image_md(m.group(1), current_ns)
    text = re.sub(r'\{\{:([^}]*)\}\}', local_img, text)

    # Convert other local DokuWiki images {{namespace:image?params|alt}}
    def ns_img(m):
        inner = m.group(1)
        if inner.startswith(('http://', 'https://')):
            return m.group(0)  # external, handled below
        return local_image_md(inner, current_ns)
    text = re.sub(r'\{\{([a-z_][\w.-]*:[^}]*)\}\}', ns_img, text)

    # Convert local images without namespace {{image?params|alt}}
    text = re.sub(r'\{\{([a-z_][\w.-]*\.[a-z]+[^}]*)\}\}', lambda m: local_image_md(m.group(1), current_ns), text)

    # Convert external images {{http://...}} or {{https://...}}
    def img_replace(m):
        url = m.group(1)
        alt = m.group(2) or ''
        return f'![{alt}]({url})'
    text = re.sub(r'\{\{(https?://[^|}?]+)[^}]*\|?([^}]*)\}\}', img_replace, text)

    # Handle ~~REDIRECT>target~~
    def redirect_replace(m):
        target = m.group(1)
        link = resolve_internal_link(target, target.split(':')[-1], current_ns)
        return f'*Redirect to {link}*'
    text = re.sub(r'~~REDIRECT>([^~]+)~~', redirect_replace, text)

    # Convert external links [[http://...|text]] and [[https://...|text]] FIRST
    # Strip trailing whitespace captured before the | separator
    def ext_link(m):
        url = m.group(1).strip()
        label = m.group(2)
        return f'[{label}]({url})'
    text = re.sub(r'\[\[(https?://[^\]|]+)\|([^\]]+)\]\]', ext_link, text)

    def ext_link_simple(m):
        url = m.group(1).strip()
        return f'[{url}]({url})'
    text = re.sub(r'\[\[(https?://[^\]]+)\]\]', ext_link_simple, text)

    # Convert interwiki links [[wp>Page|Text]] and [[doku>Page|Text]]
    text = re.sub(r'\[\[wp>([^|\]]+)\|([^\]]+)\]\]', r'[\2](https://en.wikipedia.org/wiki/\1)', text)
    text = re.sub(r'\[\[wp>([^\]]+)\]\]', r'[\1](https://en.wikipedia.org/wiki/\1)', text)
    text = re.sub(r'\[\[doku>([^|\]]+)\|([^\]]+)\]\]', r'[\2](https://www.dokuwiki.org/\1)', text)
    text = re.sub(r'\[\[doku>([^\]]+)\]\]', r'[\1](https://www.dokuwiki.org/\1)', text)

    # Convert [[namespace:page#anchor|text]] and [[namespace:page|text]] internal links
    def internal_link(m):
        target = m.group(1).strip()
        label = m.group(2).strip()
        return resolve_internal_link(target, label, current_ns)
    text = re.sub(r'\[\[([^|\]]+)\|([^\]]+)\]\]', internal_link, text)

    # Links without label [[page]] or [[page#anchor]]
    def internal_link_simple(m):
        target = m.group(1).strip()
        return resolve_internal_link(target, '', current_ns)
    text = re.sub(r'\[\[([^\]]+)\]\]', internal_link_simple, text)

    # DokuWiki single-bracket anchor refs like [#standard_libraries]
    # (double-bracket [[#...]] already handled above)
    def anchor_ref(m):
        name = m.group(1)
        return f'[{name.replace("_", " ")}](#{kebab_anchor(name)})'
    text = re.sub(r'\[#([^\]]+)\]', anchor_ref, text)

    # Bold: **text** is already Markdown compatible
    # Italic: //text// → *text*
    text = re.sub(r'(?<!:)//([^/\n]+?)//', r'*\1*', text)

    # Underline: __text__ → <u>text</u>
    # But NOT when __ is part of a Lua identifier (preceded by word char or .)
    text = re.sub(r'(?<![\w.])__([^_\n]+?)__(?![\w])', r'<u>\1</u>', text)

    # Monospace: ''text'' → `text`
    text = re.sub(r"''([^']+)''", r'`\1`', text)

    # Strikethrough: <del>text</del> → ~~text~~
    text = re.sub(r'<del>([^<]+)</del>', r'~~\1~~', text)

    # Line break: \\ → two spaces + newline (Markdown line break)
    text = re.sub(r'\\\\\s*', '  \n', text)

    # Restore inline code spans
    text = re.sub(r'\x00CODE(\d+)\x00', lambda m: code_spans[int(m.group(1))], text)

    return text


def convert_table(lines: list[str], start_idx: int, current_ns: str = '') -> tuple[str, int]:
    """Convert DokuWiki table to Markdown table. Returns (converted, next_line_idx)."""
    table_lines = []
    i = start_idx
    while i < len(lines) and (lines[i].startswith('|') or lines[i].startswith('^')):
        table_lines.append(lines[i])
        i += 1

    if not table_lines:
        return '', start_idx

    rows = []
    for tl in table_lines:
        tl = tl.strip()
        if tl.startswith('|') or tl.startswith('^'):
            tl = re.sub(r':::', '', tl)
            # Protect pipes inside [[...|...]] links before splitting
            placeholders = []
            def protect_link(m):
                placeholders.append(m.group(0))
                return f'\x00LINK{len(placeholders)-1}\x00'
            tl = re.sub(r'\[\[[^\]]*\]\]', protect_link, tl)
            cells = re.split(r'[\|\^]', tl)
            # Restore links in cells
            cells = [re.sub(r'\x00LINK(\d+)\x00', lambda m: placeholders[int(m.group(1))], c).strip() for c in cells[1:-1]]
            rows.append(cells)

    if not rows:
        return '', i

    max_cols = max(len(r) for r in rows) if rows else 0
    if max_cols == 0:
        return '', i
    for r in rows:
        while len(r) < max_cols:
            r.append('')

    md_rows = []
    for r in rows:
        md_cells = [convert_inline(c, current_ns) for c in r]
        md_rows.append('| ' + ' | '.join(md_cells) + ' |')

    if len(md_rows) >= 1:
        sep = '| ' + ' | '.join(['---'] * max_cols) + ' |'
        md_rows.insert(1, sep)

    return '\n'.join(md_rows), i


def detect_namespace(filename: str) -> str:
    """Detect the namespace from the source filename prefix."""
    prefix_map = {
        'block_': 'block',
        'item_': 'item',
        'api_': 'api',
        'component_': 'component',
        'addon_': 'addon',
        'tutorial_': 'tutorial',
    }
    for prefix, ns in prefix_map.items():
        if filename.startswith(prefix):
            return ns
    return ''


def convert_file(content: str, filename: str) -> str:
    """Convert a single DokuWiki text file to Markdown."""
    current_ns = detect_namespace(filename)

    # Pre-process: join lines that are split inside [[...]] links
    # BUT: don't match Lua comments --[[ ... ]]
    # Only match [[ that is NOT preceded by --
    def join_split_link(m):
        inner = m.group(1).replace('\n', ' ')
        return '[[' + inner + ']]'
    content = re.sub(r'(?<!-)\[\[([^\]]*?)\n\s*\]\]', join_split_link, content)

    lines = content.split('\n')
    result = []
    i = 0
    in_code_block = False

    while i < len(lines):
        line = lines[i]

        # Handle <code> / <file> blocks AND Markdown ``` fenced blocks
        code_start = re.match(r'^\s*<(code|file)(\s+\w*)?>\s*$', line)
        md_fence = re.match(r'^\s*```\s*(\w*)\s*$', line)
        if code_start and not in_code_block:
            in_code_block = True
            lang = code_start.group(2).strip() if code_start.group(2) else ''
            result.append(f'```{lang}')
            i += 1
            continue
        if md_fence and not in_code_block:
            in_code_block = True
            lang = md_fence.group(1).strip()
            result.append(f'```{lang}')
            i += 1
            continue
        if in_code_block and (re.match(r'^\s*</(code|file)>\s*$', line) or re.match(r'^\s*```\s*$', line)):
            in_code_block = False
            result.append('```')
            i += 1
            continue
        if in_code_block:
            result.append(line)
            i += 1
            continue

        # Skip DokuWiki table layout lines like |< 100% 15% 15% >|
        if re.match(r'^\|<[^>]+>\|?\s*$', line):
            i += 1
            continue

        # Handle tables
        if line.startswith('|') or line.startswith('^'):
            table_md, next_i = convert_table(lines, i, current_ns)
            if table_md:
                result.append(table_md)
                i = next_i
                continue

        # Handle DokuWiki two-line headings: Title\n====== or Title\n----
        if i + 1 < len(lines):
            next_line = lines[i + 1].strip()
            # = underline headings
            m = re.match(r'^(={2,})$', next_line)
            if m and line.strip() and not re.match(r'^\s{2,}\S', line):
                level = len(m.group(1))
                md_level = 7 - level
                md_level = max(1, min(6, md_level))
                title = line.strip()
                result.append(f"{'#' * md_level} {title}")
                i += 2
                continue
            # - underline headings (setext H2)
            # Only match if title line is NOT indented (indented = list continuation, not heading)
            m = re.match(r'^(-{4,})$', next_line)
            if m and line.strip() and not re.match(r'^\s{2,}\S', line):
                title = line.strip()
                result.append(f"## {title}")
                i += 2
                continue

        # Handle DokuWiki single-line headings: ====== Title ======
        # Allow asymmetric: === Title == (use left side for level)
        # Also handle no-space: ====Title==== or ===Title===
        m = re.match(r'^(\s*)(={1,6})\s*(.+?)\s*=*\s*$', line)
        if m and m.group(3).strip():
            title_text = m.group(3).strip()
            level = len(m.group(2))
            md_level = 7 - level
            md_level = max(1, min(6, md_level))
            result.append(f"{'#' * md_level} {title_text}")
            i += 1
            continue

        # Skip standalone === lines that weren't caught as heading underlines
        if re.match(r'^={2,}\s*$', line):
            i += 1
            continue

        # Handle ---- horizontal rules (standalone, NOT preceded by a title line)
        if re.match(r'^-{4,}\s*$', line):
            # Ensure blank line before --- so it doesn't become a setext heading
            if result and result[-1].strip():
                result.append('')  # add blank line
            result.append('---')
            i += 1
            continue

        # Convert inline markup
        line = convert_inline(line, current_ns)

        # Escape literal '#' at line start that would render as a heading.
        # Only escape INDENTED '#' lines (DokuWiki text examples like shell.md).
        # Top-level '# Title' lines in source are author-written Markdown
        # headings (translate_rule.md, modding_onefour.md) and must be kept.
        if re.match(r'^\s{1,3}#{1,6}(?=\s)', line):
            line = re.sub(r'^(\s{1,3})#{1,6}(?=\s)', r'\1\\#', line, count=1)

        # Clean up multiple blank lines
        if line.strip() == '' and result and result[-1].strip() == '':
            i += 1
            continue

        result.append(line)
        i += 1

    # Post-processing: clean up
    md = '\n'.join(result)

    # Remove empty headings like "## "
    md = re.sub(r'^#{1,6}\s*$', '', md, flags=re.MULTILINE)

    # Remove trailing whitespace on lines
    md = re.sub(r'[ \t]+\n', '\n', md)

    # Collapse 3+ blank lines to 2
    md = re.sub(r'\n{3,}', '\n\n', md)

    # Strip leading/trailing whitespace
    md = md.strip() + '\n'

    return md


def determine_md_path(txt_path: Path, src_dir: Path, out_dir: Path) -> Path:
    """Determine the output markdown path based on filename conventions."""
    name = txt_path.stem

    prefix_map = {
        'block_': 'block',
        'item_': 'item',
        'api_': 'api',
        'component_': 'component',
        'addon_': 'addon',
        'tutorial_': 'tutorial',
    }

    for prefix, subdir in prefix_map.items():
        if name.startswith(prefix):
            page_name = name[len(prefix):]
            return out_dir / subdir / f'{page_name}.md'

    if name in ('start', 'start_zh', 'contents', 'contents_zh',
                'apis', 'components', 'addons', 'tutorials',
                'basic_commands', 'chinese_page', 'onethree',
                'openos', 'openos_zh', 'imc',
                'lua_conventions', 'lua_conventions_zh',
                'computer_users', 'computer_users_zh',
                'crossmod_interoperation', 'crossmod_interoperation_zh'):
        return out_dir / f'{name}.md'

    if name.startswith('wiki_') or name == 'playground_playground':
        return None

    return out_dir / f'{name}.md'


def downgrade_dead_links(content: str, md_path: Path, out_dir: Path, all_md: set) -> tuple[str, int]:
    """Replace links whose target .md does not exist with plain label text,
    so agents never follow dead links. Only touches relative .md paths.
    Returns (new_content, downgraded_count)."""
    count = 0
    def repl(m):
        nonlocal count
        label = m.group(1)
        target = m.group(2)
        if target.startswith(('http://', 'https://', '#', '/')):
            return m.group(0)
        # strip anchor fragment
        path_part = target.split('#')[0].strip()
        if not path_part or not path_part.endswith('.md'):
            return m.group(0)
        cand = (md_path.parent / path_part).resolve()
        if str(cand).lower() in all_md:
            return m.group(0)
        count += 1
        return label  # dead link → plain text
    new = re.sub(r'\[([^\]]*)\]\(([^)]+)\)', repl, content)
    return new, count


def main():
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} <input_dir> <output_dir>')
        print(f'  Converts DokuWiki .txt exports to Markdown .md files')
        sys.exit(1)

    src_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])

    if not src_dir.is_dir():
        print(f'Error: {src_dir} is not a directory')
        sys.exit(1)

    for subdir in ('block', 'item', 'api', 'component', 'addon', 'tutorial'):
        (out_dir / subdir).mkdir(parents=True, exist_ok=True)

    txt_files = sorted(src_dir.glob('*.txt'))
    if not txt_files:
        print(f'No .txt files found in {src_dir}')
        sys.exit(1)

    converted = 0
    skipped = 0
    md_paths = []
    total_links = 0
    total_ext_links = 0
    total_images = 0

    for txt_path in txt_files:
        md_path = determine_md_path(txt_path, src_dir, out_dir)
        if md_path is None:
            skipped += 1
            continue

        content = txt_path.read_text(encoding='utf-8', errors='replace')
        md_content = convert_file(content, txt_path.name)

        stripped = md_content.strip()
        if not stripped or len(stripped) < 10:
            skipped += 1
            continue

        md_path.parent.mkdir(parents=True, exist_ok=True)
        md_path.write_text(md_content, encoding='utf-8')
        md_paths.append(md_path)
        converted += 1
        total_links += len(re.findall(r'\[[^\]]+\]\([^)]+\)', md_content))
        total_ext_links += len(re.findall(r'\[[^\]]+\]\((?:https?://|www\.)[^)]+\)', md_content))
        total_images += len(re.findall(r'!\[[^\]]*\]\([^)]+\)', md_content))
        rel = md_path.relative_to(out_dir)
        print(f'  {txt_path.name} -> {rel}')

    # Second pass: downgrade links to non-existent target files into plain text
    all_md = {str(p.resolve()).lower() for p in md_paths}
    dead_total = 0
    for md_path in md_paths:
        content = md_path.read_text(encoding='utf-8')
        new_content, dead_count = downgrade_dead_links(content, md_path, out_dir, all_md)
        dead_total += dead_count
        if new_content != content:
            md_path.write_text(new_content, encoding='utf-8')

    print(f'\nDone: {converted} converted, {skipped} skipped, {len(txt_files)} total')
    print(f'Stats: internal_links={total_links - total_ext_links}, '
          f'external_links={total_ext_links}, images={total_images}, '
          f'dead_links_downgraded={dead_total}')


if __name__ == '__main__':
    main()

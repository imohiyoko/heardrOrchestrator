"""最小限の Markdown → HTML。外部由来の本文なので、必ず先に e() でエスケープしてから記法を当てる。

対応: 見出し・段落・箇条書き(番号つき含む)・引用・コードブロック(```)・水平線・表(| 区切り)・
インライン(`code`・**太字**・*斜体*・~~取り消し~~・[文字](http(s)://...))。
生の HTML は書かれていても文字として出す。リンクは http(s) だけを外部リンクにし、それ以外は文字のまま。
"""

import re

from .sanitize import e

_CODE_RE = re.compile(r"`([^`\n]+)`")
_LINK_RE = re.compile(r"!?\[([^\]\n]*)\]\(([^)\s]+)(?:\s+&quot;[^\n]*?&quot;)?\)")
_BOLD_RE = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__")
_ITAL_RE = re.compile(r"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])")
_STRIKE_RE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")
_AUTO_RE = re.compile(r"(?<![\"'=/\w])(https?://[^\s<>&\"']+)")
_SAFE_URL = re.compile(r"https?://[^\s<>\"'`]+", re.I)


def inline(raw):
    """1 行(または段落)分。返り値は HTML。"""
    s = e(raw)
    codes = []

    def keep(html):
        codes.append(html)
        return f"\x00{len(codes) - 1}\x00"

    s = _CODE_RE.sub(lambda m: keep(f"<code>{m.group(1)}</code>"), s)

    def link(m):
        text, url = m.group(1), m.group(2).replace("&amp;", "&")
        if m.group(0).startswith("!"):
            return keep(f"[画像: {text or '無題'}]")
        if _SAFE_URL.fullmatch(url):
            return keep(f'<a href="{e(url)}" rel="noopener noreferrer" target=_blank>{text or e(url)}</a>')
        return keep(f"{text} <span class=note>({e(url)})</span>")

    s = _LINK_RE.sub(link, s)
    s = _AUTO_RE.sub(lambda m: keep(f'<a href="{m.group(1)}" rel="noopener noreferrer" target=_blank>{m.group(1)}</a>'), s)
    s = _BOLD_RE.sub(lambda m: f"<strong>{m.group(1) or m.group(2)}</strong>", s)
    s = _ITAL_RE.sub(lambda m: f"<em>{m.group(1)}</em>", s)
    s = _STRIKE_RE.sub(lambda m: f"<del>{m.group(1)}</del>", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], s)


_HR_RE = re.compile(r" {0,3}([-*_])(\s*\1){2,}\s*")
_H_RE = re.compile(r" {0,3}(#{1,6})\s+(.*?)\s*#*\s*")
_UL_RE = re.compile(r"(\s*)[-*+]\s+(.*)")
_OL_RE = re.compile(r"(\s*)\d{1,9}[.)]\s+(.*)")
_TASK_RE = re.compile(r"\[([ xX])\]\s+(.*)")
_FENCE_RE = re.compile(r" {0,3}(```+|~~~+)\s*([\w+-]*)")
_TSEP_RE = re.compile(r"\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*")


def _cells(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def render(text):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out, para, i, n = [], [], 0, len(lines)

    def flush():
        if para:
            out.append("<p>" + "<br>".join(inline(x) for x in para) + "</p>")
            para.clear()

    while i < n:
        line = lines[i]
        m = _FENCE_RE.fullmatch(line)
        if m:
            flush()
            fence, body = m.group(1), []
            i += 1
            while i < n and not lines[i].strip().startswith(fence):
                body.append(lines[i])
                i += 1
            i += 1
            out.append(f"<pre><code>{e(chr(10).join(body))}</code></pre>")
            continue
        if not line.strip():
            flush()
            i += 1
            continue
        if _HR_RE.fullmatch(line):
            flush()
            out.append("<hr>")
            i += 1
            continue
        m = _H_RE.fullmatch(line)
        if m:
            flush()
            lv = len(m.group(1))
            out.append(f"<h{lv + 1 if lv < 6 else 6} class=md>{inline(m.group(2))}</h{lv + 1 if lv < 6 else 6}>")
            i += 1
            continue
        if "|" in line and i + 1 < n and _TSEP_RE.fullmatch(lines[i + 1]) and "-" in lines[i + 1]:
            flush()
            head = _cells(line)
            rows = []
            i += 2
            while i < n and "|" in lines[i] and lines[i].strip():
                rows.append(_cells(lines[i]))
                i += 1
            h = "".join(f"<th>{inline(c)}</th>" for c in head)
            b = "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f"<table><tr>{h}</tr>{b}</table>")
            continue
        if line.lstrip().startswith(">"):
            flush()
            quote = []
            while i < n and lines[i].lstrip().startswith(">"):
                quote.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>{render(chr(10).join(quote))}</blockquote>")
            continue
        if _UL_RE.fullmatch(line) or _OL_RE.fullmatch(line):
            flush()
            ordered = bool(_OL_RE.fullmatch(line)) and not _UL_RE.fullmatch(line)
            items = []
            while i < n:
                mu = _UL_RE.fullmatch(lines[i]) or _OL_RE.fullmatch(lines[i])
                if mu:
                    depth = len(mu.group(1).expandtabs(4)) // 2
                    items.append([depth, mu.group(2)])
                elif lines[i].strip() and items and lines[i][:1] in (" ", "\t"):
                    items[-1][1] += " " + lines[i].strip()  # 続きの行
                else:
                    break
                i += 1
            tag = "ol" if ordered else "ul"
            lis = []
            for depth, body in items:
                mt = _TASK_RE.fullmatch(body)
                content = (("☑ " if mt.group(1) in "xX" else "☐ ") + inline(mt.group(2))) if mt else inline(body)
                lis.append(f'<li style="margin-left:{min(depth, 6) * 1.5}em">{content}</li>')
            out.append(f"<{tag}>{''.join(lis)}</{tag}>")
            continue
        para.append(line.strip())
        i += 1
    flush()
    return "".join(out)

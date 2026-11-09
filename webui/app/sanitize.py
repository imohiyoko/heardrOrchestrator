"""外部由来の文字列の無害化(HTML に出す前に必ず通す)。"""

import html
import re


_ESC_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"            # CSI
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?"  # OSC
    r"|\x1b[P^_X][^\x1b]*(?:\x1b\\)?"      # DCS/PM/APC/SOS
    r"|\x1b[ -/]*[0-~]"                    # その他の ESC 列
)
_CTRL_RE = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f‪-‮⁦-⁩]")


def clean(s):
    """ターミナル制御文字(ANSI など)を除く。改行とタブは残す。"""
    s = _ESC_RE.sub("", str(s)).replace("\r\n", "\n").replace("\r", "\n")
    return _CTRL_RE.sub("", s)


def e(s):
    """外部由来の文字列は必ずこれを通して HTML に出す。"""
    return html.escape(clean("" if s is None else s), quote=True)

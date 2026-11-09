"""Web UI からの書き込み。tasks.db には直接書かず、必ず tb を通す(記録と検査を tb に一本化する)。"""

import os
import subprocess

from .config import HERDR_ROOT, TB_DB

TB = os.path.join(HERDR_ROOT, "taskboard", "bin", "tb")
NOTE_MAX = 200


def _run_tb(args):
    """(終了コード, 出力)。tb が無い・失敗・タイムアウトでも例外にしない。
    HERDR_PANE_ID は外す: Web UI の操作は人の操作として扱う(ログイン済みのブラウザからだけ届く)。"""
    env = {k: v for k, v in os.environ.items() if k != "HERDR_PANE_ID"}
    env["TB_DB"] = TB_DB()
    try:
        p = subprocess.run(["bash", TB, *args], env=env, capture_output=True, text=True, timeout=15,
                           stdin=subprocess.DEVNULL, errors="replace")
    except (OSError, subprocess.SubprocessError):
        return 1, ""
    return p.returncode, (p.stdout + p.stderr).strip()


def resolve_comment(cid, note):
    """question / blocked の報告を対応済みにする。返り値: done | already | error。"""
    note = (note or "").strip()[:NOTE_MAX]
    rc, out = _run_tb(["resolve", f"C-{int(cid)}"] + (["-m", note] if note else []))
    if rc != 0:
        return "error"
    return "already" if "すでに" in out else "done"

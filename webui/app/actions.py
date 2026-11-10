"""Web UI からの書き込み。tasks.db には直接書かず、必ず tb を通す(記録と検査を tb に一本化する)。"""

import os
import re
import subprocess

from .config import HERDR_ROOT, TB_DB

TB = os.path.join(HERDR_ROOT, "taskboard", "bin", "tb")
NOTE_MAX = 200


def _run_tb(args, timeout=15):
    """(終了コード, 出力)。tb が無い・失敗・タイムアウトでも例外にしない。
    HERDR_PANE_ID は外す: Web UI の操作は人の操作として扱う(ログイン済みのブラウザからだけ届く)。"""
    env = {k: v for k, v in os.environ.items() if k != "HERDR_PANE_ID"}
    env["TB_DB"] = TB_DB()
    try:
        p = subprocess.run(["bash", TB, *args], env=env, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, errors="replace")
    except (OSError, subprocess.SubprocessError):
        return -1, ""  # tb の終了コードと重ならない値(タイムアウトを「断った」と見せない)
    return p.returncode, (p.stdout + p.stderr).strip()


def resolve_comment(cid, note):
    """question / blocked の報告を対応済みにする。返り値: done | already | error。"""
    note = (note or "").strip()[:NOTE_MAX]
    rc, out = _run_tb(["resolve", f"C-{int(cid)}"] + (["-m", note] if note else []))
    if rc != 0:
        return "error"
    return "already" if "すでに" in out else "done"


AGENT_NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}")
MODEL_RE = re.compile(r"[A-Za-z0-9._:-]{1,64}")
ROLE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
PROMPT_MAX = 4000
CWD_MAX = 1024
# agent の起動は herdr の待ち(start のやり直し・最初の指示の送信待ち)があるので長めに待つ
SPAWN_TIMEOUT = 90


def _rc_state(rc):
    """tb の終了コード → 画面に出す結果。0 実行済み / 20 人の承認待ち / 1,2 前提違いで断った / それ以外は失敗。"""
    return {0: "done", 20: "pending", 1: "refused", 2: "refused"}.get(rc, "error")


def agent_op(op, name):
    """agent 一覧のボタン。op: stop | force-stop | revive | revive-fresh。返り値: done | refused | error。"""
    if not AGENT_NAME_RE.fullmatch(name or ""):
        return "refused"
    args = {"stop": ["agent-stop", name], "force-stop": ["agent-stop", name, "--force"],
            "revive": ["agent-revive", name], "revive-fresh": ["agent-revive", name, "--fresh"]}.get(op)
    if args is None:
        return "refused"
    rc, _ = _run_tb(args, timeout=SPAWN_TIMEOUT)
    return _rc_state(rc)


def agent_decide(lid, approve):
    """承認待ちの操作(L-<n>)を実行する / 却下する。"""
    rc, _ = _run_tb(["agent-approve" if approve else "agent-reject", f"L-{int(lid)}"], timeout=SPAWN_TIMEOUT)
    return _rc_state(rc)


def agent_new(form):
    """新しい agent を作る。入力の検査はここと tb の両方で行う。返り値: (結果, エラー文)。"""
    name = (form.get("name") or "").strip()
    cwd = (form.get("cwd") or "").strip()
    model = (form.get("model") or "").strip()
    role = (form.get("role") or "").strip()
    prompt = (form.get("prompt") or "").strip()
    killable = (form.get("killable") or "unknown").strip()
    if not AGENT_NAME_RE.fullmatch(name):
        return "refused", "名前は英小文字で始まり、英小文字・数字・_・- の 32 字以内にしてください"
    if cwd and (len(cwd) > CWD_MAX or "\n" in cwd or not cwd.startswith(("/", "~"))):
        return "refused", "作業ディレクトリは絶対パス(/ か ~ で始まる)にしてください"
    if model and not MODEL_RE.fullmatch(model):
        return "refused", "モデル名に使えない文字があります"
    if role and not ROLE_RE.fullmatch(role):
        return "refused", "役割名に使えない文字があります"
    if len(prompt) > PROMPT_MAX:
        return "refused", f"最初の指示は {PROMPT_MAX} 字までです"
    if killable not in ("unknown", "yes", "no"):
        return "refused", "止めてよいかの指定が不正です"
    args = ["agent-new", name]
    for flag, v in (("--cwd", cwd), ("--model", model), ("--role", role), ("--prompt", prompt)):
        if v:
            args += [flag, v]
    if killable != "unknown":
        args += ["--killable", killable]
    rc, out = _run_tb(args, timeout=SPAWN_TIMEOUT)
    st = _rc_state(rc)
    if st == "done":
        return st, ""
    # tb のエラー文(「tb: ...」の 1 行目)をそのまま見せる。値は表示時にエスケープする
    first = next((ln for ln in out.splitlines() if ln.startswith("tb: ")), "")
    return st, (first[4:] if first else "作成できませんでした")[:300]

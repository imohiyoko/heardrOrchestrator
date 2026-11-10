"""agent が報告した成果物(ローカルのファイル)を見つけて、安全に読む。

見せてよいのは tasks.db に登録された成果物だけ(パスを URL で受け取らない)。
- `C-<報告id>/<n>`: comments.deliverables の n 番目
- `task:<タスクid>/<n>`: tasks.deliverables の n 番目
- `A-<アラートid>`: alerts.result_path(解析レポート。ファイルが無くても DB に保存された本文を出す)
相対パスは、報告した agent の作業ディレクトリ(agent_activity.cwd)を基準にする。
ディレクトリが成果物なら、その中のファイルも(外へ出ない範囲で)見られる。
"""

import json
import os
import re
import stat

from .config import RUN_DIR
from .data import q

MAX_BYTES = 1024 * 1024        # これより大きいファイルは先頭だけ出す
MAX_LIST = 500                 # ディレクトリの一覧に出す件数
MD_EXT = (".md", ".markdown", ".mdown", ".mkd")

# 認証情報が置かれがちな場所は、成果物として登録されていても開かない
DENY_DIRS = {".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store", ".config/gcloud", "Keychains"}
DENY_NAME_RE = re.compile(r"(^\.env(\..*)?$|^id_[a-z0-9]+(\.pub)?$|\.(pem|key|p12|pfx|keychain|keychain-db)$|^\.netrc$|^\.pgpass$|^credentials(\.json)?$)", re.I)
URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)
REF_RE = re.compile(r"(C)-([0-9]{1,9})/([0-9]{1,4})|(task):([^/]{1,200})/([0-9]{1,4})|(A)-([0-9]{1,9})")


def _json_list(s):
    try:
        v = json.loads(s or "[]")
        return [str(x) for x in v] if isinstance(v, list) else []
    except ValueError:
        return []


def _cwd_for(session):
    if not session:
        return None
    r = q("SELECT cwd FROM agent_activity WHERE session_id=?", (session,))
    return (r[0].get("cwd") or None) if r else None


def is_url(raw):
    return bool(URL_RE.fullmatch((raw or "").strip()))


def resolve_path(raw, base):
    """登録された文字列 → 絶対パス(実体)。決められないときは None。"""
    s = (raw or "").strip()
    if not s or is_url(s) or "\x00" in s:
        return None
    if s.startswith("file://"):
        s = s[len("file://"):]
    s = os.path.expanduser(s)
    if not os.path.isabs(s):
        if not base or not os.path.isabs(base):
            return None
        s = os.path.join(base, s)
    return os.path.realpath(s)


def denied(path):
    """認証情報らしい場所・Web UI 自身のログイン情報は開かない。理由の文字列か None。"""
    parts = path.split(os.sep)
    joined = "/".join(parts)
    for d in DENY_DIRS:
        if f"/{d}/" in joined + "/":
            return "認証情報が置かれる場所なので開きません"
    if DENY_NAME_RE.search(os.path.basename(path)):
        return "認証情報らしいファイル名なので開きません"
    run = os.path.realpath(RUN_DIR())
    if path == run or path.startswith(run + os.sep):
        return "Web UI のログイン情報なので開きません"
    return None


def lookup(ref):
    """ref → dict(raw, base, path, report, task, from, ts, kind) か None。"""
    m = REF_RE.fullmatch(ref or "")
    if not m:
        return None
    if m.group(1):
        rows = q("SELECT id,task_id,kind,deliverables,from_name,from_session,created_at FROM comments WHERE id=?", (int(m.group(2)),))
        if not rows:
            return None
        c, i = rows[0], int(m.group(3))
        dl = _json_list(c["deliverables"])
        if i >= len(dl):
            return None
        base = _cwd_for(c["from_session"])
        return {"ref": ref, "raw": dl[i], "base": base, "path": resolve_path(dl[i], base), "report": None,
                "task": c["task_id"], "from": c["from_name"], "ts": c["created_at"], "kind": c["kind"]}
    if m.group(4):
        rows = q("SELECT id,owner_agent,session_id,deliverables,updated_at FROM tasks WHERE id=?", (m.group(5),))
        if not rows:
            return None
        t, i = rows[0], int(m.group(6))
        dl = _json_list(t["deliverables"])
        if i >= len(dl):
            return None
        base = _cwd_for(t["session_id"])
        return {"ref": ref, "raw": dl[i], "base": base, "path": resolve_path(dl[i], base), "report": None,
                "task": t["id"], "from": t["owner_agent"], "ts": t["updated_at"], "kind": "task"}
    rows = q("SELECT id,title,result_path,result_report,result_by,analyzed_at FROM alerts WHERE id=?", (int(m.group(8)),))
    if not rows or not (rows[0]["result_path"] or rows[0]["result_report"]):
        return None
    a = rows[0]
    return {"ref": ref, "raw": a["result_path"] or "", "base": None, "path": resolve_path(a["result_path"], None),
            "report": a["result_report"], "task": None, "from": a["result_by"], "ts": a["analyzed_at"],
            "kind": "alert", "title": a["title"]}


def sub_path(root, sub):
    """ディレクトリの成果物の中のファイル。外へ出る指定(.. やリンク)は None。"""
    if not sub:
        return root
    if sub.startswith("/") or "\x00" in sub:
        return None
    p = os.path.realpath(os.path.join(root, sub))
    return p if p.startswith(root + os.sep) else None


def read_text(path):
    """(kind, text, truncated, size)。kind: file / dir / missing / binary / denied / error。"""
    why = denied(path)
    if why:
        return "denied", why, False, 0
    try:
        st = os.stat(path)
    except OSError:
        return "missing", "", False, 0
    if stat.S_ISDIR(st.st_mode):
        return "dir", "", False, 0
    if not stat.S_ISREG(st.st_mode):
        return "error", "通常のファイルではありません", False, 0
    try:
        with open(path, "rb") as f:
            data = f.read(MAX_BYTES + 1)
    except OSError:
        return "error", "読めませんでした(権限など)", False, st.st_size
    if b"\x00" in data[:8192]:
        return "binary", "", False, st.st_size
    trunc = len(data) > MAX_BYTES
    return "file", data[:MAX_BYTES].decode("utf-8", "replace"), trunc, st.st_size


def list_dir(path):
    """[(相対名, is_dir)]。隠しファイルと、外を指すリンクは出さない。"""
    out = []
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in ("node_modules", "__pycache__"))
        for fn in sorted(filenames):
            if fn.startswith("."):
                continue
            full = os.path.join(dirpath, fn)
            if sub_path(path, os.path.relpath(full, path)) is None:
                continue
            out.append(os.path.relpath(full, path))
            if len(out) >= MAX_LIST:
                return out, True
    return out, False


def exists_label(entry):
    if is_url(entry["raw"]):
        return "URL"
    p = entry["path"]
    if p is None:
        return "場所不明" if not (entry.get("report")) else "DB に本文"
    if denied(p):
        return "非表示"
    if os.path.isdir(p):
        return "フォルダ"
    if os.path.isfile(p):
        return "あり"
    return "DB に本文" if entry.get("report") else "なし"


def recent_docs(limit=200):
    """一覧用。新しい順。同じ (タスク, 文字列) は最新の 1 件にまとめる。"""
    items, seen = [], set()
    for c in q("SELECT id,task_id,kind,deliverables,from_name,from_session,created_at FROM comments "
               "WHERE deliverables IS NOT NULL AND deliverables NOT IN ('','[]') ORDER BY id DESC LIMIT 300"):
        base = None
        for i, raw in enumerate(_json_list(c["deliverables"])):
            key = (c["task_id"], raw.strip())
            if key in seen:
                continue
            seen.add(key)
            if base is None:
                base = _cwd_for(c["from_session"]) or ""
            items.append({"ref": f"C-{c['id']}/{i}", "raw": raw, "path": resolve_path(raw, base or None), "report": None,
                          "task": c["task_id"], "from": c["from_name"], "ts": c["created_at"] or "", "kind": c["kind"]})
    for t in q("SELECT id,owner_agent,session_id,deliverables,updated_at FROM tasks "
               "WHERE deliverables IS NOT NULL AND deliverables NOT IN ('','[]') ORDER BY updated_at DESC LIMIT 300"):
        base = None
        for i, raw in enumerate(_json_list(t["deliverables"])):
            key = (t["id"], raw.strip())
            if key in seen:
                continue
            seen.add(key)
            if base is None:
                base = _cwd_for(t["session_id"]) or ""
            items.append({"ref": f"task:{t['id']}/{i}", "raw": raw, "path": resolve_path(raw, base or None), "report": None,
                          "task": t["id"], "from": t["owner_agent"], "ts": t["updated_at"] or "", "kind": "task"})
    for a in q("SELECT id,title,result_path,result_report,result_by,analyzed_at FROM alerts "
               "WHERE result_path IS NOT NULL OR result_report IS NOT NULL ORDER BY id DESC LIMIT 100"):
        items.append({"ref": f"A-{a['id']}", "raw": a["result_path"] or "", "path": resolve_path(a["result_path"], None),
                      "report": a["result_report"], "task": None, "from": a["result_by"], "ts": a["analyzed_at"] or "",
                      "kind": "alert", "title": a["title"]})
    items.sort(key=lambda x: x["ts"], reverse=True)
    return items[:limit]


def comment_refs(cid, deliverables):
    return [(f"C-{cid}/{i}", raw) for i, raw in enumerate(_json_list(deliverables))]


def task_refs(tid, deliverables):
    return [(f"task:{tid}/{i}", raw) for i, raw in enumerate(_json_list(deliverables))]

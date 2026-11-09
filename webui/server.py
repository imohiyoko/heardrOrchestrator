#!/usr/bin/env python3
"""herdr Web UI 第 1 段(読み取り専用)。標準ライブラリだけ。127.0.0.1 限定、トークン必須。

サーバー側で HTML を組み立てる複数ページ構成(SPA ではない)。書き込み系は持たない。
設定は環境変数(README 参照)。
"""
import html
import json
import os
import re
import shlex
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit

import auth

ROOT = os.path.dirname(os.path.abspath(__file__))
HERDR_ROOT = os.path.dirname(ROOT)

HOST = "127.0.0.1"
COOKIE = "herdr_webui_session"
REFRESH_SEC = 8
CACHE_TTL = 3.0
STALL_MIN = 30  # working のまま最終入力から何分超で滞留警告にするか


def cfg(name, default):
    return os.environ.get(name) or default


HERDR_BIN = lambda: cfg("HERDR_BIN", "herdr")  # noqa: E731
TB_DB = lambda: cfg("WEBUI_TB_DB", os.path.join(HERDR_ROOT, "taskboard", "data", "tasks.db"))  # noqa: E731
SCHED_LOGS = lambda: cfg("WEBUI_SCHED_LOGS", os.path.join(HERDR_ROOT, "scheduler", "logs"))  # noqa: E731
DISPATCH = lambda: cfg("WEBUI_DISPATCH", os.path.join(HERDR_ROOT, "conductor", "dispatch.jsonl"))  # noqa: E731
RUN_DIR = lambda: cfg("WEBUI_RUN_DIR", os.path.join(ROOT, "run"))  # noqa: E731
SCHED_ROOT = os.path.join(HERDR_ROOT, "scheduler")
SCHED_JOBS = lambda: cfg("WEBUI_SCHED_JOBS", os.path.join(SCHED_ROOT, "jobs"))  # noqa: E731
SCHED_SETTINGS = lambda: cfg("WEBUI_SCHED_SETTINGS", os.path.join(SCHED_ROOT, "settings"))  # noqa: E731

# ---------------------------------------------------------------- 出力の無害化

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


# ---------------------------------------------------------------- データ源

_cache = {}
_cache_lock = threading.Lock()


def cached(key, fn):
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < CACHE_TTL:
            return hit[1]
    val = fn()
    with _cache_lock:
        _cache[key] = (time.monotonic(), val)
        if len(_cache) > 200:
            for k in sorted(_cache, key=lambda k: _cache[k][0])[:100]:
                _cache.pop(k, None)
    return val


def run_herdr(args):
    """(出力, エラー文)。herdr が無い・失敗・タイムアウトでも例外にしない。"""
    try:
        p = subprocess.run([HERDR_BIN(), *args], capture_output=True, text=True,
                           timeout=5, stdin=subprocess.DEVNULL, errors="replace")
    except (OSError, subprocess.SubprocessError) as ex:
        return None, f"herdr を実行できません: {type(ex).__name__}"
    if p.returncode != 0:
        return None, f"herdr が失敗しました (exit {p.returncode}): {p.stderr.strip()[:200]}"
    return p.stdout, None


def get_agents():
    def load():
        out, err = run_herdr(["agent", "list"])
        if err:
            return [], err
        try:
            d = json.loads(out)
            agents = d["result"]["agents"]
            if not isinstance(agents, list):
                raise ValueError
            return [a for a in agents if isinstance(a, dict)], None
        except (ValueError, KeyError, TypeError):
            return [], "herdr agent list の出力を解釈できません"
    return cached("agents", load)


def agent_key(a):
    return a.get("name") or a.get("pane_id") or ""


def agent_session(a):
    s = a.get("agent_session")
    return s.get("value") if isinstance(s, dict) else None


def read_agent(a, lines=60, source="recent"):
    """agent read の出力(無害化前)。pane_id は herdr が返した値だけを使う。"""
    pane = a.get("pane_id")
    if not pane:
        return None, "pane_id がありません"

    def load():
        out, err = run_herdr(["agent", "read", pane, "--source", source, "--lines", str(lines), "--format", "text"])
        return out, err
    return cached(("read", pane, lines, source), load)


def workspace_label(ws_id):
    """workspace_id -> 表示ラベル。取れなければ None。"""
    def load():
        out, err = run_herdr(["workspace", "list"])
        if err:
            return {}
        try:
            return {w["workspace_id"]: w.get("label") for w in json.loads(out)["result"]["workspaces"]}
        except (ValueError, KeyError, TypeError):
            return {}
    return cached("workspaces", load).get(ws_id)


def db_conn():
    path = TB_DB()
    if not os.path.isfile(path):
        return None
    try:
        c = sqlite3.connect(f"file:{quote(path)}?mode=ro", uri=True, timeout=2)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA query_only=ON")
        return c
    except sqlite3.Error:
        return None


def q(sql, params=()):
    """読み取り専用で実行。DB 不在・テーブル欠落・破損でも空リスト。"""
    c = db_conn()
    if c is None:
        return []
    try:
        return [dict(r) for r in c.execute(sql, params).fetchall()]
    except sqlite3.Error:
        return []
    finally:
        c.close()


def tail_lines(path, n, maxbytes=262144):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - maxbytes))
            data = f.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    if size > maxbytes and lines:
        lines = lines[1:]  # 途中から始まる行は捨てる
    return lines[-n:]


def parse_jsonl(lines):
    out = []
    for ln in lines:
        try:
            d = json.loads(ln)
            if isinstance(d, dict):
                out.append(d)
        except ValueError:
            continue
    return out


def needs_human():
    """承認待ち: question/blocked の報告(未完了タスク)、pending-human の代行依頼、blocked の agent。"""
    comments = q(
        "SELECT c.*, t.status AS task_status, t.title AS task_title FROM comments c "
        "LEFT JOIN tasks t ON t.id=c.task_id WHERE c.kind IN ('question','blocked') "
        "AND COALESCE(t.status,'') != 'done' ORDER BY c.id DESC LIMIT 100")
    proxies = q("SELECT * FROM proxy_requests WHERE status='pending-human' ORDER BY id DESC LIMIT 100")
    agents, _ = get_agents()
    blocked = [a for a in agents if a.get("agent_status") == "blocked"]
    return comments, proxies, blocked


def badge_count():
    c, p, b = needs_human()
    return len(c) + len(p) + len(b)


def parse_ts(s):
    if not s:
        return None
    try:
        d = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def activity_for(a):
    sid = agent_session(a)
    rows = []
    if sid:
        rows = q("SELECT * FROM agent_activity WHERE session_id=?", (sid,))
    if not rows and a.get("pane_id"):
        rows = q("SELECT * FROM agent_activity WHERE pane_id=? ORDER BY updated_at DESC LIMIT 1", (a["pane_id"],))
    return rows[0] if rows else None


def stalled(a, act):
    if a.get("agent_status") != "working" or not act:
        return False
    p, s = parse_ts(act.get("last_prompt_at")), parse_ts(act.get("last_stop_at"))
    if not p or (s and s >= p):
        return False
    return datetime.now(timezone.utc) - p > timedelta(minutes=STALL_MIN)


def tasks_for_agent(a):
    name, sid = a.get("name"), agent_session(a)
    rows = []
    if name:
        rows += q("SELECT * FROM tasks WHERE owner_agent=? AND status!='done' ORDER BY updated_at DESC", (name,))
    if sid:
        rows += [r for r in q("SELECT * FROM tasks WHERE session_id=? AND status!='done' ORDER BY updated_at DESC", (sid,))
                 if r["id"] not in {x["id"] for x in rows}]
    return rows


# ---------------------------------------------------------------- HTML

CSS = """
body{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:0;color:#1f2328;background:#f6f8fa}
nav{background:#24292f;padding:8px 16px;display:flex;gap:16px;align-items:center}
nav form{margin:0 0 0 auto}nav button{cursor:pointer}
nav a{color:#fff;text-decoration:none;padding:2px 6px;border-radius:4px}
nav a.on{background:#0969da}
.badge{background:#cf222e;color:#fff;border-radius:10px;padding:0 7px;font-size:12px;margin-left:4px}
.badge.zero{background:#6e7781}
main{padding:16px;max-width:1200px;margin:auto}
h1{font-size:20px}h2{font-size:16px;margin-top:24px}
table{border-collapse:collapse;width:100%;background:#fff}
th,td{border:1px solid #d0d7de;padding:4px 8px;text-align:left;vertical-align:top}
th{background:#eaeef2}
pre{background:#fff;border:1px solid #d0d7de;padding:8px;overflow:auto;white-space:pre-wrap;word-break:break-all}
code{background:#eaeef2;padding:1px 4px;border-radius:3px}
.st-working{color:#9a6700}.st-blocked,.warn{color:#cf222e;font-weight:bold}.st-idle{color:#6e7781}.st-done{color:#1a7f37}
.note{color:#6e7781;font-size:12px}.err{background:#ffebe9;border:1px solid #cf222e;padding:6px 10px}
"""

NAV = [("/", "概要"), ("/agents", "agent"), ("/tasks", "タスク"), ("/inbox", "報告・承認待ち"),
       ("/jobs", "定期実行"), ("/ledger", "台帳")]


def page(title, body, path, badge, logout="", refresh=True):
    links = []
    for href, label in NAV:
        on = path == href or (href != "/" and path.startswith(href + "/"))
        b = ""
        if href == "/inbox":
            b = f'<span class="badge{"" if badge else " zero"}">{badge}</span>'
        links.append(f'<a href="{href}"{" class=on" if on else ""}>{label}{b}</a>')
    return (
        "<!doctype html><html lang=ja><head><meta charset=utf-8>"
        + (f'<meta http-equiv="refresh" content="{REFRESH_SEC}">' if refresh else "") +
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        '<meta name=referrer content=same-origin>'
        f"<title>{e(title)} - herdr</title><style>{CSS}</style></head><body>"
        f"<nav>{''.join(links)}{logout}</nav><main><h1>{e(title)}</h1>{body}"
        f'<p class=note>{f"自動更新 {REFRESH_SEC} 秒" if refresh else "自動更新なし"} / 変更できるのは定期実行の設定だけ / 機密を含みうる画面です</p></main></body></html>'
    )


def table(headers, rows):
    """rows の各セルは HTML 済み(呼び出し側で e() を通す)。"""
    if not rows:
        return "<p class=note>(なし)</p>"
    h = "".join(f"<th>{x}</th>" for x in headers)
    b = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table><tr>{h}</tr>{b}</table>"


def state_html(s):
    s = s or "unknown"
    return f'<span class="st-{e(s)}">{e(s)}</span>'


def alink(a, frag=""):
    k = agent_key(a)
    return f'<a href="/agents/{quote(k, safe="")}{frag}">{e(k)}</a>'


def tlink(tid):
    return f'<a href="/tasks/{quote(str(tid), safe="")}">{e(tid)}</a>'


def err_html(err):
    return f'<p class=err>{e(err)}</p>' if err else ""


def cur_task_title(a, tasks):
    if tasks:
        return e(tasks[0]["title"])
    return e(a.get("terminal_title_stripped") or a.get("terminal_title") or "")


def page_overview(_qs):
    agents, err = get_agents()
    comments, proxies, blocked = needs_human()
    counts = {}
    for a in agents:
        counts[a.get("agent_status") or "unknown"] = counts.get(a.get("agent_status") or "unknown", 0) + 1
    stall = []
    for a in agents:
        act = activity_for(a)
        if stalled(a, act):
            stall.append((a, act))
    body = err_html(err)
    body += "<h2>承認待ち</h2>" + table(
        ["種別", "件数", ""],
        [["報告 (question/blocked)", len(comments), '<a href="/inbox">見る</a>'],
         ["代行依頼 (pending-human)", len(proxies), '<a href="/inbox">見る</a>'],
         ["blocked の agent", len(blocked), ", ".join(alink(a) for a in blocked)]])
    body += "<h2>agent の状態</h2>" + (
        " / ".join(f'{state_html(k)}: {v}' for k, v in sorted(counts.items())) or "<p class=note>(なし)</p>")
    body += f"<h2>滞留 (working のまま {STALL_MIN} 分超)</h2>" + table(
        ["agent", "最終入力"], [[alink(a), e(act.get("last_prompt_at"))] for a, act in stall])
    done = q("SELECT id,project,title,owner_agent,updated_at FROM tasks WHERE status='done' "
             "ORDER BY updated_at DESC LIMIT 5")
    body += "<h2>直近の完了</h2>" + table(
        ["タスク", "PJ", "題", "担当", "更新"],
        [[tlink(t["id"]), e(t["project"]), e(t["title"]), e(t["owner_agent"]), e(t["updated_at"])] for t in done])
    return "概要", body


def page_agents(_qs):
    agents, err = get_agents()
    rows = []
    for a in agents:
        act = activity_for(a)
        tasks = tasks_for_agent(a)
        warn = ""
        if a.get("agent_status") == "blocked":
            warn = "blocked(人の対応待ち)"
        elif stalled(a, act):
            warn = f"滞留 ({STALL_MIN} 分超)"
        rows.append([
            alink(a), state_html(a.get("agent_status")), e(a.get("workspace_id")), cur_task_title(a, tasks),
            f'入力 {e(act.get("last_prompt_at") if act else "-")}<br>停止 {e(act.get("last_stop_at") if act else "-")}',
            f'<span class=warn>{e(warn)}</span>' if warn else ""])
    return "agent 一覧", err_html(err) + table(
        ["名前", "状態", "workspace", "いま何を", "最終入力 / 停止", "警告"], rows)


def find_agent(key):
    agents, err = get_agents()
    for a in agents:
        if agent_key(a) == key or a.get("pane_id") == key:
            return a, err
    return None, err


def page_agent(key):
    a, err = find_agent(key)
    if a is None:
        return None
    act = activity_for(a)
    tasks = tasks_for_agent(a)
    sid = agent_session(a) or (tasks[0]["session_id"] if tasks and tasks[0].get("session_id") else None)
    resume = f"claude --resume {shlex.quote(str(sid))}" if sid else None
    info = [
        ("状態", state_html(a.get("agent_status")) + (' <span class=warn>滞留</span>' if stalled(a, act) else "")),
        ("場所", f'workspace {e(workspace_label(a.get("workspace_id")) or "-")} ({e(a.get("workspace_id"))})'
                 f' / tab {e(a.get("tab_id"))} / pane {e(a.get("pane_id"))}'),
        ("cwd", e(a.get("foreground_cwd") or a.get("cwd"))),
        ("端末タイトル", e(a.get("terminal_title_stripped") or a.get("terminal_title"))),
        ("最終入力", e(act.get("last_prompt_at") if act else "-")),
        ("最終停止", e(act.get("last_stop_at") if act else "-")),
        ("session_id", f"<code>{e(sid)}</code>" if sid else "-"),
        ("resume コマンド", f"<code>{e(resume)}</code>" if resume else "-"),
    ]
    body = err_html(err) + "<table>" + "".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in info) + "</table>"
    attach = "herdr agent attach " + shlex.quote(str(agent_key(a)))
    if a.get("agent_status") == "blocked":
        body += '<h2 id="approval">承認待ちの内容</h2>'
        dlg, derr = read_agent(a, 40, "visible")
        body += err_html(derr)
        if dlg is not None:
            body += f"<pre>{e(dlg)}</pre>"
        body += ('<p class=note>要約・加工なしの端末表示です。承認の入力はブラウザ上では行えません。'
                 '下のコマンドで手元の herdr から開いて、人が操作してください。</p>')
    body += ('<h2>手元で開く</h2><p><input type=text readonly size=60 value="' + e(attach) +
             '" onfocus="this.select()"> <span class=note>クリックで全選択 → コピーして手元の端末で実行</span></p>')
    body += "<h2>担当タスク</h2>" + table(
        ["タスク", "PJ", "題", "状態", "更新"],
        [[tlink(t["id"]), e(t["project"]), e(t["title"]), e(t["status"]), e(t["updated_at"])] for t in tasks])
    out, rerr = read_agent(a)
    body += "<h2>直近の出力 (agent read)</h2>" + err_html(rerr)
    if out is not None:
        body += f"<pre>{e(out)}</pre>"
    return f"agent: {clean(agent_key(a))}", body


TASK_STATUSES = ["todo", "in_progress", "review", "done", "blocked"]


def page_tasks(qs):
    proj = (qs.get("project") or [""])[0]
    st = (qs.get("status") or [""])[0]
    where, params = [], []
    if proj:
        where.append("project=?")
        params.append(proj)
    if st in TASK_STATUSES:
        where.append("status=?")
        params.append(st)
    sql = "SELECT * FROM tasks" + (" WHERE " + " AND ".join(where) if where else "") + \
          " ORDER BY project, updated_at DESC LIMIT 300"
    rows = q(sql, params)
    projects = [r["project"] for r in q("SELECT DISTINCT project FROM tasks ORDER BY project")]

    def href(**kw):
        d = {"project": proj, "status": st}
        d.update(kw)
        d = {k: v for k, v in d.items() if v}
        return "/tasks" + ("?" + urlencode(d) if d else "")
    f = "PJ: " + " ".join(f'<a href="{e(href(project=p))}">{e(p)}</a>' for p in projects)
    f += f' <a href="{e(href(project=""))}">[全部]</a><br>状態: ' + " ".join(
        f'<a href="{e(href(status=s))}">{e(s)}</a>' for s in TASK_STATUSES) + f' <a href="{e(href(status=""))}">[全部]</a>'
    if not db_conn_ok():
        f += '<p class=err>タスク DB がありません(または開けません)</p>'
    body = f + table(
        ["タスク", "PJ", "題", "状態", "担当", "session_id", "成果物", "報告済み"],
        [[tlink(t["id"]), e(t["project"]), e(t["title"]), e(t["status"]), e(t["owner_agent"]),
          e(t["session_id"]), str(len(safe_json_list(t["deliverables"]))), "○" if t["reported_at"] else "-"]
         for t in rows])
    return "タスク", body


def db_conn_ok():
    c = db_conn()
    if c is None:
        return False
    c.close()
    return True


def safe_json_list(s):
    try:
        v = json.loads(s or "[]")
        return v if isinstance(v, list) else []
    except ValueError:
        return []


def page_task(tid):
    rows = q("SELECT * FROM tasks WHERE id=?", (tid,))
    if not rows:
        return None
    t = rows[0]
    info = [(k, e(t.get(k))) for k in ["id", "project", "title", "status", "owner_agent", "session_id", "account",
                                        "parent_id", "summary", "note", "reported_at", "created_at", "updated_at"]]
    dl = safe_json_list(t["deliverables"])
    info.append(("成果物", "<br>".join(e(x) for x in dl) or "-"))
    if t.get("session_id"):
        info.append(("resume コマンド", f'<code>{e("claude --resume " + shlex.quote(t["session_id"]))}</code>'))
    body = "<table>" + "".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in info) + "</table>"
    cm = q("SELECT * FROM comments WHERE task_id=? ORDER BY id DESC", (tid,))
    body += "<h2>報告</h2>" + table(
        ["id", "種別", "本文", "成果物", "from", "配送", "時刻"],
        [[f"C-{c['id']}", e(c["kind"]), f'<pre>{e(c["text"])}</pre>',
          "<br>".join(e(x) for x in safe_json_list(c["deliverables"])), e(c["from_name"]),
          "済" if c["delivered_at"] else "未", e(c["created_at"])] for c in cm])
    px = q("SELECT * FROM proxy_requests WHERE task_id=? ORDER BY id DESC", (tid,))
    body += "<h2>代行依頼</h2>" + table(
        ["id", "状態", "effect", "コマンド", "理由", "結果"],
        [[e(p["id"]), e(p["status"]), e(p["effect"]), f'<pre>{e(p["cmd"])}</pre>', e(p["why"]), e(p["result"])]
         for p in px])
    return f"タスク {clean(t['id'])}", body


def page_inbox(_qs):
    comments, proxies, blocked = needs_human()
    ids = {c["id"] for c in comments}
    body = "<h2>要対応 (needs-human)</h2>"
    body += table(["id", "種別", "タスク", "本文", "from", "時刻"],
                  [[f"C-{c['id']}", f'<span class=warn>{e(c["kind"])}</span>', tlink(c["task_id"]),
                    f'<pre>{e(c["text"])}</pre>', e(c["from_name"]), e(c["created_at"])] for c in comments])
    body += "<h3>代行依頼 (pending-human)</h3>" + table(
        ["id", "タスク", "effect", "コマンド", "理由"],
        [[e(p["id"]), tlink(p["task_id"]), e(p["effect"]), f'<pre>{e(p["cmd"])}</pre>', e(p["why"])] for p in proxies])
    body += "<h3>blocked の agent</h3>" + table(
        ["agent", "workspace", ""],
        [[alink(a, "#approval"), e(a.get("workspace_id")), f'<a href="/agents/{quote(agent_key(a), safe="")}#approval">承認待ちの内容を見る</a>']
         for a in blocked])
    rest = [c for c in q("SELECT * FROM comments ORDER BY id DESC LIMIT 60") if c["id"] not in ids][:50]
    body += "<h2>直近の報告</h2>" + table(
        ["id", "種別", "タスク", "本文", "from", "時刻"],
        [[f"C-{c['id']}", e(c["kind"]), tlink(c["task_id"]), f'<pre>{e(c["text"])}</pre>', e(c["from_name"]),
          e(c["created_at"])] for c in rest])
    return "報告・承認待ち", body


JOB_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
HM_RE = re.compile(r"([01][0-9]|2[0-3]):[0-5][0-9]")
DAY_TOKENS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
DAY_PRESETS = (("daily", "毎日"), ("weekdays", "平日"), ("weekends", "土日"))


def job_names():
    try:
        return sorted(n[:-5] for n in os.listdir(SCHED_JOBS()) if n.endswith(".conf") and JOB_RE.fullmatch(n[:-5]))
    except OSError:
        return []


def job_info(name):
    """scheduler/bin/show.sh で、実際に効く設定(conf + settings)を得る。(dict, None) か (None, エラー文)。"""
    env = dict(os.environ, JOBS_DIR=SCHED_JOBS(), SCHED_SETTINGS_DIR=SCHED_SETTINGS())
    for k in ("SCHED_WINDOW", "SCHED_START", "SCHED_END", "SCHED_INTERVAL_MIN"):
        env.pop(k, None)
    try:
        r = subprocess.run(["bash", os.path.join(SCHED_ROOT, "bin", "show.sh"), name], env=env,
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None, "設定を読めませんでした"
    if r.returncode != 0:
        return None, clean(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "設定を読めませんでした")
    try:
        return json.loads(r.stdout), None
    except ValueError:
        return None, "設定を読めませんでした"


def job_last(name):
    recs = parse_jsonl(tail_lines(os.path.join(SCHED_LOGS(), name + ".log"), 200))
    last = recs[-1] if recs else None
    ran = [r for r in recs if r.get("action") in ("ran", "failed", "sent")]
    return last, (ran[-1] if ran else None)


def page_jobs(_qs):
    names = job_names()
    try:
        logged = sorted(n[:-4] for n in os.listdir(SCHED_LOGS()) if n.endswith(".log") and JOB_RE.fullmatch(n[:-4]))
    except OSError:
        logged = []
    rows = []
    for n in sorted(set(names) | set(logged)):
        info, err = job_info(n) if n in names else (None, "jobs/ に conf がない")
        last, lr = job_last(n)
        if info:
            sched = (f'{e(info["interval_min"])} 分おき / {e(info["start"])}-{e(info["end"])} / {e(info["days"])}'
                     + (" <span class=note>(Web UI で変更済み)</span>" if info.get("overridden") else ""))
            st = "有効" if info.get("enabled") else '<span class=warn>一時停止</span>'
            what = e(info["target"]) if info["kind"] == "prompt" else "コマンド"
        else:
            sched, st, what = f'<span class=warn>{e(err)}</span>', "-", "-"
        rows.append([f'<a href="/jobs/{quote(n)}">{e(n)}</a>' if n in names else e(n), what, sched, st,
                     (f'{e(last.get("ts"))} {e(last.get("action"))} {e(last.get("reason"))}' if last else "-"),
                     (f'{e(lr.get("ts"))} / {e(lr.get("action"))}' + (f' (exit {e(lr.get("exit"))})' if "exit" in lr else "")
                      if lr else "-")])
    note = "<p class=note>job 名を開くと、間隔・時間帯・曜日・一時停止を変更できます(次の分から反映)。</p>"
    return "定期実行", note + table(["job", "宛先", "間隔 / 時間帯 / 曜日", "状態", "最終記録", "最後の実行"], rows)


def page_job(name, csrf, error="", saved=False):
    """1 ジョブの設定フォーム(自動更新しない)。"""
    info, err = job_info(name)
    if not info:
        return "定期実行: " + name, err_html(err or error) + '<p><a href="/jobs">一覧へ</a></p>'
    days = info["days"]
    preset = days if days in dict(DAY_PRESETS) else ""
    opts = "".join(f'<option value={k}{" selected" if preset == k else ""}>{e(v)}</option>' for k, v in DAY_PRESETS)
    opts += f'<option value=custom{" selected" if not preset else ""}>曜日を指定</option>'
    toks = set(days.lower().replace(",", " ").split()) if not preset else set()
    checks = "".join(f'<label><input type=checkbox name=day_{t} value=1{" checked" if t in toks else ""}> {t.capitalize()}</label> '
                     for t in DAY_TOKENS)
    hid = f'<input type=hidden name=csrf value="{e(csrf)}">'
    form = (
        f'<form method=post action="/jobs/{quote(name)}">{hid}<input type=hidden name=action value=save>'
        f'<p><label>間隔(分)<br><input type=number name=interval_min min=1 max=1440 required value="{e(info["interval_min"])}"></label></p>'
        f'<p><label>開始 <input type=time name=start required value="{e(info["start"])}"></label> '
        f'<label>終了 <input type=time name=end required value="{e(info["end"])}"></label>'
        f' <span class=note>両端を含む。日またぎは不可。TZ は {e(info["tz"])}</span></p>'
        f'<p><label>曜日 <select name=days>{opts}</select></label> {checks}</p>'
        f'<p><label><input type=checkbox name=enabled value=1{" checked" if info["enabled"] else ""}> 有効(外すと一時停止)</label></p>'
        '<button type=submit>保存</button></form>'
        f'<form method=post action="/jobs/{quote(name)}" style="margin-top:12px">{hid}<input type=hidden name=action value=reset>'
        '<button type=submit>conf の値に戻す</button></form>')
    what = f'agent <code>{e(info["target"])}</code> にプロンプトを送る' if info["kind"] == "prompt" else "コマンドを実行する"
    msg = '<p class=note>保存しました。次の分から反映されます。</p>' if saved else ""
    return "定期実行: " + name, (
        err_html(error) + msg + f"<p>{what}ジョブ。{'Web UI で変更済み。' if info.get('overridden') else ''}</p>" + form +
        "<p class=note>変更できるのはスケジュールだけです(宛先・本文・コマンドは jobs/*.conf を人が編集)。"
        f'保存先: <code>scheduler/settings/{e(name)}.settings</code></p><p><a href="/jobs">一覧へ</a></p>')


def save_job_settings(name, form):
    """フォームを検証して settings を書く。エラー文か None。"""
    path = os.path.join(SCHED_SETTINGS(), name + ".settings")
    if os.path.islink(path):
        return "settings がシンボリックリンクです。手で確認してください"
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    if form.get("action") == "reset":
        if old is not None:
            os.unlink(path)
        return None
    iv, start, end = form.get("interval_min", "").strip(), form.get("start", "").strip(), form.get("end", "").strip()
    if not iv.isdigit() or not 1 <= int(iv) <= 1440:
        return "間隔は 1〜1440 分の整数で入力してください"
    if not HM_RE.fullmatch(start) or not HM_RE.fullmatch(end):
        return "開始・終了は HH:MM で入力してください"
    if start > end:
        return "開始は終了より前にしてください(日またぎは未対応)"
    days = form.get("days", "")
    if days == "custom":
        picked = [t for t in DAY_TOKENS if form.get("day_" + t) == "1"]
        if not picked:
            return "曜日を 1 つ以上選んでください"
        days = " ".join(t.capitalize() for t in picked)
    elif days not in dict(DAY_PRESETS):
        return "曜日の指定が不正です"
    enabled = "1" if form.get("enabled") == "1" else "0"
    body = f"# Web UI が書く上書き設定({time.strftime('%Y-%m-%dT%H:%M:%S%z')})\n" \
           f"INTERVAL_MIN={int(iv)}\nSTART={start}\nEND={end}\nDAYS={days}\nENABLED={enabled}\n"
    os.makedirs(SCHED_SETTINGS(), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(body)
    os.replace(tmp, path)
    _, err = job_info(name)
    if err:  # scheduler 側で読めない設定は残さない
        if old is None:
            os.unlink(path)
        else:
            with open(path, "w") as f:
                f.write(old)
        return "scheduler が設定を受け付けませんでした: " + err
    return None


def page_ledger(_qs):
    recs = parse_jsonl(tail_lines(DISPATCH(), 30))[::-1]
    rows = []
    for r in recs:
        p = clean(r.get("prompt") or "")
        rows.append([e(r.get("ts")), e(r.get("action")), e(r.get("target")), e(r.get("profile")),
                     e(r.get("approved")), e(p[:200] + ("…" if len(p) > 200 else "")), e(r.get("result"))])
    return "台帳 (直近 30 件)", table(["時刻", "action", "宛先", "profile", "承認", "送った内容(先頭)", "結果"], rows)


STATIC = {"/": page_overview, "/agents": page_agents, "/tasks": page_tasks, "/inbox": page_inbox,
          "/jobs": page_jobs, "/ledger": page_ledger}


def route(path, qs):
    """(status, title, body) か None(404)。"""
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    if path in STATIC:
        t, b = STATIC[path](qs)
        return t, b
    m = re.fullmatch(r"/(agents|tasks)/([^/]+)", path)
    if m:
        key = unquote(m.group(2))
        r = page_agent(key) if m.group(1) == "agents" else page_task(key)
        return r
    return None


# ---------------------------------------------------------------- HTTP


def plain_page(title, body):
    """ログイン・初回設定用(ナビも自動更新もなし)。"""
    return ("<!doctype html><html lang=ja><head><meta charset=utf-8><meta name=referrer content=same-origin>"
            '<meta name=viewport content="width=device-width,initial-scale=1">'
            f"<title>{e(title)} - herdr</title><style>{CSS}</style></head><body>"
            f"<main style='max-width:420px'><h1>{e(title)}</h1>{body}</main></body></html>")


def form_html(action, csrf, fields, submit, error="", note="", next_=""):
    rows = "".join(
        f'<p><label>{e(label)}<br><input type={typ} name={name} required autocomplete={ac} style="width:100%"></label></p>'
        for name, label, typ, ac in fields)
    nx = f'<input type=hidden name=next value="{e(next_)}">' if next_ else ""
    return (f'{err_html(error)}<p class=note>{e(note)}</p>' if note or error else "") + (
        f'<form method=post action="{action}"><input type=hidden name=csrf value="{e(csrf)}">{nx}{rows}'
        f'<button type=submit>{e(submit)}</button></form>')


FORGOT = '<p class=note><a href="/reset">パスワードを忘れた</a></p>'
RESET_DENY = {"missing": "再設定は許可されていません。", "expired": "再設定の許可の期限(10 分)が切れています。",
              "invalid": "再設定の許可ファイルが不正です(通常ファイルで、自分の所有のものだけ有効)。いったん削除して作り直してください。"}


def reset_page(a, state, error=""):
    """state が ok なら新パスワードの設定画面、そうでなければ許可コマンドの案内。"""
    if state == "ok":
        return plain_page("パスワードの再設定", form_html(
            "/reset", a.form_token("anon"),
            [("password", f"新しいパスワード({auth.MIN_PASSWORD} 文字以上)", "password", "new-password"),
             ("confirm", "新しいパスワード(確認)", "password", "new-password")], "再設定する", error=error,
            note="許可の有効期間内に設定してください。成功すると全員のログインが無効になります。"))
    cmd = "touch " + shlex.quote(a.allow_path)
    return plain_page("パスワードの再設定", err_html(RESET_DENY.get(state, "")) +
                      "<p>次のコマンドを手元のシェルで実行して再設定を許可してください(10 分間有効)。実行後にこの画面を再読み込みします。</p>"
                      f"<pre>{e(cmd)}</pre>" + '<p class=note><a href="/login">ログインへ戻る</a></p>')


LOGIN_FAIL = "ユーザー名またはパスワードが違います"


class Handler(BaseHTTPRequestHandler):
    server_version = "herdr-webui"
    sys_version = ""
    auth = None
    port = 0

    def log_message(self, fmt, *args):  # クエリ・Cookie・本文はログに残さない(メソッド・パス・状態だけ)
        try:
            line = self.requestline.split(" ")
            path = urlsplit(line[1]).path if len(line) > 1 else "?"
            sys.stderr.write(f"{self.log_date_time_string()} {line[0]} {path} {args[1] if len(args) > 1 else ''}\n")
        except Exception:
            pass

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=()):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _text(self, code, msg, extra=()):
        self._send(code, msg + "\n", "text/plain; charset=utf-8", extra)

    def _redirect(self, loc, extra=()):
        self._send(302, "", "text/plain", [("Location", loc), *extra])

    def _origins(self):
        return (f"http://127.0.0.1:{self.port}", f"http://localhost:{self.port}")

    def _host_ok(self):
        # DNS リバインディング対策: Host が自分自身であること
        host = (self.headers.get("Host") or "").lower()
        return host in (f"127.0.0.1:{self.port}", f"localhost:{self.port}")

    def _origin_ok(self):
        o, ref = self.headers.get("Origin"), self.headers.get("Referer")
        if o is not None:
            return o in self._origins()
        if ref is not None:
            return any(ref == b or ref.startswith(b + "/") for b in self._origins())
        return False

    def _session_token(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE:
                return v
        return None

    def _session(self):
        return self.auth.session_hash(self._session_token())

    def _cookie(self, value, max_age):
        return ("Set-Cookie", f"{COOKIE}={value}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age}")

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > 8192:
            return None
        raw = self.rfile.read(n).decode("utf-8", "replace")
        return {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    # ---- GET
    def _get(self):
        u = urlsplit(self.path)
        path = u.path
        qs = parse_qs(u.query)
        a = self.auth
        if path == "/setup":
            if a.configured():
                return self._send(404, plain_page("見つかりません", "<p>そのページはありません。</p>"))
            return self._send(200, plain_page("初回設定", form_html(
                "/setup", a.form_token("anon"),
                [("username", "ユーザー名", "text", "username"),
                 ("password", f"パスワード({auth.MIN_PASSWORD} 文字以上)", "password", "new-password"),
                 ("confirm", "パスワード(確認)", "password", "new-password")],
                "設定する", note="最初に 1 回だけ行う設定です。設定後、この画面は閉じます。")))
        if path == "/login":
            if not a.configured():
                return self._redirect("/setup")
            nx = auth.safe_next((qs.get("next") or ["/"])[0])
            if self._session():
                return self._redirect(nx)
            return self._send(200, plain_page("ログイン", form_html(
                "/login", a.form_token("anon"),
                [("username", "ユーザー名", "text", "username"),
                 ("password", "パスワード", "password", "current-password")], "ログイン", next_=nx) + FORGOT))
        if path == "/reset":
            if not a.configured():
                return self._redirect("/setup")
            st = a.reset_state()
            if st in ("expired", "invalid"):
                sys.stderr.write(f"reset: denied ({st})\n")
            return self._send(200, reset_page(a, st))
        if path == "/logout":
            return self._text(405, "Method Not Allowed", [("Allow", "POST")])
        if not a.configured():
            return self._redirect("/setup")
        sh = self._session()
        if not sh:
            nx = u.path + (("?" + u.query) if u.query else "")
            return self._redirect("/login?" + urlencode({"next": auth.safe_next(nx)}))
        logout = (f'<form method=post action="/logout"><input type=hidden name=csrf value="{e(a.form_token("s:" + sh))}">'
                  '<button type=submit>ログアウト</button></form>')
        try:
            m = re.fullmatch(r"/jobs/([^/]+)/?", unquote(path))
            if m:  # 設定フォーム(自動更新しない)
                name = m.group(1)
                if not JOB_RE.fullmatch(name) or name not in job_names():
                    return self._send(404, page("見つかりません", "<p>そのページはありません。</p>", "", badge_count(), logout))
                title, body = page_job(name, a.form_token("s:" + sh), saved=qs.get("saved") == ["1"])
                return self._send(200, page(title, body, "/jobs/" + name, badge_count(), logout, refresh=False))
            r = route(unquote(path), qs)
            if r is None:
                return self._send(404, page("見つかりません", "<p>そのページはありません。</p>", "", badge_count(), logout))
            title, body = r
            self._send(200, page(title, body, path, badge_count(), logout))
        except Exception as ex:  # 1 ページの失敗でサーバーを落とさない(例外の内容は出さない)
            sys.stderr.write(f"internal error: {type(ex).__name__}\n")
            self._text(500, "Internal Server Error")

    # ---- POST(/login /setup /logout /reset と、定期実行の設定 /jobs/<job> だけ)
    def _post(self, path):
        a = self.auth
        if not self._origin_ok():
            return self._text(403, "Forbidden: Origin/Referer が不正です")
        form = self._body()
        if form is None:
            return self._text(413, "Payload Too Large")
        sh = self._session()
        job = path.startswith("/jobs/")
        if job and not sh:
            return self._redirect("/login")
        ctx = "s:" + sh if (path == "/logout" or job) and sh else "anon"
        if not a.check_form_token(form.get("csrf"), ctx):
            if path == "/logout" and not sh:
                return self._redirect("/login")
            return self._text(403, "Forbidden: フォームの有効期限切れです。画面を開き直してください")
        if job:
            name = path[len("/jobs/"):]
            if not JOB_RE.fullmatch(name) or name not in job_names():
                return self._text(404, "Not Found")
            try:
                err = save_job_settings(name, form)
            except OSError:
                err = "設定を書き込めませんでした"
            if err:
                title, body = page_job(name, a.form_token("s:" + sh), error=err)
                return self._send(400, page(title, body, path, badge_count(), refresh=False))
            sys.stderr.write(f"jobs: settings {'reset' if form.get('action') == 'reset' else 'saved'} {name}\n")
            return self._redirect(f"/jobs/{name}?saved=1")
        if path == "/logout":
            a.destroy_session(self._session_token())
            return self._redirect("/login", [self._cookie("", 0)])
        if path == "/setup":
            if a.configured():
                return self._send(404, plain_page("見つかりません", "<p>そのページはありません。</p>"))
            user, pw, conf = form.get("username", "").strip(), form.get("password", ""), form.get("confirm", "")
            err = None
            if not user or len(user) > 64 or clean(user) != user:
                err = "ユーザー名は 1〜64 文字で入力してください"
            elif len(pw) < auth.MIN_PASSWORD:
                err = f"パスワードは {auth.MIN_PASSWORD} 文字以上にしてください"
            elif len(pw) > auth.MAX_FIELD:
                err = "パスワードが長すぎます"
            elif pw != conf:
                err = "確認入力が一致しません"
            if err:
                return self._send(400, plain_page("初回設定", form_html(
                    "/setup", a.form_token("anon"),
                    [("username", "ユーザー名", "text", "username"),
                     ("password", f"パスワード({auth.MIN_PASSWORD} 文字以上)", "password", "new-password"),
                     ("confirm", "パスワード(確認)", "password", "new-password")], "設定する", error=err)))
            if not a.setup(user, pw):
                return self._send(404, plain_page("見つかりません", "<p>そのページはありません。</p>"))
            sys.stderr.write("setup: 認証情報を作成しました\n")
            tok = a.create_session()
            return self._redirect("/", [self._cookie(tok, auth.session_ttl())])
        if path == "/reset":
            if not a.configured():
                return self._redirect("/setup")
            st = a.reset_state()
            pw, conf = form.get("password", ""), form.get("confirm", "")
            err = None
            if st != "ok":
                err = "denied"
            elif len(pw) < auth.MIN_PASSWORD:
                err = f"パスワードは {auth.MIN_PASSWORD} 文字以上にしてください"
            elif len(pw) > auth.MAX_FIELD:
                err = "パスワードが長すぎます"
            elif pw != conf:
                err = "確認入力が一致しません"
            if not err:
                st = a.reset_password(pw)
                if st == "done":
                    sys.stderr.write("reset: ok(全セッションを無効化)\n")
                    return self._redirect("/login")
                err = "denied"
            time.sleep(auth.fail_delay())  # 失敗の遅延
            if err == "denied":
                sys.stderr.write(f"reset: denied ({st})\n")
                return self._send(403, reset_page(a, st))
            return self._send(400, reset_page(a, st, err))
        # /login
        if not a.configured():
            return self._redirect("/setup")
        nx = auth.safe_next(form.get("next", "/"))
        wait = a.locked_for()
        if wait:
            sys.stderr.write("login: locked\n")
            return self._send(429, plain_page("ログイン", err_html(f"失敗が続いたため一時的にロックしています。約 {wait} 秒後にやり直してください")),
                              extra=[("Retry-After", str(wait))])
        if a.attempt(form.get("username", "")[:auth.MAX_FIELD], form.get("password", "")[:auth.MAX_FIELD]):
            sys.stderr.write("login: ok\n")
            tok = a.create_session()
            return self._redirect(nx, [self._cookie(tok, auth.session_ttl())])
        sys.stderr.write("login: failed\n")
        time.sleep(auth.fail_delay())  # 失敗の遅延
        wait = a.locked_for()
        return self._send(401, plain_page("ログイン", form_html(
            "/login", a.form_token("anon"),
            [("username", "ユーザー名", "text", "username"),
             ("password", "パスワード", "password", "current-password")], "ログイン",
            error=LOGIN_FAIL + ("(ロックしました)" if wait else ""), next_=nx) + FORGOT))

    def _handle(self):
        if not self._host_ok():
            return self._text(403, "Forbidden")
        path = urlsplit(self.path).path
        if self.command == "POST" and (path in ("/login", "/setup", "/logout", "/reset")
                                       or re.fullmatch(r"/jobs/[A-Za-z0-9][A-Za-z0-9_-]{0,63}", path)):
            return self._post(path)
        if self.command not in ("GET", "HEAD"):
            return self._text(405, "Method Not Allowed(定期実行の設定以外は読み取り専用です)", [("Allow", "GET, HEAD")])
        self._get()

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _handle


def bind_server():
    """(server, port)。固定指定なら探索しない。全部埋まっていれば SystemExit。"""
    fixed = os.environ.get("TB_UI_PORT")
    try:
        if fixed:
            lo = hi = int(fixed)
        else:
            lo, hi = (int(x) for x in cfg("HERDR_WEBUI_RANGE", "8800-8819").split("-"))
    except ValueError:
        raise SystemExit("herdr-webui: ポート指定が数値ではありません")
    last = None
    for p in range(lo, hi + 1):
        try:
            return ThreadingHTTPServer((HOST, p), Handler), p
        except OSError as ex:
            last = ex
    if fixed:
        raise SystemExit(f"herdr-webui: ポート {lo} を使えません: {last}")
    raise SystemExit(f"herdr-webui: ポート {lo}〜{hi} がすべて使用中です")


def main():
    run_dir = RUN_DIR()
    Handler.auth = auth.Auth(run_dir)
    srv, port = bind_server()
    Handler.port = port
    port_file = os.path.join(run_dir, "port")
    with open(port_file, "w") as f:
        f.write(f"{port}\n")
    print(f"herdr-webui: listening on http://{HOST}:{port}/", flush=True)
    print(f"herdr-webui: port={port}", flush=True)
    if Handler.auth.configured():
        print(f"herdr-webui: ログイン http://{HOST}:{port}/login", flush=True)
    else:
        print(f"herdr-webui: 初回設定(ユーザー名とパスワードを作る) http://{HOST}:{port}/setup", flush=True)

    def stop(*_):
        threading.Thread(target=srv.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
        try:
            os.remove(port_file)
        except OSError:
            pass


if __name__ == "__main__":
    main()

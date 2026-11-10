"""HTML の組み立てと各ページ。"""

import json
import os
import re
import shlex
from urllib.parse import quote, unquote, urlencode

from .config import DISPATCH, JOB_RE, REFRESH_SEC, SCHED_LOGS, STALL_MIN
from .sanitize import clean, e
from .herdr import agent_key, agent_session, get_agents, read_agent, workspace_label
from .data import NOTIFY_POLL_SEC, activity_for, db_conn, needs_human, parse_jsonl, q, stalled, tail_lines, tasks_for_agent, urgent_items
from .actions import NOTE_MAX
from .jobs import DAY_PRESETS, DAY_TOKENS, job_info, job_last, job_names
from . import docs
from .markdown import render as render_md


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
.note{color:#6e7781;font-size:12px}
.doc{background:#fff;border:1px solid #d0d7de;padding:8px 24px;overflow-wrap:anywhere}
.doc table{width:auto}.doc pre{background:#f6f8fa}.doc blockquote{border-left:4px solid #d0d7de;margin:0;padding:0 12px;color:#57606a}
.doc h2.md{font-size:20px;border-bottom:1px solid #d0d7de}.doc ul,.doc ol{padding-left:1.5em}.err{background:#ffebe9;border:1px solid #cf222e;padding:6px 10px}
"""
NAV = [("/", "概要"), ("/notifications", "緊急通知"), ("/agents", "agent"), ("/tasks", "タスク"),
       ("/inbox", "報告・承認待ち"), ("/docs", "ドキュメント"), ("/jobs", "定期実行"), ("/ledger", "台帳")]


def page(title, body, path, badge, logout="", refresh=True):
    links = []
    for href, label in NAV:
        on = path == href or (href != "/" and path.startswith(href + "/"))
        b = ""
        if href == "/inbox":
            b = f'<span class="badge{"" if badge else " zero"}">{badge}</span>'
        elif href == "/notifications":
            n = len(urgent_items())
            b = f'<span id=nbadge class="badge{"" if n else " zero"}">{n}</span>'
        links.append(f'<a href="{href}"{" class=on" if on else ""}>{label}{b}</a>')
    return (
        "<!doctype html><html lang=ja><head><meta charset=utf-8>"
        + (f'<meta http-equiv="refresh" content="{REFRESH_SEC}">' if refresh else "") +
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        '<meta name=referrer content=same-origin>'
        f"<title>{e(title)} - herdr</title><style>{CSS}</style>"
        '<script src="/notify.js" defer></script></head><body>'
        f"<nav>{''.join(links)}{logout}</nav><main><h1>{e(title)}</h1>{body}"
        f'<p class=note>{f"自動更新 {REFRESH_SEC} 秒" if refresh else "入力欄があるので自動更新なし(再読み込みで更新)"} / 変更できるのは定期実行の設定と報告の「対応済み」だけ / 機密を含みうる画面です / Chrome 通知は「緊急通知」で設定</p></main></body></html>'
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
    info = [
        ("状態", state_html(a.get("agent_status")) + (' <span class=warn>滞留</span>' if stalled(a, act) else "")),
        ("場所", f'workspace {e(workspace_label(a.get("workspace_id")) or "-")} ({e(a.get("workspace_id"))})'
                 f' / tab {e(a.get("tab_id"))} / pane {e(a.get("pane_id"))}'),
        ("cwd", e(a.get("foreground_cwd") or a.get("cwd"))),
        ("端末タイトル", e(a.get("terminal_title_stripped") or a.get("terminal_title"))),
        ("最終入力", e(act.get("last_prompt_at") if act else "-")),
        ("最終停止", e(act.get("last_stop_at") if act else "-")),
        ("session_id", f"<code>{e(sid)}</code>" if sid else "-"),
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
             '"> <span class=note>欄をクリックして全選択(Cmd+A)→ コピーして手元の端末で実行</span></p>'
             '<p class=warn>別のターミナルで claude --resume を実行しないでください。動いている agent と会話が枝分かれします。</p>')
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


RESOLVE_MSG = {"done": "対応済みにしました。", "already": "すでに対応済みでした。",
               "error": "対応済みにできませんでした(tb の実行に失敗)。"}


def resolvable(c):
    return c.get("kind") in ("question", "blocked") and "resolved_at" in c and not c.get("resolved_at")


def resolve_form(c, back, ctx):
    """「対応済みにする」。ログイン済みのブラウザからの POST だけを受ける(書き込みは tb resolve が行う)。"""
    ctx["norefresh"] = True  # 入力欄があるので自動更新しない
    return (f'<form method=post action="/resolve"><input type=hidden name=csrf value="{e(ctx.get("csrf", ""))}">'
            f'<input type=hidden name=id value="{int(c["id"])}"><input type=hidden name=back value="{e(back)}">'
            f'<input type=text name=note maxlength={NOTE_MAX} placeholder="メモ(任意)" size=18> '
            '<button type=submit>対応済みにする</button></form>')


def resolved_label(c):
    if not c.get("resolved_at"):
        return ""
    return "対応済み " + e(c["resolved_at"]) + (f'<br>{e(c["resolved_note"])}' if c.get("resolved_note") else "")


def resolve_cell(c, back, ctx):
    return resolve_form(c, back, ctx) if resolvable(c) else resolved_label(c)


def resolve_notice(qs):
    st = (qs.get("resolved") or [""])[0]
    return f"<p class=note>{e(RESOLVE_MSG[st])}</p>" if st in RESOLVE_MSG else ""


def page_task(tid, qs=None, ctx=None):
    ctx = {} if ctx is None else ctx
    rows = q("SELECT * FROM tasks WHERE id=?", (tid,))
    if not rows:
        return None
    t = rows[0]
    info = [(k, e(t.get(k))) for k in ["id", "project", "title", "status", "owner_agent", "session_id", "account",
                                        "parent_id", "summary", "note", "reported_at", "created_at", "updated_at"]]
    info.append(("成果物", "<br>".join(doc_link(r, raw) for r, raw in docs.task_refs(t["id"], t["deliverables"])) or "-"))
    body = resolve_notice(qs or {}) + "<table>" + "".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in info) + "</table>"
    cm = q("SELECT * FROM comments WHERE task_id=? ORDER BY id DESC", (tid,))
    back = "/tasks/" + quote(str(tid), safe="")
    body += "<h2>報告</h2>" + table(
        ["id", "種別", "本文", "成果物", "from", "配送", "時刻", "対応"],
        [[f"C-{c['id']}", e(c["kind"]), f'<pre>{e(c["text"])}</pre>',
          "<br>".join(doc_link(r, raw) for r, raw in docs.comment_refs(c["id"], c["deliverables"])), e(c["from_name"]),
          "済" if c["delivered_at"] else "未", e(c["created_at"]), resolve_cell(c, back, ctx)] for c in cm])
    px = q("SELECT * FROM proxy_requests WHERE task_id=? ORDER BY id DESC", (tid,))
    body += "<h2>代行依頼</h2>" + table(
        ["id", "状態", "effect", "コマンド", "理由", "結果"],
        [[e(p["id"]), e(p["status"]), e(p["effect"]), f'<pre>{e(p["cmd"])}</pre>', e(p["why"]), e(p["result"])]
         for p in px])
    return f"タスク {clean(t['id'])}", body


def page_inbox(qs, ctx=None):
    ctx = {} if ctx is None else ctx
    comments, proxies, blocked = needs_human()
    ids = {c["id"] for c in comments}
    body = resolve_notice(qs) + "<h2>要対応 (needs-human)</h2>"
    body += table(["id", "種別", "タスク", "本文", "from", "時刻", "操作"],
                  [[f"C-{c['id']}", f'<span class=warn>{e(c["kind"])}</span>', tlink(c["task_id"]),
                    f'<pre>{e(c["text"])}</pre>', e(c["from_name"]), e(c["created_at"]),
                    resolve_cell(c, "/inbox", ctx)] for c in comments])
    body += "<h3>代行依頼 (pending-human)</h3>" + table(
        ["id", "タスク", "effect", "コマンド", "理由"],
        [[e(p["id"]), tlink(p["task_id"]), e(p["effect"]), f'<pre>{e(p["cmd"])}</pre>', e(p["why"])] for p in proxies])
    body += "<h3>blocked の agent</h3>" + table(
        ["agent", "workspace", ""],
        [[alink(a, "#approval"), e(a.get("workspace_id")), f'<a href="/agents/{quote(agent_key(a), safe="")}#approval">承認待ちの内容を見る</a>']
         for a in blocked])
    rest = [c for c in q("SELECT * FROM comments ORDER BY id DESC LIMIT 60") if c["id"] not in ids][:50]
    body += "<h2>直近の報告</h2>" + table(
        ["id", "種別", "タスク", "本文", "from", "時刻", "状態"],
        [[f"C-{c['id']}", e(c["kind"]), tlink(c["task_id"]), f'<pre>{e(c["text"])}</pre>', e(c["from_name"]),
          e(c["created_at"]), resolved_label(c)] for c in rest])
    return "報告・承認待ち", body


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


def page_ledger(_qs):
    recs = parse_jsonl(tail_lines(DISPATCH(), 30))[::-1]
    rows = []
    for r in recs:
        p = clean(r.get("prompt") or "")
        rows.append([e(r.get("ts")), e(r.get("action")), e(r.get("target")), e(r.get("profile")),
                     e(r.get("approved")), e(p[:200] + ("…" if len(p) > 200 else "")), e(r.get("result"))])
    return "台帳 (直近 30 件)", table(["時刻", "action", "宛先", "profile", "承認", "送った内容(先頭)", "結果"], rows)


def page_notifications(_qs):
    items = urgent_items()
    body = ("<p>10 分おきのまとめ送信を待たずに知らせるものです。開いている間、"
            f"{NOTIFY_POLL_SEC} 秒ごとに確認し、新しく出たものを Chrome のデスクトップ通知で出します。</p>"
            "<p><span id=nstate class=note>Chrome 通知: JavaScript が無効か、読み込み中です</span> "
            "<button type=button id=nenable hidden>Chrome 通知を有効にする</button></p>")
    body += table(["種別", "対象", "内容", "時刻"],
                  [[f'<span class=warn>{e(it["label"])}</span>', f'<a href="{e(it["href"])}">{e(it["title"])}</a>',
                    e(it["body"]), e(it["ts"])] for it in items])
    body += ("<p class=note>対象: 未完了タスクの question/blocked 報告、pending-human の代行依頼、blocked の agent、"
             f"working のまま {STALL_MIN} 分超の agent、最後の実行が失敗した定期実行。"
             "通知は Web UI のタブが 1 つ開いている間だけ届きます(タブを閉じると止まる)。</p>")
    return "緊急通知", body


def doc_href(ref, sub=""):
    return "/docs/view?" + urlencode({"ref": ref, **({"sub": sub} if sub else {})})


def doc_link(ref, raw):
    """成果物の文字列 → Web UI で開くリンク(URL ならそのまま外部リンク)。"""
    raw = str(raw)
    if docs.is_url(raw):
        return f'<a href="{e(raw.strip())}" rel="noopener noreferrer" target=_blank>{e(raw)}</a>'
    return f'<a href="{e(doc_href(ref))}">{e(raw)}</a>'


def _doc_name(raw):
    s = str(raw or "").rstrip("/")
    return os.path.basename(s) or s


def page_docs(qs, ctx=None):
    if ctx is not None:
        ctx["norefresh"] = True  # 絞り込みの入力欄があるので自動更新しない
    items = docs.recent_docs()
    kw = clean((qs.get("q") or [""])[0]).strip()[:100]
    if kw:
        low = kw.lower()
        items = [it for it in items if low in " ".join(str(it.get(k) or "") for k in ("raw", "task", "from", "title")).lower()]
    body = ("<p>agent が報告(<code>tb comment --deliverables</code>・タスクの成果物・アラートの解析レポート)で"
            "「ここにまとめました」と示したファイルを、新しい順に並べています。名前を押すとこの画面で読めます"
            "(Markdown は整形して表示)。</p>"
            f'<form method=get action="/docs"><input type=search name=q value="{e(kw)}" placeholder="パス・タスク・agent で絞り込み" size=36> '
            "<button type=submit>絞り込み</button></form>")
    rows = []
    for it in items:
        name = _doc_name(it["raw"]) or (f"A-{it['ref'][2:]} の解析レポート" if it["kind"] == "alert" else "-")
        if docs.is_url(it["raw"]):
            link = doc_link(it["ref"], it["raw"])
        else:
            link = f'<a href="{e(doc_href(it["ref"]))}">{e(name)}</a>'
        ctx_cell = tlink(it["task"]) if it["task"] else e(it.get("title") or "")
        rows.append([e(it["ts"]), link, f'<span class=note>{e(it["raw"])}</span>', ctx_cell, e(it["from"]),
                     e(it["kind"]), e(docs.exists_label(it))])
    body += table(["時刻", "ドキュメント", "パス", "タスク / アラート", "from", "種別", "状態"], rows)
    body += ("<p class=note>開けるのは tasks.db に成果物として登録されたものだけです。相対パスは報告した agent の作業ディレクトリが基準です。"
             "鍵・.env などの認証情報らしいものは登録されていても表示しません。</p>")
    return "ドキュメント", body


def page_doc(qs, ctx):
    ctx["norefresh"] = True  # 読んでいる途中で再読み込みしない
    ref = (qs.get("ref") or [""])[0]
    sub = (qs.get("sub") or [""])[0]
    ent = docs.lookup(ref)
    if ent is None:
        return None
    raw_mode = (qs.get("raw") or [""])[0] == "1"
    title = _doc_name(ent["raw"]) or f"{ref} の解析レポート"
    meta = [("登録された値", e(ent["raw"]) or "-"), ("場所", e(ent["path"]) if ent["path"] else "-"),
            ("タスク", tlink(ent["task"]) if ent["task"] else e(ent.get("title") or "-")),
            ("from", e(ent["from"])), ("時刻", e(ent["ts"])), ("参照", e(ref))]
    head = "<p><a href=\"/docs\">← ドキュメント一覧</a></p>"
    if docs.is_url(ent["raw"]):
        return title, head + f'<p>URL です: {doc_link(ref, ent["raw"])}</p>'
    path = ent["path"]
    if path and sub:
        p2 = docs.sub_path(path, sub)
        if p2 is None or not os.path.isdir(path):
            return None
        path, title = p2, sub
        meta.insert(2, ("フォルダ内", e(sub)))
    info = "<table>" + "".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in meta) + "</table>"
    if path is None:
        if ent.get("report"):
            return title, head + info + "<h2>解析レポート(DB に保存された本文)</h2>" + _doc_body(ent["report"], ".md", raw_mode, ref, sub)
        return title, head + info + err_html("ファイルの場所を決められません(相対パスで、報告した agent の作業ディレクトリが分からない)")
    kind, text, trunc, size = docs.read_text(path)
    if kind == "dir":
        files, more = docs.list_dir(path)
        rows = [[f'<a href="{e(doc_href(ref, os.path.relpath(os.path.join(path, f), ent["path"])))}">{e(f)}</a>'] for f in files]
        return title, head + info + "<h2>フォルダの中身</h2>" + table(["ファイル"], rows) + (
            f"<p class=note>先頭 {docs.MAX_LIST} 件だけ表示しています</p>" if more else "")
    if kind == "missing":
        if ent.get("report"):
            return title, head + info + "<p class=note>ファイルは見つかりませんでした。DB に保存された本文を表示します。</p>" + \
                _doc_body(ent["report"], ".md", raw_mode, ref, sub)
        return title, head + info + err_html("ファイルが見つかりません(移動・削除された可能性があります)")
    if kind == "binary":
        return title, head + info + err_html(f"テキストではないので表示しません({size} バイト)")
    if kind in ("denied", "error"):
        return title, head + info + err_html(text)
    note = f"<p class=note>大きいので先頭 {docs.MAX_BYTES // 1024} KB だけ表示しています(全体 {size} バイト)</p>" if trunc else ""
    return title, head + info + note + _doc_body(text, os.path.splitext(path)[1].lower(), raw_mode, ref, sub)


def _doc_body(text, ext, raw_mode, ref, sub):
    if ext in docs.MD_EXT:
        q_ = {"ref": ref, **({"sub": sub} if sub else {})}
        if raw_mode:
            sw = f'<p class=note><a href="/docs/view?{e(urlencode(q_))}">整形して表示</a></p>'
            return sw + f"<pre>{e(text)}</pre>"
        sw = f'<p class=note><a href="/docs/view?{e(urlencode({**q_, "raw": "1"}))}">元のテキストを表示</a></p>'
        return sw + f"<div class=doc>{render_md(text)}</div>"
    return f"<pre>{e(text)}</pre>"


STATIC = {"/": page_overview, "/notifications": page_notifications, "/agents": page_agents, "/tasks": page_tasks, "/inbox": page_inbox,
          "/jobs": page_jobs, "/ledger": page_ledger}


def route(path, qs, ctx=None):
    """(title, body) か None(404)。ctx: {"csrf": フォーム用トークン}。フォームを出したページは ctx["norefresh"] を立てる。"""
    ctx = {} if ctx is None else ctx
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    if path == "/inbox":
        return page_inbox(qs, ctx)
    if path == "/docs":
        return page_docs(qs, ctx)
    if path == "/docs/view":
        return page_doc(qs, ctx)
    if path in STATIC:
        t, b = STATIC[path](qs)
        return t, b
    m = re.fullmatch(r"/(agents|tasks)/([^/]+)", path)
    if m:
        key = unquote(m.group(2))
        r = page_agent(key) if m.group(1) == "agents" else page_task(key, qs, ctx)
        return r
    return None


NOTIFY_JS = """(function () {
  "use strict";
  var KEY = "herdr-webui-notified", POLL = %d;
  var badge = document.getElementById("nbadge");
  var state = document.getElementById("nstate");
  var btn = document.getElementById("nenable");
  function supported() { return "Notification" in window; }
  function load() {
    try { var v = JSON.parse(localStorage.getItem(KEY)); return v && typeof v === "object" ? v : null; }
    catch (x) { return null; }
  }
  function save(v) { try { localStorage.setItem(KEY, JSON.stringify(v)); } catch (x) {} }
  function showState() {
    if (!state) return;
    var t;
    if (!supported()) t = "このブラウザはデスクトップ通知に対応していません";
    else if (Notification.permission === "granted") t = "Chrome 通知: 有効";
    else if (Notification.permission === "denied") t = "Chrome 通知: ブロック中(アドレスバー左のサイト情報から通知を許可してください)";
    else t = "Chrome 通知: まだ許可していません";
    state.textContent = t;
    if (btn) btn.hidden = !supported() || Notification.permission !== "default";
  }
  function safeHref(h) { return typeof h === "string" && h.charAt(0) === "/" && h.charAt(1) !== "/" && h.charAt(1) !== "\\\\"; }
  function notify(it) {
    var n = new Notification("[herdr] " + it.label + ": " + it.title, {body: it.body, tag: "herdr-" + it.id});
    n.onclick = function () { window.focus(); if (safeHref(it.href)) location.href = it.href; n.close(); };
  }
  if (btn) btn.addEventListener("click", function () {
    Notification.requestPermission().then(function (p) {
      showState();
      if (p === "granted") new Notification("[herdr] 通知を有効にしました", {body: "新しい緊急通知をここに出します", tag: "herdr-enabled"});
    });
  });
  function poll() {
    fetch("/api/notifications", {credentials: "same-origin", cache: "no-store", headers: {"Accept": "application/json"}})
      .then(function (r) { if (!r.ok) throw new Error("status " + r.status); return r.json(); })
      .then(function (d) {
        var items = Array.isArray(d.items) ? d.items : [];
        if (badge) { badge.textContent = String(items.length); badge.className = items.length ? "badge" : "badge zero"; }
        var seen = load(), first = seen === null, now = {};
        var ok = supported() && Notification.permission === "granted";
        items.forEach(function (it) {
          now[it.id] = 1;
          if (!first && !seen[it.id] && ok) notify(it);
        });
        save(now);
      })
      .catch(function () {});
  }
  showState();
  poll();
  setInterval(poll, POLL);
})();
""" % (NOTIFY_POLL_SEC * 1000)

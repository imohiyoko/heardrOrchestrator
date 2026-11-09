"""tasks.db とログの読み取り(読み取り専用)、緊急通知の集計。"""

import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from .config import JOB_RE, SCHED_LOGS, STALL_MIN, TB_DB
from .sanitize import clean
from .herdr import agent_key, agent_session, cached, get_agents


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


NOTIFY_POLL_SEC = 15
NOTIFY_MAX = 100


def _short(s, n=200):
    s = clean("" if s is None else s).strip()
    return s[:n] + ("…" if len(s) > n else "")


def failed_jobs():
    """最後の実行(ran/failed/sent)が failed のジョブ。[(job, record)]。"""
    try:
        names = sorted(n[:-4] for n in os.listdir(SCHED_LOGS()) if n.endswith(".log") and JOB_RE.fullmatch(n[:-4]))
    except OSError:
        return []
    out = []
    for n in names:
        recs = parse_jsonl(tail_lines(os.path.join(SCHED_LOGS(), n + ".log"), 200))
        ran = [r for r in recs if r.get("action") in ("ran", "failed", "sent")]
        if ran and ran[-1].get("action") == "failed":
            out.append((n, ran[-1]))
    return out


def urgent_items():
    """10 分のまとめ送信を待たずに知らせるもの。各要素は通知 1 件(id は同じ事象なら同じ値)。

    値はすべて clean 済みのプレーンテキスト。href は常にこのサーバー内の絶対パス。
    """
    def load():
        comments, proxies, blocked = needs_human()
        items = []
        for c in comments:
            items.append({"id": f"c:{c['id']}", "kind": "comment_" + str(c["kind"]),
                          "label": "質問" if c["kind"] == "question" else "ブロック報告",
                          "title": _short(f"{c['task_id']} {c.get('task_title') or ''}", 80),
                          "body": _short(f"{c['from_name']}: {c['text']}"),
                          "href": "/tasks/" + quote(str(c["task_id"]), safe=""), "ts": clean(c.get("created_at") or "")})
        for r in proxies:
            items.append({"id": f"p:{r['id']}", "kind": "proxy_pending", "label": "代行依頼(人の判断待ち)",
                          "title": _short(f"{r['task_id']} {r.get('effect') or ''}", 80),
                          "body": _short(f"{r['cmd']} / 理由: {r['why']}"),
                          "href": "/tasks/" + quote(str(r["task_id"]), safe=""), "ts": clean(r.get("updated_at") or "")})
        for al in q("SELECT * FROM alerts WHERE status='analyzed' AND severity IN ('critical','high') ORDER BY id DESC LIMIT 50"):
            items.append({"id": f"r:{al['id']}:{clean(al.get('analyzed_at'))}", "kind": "alert_result",
                          "label": f"アラート解析結果({clean(al['severity'])})",
                          "title": _short(f"A-{al['id']} {al['title']}", 80),
                          "body": _short(f"{al.get('result_summary') or ''} / 全文: tb alerts A-{al['id']}(対応後に tb alert-close A-{al['id']})"),
                          "href": "/notifications", "ts": clean(al.get("analyzed_at") or "")})
        for al in q("SELECT * FROM alerts WHERE status='awaiting-approval' ORDER BY id DESC LIMIT 50"):
            items.append({"id": f"w:{al['id']}", "kind": "alert_approval", "label": "アラート(解析役の起動待ち)",
                          "title": _short(f"A-{al['id']} {al['title']}", 80),
                          "body": _short(f"{al.get('body') or ''} / 手元で tb alert-approve A-{al['id']}(今後も自動なら --always)"),
                          "href": "/notifications", "ts": clean(al.get("last_seen") or "")})
        for o in q("SELECT * FROM outbox WHERE status='pending' ORDER BY id DESC LIMIT 100"):
            items.append({"id": f"o:{o['id']}", "kind": "send_pending", "label": "送信の承認待ち",
                          "title": _short(f"O-{o['id']} {o['from_name']} → {o['target']} ({o['kind']})", 80),
                          "body": _short(f"{o['text']} / 手元で tb approve O-{o['id']}(今後も許可なら --always)か tb reject O-{o['id']}"),
                          "href": "/notifications", "ts": clean(o.get("created_at") or "")})
        agents, _ = get_agents()
        for a in blocked:
            k = agent_key(a)
            items.append({"id": "a:" + clean(k), "kind": "agent_blocked", "label": "承認待ちの agent",
                          "title": _short(k, 80), "body": _short(a.get("terminal_title_stripped") or a.get("terminal_title") or "人の対応待ち"),
                          "href": f"/agents/{quote(k, safe='')}#approval", "ts": ""})
        for a in agents:
            act = activity_for(a)
            if stalled(a, act):
                k = agent_key(a)
                items.append({"id": f"s:{clean(k)}:{clean(act.get('last_prompt_at'))}", "kind": "agent_stalled",
                              "label": f"滞留({STALL_MIN} 分超)", "title": _short(k, 80),
                              "body": _short(f"working のまま。最終入力 {act.get('last_prompt_at')}"),
                              "href": f"/agents/{quote(k, safe='')}", "ts": clean(act.get("last_prompt_at") or "")})
        for n, r in failed_jobs():
            items.append({"id": f"j:{n}:{clean(r.get('ts'))}", "kind": "job_failed", "label": "定期実行の失敗",
                          "title": n, "body": _short(r.get("reason") or "failed"),
                          "href": "/jobs/" + quote(n), "ts": clean(r.get("ts") or "")})
        return items[:NOTIFY_MAX]
    return cached("urgent", load)

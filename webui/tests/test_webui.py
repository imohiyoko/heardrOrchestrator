"""境界のテスト。herdr は疑似、DB・ログは一時ディレクトリ。実ポートは高位の小さな範囲だけ使い、必ず片付ける。"""
import atexit
import glob
import http.client
import json
import os
import random
import re
import signal
import hashlib
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(os.path.dirname(HERE), "server.py")
SCHEMA_DIR = os.path.join(os.path.dirname(os.path.dirname(HERE)), "taskboard", "schema")
TMP = tempfile.mkdtemp(prefix="webui-test-")
procs, socks = [], []
fails = []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(3)
            except subprocess.TimeoutExpired:
                p.kill()
    for s in socks:
        s.close()
    subprocess.run(["rm", "-rf", TMP])


atexit.register(cleanup)


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  [{detail}]" if not cond and detail else ""))
    if not cond:
        fails.append(name)


def occupy(port):
    s = socket.socket()
    s.bind(("127.0.0.1", port))
    s.listen(1)
    socks.append(s)
    return s


def free_range(n):
    for _ in range(200):
        base = random.randint(30000, 60000)
        try:
            ss = []
            for p in range(base, base + n):
                s = socket.socket()
                s.bind(("127.0.0.1", p))
                ss.append(s)
            for s in ss:
                s.close()
            return base
        except OSError:
            for s in ss:
                s.close()
    raise SystemExit("空きポート範囲が見つからない")


def make_env(name, **extra):
    d = os.path.join(TMP, name)
    os.makedirs(d, exist_ok=True)
    env = dict(os.environ)
    env.pop("TB_UI_PORT", None)
    env.update(
        WEBUI_FAIL_DELAY="0", HERDR_BIN=os.path.join(HERE, "fake", "herdr"), FAKE_HERDR_DIR=os.path.join(TMP, "fake"),
        WEBUI_RUN_DIR=os.path.join(d, "run"), WEBUI_TB_DB=os.path.join(d, "tasks.db"),
        WEBUI_SCHED_LOGS=os.path.join(d, "logs"), WEBUI_DISPATCH=os.path.join(d, "dispatch.jsonl"),
        WEBUI_SCHED_JOBS=os.path.join(d, "jobs"), WEBUI_SCHED_SETTINGS=os.path.join(d, "settings"))
    env.update(extra)
    return env, d


def start(env):
    p = subprocess.Popen([sys.executable, SERVER], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    procs.append(p)
    return p


def wait_port(env, p, timeout=5):
    pf = os.path.join(env["WEBUI_RUN_DIR"], "port")
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(pf):
            return int(open(pf).read())
        if p.poll() is not None:
            return None
        time.sleep(0.05)
    return None


def stop(p):
    p.send_signal(signal.SIGTERM)
    try:
        p.wait(3)
    except subprocess.TimeoutExpired:
        p.kill()


def req(port, method, path, cookie=None, host=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    h = {"Host": host or f"127.0.0.1:{port}"}
    if cookie:
        h["Cookie"] = cookie
    c.request(method, path, headers=h)
    r = c.getresponse()
    body = r.read().decode("utf-8", "replace")
    out = (r.status, dict(r.getheaders()), body)
    c.close()
    return out


# ---- fixtures
os.makedirs(os.path.join(TMP, "fake"))
XSS = "<script>alert(1)</script>"
agents = {"id": "x", "result": {"agents": [
    {"name": "alpha", "agent": "claude", "agent_status": "working", "pane_id": "w1:p1", "workspace_id": "w1", "cwd": TMP,
     "agent_session": {"kind": "id", "value": "11111111-2222-3333-4444-555555555555"},
     "terminal_title_stripped": "title " + XSS},
    {"name": "<img src=x onerror=alert(2)>", "agent": "claude", "agent_status": "blocked", "pane_id": "w1:p2",
     "workspace_id": "w1"},
    {"agent": "claude", "agent_status": "idle", "pane_id": "w1:p3", "workspace_id": "w1"},
]}}
json.dump(agents, open(os.path.join(TMP, "fake", "list.json"), "w"))
open(os.path.join(TMP, "fake", "read.txt"), "w").write(
    "\x1b[31mred\x1b[0m \x1b]0;evil title\x07" + XSS + "\x00\x08 end\r\n")


open(os.path.join(TMP, "fake", "dialog.txt"), "w").write(
    "\x1b[1mDo you want to run?\x1b[0m\n> rm -rf /tmp/x " + XSS + "\n  1. Yes\n  2. No\r\n")


def make_db(path):
    c = sqlite3.connect(path)
    # 本物のスキーマ(taskboard/schema/*.sql を tb と同じ順に流す)。手書きのスキーマは持たない
    for f in sorted(glob.glob(os.path.join(SCHEMA_DIR, "[0-9][0-9][0-9]_*.sql"))):
        c.executescript(open(f, encoding="utf-8").read())
        c.execute(f"PRAGMA user_version={int(os.path.basename(f)[:3])}")  # tb と同じく版を記録(tb が移行し直さない)
    c.execute("INSERT INTO tasks VALUES ('T-1','pj','題 " + XSS + "','alpha','11111111-2222-3333-4444-555555555555',"
              "NULL,'in_progress',NULL,'[\"a.md\"]',NULL,NULL,NULL,'2026-11-06T00:00:00Z','2026-11-06T00:00:00Z')")
    c.execute("INSERT INTO comments (task_id,kind,text,from_name,from_pane,from_session,created_at) VALUES "
              "('T-1','question','質問 " + XSS + "','alpha','w1:p1','s','2026-11-06T00:00:00Z')")
    c.execute("INSERT INTO agent_activity VALUES ('11111111-2222-3333-4444-555555555555','w1:p1',NULL,NULL,NULL,NULL,"
              "'2026-11-06T00:00:00Z',NULL,'2026-11-06T00:00:00Z')")
    c.commit()
    c.close()


# ================= ポート探索
base = free_range(3)
occupy(base)
env, _ = make_env("collide", HERDR_WEBUI_RANGE=f"{base}-{base + 2}")
p = start(env)
port = wait_port(env, p)
check("ポート衝突で +1", port == base + 1, f"port={port}")
if port:
    check("run/port に書く", open(os.path.join(env["WEBUI_RUN_DIR"], "port")).read().strip() == str(port))
stop(p)
check("終了時に run/port を消す", not os.path.exists(os.path.join(env["WEBUI_RUN_DIR"], "port")))

occupy(base + 1)
occupy(base + 2)
env, _ = make_env("full", HERDR_WEBUI_RANGE=f"{base}-{base + 2}")
p = start(env)
try:
    rc = p.wait(5)
except subprocess.TimeoutExpired:
    rc = None
check("全部埋まっていればエラー終了", rc not in (None, 0), f"rc={rc}")
check("エラー文に使用中と出る", "使用中" in (p.stderr.read() if rc else ""))

env, _ = make_env("fixed", TB_UI_PORT=str(base), HERDR_WEBUI_RANGE=f"{base}-{base + 2}")
p = start(env)
try:
    rc = p.wait(5)
except subprocess.TimeoutExpired:
    rc = None
check("TB_UI_PORT 固定は探索しない(使用中ならエラー)", rc not in (None, 0), f"rc={rc}")
for s in socks:
    s.close()
socks.clear()

# ================= 認証つき本体
USER, PW = "tester", "correct-horse-battery-9"
WRONG = "wrong-wrong-wrong-12"


class Client:
    def __init__(self, port):
        self.port, self.cookie = port, None

    def raw(self, method, path, data=None, origin="default", cookie="default", host=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Host": host or f"127.0.0.1:{self.port}"}
        ck = self.cookie if cookie == "default" else cookie
        if ck:
            h["Cookie"] = ck
        body = None
        if data is not None:
            body = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in data.items())
            h["Content-Type"] = "application/x-www-form-urlencoded"
        if origin == "default":
            origin = f"http://127.0.0.1:{self.port}" if method == "POST" else None
        if origin:
            h["Origin"] = origin
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        text = r.read().decode("utf-8", "replace")
        out = (r.status, dict(r.getheaders()), text)
        c.close()
        return out

    def get(self, path, **kw):
        return self.raw("GET", path, **kw)

    def csrf(self, path):
        m = re.search(r'name=csrf value="([^"]+)"', self.get(path)[2])
        return m.group(1) if m else ""

    def login(self, user=USER, pw=PW, next_=None, csrf=None, **kw):
        csrf = csrf if csrf is not None else self.csrf("/login")
        d = {"csrf": csrf, "username": user, "password": pw}
        if next_ is not None:
            d["next"] = next_
        r = self.raw("POST", "/login", d, **kw)
        m = re.match(r"([^;]+)", r[1].get("Set-Cookie", ""))
        if r[0] == 302 and m:
            self.cookie = m.group(1)
        return r


NOTIFY_TAG = '<script src="/notify.js" defer></script>'


def no_js(b):
    return b.replace(NOTIFY_TAG, "")


def mode(path):
    return oct(os.stat(path).st_mode & 0o777)


def stop_out(p):
    stop(p)
    return (p.stdout.read() or "") + (p.stderr.read() or "")


import urllib.parse  # noqa: E402

base = free_range(2)
env, d = make_env("main", HERDR_WEBUI_RANGE=f"{base}-{base + 1}", WEBUI_LOCK_SEC="3")
RUN = env["WEBUI_RUN_DIR"]
make_db(env["WEBUI_TB_DB"])
os.makedirs(env["WEBUI_SCHED_LOGS"])
os.makedirs(env["WEBUI_SCHED_JOBS"])
open(os.path.join(env["WEBUI_SCHED_JOBS"], "job1.conf"), "w").write(
    "COMMAND='echo hi'\nWINDOW=09:00-21:00\nINTERVAL_MIN=10\nTZ=Asia/Tokyo\n")
open(os.path.join(env["WEBUI_SCHED_LOGS"], "job1.log"), "w").write(
    json.dumps({"ts": "2026-11-06T12:00:00+0900", "job": "job1", "action": "ran", "reason": "exit 0", "exit": 0}) + "\n")
with open(env["WEBUI_DISPATCH"], "w") as f:
    for i in range(40):
        f.write(json.dumps({"ts": f"t{i:02d}", "action": "prompt", "target": "alpha", "prompt": "p" + XSS}) + "\n")
open(os.path.join(env["WEBUI_SCHED_LOGS"], "job2.log"), "w").write(
    json.dumps({"ts": "2026-11-06T11:00:00+0900", "job": "job2", "action": "ran", "reason": "exit 0"}) + "\n" +
    json.dumps({"ts": "2026-11-06T11:10:00+0900", "job": "job2", "action": "skipped", "reason": "busy"}) + "\n" +
    json.dumps({"ts": "2026-11-06T11:20:00+0900", "job": "job2", "action": "failed", "reason": "exit 3 " + XSS}) + "\n" +
    json.dumps({"ts": "2026-11-06T11:30:00+0900", "job": "job2", "action": "skipped", "reason": "window"}) + "\n")
_c = sqlite3.connect(env["WEBUI_TB_DB"])
_c.execute("INSERT INTO proxy_requests (task_id,cmd,why,effect,status,created_at,updated_at) VALUES "
           "('T-1','git push " + XSS + "','push したい','external','pending-human','2026-11-06T00:00:00Z','2026-11-06T00:00:00Z')")
_c.execute("INSERT INTO proxy_requests (task_id,cmd,why,effect,status,created_at,updated_at) VALUES "
           "('T-1','ls','見る','read-only','done','2026-11-06T00:00:00Z','2026-11-06T00:00:00Z')")
_c.commit()
_c.close()
# 旧方式の run/token が残っていても無視される
os.makedirs(RUN, exist_ok=True)
open(os.path.join(RUN, "token"), "w").write("legacy-token-legacy-token-legacy-token-0000\n")
p = start(env)
port = wait_port(env, p)
check("起動して port が分かる", port is not None)
cl = Client(port)
PAGES = ["/", "/notifications", "/agents", "/agents/alpha", "/tasks", "/tasks/T-1", "/inbox", "/jobs", "/ledger"]

# ---- 初回設定
for path in PAGES:
    r = cl.get(path)
    check(f"未設定: {path} は /setup へ 302", r[0] == 302 and r[1].get("Location") == "/setup", str(r[:2]))
check("未設定: /login は /setup へ", cl.get("/login")[1].get("Location") == "/setup")
check("run/token は作られない", open(os.path.join(RUN, "token")).read().startswith("legacy"))
r = cl.get("/setup")
check("GET /setup が 200 でフォーム", r[0] == 200 and "name=confirm" in r[2] and "<form" in r[2])
cs = cl.csrf("/setup")
check("Origin 不一致の /setup POST は拒否",
      cl.raw("POST", "/setup", {"csrf": cs, "username": USER, "password": PW, "confirm": PW}, origin="http://evil.example")[0] == 403)
check("Origin も Referer も無い POST は拒否",
      cl.raw("POST", "/setup", {"csrf": cs, "username": USER, "password": PW, "confirm": PW}, origin=None)[0] == 403)
check("CSRF トークン無しの /setup POST は拒否",
      cl.raw("POST", "/setup", {"username": USER, "password": PW, "confirm": PW})[0] == 403)
check("改ざん CSRF トークンは拒否",
      cl.raw("POST", "/setup", {"csrf": cs[:-1] + ("0" if cs[-1] != "0" else "1"), "username": USER, "password": PW,
                               "confirm": PW})[0] == 403)
check("パスワード 12 文字未満は拒否", cl.raw("POST", "/setup", {"csrf": cs, "username": USER, "password": "short-11-ch", "confirm": "short-11-ch"})[0] == 400)
check("確認入力の不一致は拒否", cl.raw("POST", "/setup", {"csrf": cs, "username": USER, "password": PW, "confirm": PW + "x"})[0] == 400)
check("拒否の間は auth.json が作られない", not os.path.exists(os.path.join(RUN, "auth.json")))
r = cl.raw("POST", "/setup", {"csrf": cs, "username": USER, "password": PW, "confirm": PW})
check("初回設定が成功(302 + Cookie)", r[0] == 302 and "Set-Cookie" in r[1], str(r[:2]))
ck = r[1].get("Set-Cookie", "")
check("Cookie が HttpOnly / SameSite=Strict / Path=/", "HttpOnly" in ck and "SameSite=Strict" in ck and "Path=/" in ck, ck.split("=")[0])
check("Cookie の有効期間が 12 時間", "Max-Age=43200" in ck, ck.split(";")[-1])
check("auth.json が 0600", mode(os.path.join(RUN, "auth.json")) == "0o600", mode(os.path.join(RUN, "auth.json")))
check("sessions.json が 0600", mode(os.path.join(RUN, "sessions.json")) == "0o600")
raw_auth = open(os.path.join(RUN, "auth.json")).read()
check("auth.json に平文パスワードを含まない", PW not in raw_auth)
aj = json.load(open(os.path.join(RUN, "auth.json")))
hrec = [v for v in aj.values() if isinstance(v, dict)][0]
check("scrypt・salt 16 バイト以上・パラメータを記録",
      hrec.get("algo") == "scrypt" and len(hrec["salt"]) >= 32 and all(k in hrec for k in ("n", "r", "p")))
check("/setup は以後 404(GET)", cl.get("/setup")[0] == 404)
check("/setup は以後 404(POST)", cl.raw("POST", "/setup", {"csrf": cs, "username": "x", "password": PW, "confirm": PW})[0] == 404)

# ---- 未ログイン
anon = Client(port)
for path in PAGES:
    r = anon.get(path)
    check(f"未ログイン: {path} は /login へ 302", r[0] == 302 and r[1]["Location"].startswith("/login?next="), str(r[:2]))
check("next に元の URL を渡す", anon.get("/tasks?project=pj")[1]["Location"] == "/login?next=%2Ftasks%3Fproject%3Dpj")
check("未ログインの未知 URL も /login へ", anon.get("/nope")[0] == 302)
check("GET /login が 200", anon.get("/login")[0] == 200)
check("不正な Host は 403", anon.get("/login", host="evil.example")[0] == 403)
check("?token= の経路がない(Cookie も出ない)",
      "Set-Cookie" not in anon.get("/?token=" + open(os.path.join(RUN, "token")).read().strip())[1])
check("旧 run/token の値では入れない", anon.get("/agents?token=legacy-token-legacy-token-legacy-token-0000")[0] == 302)
for path in ["/login", "/"]:
    check(f"ログイン画面に token の導線がない({path})", "token=" not in anon.get(path)[2].lower().replace("csrf", ""))

# ---- ログイン
check("CSRF トークン無しの /login は拒否", anon.raw("POST", "/login", {"username": USER, "password": PW})[0] == 403)
check("Origin 不一致の /login は拒否",
      anon.login(origin="http://evil.example")[0] == 403 and anon.cookie is None)
r = anon.login(user=USER, pw=WRONG)
check("誤ったパスワードで拒否(401・Cookie なし)", r[0] == 401 and anon.cookie is None and "Set-Cookie" not in r[1])
msg_pw = re.search(r"class=err>([^<]*)", r[2]).group(1)
r2 = anon.login(user="nobody", pw=PW)
msg_user = re.search(r"class=err>([^<]*)", r2[2]).group(1)
check("ユーザー名違いとパスワード違いでメッセージが同じ", msg_pw == msg_user and r2[0] == 401, f"{msg_pw}|{msg_user}")
check("エラー画面に入力値を戻さない", WRONG not in r[2] and PW not in r2[2])
# ロックアウト(ここまでで 2 回失敗、LOCK_MAX=5)
for _ in range(3):
    r = anon.login(user=USER, pw=WRONG)
check("5 回失敗でロック(正しいパスワードでも 429)", anon.login()[0] == 429 and anon.cookie is None)
check("429 に Retry-After", "Retry-After" in anon.login()[1])
time.sleep(3.3)
r = anon.login(next_="/tasks")
check("ロック時間の経過後にログインできる(next へ)", r[0] == 302 and r[1]["Location"] == "/tasks" and anon.cookie, str(r[:2]))
for ext in ["http://evil.example/x", "//evil.example/x", "https://evil.example", "/\\evil.example", "javascript:alert(1)"]:
    c2 = Client(port)
    r = c2.login(next_=ext)
    check(f"next に外部 URL({ext})を渡しても無視", r[0] == 302 and r[1]["Location"] == "/", r[1].get("Location", ""))
check("未ログインの next も外部 URL は無視",
      "evil" not in Client(port).get("/login?next=http%3A%2F%2Fevil.example%2F")[2])

# ---- ログイン後のページ
cl = Client(port)
cl.login()
sess_cookie = cl.cookie
cookie_val = sess_cookie.split("=", 1)[1]
sj = open(os.path.join(RUN, "sessions.json")).read()
check("sessions.json に Cookie 値そのものを含まない(ハッシュのみ)", cookie_val not in sj and hashlib.sha256(cookie_val.encode()).hexdigest() in sj)
check("sessions.json に有効期限(約 12 時間後)", any(abs(v - time.time() - 43200) < 60 for v in json.load(open(os.path.join(RUN, "sessions.json"))).values()))
check("sessions.json が 0600", mode(os.path.join(RUN, "sessions.json")) == "0o600")
check("ログイン済みで /login は元のページへ", cl.get("/login?next=/agents")[1].get("Location") == "/agents")

for path in PAGES:
    s_, h, b = cl.get(path)
    check(f"GET {path} が 200", s_ == 200, str(s_))
    # 入力欄(対応済みにする)があるページは自動更新しない
    check(f"{path}: 共通ナビ・meta refresh・バッジ",
          (('http-equiv="refresh"' in b) != ('action="/resolve"' in b)) and 'href="/ledger"' in b and 'class="badge"' in b, path)
    check(f"{path}: スクリプトは同一オリジンの notify.js だけ",
          re.findall(r"<script[^>]*>", b, re.I) == [NOTIFY_TAG[:-9]] and "<script" not in no_js(b).lower()
          and "<img" not in b.lower(), str(re.findall(r"<script[^>]*>", b, re.I)))
    check(f"{path}: 制御文字なし", not re.search("[\x00-\x08\x0b-\x1f\x1b]", b))
    check(f"{path}: ?token= の経路がない", "token=" not in b)

b = cl.get("/agents/alpha")[2]
check("エスケープされて表示", "&lt;script&gt;alert(1)&lt;/script&gt;" in b)
check("ANSI/OSC を除去(本文は残る)", "red" in b and "evil title" not in b and "\\x1b" not in b)
check("resume コマンドは出さず、使わないよう注意する", "claude --resume 1111" not in b and "claude --resume を実行しないでください" in b)
check("attach 欄にインラインのスクリプトがない", "onfocus" not in b)
check("名前に HTML を含む agent も安全", "&lt;img src=x onerror=alert(2)&gt;" in cl.get("/agents")[2])
check("pane_id フォールバックの URL", cl.get("/agents/w1%3Ap3")[0] == 200)
check("未知の agent は 404", cl.get("/agents/nope")[0] == 404)
check("未知のタスクは 404", cl.get("/tasks/nope")[0] == 404)
check("未知の URL は 404", cl.get("/nope")[0] == 404)
check("パストラバーサル風も 404", cl.get("/agents/..%2F..%2Fetc")[0] == 404)
inbox = cl.get("/inbox")[2]
check("承認待ちバッジの件数(question 1 + pending-human 1 + blocked agent 1)", '<span class="badge">3</span>' in inbox)

# ---- 緊急通知(/notifications・/api/notifications・/notify.js)
r = cl.get("/notifications")
check("GET /notifications が 200", r[0] == 200, str(r[0]))
nb = r[2]
for label in ("質問", "代行依頼", "承認待ちの agent", "滞留", "定期実行の失敗"):
    check(f"/notifications に {label}", label in nb)
check("/notifications: 通知ボタンと状態表示", "id=nenable" in nb and "id=nstate" in nb)
check("/notifications: 外部由来の値はエスケープ", "exit 3 &lt;script&gt;" in nb and "<script>alert" not in nb)
check("ナビに緊急通知バッジ(5 件)", '<span id=nbadge class="badge">5</span>' in inbox, re.findall(r"<span id=nbadge[^<]*<", inbox))
r = cl.get("/api/notifications")
check("/api/notifications が 200 JSON", r[0] == 200 and r[1].get("Content-Type", "").startswith("application/json"), str(r[:2]))
items = json.loads(r[2])["items"] if r[0] == 200 else []
ids = [it["id"] for it in items]
check("通知 id(報告・代行依頼・blocked・滞留・ジョブ失敗)",
      ids[:2] == ["c:1", "p:1"] and "a:<img src=x onerror=alert(2)>" in ids and "s:alpha:2026-11-06T00:00:00Z" in ids
      and "j:job2:2026-11-06T11:20:00+0900" in ids and len(ids) == 5, str(ids))
check("成功したジョブ・完了した代行依頼は通知しない", not any(i.startswith("j:job1") or i == "p:2" for i in ids))
check("href はすべてサーバー内の絶対パス", all(it["href"].startswith("/") and not it["href"].startswith("//") for it in items))
check("blocked の通知は承認待ちの内容へ", any(it["href"].endswith("#approval") for it in items if it["kind"] == "agent_blocked"))
check("通知の値に制御文字なし", not any(re.search("[\x00-\x08\x0b-\x1f\x1b]", str(v)) for it in items for v in it.values()))
check("/api/notifications も Host 検査", cl.get("/api/notifications", host="evil.example")[0] == 403)
r = Client(port).get("/api/notifications")
check("未ログインの /api/notifications は 401(リダイレクトせず中身も出さない)",
      r[0] == 401 and "Location" not in r[1] and "質問" not in r[2] and "alpha" not in r[2], str(r[:2]))
check("無効な Cookie の /api/notifications も 401", Client(port).get("/api/notifications", cookie="herdr_webui_session=nope")[0] == 401)
check("POST /api/notifications は 405", cl.raw("POST", "/api/notifications", {"a": "b"})[0] == 405)
# 送信の承認待ち(tb send が approvals.conf で ask になったもの)
_c = sqlite3.connect(env["WEBUI_TB_DB"])
_c.executescript("INSERT INTO outbox (from_name,from_pane,from_session,target,kind,text,status,created_at) VALUES ('conductor','w0:p1','s','w1','task','調べて <b>x</b>','pending','t');"
                 "INSERT INTO outbox (from_name,from_pane,from_session,target,kind,text,status,created_at) VALUES ('conductor','w0:p1','s','w1','task','済','sent','t');")
_c.commit(); _c.close()
time.sleep(3.2)  # 通知のキャッシュ切れを待つ
r = cl.get("/api/notifications")
_it = [it for it in json.loads(r[2])["items"] if it["id"].startswith("o:")] if r[0] == 200 else []
check("送信の承認待ちが通知に出る(承認コマンド付き)", [it["id"] for it in _it] == ["o:1"] and "tb approve O-1" in _it[0]["body"], str(_it))
check("送信の承認待ちは /notifications でエスケープ", "&lt;b&gt;x&lt;/b&gt;" in cl.get("/notifications")[2])
_c = sqlite3.connect(env["WEBUI_TB_DB"])
_c.executescript("INSERT INTO alerts (fingerprint,source,first_seen,last_seen,severity,title,status,result_summary,analyzed_at) VALUES ('f1','watch','t0','t0','critical','API <i>5xx</i>','analyzed','設定漏れ','t1');"
                 "INSERT INTO alerts (fingerprint,source,first_seen,last_seen,severity,title,status,result_summary,analyzed_at) VALUES ('f2','watch','t0','t0','low','軽微','analyzed','誤報','t2');"
                 "INSERT INTO alerts (fingerprint,source,first_seen,title,status,body,last_seen) VALUES ('f3','watch','t0','ディスク','awaiting-approval','80%','t3');"
                 "INSERT INTO alerts (fingerprint,source,first_seen,last_seen,title,status) VALUES ('f4','watch','t0','t0','解析中','analyzing');")
_c.commit(); _c.close()
time.sleep(3.2)
_ids = [it["id"] for it in json.loads(cl.get("/api/notifications")[2])["items"] if it["id"][:2] in ("r:", "w:")]
check("アラート: critical/high の解析結果と起動待ちだけ通知", _ids == ["r:1:t1", "w:3"], str(_ids))
check("アラート: 題名はエスケープ", "API &lt;i&gt;5xx&lt;/i&gt;" in cl.get("/notifications")[2])
r = cl.get("/notify.js")
check("/notify.js が 200 の JavaScript", r[0] == 200 and r[1].get("Content-Type", "").startswith("text/javascript")
      and "Notification" in r[2] and "/api/notifications" in r[2], str(r[:2]))
check("/notify.js は innerHTML を使わない", "innerHTML" not in r[2] and "eval(" not in r[2])
check("未ログインの /notify.js は /login へ", Client(port).get("/notify.js")[0] == 302)
csp = r[1].get("Content-Security-Policy", "")
check("CSP は script-src 'self' / connect-src 'self' だけを足す(インラインスクリプト不可)",
      "default-src 'none'" in csp and "script-src 'self';" in csp and "connect-src 'self';" in csp
      and "unsafe-inline'; base-uri" in csp and csp.count("unsafe-inline") == 1, csp)
check("CORP same-origin", r[1].get("Cross-Origin-Resource-Policy") == "same-origin")
if subprocess.run(["which", "node"], capture_output=True).returncode == 0:
    jsf = os.path.join(TMP, "notify.js")
    open(jsf, "w").write(r[2])
    check("notify.js の構文(node --check)", subprocess.run(["node", "--check", jsf], capture_output=True).returncode == 0)
check("台帳は直近 30 件", cl.get("/ledger")[2].count("<tr>") == 31)
check("定期実行が出る", "job1" in cl.get("/jobs")[2])

# ---- 定期実行の設定(Web UI から変更できる唯一の操作)
SET = os.path.join(env["WEBUI_SCHED_SETTINGS"], "job1.settings")
check("一覧に実際の間隔が出る", "10 分おき / 09:00-21:00 / daily" in cl.get("/jobs")[2])
r = cl.get("/jobs/job1")
check("設定フォームが出る(自動更新しない)", r[0] == 200 and 'name=interval ' in r[2] and 'name=interval_unit' in r[2] and 'http-equiv="refresh"' not in r[2])
check("未知のジョブは 404", cl.get("/jobs/nope")[0] == 404 and cl.raw("POST", "/jobs/nope", {"csrf": cl.csrf("/jobs/job1")})[0] == 404)
good = {"action": "save", "interval_min": "15", "start": "10:00", "end": "18:00", "days": "weekdays", "enabled": "1"}
check("CSRF 無しの設定 POST は拒否", cl.raw("POST", "/jobs/job1", good)[0] == 403 and not os.path.exists(SET))
check("Origin 不一致の設定 POST は拒否",
      cl.raw("POST", "/jobs/job1", {**good, "csrf": cl.csrf("/jobs/job1")}, origin="http://evil.example")[0] == 403)
check("未ログインの設定 POST は /login へ", Client(port).raw("POST", "/jobs/job1", good)[0] == 302 and not os.path.exists(SET))
check("ログイン画面の CSRF(anon)は使えない", cl.raw("POST", "/jobs/job1", {**good, "csrf": cl.csrf("/login")})[0] == 403)
r = cl.raw("POST", "/jobs/job1", {**good, "csrf": cl.csrf("/jobs/job1")})
check("保存すると 302 で戻る", r[0] == 302 and r[1].get("Location") == "/jobs/job1?saved=1", str(r[:2]))
body = open(SET).read() if os.path.exists(SET) else ""
check("settings に書かれる(0600)", "INTERVAL_MIN=15" in body and "DAYS=weekdays" in body and "ENABLED=1" in body
      and mode(SET) == "0o600", body)
check("一覧に反映", "15 分おき / 10:00-18:00 / weekdays" in cl.get("/jobs")[2])
for bad, label in ((dict(interval_min="0"), "間隔 0"), (dict(interval_min="5; rm"), "間隔に記号"),
                   (dict(start="25:00"), "開始が範囲外"), (dict(start="19:00"), "開始が終了より後"),
                   (dict(days="$(id)"), "曜日が不正"), (dict(days="custom"), "曜日を 1 つも選ばない"),
                   (dict(start="10:00\nCOMMAND=x"), "改行の注入")):
    r = cl.raw("POST", "/jobs/job1", {**good, **bad, "csrf": cl.csrf("/jobs/job1")})
    check(f"不正な入力は 400 で書かない: {label}", r[0] == 400 and open(SET).read() == body, str(r[0]))
r = cl.raw("POST", "/jobs/job1", {**good, "days": "custom", "day_mon": "1", "day_fri": "1", "enabled": "",
                                  "csrf": cl.csrf("/jobs/job1")})
check("曜日指定と一時停止", r[0] == 302 and "DAYS=Mon Fri" in open(SET).read() and "ENABLED=0" in open(SET).read())
check("一時停止が一覧に出る", "一時停止" in cl.get("/jobs")[2])
# 秒単位の間隔・時刻
r = cl.raw("POST", "/jobs/job1", {**good, "interval": "30", "interval_unit": "sec", "start": "10:00:15", "end": "10:30",
                                  "csrf": cl.csrf("/jobs/job1")})
sb = open(SET).read()
check("秒の間隔を保存", r[0] == 302 and "INTERVAL_SEC=30" in sb and "INTERVAL_MIN" not in sb and "START=10:00:15" in sb, sb)
check("一覧に秒の間隔", "30 秒おき / 10:00:15-10:30 / weekdays" in cl.get("/jobs")[2])
f = cl.get("/jobs/job1")[2]
check("フォームに秒の値と単位", 'value="30"' in f and "<option value=sec selected>" in f and 'value="10:00:15"' in f)
r = cl.raw("POST", "/jobs/job1", {**good, "interval": "2", "interval_unit": "min", "csrf": cl.csrf("/jobs/job1")})
check("分の間隔で保存し直すと INTERVAL_MIN", r[0] == 302 and "INTERVAL_MIN=2" in open(SET).read()
      and "INTERVAL_SEC" not in open(SET).read())
sb = open(SET).read()
for bad, label in ((dict(interval="86401", interval_unit="sec"), "秒の上限超え"), (dict(interval="5", interval_unit="hour"), "単位が不正"),
                   (dict(start="10:00:60"), "秒が範囲外"), (dict(start="18:00:30", end="18:00:10"), "開始が終了より後(秒)")):
    r = cl.raw("POST", "/jobs/job1", {**good, **bad, "csrf": cl.csrf("/jobs/job1")})
    check(f"不正な入力は 400 で書かない: {label}", r[0] == 400 and open(SET).read() == sb, str(r[0]))
r = cl.raw("POST", "/jobs/job1", {**good, "start": "18:00:30", "end": "18:00", "csrf": cl.csrf("/jobs/job1")})
check("終了 HH:MM はその分の 59 秒までなので 18:00:30-18:00 は可", r[0] == 302, str(r[0]))
r = cl.raw("POST", "/jobs/job1", {"action": "reset", "csrf": cl.csrf("/jobs/job1")})
check("conf の値に戻すと settings を消す", r[0] == 302 and not os.path.exists(SET) and "10 分おき" in cl.get("/jobs")[2])
check("tasks のフィルタ", "T-1" in cl.get("/tasks?project=pj&status=in_progress")[2] and "T-1" not in cl.get("/tasks?status=done")[2])
check("フィルタ値の XSS", "<script>" not in cl.get("/tasks?project=%3Cscript%3E")[2])

# 承認待ちの内容(表示とコマンドのみ)
bl = cl.get("/agents/%3Cimg%20src%3Dx%20onerror%3Dalert(2)%3E")
check("blocked の詳細に承認待ちの内容が出る", bl[0] == 200 and "承認待ちの内容" in bl[2] and "Do you want to run?" in bl[2])
check("ダイアログ内容がエスケープされ ANSI が除かれる",
      "rm -rf /tmp/x &lt;script&gt;alert(1)&lt;/script&gt;" in bl[2] and "[1m" not in bl[2] and "<script" not in no_js(bl[2]).lower())
check("手元で開くコマンド(readonly 入力)", "readonly" in bl[2] and "herdr agent attach &#x27;&lt;img" in bl[2])
check("場所(workspace ラベル / tab / pane)", "ws-label" in bl[2] and "w1:p2" in bl[2])
idle = cl.get("/agents/w1%3Ap3")
check("idle には承認待ちの内容が出ない", "承認待ちの内容" not in idle[2] and "Do you want to run?" not in idle[2])
check("名前なしは pane_id で attach", "herdr agent attach w1:p3" in idle[2])
check("フォームはログアウトだけ(承認・send-keys のボタンなし)",
      re.findall(r"<form[^>]*action=\"([^\"]+)\"", bl[2]) == ["/logout"] and bl[2].lower().count("<button") == 1)
check("inbox の blocked 行から詳細へリンク", "#approval" in inbox)

# ---- 報告を対応済みにする(/resolve。書き込みは tb resolve が行う)
ib = cl.get("/inbox")[2]
check("inbox に「対応済みにする」(C-1)", 'action="/resolve"' in ib and 'name=id value="1"' in ib)
check("タスク画面にも「対応済みにする」", 'action="/resolve"' in cl.get("/tasks/T-1")[2])
good = {"id": "1", "note": "決めた <b>x</b>", "back": "/inbox"}
check("CSRF 無しの /resolve は拒否", cl.raw("POST", "/resolve", good)[0] == 403)
check("Origin 不一致の /resolve は拒否", cl.raw("POST", "/resolve", {**good, "csrf": cl.csrf("/inbox")}, origin="http://evil.example")[0] == 403)
check("未ログインの /resolve は /login へ", Client(port).raw("POST", "/resolve", good)[0] == 302)
check("ログイン画面の CSRF(anon)は使えない", cl.raw("POST", "/resolve", {**good, "csrf": cl.csrf("/login")})[0] == 403)
check("id が数字でなければ 400", cl.raw("POST", "/resolve", {**good, "id": "1;x", "csrf": cl.csrf("/inbox")})[0] == 400)
r = cl.raw("POST", "/resolve", {**good, "csrf": cl.csrf("/inbox")})
check("対応済みにすると inbox へ戻る", r[0] == 302 and r[1].get("Location") == "/inbox?resolved=done", str(r[:2]))
_c = sqlite3.connect(env["WEBUI_TB_DB"])
_row = _c.execute("SELECT resolved_at IS NOT NULL, resolved_note FROM comments WHERE id=1").fetchone()
_c.close()
check("tb resolve で DB に記録(メモも)", _row == (1, "決めた <b>x</b>"), str(_row))
time.sleep(3.2)  # needs_human のキャッシュ切れを待つ
ib = cl.get("/inbox?resolved=done")[2]
check("対応済みは要対応から消え、バッジが減る", '<span class="badge">2</span>' in ib and 'name=id value="1"' not in ib)
check("結果の表示と、メモのエスケープ", "対応済みにしました" in ib and "決めた &lt;b&gt;x&lt;/b&gt;" in cl.get("/tasks/T-1")[2])
check("緊急通知からも消える", "c:1" not in [it["id"] for it in json.loads(cl.get("/api/notifications")[2])["items"]])
r = cl.raw("POST", "/resolve", {**good, "back": "//evil.example/x", "csrf": cl.csrf("/inbox")})
check("2 回目は already、戻り先は自サイトだけ", r[0] == 302 and r[1].get("Location") == "/inbox?resolved=already", str(r[:2]))
r = cl.raw("POST", "/resolve", {"id": "999", "back": "/tasks/T-1", "csrf": cl.csrf("/inbox")})
check("存在しない報告は error", r[0] == 302 and r[1].get("Location") == "/tasks/T-1?resolved=error", str(r[:2]))

# ---- agent の停止・復活・新規作成(/agent-op /agent-new。書き込みは tb agent-* が行う)
FLOG = os.path.join(TMP, "fake", "log")


def flog():
    return open(FLOG).read() if os.path.exists(FLOG) else ""


def regdb(sql, args=()):
    c = sqlite3.connect(env["WEBUI_TB_DB"])
    try:
        r = c.execute(sql, args).fetchall()
        c.commit()
        return r
    finally:
        c.close()


ag = cl.get("/agents")[2]
check("agent 一覧に停止のボタンと新規作成へのリンク", 'action="/agent-op"' in ag and 'href="/agent-new"' in ag)
check("未判定・未完了タスクありは確認つきの強制停止", 'value="force-stop"' in ag and "name=confirm" in ag and 'value="stop"' not in ag)
good_op = {"op": "force-stop", "name": "alpha", "confirm": "1"}
check("CSRF 無しの /agent-op は拒否", cl.raw("POST", "/agent-op", good_op)[0] == 403)
check("Origin 不一致の /agent-op は拒否", cl.raw("POST", "/agent-op", {**good_op, "csrf": cl.csrf("/agents")}, origin="http://evil.example")[0] == 403)
check("未ログインの /agent-op は /login へ", Client(port).raw("POST", "/agent-op", good_op)[0] == 302)
check("名前が不正なら 400", cl.raw("POST", "/agent-op", {**good_op, "name": "a;b", "csrf": cl.csrf("/agents")})[0] == 400)
check("不明な op は 400", cl.raw("POST", "/agent-op", {**good_op, "op": "rm", "csrf": cl.csrf("/agents")})[0] == 400)
r = cl.raw("POST", "/agent-op", {"op": "stop", "name": "alpha", "csrf": cl.csrf("/agents")})
check("印の無い agent の通常停止は断る", r[0] == 302 and r[1].get("Location") == "/agents?op=refused" and "pane close" not in flog(), str(r[:2]))
r = cl.raw("POST", "/agent-op", {"op": "force-stop", "name": "alpha", "csrf": cl.csrf("/agents")})
check("強制停止は確認のチェックが要る", r[0] == 302 and r[1].get("Location") == "/agents?op=refused" and "pane close" not in flog())
r = cl.raw("POST", "/agent-op", {**good_op, "csrf": cl.csrf("/agents")})
check("強制停止で pane を閉じる", r[0] == 302 and r[1].get("Location") == "/agents?op=done" and "pane close w1:p1" in flog(), str(r[:2]) + flog())
check("台帳に会話が残る", regdb("SELECT state, session_id FROM agents WHERE name='alpha'") == [("stopped", "11111111-2222-3333-4444-555555555555")])
time.sleep(3.2)  # agent list のキャッシュ切れを待つ
ag = cl.get("/agents?op=done")[2]
check("結果の表示と、停止中の一覧・復活ボタン", "実行しました" in ag and "停止中の agent" in ag and 'value="revive"' in ag and 'value="revive-fresh"' in ag)
check("直近の操作に human の記録", "alpha" in ag and "human" in ag)
r = cl.raw("POST", "/agent-op", {"op": "revive", "name": "alpha", "csrf": cl.csrf("/agents")})
check("同じ会話で復活(claude --resume)", r[0] == 302 and r[1].get("Location") == "/agents?op=done"
      and "agent start alpha --kind claude --pane w9:p1 -- --resume 11111111-2222-3333-4444-555555555555" in flog(), str(r[:2]) + flog())
nw = cl.get("/agent-new")
check("新規作成フォーム(自動更新なし・役割の候補)", nw[0] == 200 and 'action="/agent-new"' in nw[2] and 'http-equiv="refresh"' not in nw[2]
      and '<option value="worker">' in nw[2] and '<option value="_common">' not in nw[2])
check("CSRF 無しの /agent-new は拒否", cl.raw("POST", "/agent-new", {"name": "newbie"})[0] == 403)
r = cl.raw("POST", "/agent-new", {"name": "Bad<b>", "csrf": cl.csrf("/agent-new")})
check("不正な名前はフォームに戻してエラー(エスケープ)", r[0] == 400 and "英小文字" in r[2] and "Bad&lt;b&gt;" in r[2] and "Bad<b>" not in r[2])
r = cl.raw("POST", "/agent-new", {"name": "newbie", "cwd": "relative/dir", "csrf": cl.csrf("/agent-new")})
check("相対パスの cwd は断る", r[0] == 400 and "絶対パス" in r[2])
r = cl.raw("POST", "/agent-new", {"name": "newbie", "cwd": "/no/such/dir", "csrf": cl.csrf("/agent-new")})
check("存在しない cwd は tb のエラーを見せる", r[0] == 400 and "ディレクトリがありません" in r[2], r[2][-400:])
r = cl.raw("POST", "/agent-new", {"name": "newbie", "cwd": TMP, "model": "haiku", "role": "worker", "killable": "yes",
                                  "prompt": "最初の指示", "csrf": cl.csrf("/agent-new")})
check("新しい agent を作る", r[0] == 302 and r[1].get("Location") == "/agents?op=done"
      and "--label newbie" in flog() and "agent start newbie --kind claude --pane w9:p1 -- --model haiku" in flog()
      and "agent prompt newbie [from: tb / agent / human] 最初の指示" in flog(), str(r[:2]) + flog())
check("台帳に役割と印", regdb("SELECT role, killable, created_by FROM agents WHERE name='newbie'") == [("worker", "yes", "human")])
regdb("INSERT INTO agent_ops (op, target, args, requested_by, status, created_at) VALUES ('new','helper','{\"cwd\":\"" + TMP + "\"}','conductor','pending','2026-11-10T00:00:00Z')")
lid = regdb("SELECT max(id) FROM agent_ops")[0][0]
time.sleep(3.2)
ag = cl.get("/agents")[2]
check("承認待ちの操作に承認・却下のボタン", f'name=id value="{lid}"' in ag and 'value="approve"' in ag and 'value="reject"' in ag)
check("緊急通知にも出る", f"l:{lid}" in [it["id"] for it in json.loads(cl.get("/api/notifications")[2])["items"]])
check("id が数字でなければ 400", cl.raw("POST", "/agent-op", {"op": "approve", "id": "1;x", "csrf": cl.csrf("/agents")})[0] == 400)
r = cl.raw("POST", "/agent-op", {"op": "approve", "id": str(lid), "csrf": cl.csrf("/agents")})
check("承認すると実行する", r[0] == 302 and r[1].get("Location") == "/agents?op=done" and "--label helper" in flog(), str(r[:2]))
check("記録は依頼者のまま done", regdb("SELECT status, requested_by FROM agent_ops WHERE id=?", (lid,)) == [("done", "conductor")])
r = cl.raw("POST", "/agent-op", {"op": "reject", "id": str(lid), "csrf": cl.csrf("/agents")})
check("済んだものは却下できない", r[0] == 302 and r[1].get("Location") == "/agents?op=refused", str(r[:2]))
os.remove(os.path.join(TMP, "fake", "closed"))
# ---- ドキュメント(agent が成果物として報告したローカルのファイル)
DOCS = os.path.join(d, "work")
os.makedirs(os.path.join(DOCS, "out", "sub"), exist_ok=True)
os.makedirs(os.path.join(d, "home", ".ssh"), exist_ok=True)
open(os.path.join(DOCS, "summary.md"), "w").write(
    "# まとめ " + XSS + "\n\n- 項目 **太字** と `code`\n- [リンク](https://example.com/a?b=1&c=2)\n- [危険](javascript:alert(1))\n\n"
    "| 列1 | 列2 |\n|---|---|\n| a | <b>b</b> |\n\n```\n<script>x</script>\n```\n")
open(os.path.join(DOCS, "out", "sub", "note.txt"), "w").write("内側のファイル " + XSS)
open(os.path.join(d, "outside.txt"), "w").write("外のファイル")
os.symlink(os.path.join(d, "outside.txt"), os.path.join(DOCS, "out", "link.txt"))
open(os.path.join(DOCS, ".env"), "w").write("SECRET=1")
open(os.path.join(d, "home", ".ssh", "id_ed25519"), "w").write("PRIVATE")
open(os.path.join(DOCS, "bin.dat"), "wb").write(b"\x00\x01\x02")
_c = sqlite3.connect(env["WEBUI_TB_DB"])
_c.execute("INSERT INTO agent_activity (session_id,cwd,updated_at) VALUES ('sess-w',?, '2026-11-06T00:00:00Z')", (DOCS,))
_dl = json.dumps(["summary.md", os.path.join(DOCS, "out"), ".env", os.path.join(d, "home", ".ssh", "id_ed25519"),
                  "bin.dat", "gone.md", "https://example.com/pr/1", os.path.join(d, "outside.txt") + "/../" + "outside.txt"])
_c.execute("INSERT INTO comments (task_id,kind,text,deliverables,from_name,from_pane,from_session,created_at) VALUES "
           "('T-1','done','終わり',?,'alpha','w1:p1','sess-w','2026-11-07T00:00:00Z')", (_dl,))
_cid = _c.execute("SELECT max(id) FROM comments").fetchone()[0]
_c.execute("INSERT INTO alerts (fingerprint,title,source,status,result_summary,result_report,result_path,result_by,first_seen,last_seen,analyzed_at) "
           "VALUES ('f','障害 " + XSS + "','cli','analyzed','要約','## 原因\n\nDB の本文','/nonexistent/report.md','analyst','t','t','2026-11-08T00:00:00Z')")
_aid = _c.execute("SELECT max(id) FROM alerts").fetchone()[0]
_c.commit()
_c.close()
s_, _, b = cl.get("/docs")
check("GET /docs が 200 で一覧", s_ == 200 and "summary.md" in b and f"ref=C-{_cid}%2F0" in b and f"ref=A-{_aid}" in b, str(s_))
check("/docs: ナビにドキュメント・入力欄があるので自動更新しない", 'href="/docs"' in b and 'http-equiv="refresh"' not in b)
check("/docs: 状態(あり/フォルダ/なし/非表示/URL/DB に本文)",
      all(x in b for x in ("あり", "フォルダ", "なし", "非表示", "URL", "DB に本文")))
check("/docs: XSS がエスケープ", "<script" not in no_js(b).lower())
check("/docs?q= で絞り込み", "summary.md" in cl.get("/docs?q=summary")[2] and "summary.md" not in cl.get("/docs?q=zzzz")[2])
V = lambda ref, **kw: cl.get("/docs/view?" + urllib.parse.urlencode({"ref": ref, **kw}))  # noqa: E731
s_, _, b = V(f"C-{_cid}/0")
check("相対パスは agent の作業ディレクトリ基準で開ける", s_ == 200 and "<div class=doc>" in b, str(s_))
check("Markdown を整形(見出し・太字・code・表)",
      "<h2 class=md>まとめ &lt;script&gt;" in b and "<strong>太字</strong>" in b and "<code>code</code>" in b and "<th>列1</th>" in b)
check("Markdown: http(s) だけリンクにし、javascript: はリンクにしない",
      'href="https://example.com/a?b=1&amp;c=2"' in b and 'href="javascript' not in b.lower())
check("Markdown: 生 HTML とコードブロックはエスケープ", "&lt;b&gt;b&lt;/b&gt;" in b and "&lt;script&gt;x&lt;/script&gt;" in b
      and "<script" not in no_js(b).lower())
check("文書ページは自動更新しない", 'http-equiv="refresh"' not in b)
check("元のテキスト表示", "<pre># まとめ &lt;script&gt;" in V(f"C-{_cid}/0", raw="1")[2])
b = V(f"C-{_cid}/1")[2]
check("フォルダは中身の一覧(外を指すリンクは出さない)", "sub/note.txt" in b and "link.txt" not in b)
check("フォルダ内のファイルを開ける", "内側のファイル &lt;script&gt;" in V(f"C-{_cid}/1", sub="sub/note.txt")[2])
check("フォルダの外へは出られない(.. / 絶対パス / リンク)",
      all(V(f"C-{_cid}/1", sub=x)[0] == 404 for x in ("../summary.md", "/etc/passwd", "link.txt", "../../outside.txt")))
check(".env は開かない", "認証情報" in V(f"C-{_cid}/2")[2] and "SECRET" not in V(f"C-{_cid}/2")[2])
check(".ssh の鍵は開かない", "PRIVATE" not in V(f"C-{_cid}/3")[2] and "認証情報" in V(f"C-{_cid}/3")[2])
check("バイナリは表示しない", "テキストではない" in V(f"C-{_cid}/4")[2])
check("無いファイルは見つからないと出す", "見つかりません" in V(f"C-{_cid}/5")[2])
check("URL の成果物は外部リンク", 'href="https://example.com/pr/1"' in V(f"C-{_cid}/6")[2])
b = V(f"A-{_aid}")[2]
check("アラートの解析レポートは DB の本文を出す", "DB の本文" in b and "<h3 class=md>原因</h3>" in b and "&lt;script&gt;" in b)
check("登録されていない参照は 404", all(V(x)[0] == 404 for x in (f"C-{_cid}/99", "C-99999/0", "task:nope/0", "T-1/0", "A-99999", "/etc/passwd", "")))
# パスを指定して開く(agent の作業ディレクトリ配下だけ)
check("/docs に開ける範囲(agent の作業ディレクトリ)が出る", f"<code>{DOCS}</code>" in cl.get("/docs")[2])
b = V("", path=os.path.join(DOCS, "summary.md"))[2]
check("作業ディレクトリ配下のパスは開ける(Markdown 整形)", "<div class=doc>" in b and "<strong>太字</strong>" in b)
check("パス指定でもフォルダの中を開ける", "内側のファイル" in V("", path=os.path.join(DOCS, "out"), sub="sub/note.txt")[2])
for bad in ("/etc/passwd", os.path.join(d, "outside.txt"), os.path.join(DOCS, "out", "link.txt"), os.path.join(DOCS, "..", "outside.txt"),
            "summary.md", "~"):
    b = V("", path=bad)[2]
    check(f"範囲外・相対は開けない: {bad}", "開けません" in b or "絶対パス" in b, bad)
check("パス指定でも .env は開かない", "SECRET" not in V("", path=os.path.join(DOCS, ".env"))[2])
# Mermaid(同梱の mermaid.js でブラウザが描く)
open(os.path.join(DOCS, "flow.md"), "w").write("# 図\n\n```mermaid\ngraph TD\n  A[" + XSS + "] --> B\n```\n")
open(os.path.join(DOCS, "seq.mmd"), "w").write("sequenceDiagram\n  A->>B: hi\n")
b = V("", path=os.path.join(DOCS, "flow.md"))[2]
check("```mermaid は pre.mermaid(中身はエスケープ)", "<pre class=mermaid>graph TD\n  A[&lt;script&gt;" in b)
check("Mermaid があるページだけ同梱 JS を読む", '<script src="/static/mermaid.min.js" defer>' in b and '<script src="/docs.js" defer>' in b
      and "/static/mermaid.min.js" not in V("", path=os.path.join(DOCS, "summary.md"))[2])
check(".mmd も図にする", "<pre class=mermaid>sequenceDiagram" in V("", path=os.path.join(DOCS, "seq.mmd"))[2])
s_, h, b = cl.get("/static/mermaid.min.js")
check("同梱の mermaid.min.js を同一オリジンから配る", s_ == 200 and h.get("Content-Type", "").startswith("text/javascript") and len(b) > 100000)
check("未ログインでは同梱 JS も読めない", Client(port).get("/static/mermaid.min.js")[0] == 302 and Client(port).get("/docs.js")[0] == 302)
check("static の他のファイルは出さない", cl.get("/static/mermaid.LICENSE")[0] == 404 and cl.get("/static/../app/docs.py")[0] == 404)
b = cl.get("/tasks/T-1")[2]
check("タスク画面の成果物が Web UI へのリンクになる", f'href="/docs/view?ref=C-{_cid}%2F0"' in b and f'href="/docs/view?ref=task%3AT-1%2F0"' in b)

# ---- 他のメソッド
for method in ("POST", "PUT", "DELETE", "PATCH"):
    for path in ("/inbox", "/agents/alpha", "/tasks"):
        check(f"{method} {path} は 405", cl.raw(method, path, {"a": "b"} if method == "POST" else None)[0] == 405)
check("未ログインでも他の POST は 405", Client(port).raw("POST", "/inbox", {"a": "b"})[0] == 405)
check("PUT /login も 405", cl.raw("PUT", "/login")[0] == 405)
check("GET /logout は 405", cl.get("/logout")[0] == 405)

# ---- サーバー再起動後もセッションが続く
out1 = stop_out(p)
p = start(env)
port2 = wait_port(env, p)
cl2 = Client(port2)
cl2.cookie = sess_cookie
check("再起動後も同じセッションで入れる", cl2.get("/inbox")[0] == 200)
check("再起動後は /setup が 404 のまま", cl2.get("/setup")[0] == 404)

# ---- 期限切れセッション
sess_path = os.path.join(RUN, "sessions.json")
d_ = json.load(open(sess_path))
h_ = hashlib.sha256(cookie_val.encode()).hexdigest()
d_[h_] = time.time() - 1
json.dump(d_, open(sess_path, "w"))
r = cl2.get("/inbox")
check("期限切れセッションは /login へ", r[0] == 302 and r[1]["Location"].startswith("/login"), str(r[:2]))
check("不明なセッション値は /login へ", Client(port2).get("/inbox", cookie="herdr_webui_session=nope")[0] == 302)

# ---- logout
cl3 = Client(port2)
cl3.login()
old = cl3.cookie
tok = cl3.csrf("/inbox")
check("CSRF 無しの logout は拒否(セッションは残る)", cl3.raw("POST", "/logout", {})[0] == 403 and cl3.get("/inbox")[0] == 200)
check("Origin 不一致の logout は拒否", cl3.raw("POST", "/logout", {"csrf": tok}, origin="http://evil.example")[0] == 403 and cl3.get("/inbox")[0] == 200)
tok = cl3.csrf("/inbox")
r = cl3.raw("POST", "/logout", {"csrf": tok})
check("logout は 302 /login で Cookie を消す", r[0] == 302 and r[1]["Location"] == "/login" and "Max-Age=0" in r[1].get("Set-Cookie", ""))
check("logout 後は同じ Cookie が無効", Client(port2).get("/inbox", cookie=old)[0] == 302)
check("logout でサーバー側のセッションも消える", hashlib.sha256(old.split("=", 1)[1].encode()).hexdigest() not in open(sess_path).read())


# ---- パスワード再設定(run/allow-reset)
NEWPW = "brand-new-password-77"
ALLOW = os.path.join(os.path.abspath(RUN), "allow-reset")
anon = Client(port2)
check("ログイン画面に「パスワードを忘れた」リンク", 'href="/reset"' in anon.get("/login")[2])
r = anon.get("/reset")
check("許可ファイルなしは入力欄を出さずコマンドを表示",
      r[0] == 200 and "name=confirm" not in r[2] and "touch " + ALLOW in r[2].replace("&#x27;", "'"), r[2][-400:])
lg = anon.csrf("/login")
before = open(os.path.join(RUN, "auth.json")).read()
r = anon.raw("POST", "/reset", {"csrf": lg, "password": NEWPW, "confirm": NEWPW})
check("許可ファイルなしの POST は拒否", r[0] == 403 and open(os.path.join(RUN, "auth.json")).read() == before)
check("古いパスワードのままログインできる", Client(port2).login()[0] == 302)

oldc = Client(port2)
oldc.login()
for _ in range(5):
    Client(port2).login(pw=WRONG)
check("(準備)ロックアウト中", Client(port2).login()[0] == 429)

open(ALLOW, "w").close()
r = anon.get("/reset")
check("許可ファイルありでフォームが出る", r[0] == 200 and "name=confirm" in r[2])
cs = anon.csrf("/reset")
base_ = {"csrf": cs, "password": NEWPW, "confirm": NEWPW}
check("12 文字未満は拒否(許可は残る)", anon.raw("POST", "/reset", {**base_, "password": "short-11-ch", "confirm": "short-11-ch"})[0] == 400 and os.path.exists(ALLOW))
check("確認入力の不一致は拒否", anon.raw("POST", "/reset", {**base_, "confirm": NEWPW + "x"})[0] == 400 and os.path.exists(ALLOW))
check("CSRF トークン不一致は拒否", anon.raw("POST", "/reset", {**base_, "csrf": cs[:-1] + ("0" if cs[-1] != "0" else "1")})[0] == 403)
check("CSRF トークン無しは拒否", anon.raw("POST", "/reset", {"password": NEWPW, "confirm": NEWPW})[0] == 403)
check("Origin 不一致は拒否", anon.raw("POST", "/reset", base_, origin="http://evil.example")[0] == 403)
check("Origin 無しは拒否", anon.raw("POST", "/reset", base_, origin=None)[0] == 403)
check("拒否された POST では許可ファイルは消えない", os.path.exists(ALLOW))
os.utime(ALLOW, (time.time() - 540, time.time() - 540))  # 9 分前: まだ有効
r = anon.raw("POST", "/reset", base_)
check("10 分以内なら成功(302 /login)", r[0] == 302 and r[1]["Location"] == "/login", str(r[:2]))
check("成功後に許可ファイルが消える", not os.path.exists(ALLOW))
check("auth.json は 0600 のまま", mode(os.path.join(RUN, "auth.json")) == "0o600")
check("auth.json に新パスワードの平文を含まない", NEWPW not in open(os.path.join(RUN, "auth.json")).read())
check("全セッションが無効化(sessions.json が空)", json.load(open(sess_path)) == {} and mode(sess_path) == "0o600")
check("古いセッションは使えない", oldc.get("/inbox")[0] == 302)
check("古いパスワードで拒否", Client(port2).login(pw=PW)[0] == 401)
nc = Client(port2)
check("新パスワードでログインできる(ロックアウトも解除)", nc.login(pw=NEWPW)[0] == 302 and nc.get("/inbox")[0] == 200)
check("再設定後に同じ許可は再利用できない", anon.raw("POST", "/reset", {**base_, "csrf": anon.csrf("/login")})[0] == 403)

open(ALLOW, "w").close()
os.utime(ALLOW, (time.time() - 660, time.time() - 660))  # 11 分前
r = anon.get("/reset")
check("期限切れはフォームを出さずコマンドを表示", "name=confirm" not in r[2] and "期限" in r[2] and "touch " in r[2])
r = anon.raw("POST", "/reset", {**base_, "csrf": anon.csrf("/login"), "password": NEWPW + "2", "confirm": NEWPW + "2"})
check("期限切れの POST は拒否(パスワード不変)", r[0] == 403 and Client(port2).login(pw=NEWPW)[0] == 302)
os.remove(ALLOW)

target = os.path.join(TMP, "real-allow")
open(target, "w").close()
os.symlink(target, ALLOW)
r = anon.get("/reset")
check("シンボリックリンクはフォームを出さない", "name=confirm" not in r[2] and "不正" in r[2])
r = anon.raw("POST", "/reset", {**base_, "csrf": anon.csrf("/login"), "password": NEWPW + "3", "confirm": NEWPW + "3"})
check("シンボリックリンクの POST は拒否", r[0] == 403 and Client(port2).login(pw=NEWPW)[0] == 302 and os.path.islink(ALLOW))
os.remove(ALLOW)

# 時刻の注入(待たない)
import importlib.util  # noqa: E402
spec = importlib.util.spec_from_file_location("webui_auth", os.path.join(os.path.dirname(HERE), "auth.py"))
am = importlib.util.module_from_spec(spec)
spec.loader.exec_module(am)
ut = os.path.join(TMP, "unit-run")
ua = am.Auth(ut)
open(ua.allow_path, "w").close()
t0 = os.stat(ua.allow_path).st_mtime
check("[注入] 9 分後は ok", ua.reset_state(t0 + 540) == "ok")
check("[注入] 10 分ちょうどは ok、10 分 1 秒後は expired", ua.reset_state(t0 + 600) == "ok" and ua.reset_state(t0 + 601) == "expired")
check("[注入] 作成より未来すぎる時刻は invalid", ua.reset_state(t0 - 3600) == "invalid")
check("[注入] 許可なしは missing", (os.remove(ua.allow_path) or ua.reset_state()) == "missing")

check("PUT /reset は 405", anon.raw("PUT", "/reset")[0] == 405)
check("GET /reset は設定済みで 200(情報のみ)", anon.get("/reset")[0] == 200)

# ---- herdr 失敗でも落ちない
cl4 = Client(port2)
cl4.login(pw=NEWPW)
open(os.path.join(TMP, "fake", "fail"), "w").close()
time.sleep(3.2)  # キャッシュ失効待ち
s_, h, b = cl4.get("/agents")
check("herdr 失敗でも 200 でエラー表示", s_ == 200 and "herdr が失敗しました" in b, str(s_))
os.remove(os.path.join(TMP, "fake", "fail"))
check("サーバーは生きている", p.poll() is None)

out2 = stop_out(p)
check("ログに再設定の成功と拒否(期限切れ・不正)が残る", "reset: ok" in out2 and "reset: denied (expired)" in out2 and "reset: denied (invalid)" in out2 and "reset: denied (missing)" in out2, out2[-600:])
leak = [x for x in (PW, NEWPW, WRONG, cookie_val, old.split("=", 1)[1], "legacy-token") if x in out1 + out2]
check("ログ(stdout/stderr)にパスワード・セッション値を出さない", not leak, f"{len(leak)} 件")

# ================= DB 不在・ログ不在・壊れた DB
for name, prep in (("nodb", None), ("baddb", lambda e_: open(e_["WEBUI_TB_DB"], "w").write("not a sqlite file"))):
    base = free_range(1)
    env, d = make_env(name, HERDR_WEBUI_RANGE=f"{base}-{base}")
    if prep:
        prep(env)
    p = start(env)
    port = wait_port(env, p)
    check(f"{name}: 起動できる", port is not None)
    if port:
        c = Client(port)
        c.raw("POST", "/setup", {"csrf": c.csrf("/setup"), "username": USER, "password": PW, "confirm": PW})
        c.cookie = None
        c.login()
        for path in ["/", "/notifications", "/api/notifications", "/agents", "/tasks", "/tasks/T-1", "/inbox", "/jobs", "/ledger"]:
            s_ = c.get(path)[0]
            check(f"{name}: GET {path}", s_ in (200, 404), str(s_))
        check(f"{name}: サーバー生存", p.poll() is None)
        if name == "nodb":
            check("DB 不在の表示", "タスク DB がありません" in c.get("/tasks")[2])
    stop(p)

# ================= ブラウザ相当の Origin(Referrer-Policy 起因の不具合の回帰)
# Referrer-Policy: no-referrer だと、ブラウザは同一オリジンの POST でも Origin: null にし Referer も付けない。
# → 全フォームが 403 になった。同一オリジンには Origin/Referer を付ける same-origin にする。
base = free_range(1)
env, d = make_env("origin0", HERDR_WEBUI_RANGE=f"{base}-{base}")
p = start(env)
port = wait_port(env, p)
c0 = Client(port)
r = c0.get("/setup")
check("Referrer-Policy は same-origin(no-referrer ではない)", r[1].get("Referrer-Policy") == "same-origin", r[1].get("Referrer-Policy"))
r = c0.get("/setup")
check("/setup の Referrer-Policy ヘッダ", r[1].get("Referrer-Policy") == "same-origin")
check("/setup の meta referrer も same-origin", "name=referrer content=same-origin" in r[2] and "no-referrer" not in r[2])
stop(p)

BAD = [("null", "Origin: null"), ("http://evil.example", "外部オリジン"), (None, "Origin も Referer も無い")]
for host in ("127.0.0.1", "localhost"):
    base = free_range(1)
    env, d = make_env("origin-" + host, HERDR_WEBUI_RANGE=f"{base}-{base}")
    RUN_ = env["WEBUI_RUN_DIR"]
    p = start(env)
    port = wait_port(env, p)
    good = f"http://{host}:{port}"
    c = Client(port)
    H = f"{host}:{port}"
    pw1, pw2 = "origin-test-password-1", "origin-test-password-2"

    def post(path, data, origin, cookie="default"):
        return c.raw("POST", path, data, origin=origin, cookie=cookie, host=H)

    def tok(path, cookie="default"):
        m = re.search(r'name=csrf value="([^"]+)"', c.raw("GET", path, host=H, cookie=cookie)[2])
        return m.group(1) if m else ""

    # /setup: 不正な Origin は 403、正しい Origin は成功
    for o, label in BAD:
        r = post("/setup", {"csrf": tok("/setup"), "username": "u", "password": pw1, "confirm": pw1}, o)
        check(f"[{host}] /setup: {label} は 403", r[0] == 403, str(r[0]))
    check(f"[{host}] 拒否の間は auth.json が作られない", not os.path.exists(os.path.join(RUN_, "auth.json")))
    r = post("/setup", {"csrf": tok("/setup"), "username": "u", "password": pw1, "confirm": pw1}, good)
    check(f"[{host}] /setup: Origin {good} で成功", r[0] == 302 and "Set-Cookie" in r[1], str(r[:2]))
    ck = re.match(r"([^;]+)", r[1]["Set-Cookie"]).group(1)

    # /logout
    for o, label in BAD:
        r = post("/logout", {"csrf": tok("/", ck)}, o, ck)
        check(f"[{host}] /logout: {label} は 403(セッションは残る)", r[0] == 403 and c.raw("GET", "/inbox", cookie=ck, host=H)[0] == 200, str(r[0]))
    r = post("/logout", {"csrf": tok("/", ck)}, good, ck)
    check(f"[{host}] /logout: Origin {good} で成功", r[0] == 302 and r[1]["Location"] == "/login", str(r[:2]))

    # /login
    for o, label in BAD:
        r = post("/login", {"csrf": tok("/login"), "username": "u", "password": pw1}, o)
        check(f"[{host}] /login: {label} は 403", r[0] == 403 and "Set-Cookie" not in r[1], str(r[0]))
    r = post("/login", {"csrf": tok("/login"), "username": "u", "password": pw1}, good)
    check(f"[{host}] /login: Origin {good} で成功", r[0] == 302 and "Set-Cookie" in r[1], str(r[:2]))
    ck = re.match(r"([^;]+)", r[1]["Set-Cookie"]).group(1)

    # /reset
    allow = os.path.join(os.path.abspath(RUN_), "allow-reset")
    open(allow, "w").close()
    for o, label in BAD:
        r = post("/reset", {"csrf": tok("/login"), "password": pw2, "confirm": pw2}, o)
        check(f"[{host}] /reset: {label} は 403(許可は残る)", r[0] == 403 and os.path.exists(allow), str(r[0]))
    r = post("/reset", {"csrf": tok("/login"), "password": pw2, "confirm": pw2}, good)
    check(f"[{host}] /reset: Origin {good} で成功", r[0] == 302 and r[1]["Location"] == "/login" and not os.path.exists(allow), str(r[:2]))
    # 成功後も、Origin も Referer も無い POST は 403 のまま
    r = c.raw("POST", "/login", {"csrf": tok("/login"), "username": "u", "password": pw2}, origin=None, host=H)
    check(f"[{host}] Origin も Referer も無い /login は 403(成功後も)", r[0] == 403)
    stop(p)

print()
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)

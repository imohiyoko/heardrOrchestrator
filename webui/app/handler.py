"""HTTP ハンドラ・ログイン・起動。"""

import json
import os
import re
import shlex
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlencode, urlsplit

import auth

from .config import COOKIE, HOST, JOB_RE, RUN_DIR, cfg
from .sanitize import clean, e
from .actions import resolve_comment
from .data import NOTIFY_POLL_SEC, badge_count, urgent_items
from .jobs import job_names, save_job_settings
from .views import CSS, NOTIFY_JS, err_html, page, page_job, route


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
                         "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; "
                         "base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
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
        if path == "/api/notifications":  # スクリプト用。未ログインはリダイレクトせず 401
            if not a.configured() or not self._session():
                return self._send(401, '{"error":"login required"}', "application/json; charset=utf-8")
            try:
                data = json.dumps({"items": urgent_items(), "poll_sec": NOTIFY_POLL_SEC}, ensure_ascii=False)
            except Exception as ex:
                sys.stderr.write(f"internal error: {type(ex).__name__}\n")
                return self._text(500, "Internal Server Error")
            return self._send(200, data, "application/json; charset=utf-8")
        if not a.configured():
            return self._redirect("/setup")
        sh = self._session()
        if not sh:
            nx = u.path + (("?" + u.query) if u.query else "")
            return self._redirect("/login?" + urlencode({"next": auth.safe_next(nx)}))
        logout = (f'<form method=post action="/logout"><input type=hidden name=csrf value="{e(a.form_token("s:" + sh))}">'
                  '<button type=submit>ログアウト</button></form>')
        if path == "/notify.js":
            return self._send(200, NOTIFY_JS, "text/javascript; charset=utf-8")
        try:
            m = re.fullmatch(r"/jobs/([^/]+)/?", unquote(path))
            if m:  # 設定フォーム(自動更新しない)
                name = m.group(1)
                if not JOB_RE.fullmatch(name) or name not in job_names():
                    return self._send(404, page("見つかりません", "<p>そのページはありません。</p>", "", badge_count(), logout))
                title, body = page_job(name, a.form_token("s:" + sh), saved=qs.get("saved") == ["1"])
                return self._send(200, page(title, body, "/jobs/" + name, badge_count(), logout, refresh=False))
            ctx = {"csrf": a.form_token("s:" + sh)}
            r = route(unquote(path), qs, ctx)
            if r is None:
                return self._send(404, page("見つかりません", "<p>そのページはありません。</p>", "", badge_count(), logout))
            title, body = r
            self._send(200, page(title, body, path, badge_count(), logout, refresh=not ctx.get("norefresh")))
        except Exception as ex:  # 1 ページの失敗でサーバーを落とさない(例外の内容は出さない)
            sys.stderr.write(f"internal error: {type(ex).__name__}\n")
            self._text(500, "Internal Server Error")

    # ---- POST(/login /setup /logout /reset と、定期実行の設定 /jobs/<job>、報告の対応済み /resolve だけ)
    def _post(self, path):
        a = self.auth
        if not self._origin_ok():
            return self._text(403, "Forbidden: Origin/Referer が不正です")
        form = self._body()
        if form is None:
            return self._text(413, "Payload Too Large")
        sh = self._session()
        job = path.startswith("/jobs/")
        if (job or path == "/resolve") and not sh:
            return self._redirect("/login")
        ctx = "s:" + sh if (path in ("/logout", "/resolve") or job) and sh else "anon"
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
        if path == "/resolve":  # 報告を対応済みにする(書き込みは tb resolve)
            cid, back = form.get("id", ""), form.get("back", "/inbox")
            if not re.fullmatch(r"[0-9]{1,9}", cid):
                return self._text(400, "Bad Request")
            if not re.fullmatch(r"/inbox|/tasks/[A-Za-z0-9_%-]{1,200}", back):
                back = "/inbox"
            st = resolve_comment(int(cid), form.get("note", ""))
            sys.stderr.write(f"resolve: C-{cid} {st}\n")
            return self._redirect(back + "?" + urlencode({"resolved": st}))
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
        if self.command == "POST" and (path in ("/login", "/setup", "/logout", "/reset", "/resolve")
                                       or re.fullmatch(r"/jobs/[A-Za-z0-9][A-Za-z0-9_-]{0,63}", path)):
            return self._post(path)
        if self.command not in ("GET", "HEAD"):
            return self._text(405, "Method Not Allowed(定期実行の設定と報告の対応済み以外は読み取り専用です)", [("Allow", "GET, HEAD")])
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

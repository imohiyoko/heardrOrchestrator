# webui — herdr 進捗の Web UI

agent・タスク・報告・定期実行・台帳を、ブラウザで見るための小さなサーバー。
Python 3 の標準ライブラリだけで動く(依存なし)。

- サーバー側で HTML を組み立てる複数ページ構成(SPA ではない)。自動更新は `<meta http-equiv="refresh">`(8 秒)。
- 全ページに共通ナビと、承認待ち件数のバッジ(報告の question/blocked + `pending-human` の代行依頼 + blocked の agent)。
- まとめ送信(10 分おき)より急ぐものは「緊急通知」(`/notifications`)に集め、ナビにも件数バッジを出す。
  Web UI のタブが開いていれば、新しく出たものを Chrome のデスクトップ通知でも出す(下の「緊急通知」)。
- **変更できるのは定期実行のスケジュールだけ**(`/jobs/<job>`: 間隔・時間帯・曜日・一時停止)。それ以外は読み取り専用で、POST/PUT/DELETE/PATCH は 405。
  承認ボタンはない(承認は人が別の経路で行う)。

## 起動

```bash
python3 webui/server.py
```

起動時に標準出力へポートと、ログイン(または初回設定)の URL を出す。URL に機密は含まれない。

```
herdr-webui: listening on http://127.0.0.1:8800/
herdr-webui: port=8800
herdr-webui: 初回設定(ユーザー名とパスワードを作る) http://127.0.0.1:8800/setup
```

## ログイン(ID/パスワード)

認証は ID/パスワードのログイン方式。従来の `?token=` と `run/token` は**廃止**した(コードから参照しない)。
残っている `run/token` は不要なので削除してよい。

- **初回設定**: `run/auth.json` が無いときだけ `/setup` が開く。ユーザー名とパスワード(確認入力あり、**12 文字以上**)を
  画面で作る。設定後は自動でログインされ、`/setup` は 404 で閉じる。最初にアクセスした人が設定するので、
  起動したらすぐ自分で設定すること(待ち受けは 127.0.0.1 のみ)。
- **ログイン**: `/login`。未ログインで他の URL を開くと `/login?next=<元のパス>` に 302 する。
  `next` は同一オリジンのパスだけ有効で、外部 URL は無視して `/` に戻す。
- **有効期間**: 12 時間(`WEBUI_SESSION_TTL` 秒で変更可)。サーバーを再起動してもセッションは続く。
- **ログアウト**: 各ページ右上のボタン(`POST /logout`)。サーバー側のセッションも破棄される。
- **総当たり対策**: 失敗が 5 回続くと 5 分ロック(全体でカウント。`WEBUI_LOCK_MAX` / `WEBUI_LOCK_SEC`)。ロック中は正しい
  パスワードでも通らない(429)。カウントはメモリ上なので、サーバーの再起動でリセットされる。
  失敗時は「ユーザー名違い」か「パスワード違い」かを区別して表示せず、ログにも残さない。

### パスワードを忘れたとき(再設定)

ブラウザだけで再設定できる画面は**作らない**(画面に届く人がパスワードを奪えてしまうため)。
シェルを操作できる本人だけが「許可ファイル」を作り、それが 10 分間だけ再設定画面を開く。

1. ログイン画面の「パスワードを忘れた」(`/reset`)を開く。許可がなければ、実行するコマンドが表示される。
2. 手元のシェルで実行する(パスは画面に表示される絶対パス):

   ```bash
   touch webui/run/allow-reset
   ```

3. `/reset` を再読み込みし、新しいパスワード(確認入力あり、12 文字以上)を設定する。

許可は、`run/allow-reset` が**通常ファイル**で、**自分のユーザーの所有**で、**作成(更新)から 10 分以内**のときだけ有効。
シンボリックリンク・期限切れ・未来の時刻のものは無効で、画面に理由が出る。存在確認は毎回行う(キャッシュしない)。
期限が切れたら `touch` し直す。

再設定に成功すると、`run/allow-reset` を削除し、`run/auth.json` のハッシュを更新(0600 のまま)、`run/sessions.json` の
全セッションを無効化(全員が再ログイン)、ロックアウトのカウントもリセットする。ユーザー名は変わらない。
`/reset` の POST にも、ログインと同じ CSRF 検査(Origin/Referer と隠しトークン)と失敗時の遅延(`WEBUI_FAIL_DELAY`、既定 1 秒)を適用する。
成功・拒否(期限切れ・不正・未許可)はログに `reset: ok` / `reset: denied (...)` として残る(パスワードは出さない)。

**最終手段**: ユーザー名も含めて最初からやり直すなら、`run/auth.json` と `run/sessions.json` を削除して `/setup` から作り直す。

```bash
rm webui/run/auth.json webui/run/sessions.json
```

### 保存されるもの(`run/`、すべて 0600 で作成)

- `auth.json`: ユーザー名と、scrypt(salt 16 バイト、パラメータも記録)によるパスワードのハッシュ。平文はどこにも残さない。
- `sessions.json`: セッション値の SHA-256 と有効期限だけ。Cookie の値そのものは保存しない。
- Cookie は `HttpOnly; SameSite=Strict; Path=/`。

POST を受け付けるのは `/login`・`/setup`・`/logout`・`/reset` と `/jobs/<job>` だけ(`/jobs/<job>` はログイン中のセッションに結びついたトークンが必要)。これらは `Origin`/`Referer` が自分のオリジン
(`127.0.0.1:<port>`)であることと、フォームの隠しトークン(署名付き・30 分で失効)を確認する。それ以外の
POST/PUT/DELETE/PATCH は 405。

### ポート

- 既定は 8800 から +1 で実際に bind を試して空きを探す(上限 8819)。全部埋まっていればエラー終了。
- `TB_UI_PORT=8810` のように固定指定した場合は探索しない(使用中ならエラー終了)。
- 開いたポートは `run/port` に書く(終了時に消す)。

## ページ

| URL | 内容 |
| --- | --- |
| `/` | 概要(承認待ち、agent の状態、滞留、直近の完了) |
| `/notifications` | 緊急通知の一覧と、Chrome 通知を有効にするボタン |
| `/api/notifications` | 緊急通知の JSON(`/notify.js` が 15 秒ごとに取得。未ログインは 401) |
| `/agents` | agent 一覧(状態・workspace・いま何を・最終入力/停止・警告) |
| `/agents/<名前>` | 状態、担当タスク、直近の出力(`herdr agent read`)、最終入力/停止、`session_id`、`claude --resume <session_id>` |
| `/tasks`, `/tasks/<id>` | タスク一覧(`?project=` `?status=` で絞り込み)と詳細(報告・成果物・代行依頼) |
| `/inbox` | 要対応(question・blocked・pending-human・blocked の agent)を上に、直近の報告を下に |
| `/jobs` | 各 job の実際に効く設定(間隔・時間帯・曜日・有効/一時停止)、最終記録と最後の実行 |
| `/jobs/<job>` | スケジュールの変更フォーム(自動更新しない)。保存先は `scheduler/settings/<job>.settings`、次の分から反映。「conf の値に戻す」で settings を消す |
| `/ledger` | `conductor/dispatch.jsonl` の直近 30 行 |

名前の無い agent は `pane_id`(例: `w2:p3`)が名前の代わりになる。未知の URL は 404。

## データ源(すべて読み取りのみ)

- `herdr agent list` / `herdr agent read`(結果は 3 秒キャッシュ)
- `taskboard/data/tasks.db`(`mode=ro` で開く。無い・壊れていても落ちず、空の表になる)
- `scheduler/logs/*.log`、`scheduler/jobs/*.conf`(`scheduler/bin/show.sh` 経由)、`conductor/dispatch.jsonl`
- 書き込むのは `scheduler/settings/<job>.settings` だけ。入力は数値・`HH:MM`・決まった曜日だけを受け付け、scheduler が読めない内容なら元に戻す

「滞留」は、`working` のまま最終入力(`agent_activity.last_prompt_at`)から 30 分を超えて停止がない agent。

## 緊急通知

10 分おきのまとめ送信を待たずに知らせるもの。

- 未完了タスクの `question` / `blocked` の報告
- `pending-human` の代行依頼
- `blocked` の agent(承認待ち)
- 滞留している agent
- 最後の実行(`ran`/`failed`/`sent`)が `failed` の定期実行(次に成功すると消える)

Chrome 通知の使い方: `/notifications` を開いて「Chrome 通知を有効にする」を押し、許可する。
以後、Web UI のどれかのタブが開いている間、`/notify.js` が 15 秒ごとに `/api/notifications` を見て、
前回なかった項目だけを通知する(既読の管理はブラウザの localStorage。通知をクリックすると該当ページへ)。
タブを閉じると通知は止まる(Service Worker・Push は使わない)。最初に開いたときに既にあるものは通知せず、一覧とバッジで見る。
`127.0.0.1` はブラウザ上で安全なコンテキスト扱いなので、HTTPS なしで通知を使える。

## 承認待ちの対応(手元の herdr で行う)

blocked の agent は `/inbox` からリンクで `/agents/<名前>#approval` に飛べる。そこに次を出す。

- **承認待ちの内容**: `herdr agent read` の直近の画面(承認ダイアログ部分)を、ANSI を除いて HTML エスケープしただけで表示する。要約・加工はしない。
- **手元で開く**: `herdr agent attach <名前>`(名前が無い agent は `pane_id`)をコピー用の入力欄に出す。`readonly` の入力欄を選択してコピーする。
- **場所**: workspace ラベル / tab / pane_id。

**方針: ブラウザからは承認の入力をしない。** 承認ボタンも `send-keys` も作らない。内容を見て、手元の端末で `herdr agent attach` して、人が操作する。

ttyd(ブラウザ上の端末)は採用しない。署名が無効で、会社の EDR に検知された前例があるため。

## 安全性

- `127.0.0.1` のみで待ち受ける。Host ヘッダが自分以外なら 403(DNS リバインディング対策)。
- agent の出力・タスク本文・ログなど外部由来の文字列は、ANSI 等の制御文字を除いたうえで HTML エスケープして出す。
  CSP は `default-src 'none'` を基本に、`script-src 'self'` と `connect-src 'self'` だけを許す。JS は同一オリジンの
  `/notify.js`(通知のポーリングだけ。ログイン必須)の 1 本で、インラインスクリプトは使えない。通知の文面は
  `textContent` と Notification の本文(プレーンテキスト)にしか入れない。
- ログ(launchd の out/err を含む)には、メソッド・パス・状態コードだけを出す。クエリ、Cookie、フォーム本文、
  パスワード、セッション値、例外のメッセージは出さない。ログイン成否も理由を区別せず `login: ok/failed/locked` のみ。

## 見える内容に機密が含まれうる

agent の端末出力、タスクの報告、台帳(送ったプロンプト)には、社内の情報・認証情報の断片・個人名などが含まれうる。
`127.0.0.1` 限定でも、**ログイン情報(ユーザー名・パスワード)を他人に共有しない**(チャット、スクリーンショット、PR にも貼らない)。
画面共有の前に、表示中のページを確認すること。

## 常駐(launchd)

```bash
bash webui/bin/gen-plist.sh      # webui/generated/local.herdr-webui.plist を生成して lint(登録はしない)
```

ラベルは `local.herdr-webui`、`KeepAlive` あり、ログは `webui/logs/`。**登録は人が行う**:

```bash
cp webui/generated/local.herdr-webui.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.herdr-webui.plist
# 解除: launchctl bootout gui/$(id -u)/local.herdr-webui && rm ~/Library/LaunchAgents/local.herdr-webui.plist
```

## 設定(環境変数)

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `TB_UI_PORT` | (なし) | 固定ポート。指定すると探索しない |
| `HERDR_WEBUI_RANGE` | `8800-8819` | 探索範囲(`下限-上限`)。テスト用 |
| `WEBUI_SESSION_TTL` / `WEBUI_LOCK_MAX` / `WEBUI_LOCK_SEC` | `43200` / `5` / `300` | ログインの有効秒数 / ロックまでの失敗回数 / ロック秒数 |
| `WEBUI_FAIL_DELAY` | `1` | ログイン・再設定の失敗時の遅延(秒) |
| `HERDR_BIN` | `herdr` | herdr の実行ファイル(テストで疑似に差し替え) |
| `WEBUI_TB_DB` | `TB_DB`、無ければ `taskboard/data/tasks.db` | tb と同じ DB(既定は `lib/herdr_env.py`) |
| `WEBUI_SCHED_LOGS` / `WEBUI_SCHED_JOBS` / `WEBUI_SCHED_SETTINGS` / `WEBUI_DISPATCH` / `WEBUI_RUN_DIR` | 兄弟ディレクトリ / `webui/run` | データ源・settings・`run/` の場所 |

## コードの構成

`server.py` は入口だけで、中身は `app/` にある。依存は上から下への一方向(逆向きの import はしない)。

| ファイル | 中身 |
|---|---|
| `app/config.py` | 定数と、環境変数で上書きできるパス(DB と herdr の既定は `lib/herdr_env.py`) |
| `app/sanitize.py` | 外部由来の文字列の無害化(`e()` を通してから HTML に出す) |
| `app/herdr.py` | herdr CLI の呼び出し(読むだけ)と短いキャッシュ |
| `app/data.py` | tasks.db とログの読み取り(読み取り専用の接続)、緊急通知の集計 |
| `app/jobs.py` | scheduler のジョブ定義と、Web UI から書く上書き設定 |
| `app/views.py` | HTML の組み立てと各ページ |
| `app/handler.py` | HTTP ハンドラ・ログイン・起動 |
| `auth.py` | パスワードとセッション |

## テスト

```bash
bash webui/tests/run.sh
```

herdr は `tests/fake/herdr`(疑似)、DB・ログは一時ディレクトリ。本物のポートは 30000〜60000 の空き範囲から
最大 3 つだけ使い、終了時に必ず片付ける。確認する境界: ポート衝突で +1、全埋まりでエラー、`TB_UI_PORT` 固定は探索しない、
未ログインは /login へ、初回設定は 1 回だけ、パスワード 12 文字未満の拒否、ハッシュに平文を含まない、0600、ロックアウト、
パスワード再設定(許可なし・期限切れ・シンボリックリンクの拒否、成功後の許可削除とセッション失効、時刻の注入)、期限切れ・再起動後・ログアウトのセッション、`next` の外部 URL 無視、Origin 不一致・CSRF トークン無しの POST の拒否、他の POST 等は 405、不正な Host 403、XSS・ANSI のエスケープ、DB 不在・破損・herdr 失敗でも落ちない、未知の URL は 404。

## まだできていないこと

ブラウザからの承認操作、端末リンク(ttyd は採用しない)、`pane_agent_status_changed` の購読(いまは数秒おきの取得)は第 2 段以降。

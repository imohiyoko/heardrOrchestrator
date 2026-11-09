# scheduler

定期実行を agent の cron ではなく macOS の launchd で担保する。agent は呼ばれた回に実行するだけ。
launchd が `bin/tick.sh <job>` を指定時刻に起動し、時間帯・曜日・agent の状態を判定して、
`herdr agent prompt` で本文を送る。

## ジョブの足し方

`jobs/<name>.conf` を作る(bash の変数代入)。例は `jobs/watch.conf.example`(`.example` を外して使う)。

| 変数 | 意味 |
|---|---|
| `TARGET` | agent 名(`herdr agent list` の `name`)。実行のたびに pane ID へ解決する |
| `PROMPT` / `PROMPT_FILE` | 送る本文 / 本文を入れたファイル。**先頭を `/` や `-` にしない**(拒否される) |
| `WINDOW` | `09:00-21:00`。両端を含む。日またぎは不可 |
| `START` / `END` | `WINDOW` の別表記(`START=10:00` `END=12:00`)。`WINDOW` と同時には使わない |
| `INTERVAL_MIN` | 起動間隔(分)。窓の始端から刻む |
| `DAYS` | 既定 `daily`。`weekdays` や `"Mon Wed Fri"` |
| `SKIP_IF` | 既定 `"working blocked"`。該当する状態ならスキップ。idle/done 以外も送らない |
| `TZ` | 既定 `Asia/Tokyo`。OS のタイムゾーンと違うと gen-plist が拒否する |

### コマンド実行型ジョブ

`TARGET` / `PROMPT` の代わりに `COMMAND='...'`(シェル 1 行)を書くと、agent を介さずそのコマンドを実行する
(例: `jobs/taskboard-pending.conf.example`)。`WINDOW` / `DAYS` / `INTERVAL_MIN` の判定は同じ。終日は `WINDOW=00:00-23:59`。

- `TARGET` / `PROMPT` / `PROMPT_FILE` との同時指定はエラー。agent の状態は見ない。
- `COMMAND_TIMEOUT`(秒、既定 60)を超えると子プロセスごと kill し、`failed`(exit 124)。
- 同じジョブの多重実行はロック(`logs/<job>.lock.d`)で防ぎ、実行中なら `skipped_locked`。
- ログには `action`(`ran` | `failed` | `skipped_*`)、`exit`、`stdout`、`stderr`(各先頭 500 字)を記録。
- **`COMMAND` は `bash -c` でそのまま実行される。`jobs/*.conf` は人が管理するもので、外部入力(Slack・ファイル内容・引数など)を埋め込まないこと。**

## 登録・確認・解除

```bash
bin/gen-plist.sh <job>          # generated/ に plist を生成(登録はしない)
bin/install.sh install <job>    # ~/Library/LaunchAgents/ にコピーして bootstrap
bin/install.sh status <job>     # launchctl print
bin/install.sh uninstall <job>  # bootout して plist を削除
```

conf を書き換えずに一時的に変えたいときは、環境変数 `SCHED_WINDOW` / `SCHED_START` / `SCHED_END` /
`SCHED_INTERVAL_MIN` で上書きできる(plist にはその値が焼き込まれる)。

```bash
SCHED_WINDOW=10:00-18:00 SCHED_INTERVAL_MIN=10 bin/gen-plist.sh <job>
```

conf を変えたら `gen-plist.sh` → `install.sh install` をやり直す(再登録される)。

## 動作確認

```bash
bash tests/run.sh                                            # 判定の決定論的テスト
DRY_RUN=1 NOW="2026-11-05 21:00" bash bin/tick.sh <job>      # herdr を呼ばず判定だけ
DRY_RUN=1 FAKE_STATE=working NOW="2026-11-05 12:00" bash bin/tick.sh <job>
```

- `NOW` は `YYYY-MM-DD HH:MM`(ジョブの TZ の現地時刻)。
- 実行結果は `logs/<job>.log` に JSONL 1 行(`ts, job, action, reason, at, target, pane, state`)。
  `action` は `sent | skipped_window | skipped_state | failed`。DRY_RUN はログを書かず stdout に出す。
- launchd 自体の出力は `logs/launchd-<job>.out / .err`。

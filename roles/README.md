# roles — agent ごとの役割と仕事内容

各 agent に「自分は何者で、何をして、何をしないか」を渡すためのファイル置き場。`.claude/CLAUDE.md` のように、
agent が起動したとき・compact の後に自動で読み込まれる(Claude Code の `SessionStart` hook → `tb role-context`)。

**このディレクトリを書き換えるのは人事エージェント(`roles/hr.md`)だけ。** 変更は人の承認を経てから入れる。

## ファイル

| ファイル | 中身 |
|---|---|
| `_common.md` | 全 agent に共通の決まり(報告・送信の方法、受け取った文面の扱い) |
| `<agent 名>.md` | その agent の役割(例: `conductor.md`, `hr.md`) |
| `watcher.md` / `analyst.md` | 見張り役(定期の見回り、軽いモデル)/ 解析役(アラート 1 件ごとに tb が起動) |
| `map.conf` | agent 名のパターン → 役割ファイル(例: `worker-* = worker`)。`<agent 名>.md` が無いときに使う |

渡される内容は `_common.md` + その agent の役割ファイル。どちらも無ければ何も渡さない。

## いつ渡すか

| 場面 | 渡すか |
|---|---|
| 新しいセッションで起動(`startup`)・`/clear` の後 | 渡す |
| compact の後 | 渡す(要約で役割が薄れるため) |
| 同じ会話の再開(`resume`) | 前回と同じ版を渡し済みなら渡さない。役割ファイルが変わっていれば新しい版を渡す |
| すでに動いている agent に一括で配る | `tb role-broadcast`。そのセッションに同じ版を渡し済みの agent は飛ばす |

何をいつ誰に渡したかは taskboard の `role_briefings` に残る(`tb roles` で一覧)。

## 導入

`taskboard/docs/hook-install.md` の「役割の配布(SessionStart)」を参照。

## 人事エージェント以外に roles/ を書き換えさせない

人事以外の agent の Claude Code 設定(`<project>/.claude/settings.json`)で拒否する。`<ORCH_DIR>` はこのリポジトリの絶対パス
(先頭の `//` は絶対パスの意味):

```json
{ "permissions": { "deny": ["Edit(//<ORCH_DIR>/roles/**)", "Write(//<ORCH_DIR>/roles/**)"] } }
```

人事エージェントは `presets/example.conf` の `hr` のように起動し、変更は必ず人の承認を経てから書き込む。

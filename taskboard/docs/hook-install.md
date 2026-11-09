# hook の導入(agent の活動を tb に記録する)

`bin/tb-hook` を Claude Code の `UserPromptSubmit` と `Stop` に登録すると、agent が「いつ入力を受け、いつ止まったか」が
`tb activity` / `tb show` で見えるようになる。

**この文書は説明だけで、どの settings も書き換えない。** 貼るのは人が行う。

## 仕組み
- hook が `bin/tb-hook` を起動する。stdin の JSON から `hook_event_name` / `session_id` / `cwd` / `prompt_id` の 4 項目だけを読み、
  env の `HERDR_PANE_ID` / `HERDR_TAB_ID` / `HERDR_WORKSPACE_ID` と合わせて `tb touch` を呼ぶ
- **prompt 本文・agent の返答・env 全体は読まない・保存しない・ログに出さない**(hook の env には認証情報が入っている)
- 常に終了コード 0・標準出力なし。DB のロックや不正な入力でも agent を止めない(DB は 1 秒で諦める)。
  失敗は `data/touch-errors.log` に 1 行(時刻・event・理由コード)だけ残る
- 理由コード: `invalid-event` `missing-session-id` `invalid-session-id` `invalid-field` `invalid-cwd` `invalid-args` `db-locked` `db-readonly` `db-error`

## settings.json のスニペット例
`<TASKBOARD_DIR>` は taskboard を置いた絶対パスに読み替える。`bash` 経由で呼ぶので、`bin/tb-hook` に実行権限がなくても動く。

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash <TASKBOARD_DIR>/bin/tb-hook", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash <TASKBOARD_DIR>/bin/tb-hook", "timeout": 5 } ] }
    ]
  }
}
```

DB の場所を変えたいときは `TB_DB` を agent の環境に渡す(既定は `<TASKBOARD_DIR>/data/tasks.db`)。

## 置き場所
### 推奨: プロジェクト単位(`<project>/.claude/settings.json`)
- 記録したいプロジェクト(worker の cwd)だけが対象になる
- 個人用にしてコミットしたくなければ `<project>/.claude/settings.local.json` に置く(Claude Code は通常 git 管理外にする)
- 初めて開くフォルダでは「このフォルダを信頼するか」のダイアログが出る。承認するまで project の hook は動かない
  (承認すると `~/.claude.json` に記録が増える)

### グローバル(`~/.claude/settings.json`)にする場合のリスク
- **すべてのプロジェクトのすべてのセッション**が対象になる。無関係な作業・機密性の高いプロジェクトの `session_id` と `cwd`
  (フォルダ名にプロジェクト名や顧客名が入りうる)が DB に残る。DB は `data/` にあり、タスクの情報レベルより緩い扱いになりやすい
- 全セッションの全 turn で hook が走る。`tb` の不具合や DB の遅延が、短いとはいえ全 agent に効く(1 秒で諦めるが、ゼロではない)
- 一度入れると気づきにくい。外し忘れたまま taskboard を動かすと、`touch-errors.log` に失敗が溜まり続ける(agent は止まらないので気づかれない)
- 設定の場所が複数(managed / user / project / local)あり、同じ hook が二重に登録されると turn ごとに 2 回記録される(行は増えないが `updated_at` が揺れる)
- どうしてもグローバルにするなら、先に project 単位で動作を確認し、`tb activity` の対象に意図しない cwd が出ないかを見てから

## 動作確認(settings を触らずに試す)
```bash
export TB_DB=$(mktemp -d)/t.db      # 本番の DB を汚さない
echo '{"hook_event_name":"UserPromptSubmit","session_id":"demo-1","cwd":"/tmp","prompt_id":"p1"}' \
  | HERDR_PANE_ID=w1:p1 bash <TASKBOARD_DIR>/bin/tb-hook
<TASKBOARD_DIR>/bin/tb activity          # demo-1 が working=1 で出る
cat "$(dirname "$TB_DB")/touch-errors.log" 2>/dev/null   # 何も出なければ失敗なし
```

## 読み方と限界
- `working` は推定: 最後の `UserPromptSubmit` が最後の `Stop` より新しければ 1
- `stuck` は滞留の目安: `working` のまま `--stuck-min`(既定 10)分以上たったもの。**長い作業と本当の停止は区別できない**
- `Stop` は turn の終わりだけを表す。Esc での中断・プロセスの強制終了では `Stop` が来ないことがあり、`working` のまま残りうる(未検証)。
  確かめるときは `herdr agent get <名前>` の `agent_status` を見る
- 人の直接入力と `herdr agent prompt` は hook から区別できない
- `tasks.session_id` は `tb claim --session` / `tb update --session` で入れる。入っていないタスクは `tb show` の `activity` が null になる
- Claude Code が resume や compact で `session_id` を変えるかは未確認。変わると別の行になる

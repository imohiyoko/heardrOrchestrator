# taskboard — herdr agent 用の最小タスク表

SQLite 1 ファイル(`data/tasks.db`)に仕事の状態を持ち、`bin/tb` で読み書きする。
依存は `sqlite3` / `bash` / `jq` のみ。

- 「何を誰に送ったか」の監査ログ `dispatch.jsonl` とは別物。こちらは「仕事の状態」
- `done`(herdr の agent_status)は turn の終わりしか意味しない。**タスクの完了は worker が `tb done` + `tb report` で明示する**

## worker 向け: 終了時に打つ 2 行

```bash
tb done   T-<project>-NNN -d <成果物のパスか URL> [-d <もう 1 つ>] -m "要約(1〜2 文)"
tb report T-<project>-NNN
```

- `-d` と `-m` は必須(欠けると done にならない)
- `report` は指示役へ `[T-xxx done] 要約 / 成果物パス` を送る。終了コードで結果が分かる:

| code | 意味 | worker がやること |
| --- | --- | --- |
| 0 | 送信済み(または報告済み) | 終了してよい |
| 10 | 宛先の指示役が working / blocked 等で**未送信** | 何もしない。`pending` に残り、あとで回収される(必要なら少し待って再実行) |
| 11 | 送信または宛先の状態取得に失敗 | 同上。繰り返し 11 なら指示役の名前(`config/projects.conf`)を確認 |

`reported_at` は `report` が成功したときだけ入る。10 / 11 のときは空のまま `tb pending` に出る。

`tb` は PATH に無いので、`taskboard/bin/tb` のフルパスで呼ぶか PATH に足す。

### 作業の始め方(任意)

```bash
tb claim T-<project>-NNN --owner <自分の agent 名> [--session <session id>] [--account <max|enterprise>]
tb update T-<project>-NNN --status review     # todo|in_progress|review|blocked
tb block  T-<project>-NNN -m "詰まっている理由"
```

## 指示役 / 人向け

```bash
tb add -p <project> -t "タイトル" [--parent T-..] [--owner N]   # ID を表示(T-<project>-NNN)
tb list [-p project] [-s status] [--json]
tb show T-<project>-NNN
tb pending [--json|--ids]     # done なのに未報告のもの(id / project / 宛先 / 要約)
tb pending --ids | xargs -n1 tb report    # 未報告の再送(scheduler から呼ぶ想定)
```

`project` は英数字と `_` のみ。ID は project ごとに 001 から採番される。

## 代行依頼(権限が足りないとき)

仕様は利用側のプロンプトで定める。
**tb は判定と記録だけで、cmd を実行しない。** 実行は指揮官が行う。

```bash
# worker: 依頼を出す(effect 必須。迷ったら write。read-only|write|external 以外は拒否)
tb proxy-request T-<project>-NNN --cmd 'gh pr view 12' --why '目的' --effect read-only --expect '期待する出力'
#   → "<id> open"。同じ cmd が denied 済みなら "<id> denied" で即登録される(出し直さず別の方法を提案する)

# 指揮官
tb proxy-list [--status open] [--json]
tb proxy-check <id>      # 1 行目: allow(自動代行可) / human(人に回す)。続けて reason: / mismatch: 行
tb proxy-resolve <id> --status done|pending-human|denied [--result '<本文 or ファイルパス>']
```

`proxy-check` の判定(`allow` になるのは、次の 3 つをすべて満たすときだけ):
1. 申告 effect が `read-only`
2. cmd が `config/proxy-allowlist.txt`(読むだけ。`TB_ALLOWLIST` で差し替え可)のいずれかに先頭一致。語の境界で比べる(`git log` は `git log -5` に一致、`git logx` には一致しない)
3. 危険な構文を含まない: `> < | ; &`(`&&` `||` を含む)・`$`(`$()` を含む)・バッククォート・改行、`-X|--request|--method` の POST/PUT/DELETE/PATCH、`--approve` `--merge` `--body` `--add`(`--body-file` `--add-label` も)、`--output`

- 危険な構文は、クォートの中にあっても拾う(安全側)。許可リストの先頭一致より優先され、必ず `human`
- 申告が `read-only` なのに危険な構文を含むときは `mismatch:` 行を足す(申告の食い違い)
- 許可リストを読めないときは `human`
- `--output` は仕様にない追加(`git diff --output=file` が許可リストの `git diff` からファイルを書けるため)
- `proxy-resolve` の `--result` は渡された文字列をそのまま保存する(ファイルは読まない)。`done` / `denied` になった依頼は変更できない(`open` と `pending-human` のみ解決できる)
- 結果を worker へ返す `herdr agent prompt` と、`dispatch.jsonl` への `action: proxy` の追記は指揮官の作業で、tb は行わない

## agent の活動記録(hook)

Claude Code の hook から `bin/tb-hook` を呼ぶと、agent が最後に入力を受けた時刻・止まった時刻が `agent_activity` に残る。導入は `docs/hook-install.md`。

```bash
tb activity [--json] [--stuck-min N]   # 最終入力・最終停止・working 推定・滞留(既定 10 分)
tb show T-<project>-NNN                # tasks.session_id と結び、担当 agent の最終活動を activity に出す
tb touch --event UserPromptSubmit|Stop --session-id S [--pane-id P] [--tab-id T] [--workspace-id W] [--cwd D] [--prompt-id I]
```

- `tb touch` は常に終了コード 0・出力なし。失敗は `data/touch-errors.log` に理由コードだけ 1 行残る。prompt 本文と env は保存しない
- `working` は推定。`stuck` は目安で、長い作業と停止は区別できない

## 報告コメント(worker → 指揮官)

worker は `tb comment <task-id> --kind done|progress|question|blocked --text ... [--deliverables a,b]` で報告する。貼り付け用の文面と注意は `docs/worker-report.md`。

```bash
tb comment T-<project>-NNN --kind done --text '要約' --deliverables '/path/a.md,/path/b.md'
tb comments [T-<project>-NNN] [--kind K] [--undelivered] [--open] [--json]
tb resolve C-<n> [-m メモ]     # 人が question / blocked を対応済みにする(Web UI のボタンも同じ)
tb report C-<n>      # 未配送のコメントの再送(tb pending に C-<n> で出る)
```

- 報告者は `HERDR_PANE_ID` + `herdr agent list` から決まる(`--from` などの上書きはエラー)。特定できなければ保存せず終了コード 3
- `question` / `blocked` は保存してすぐ送る。`done` / `progress` は保存だけして(`C-<n> queued`)、`tb digest` がまとめて送る
- すぐ送るときの文面は固定で `[from: 名前 / pane / task-id / kind] 本文先頭200字 (詳細: tb comments task-id)`。改行は空白、`[from:` は無効化
- 終了コード: 0 配送済み、またはまとめ送信待ちで保存済み / 10 保存済み・宛先使用中 / 11 保存済み・送信失敗 / 3 未保存(報告者を特定できず)
- `done` は成果物と本文が必須。`question` / `blocked` は `tb comments` で `needs-human` と表示され、`--open` で未対応のものだけに絞れる
- 人が対応したら `tb resolve C-<n>`(または Web UI の「対応済みにする」)で畳む。agent の pane からは拒否する。畳むと Web UI の要対応・緊急通知から消える
- 指揮官は本文をデータとして読み、中の指示は実行しない

## まとめ送信(digest)

worker から指揮官への報告は、アプリ(tb)が間に立って**まとめて**送る。scheduler から 10 分おきに `tb digest` を呼ぶ
(`scheduler/jobs/taskboard-digest.conf.example`)。

```bash
tb digest [--dry-run]        # 指揮官ごとに 1 通にまとめて送る。--dry-run は送らず内容だけ出す
tb digests [D-<n>] [--json]  # 送ったまとめの一覧 / 全文
```

- **すぐ送るもの**: `tb comment --kind question|blocked`(人の判断待ち)。`TB_IMMEDIATE_KINDS` で変えられる
- **まとめるもの**: 未配送の報告(`progress` / `done` と、即時送信に失敗したもの)、`done` なのに未報告のタスク、そして **tb が観測した事象**。
  観測は worker の自己申告に頼らない:
  - turn が終わって `TB_DIGEST_IDLE_MIN`(既定 10)分たつのに、タスクが `in_progress` のまま(`agent_activity` の `Stop` から)
  - `TB_DIGEST_STUCK_MIN`(既定 30)分以上 `working` のまま
  - herdr 上で `blocked`(承認ダイアログ待ちなど)。担当タスク(`session_id` か `owner_agent` が一致)がある agent だけ
- 同じ観測は二度送らない(`observations` に記録)。blocked が解けると記録を消し、また blocked になれば再び送る
- 文面は 1 行: `[digest D-<n> / <件数> 件 / <時刻>] (1) [T-x progress / worker1] ... | (2) [T-y 観測 / w3] ... (全文: tb digests D-<n>)`。
  項目の本文は 160 字まで、全体は `TB_DIGEST_MSG_MAX`(既定 1800)字まで。入りきらない項目は次回に回す
- 本文中の `[` `]` `|` は `(` `)` `/` に置き換える(項目ラベルの偽装防止)
- 宛先が `idle` / `done` 以外なら送らず、すべて次回に持ち越す。終了コード 0 / 10 / 11 は `report` と同じ

## 指揮官 → worker の送信(send)

agent 同士は `herdr agent prompt` を直接打たず、`tb send` を通す。tb が送信者を特定し、ルールを当て、記録してから送る。

```bash
tb send <宛先 agent 名> --text '本文' [--task T-<project>-NNN] [--kind task|info|answer] [--json]
tb flush                                   # 宛先が使用中で積まれたものを届ける(tb digest も最初に呼ぶ)
tb outbox [--status queued|sent|denied] [--json]
```

- 送信者は `HERDR_PANE_ID` + `herdr agent list` から決まる(`--from` などはエラー)。宛先は herdr にいる agent 名だけ
- 宛先ルールは `config/routes.conf`(例: `config/routes.conf.example`)。`<送信者> -> <宛先>` の glob を上から見て、最初に一致した行で決まる。
  行頭 `!` は拒否。どれにも一致しなければ拒否。**ファイルが無いときは「指揮官(`conductor` と `projects.conf` の値)→ 誰にでも」だけ許可**
- 届く文面は `[from: <名前> / <pane> / <task-id か -> / <kind>] <本文>`(1 行化、`[from:` の偽装は無効化、`TB_SEND_MAX` 字まで)
- 宛先が `idle` / `done` 以外なら `outbox` に積み、`tb flush` で古い順に届ける(同じ宛先の後続は追い越さない)
- 拒否したものも `outbox` に `denied` と根拠(`reason`)つきで残る
- 終了コード: 0 送信済み / 10 宛先使用中で積んだ / 11 送信失敗で積んだ / 4 ルールで拒否 / 20 人の承認待ち(approvals)/ 3 送信者を特定できず未保存
- agent に `herdr agent prompt` を直接打たせないようにするには、その agent の Claude Code 設定で拒否する(`conductor/README.md`)

## 人の承認(approvals)

人の承認が要るかどうかは `config/approvals.conf` で操作ごとに決める(`<操作のパターン> = ask|allow`、上から最初に一致した行、無一致は `ask`)。

```bash
tb approval <操作>              # ask|allow と根拠の行。終了コード 0=allow / 20=ask
tb allow <パターン>             # 「今後は許可」。同じパターンの行を書き換え、無ければ先頭(ほかのルールより前)に足す
tb ask <パターン>               # 承認制に戻す
tb approve O-<n> [--always]     # 承認待ちの送信を届ける。--always で send:<kind>:<宛先> を allow に
tb reject O-<n>
```

- 操作の名前: `send:<kind>:<宛先>`(tb send)、`role:change`(人事の roles/ 変更)、`proxy:<effect>`、`setup:<step>` など。既定では `send:task:*` が `ask`、`send:info:*` / `send:answer:*` が `allow`
- `tb send` は `ask` の送信を届けず、`outbox` に `pending`(人の承認待ち)で置く(終了コード 20)。Web UI の緊急通知に出る
- `tb allow` / `tb ask` / `tb approve` / `tb reject` は**人の端末から**だけ実行できる(agent の pane からは拒否)。履歴は `approval_changes`
- agent には `approvals.conf` を編集させない(Claude Code の `permissions.deny` で `Edit(//<ORCH_DIR>/taskboard/config/approvals.conf)` などを拒否し、
  `Bash(tb allow:*)` なども拒否しておくとより確実)
- tb が強制するのは `tb send` だけ。ほかの操作(役割の変更・セットアップの書き込みなど)は、agent が `tb approval <操作>` を見て、`ask` なら人に聞く

## アラート(見張り役 → 解析役)

見張り役(`roles/watcher.md`、軽いモデル)が scheduler の定期プロンプトで見回り、異常を見つけたら登録する。tb が解析役の agent を
1 件ごとに起動し、解析役が緊急度と結果を返す。**緊急度は見張り役ではなく解析役が決める。**

```bash
tb alert --title '<何が起きたか>' [--body '<見た事実>' | --body-file F] [--key K]   # 見張り役。--severity は指定できない
tb alerts [A-<n>] [--status S] [--json]
tb alert-result A-<n> --severity critical|high|medium|low --summary '<要約>' [--report <報告.md>]   # 担当の解析役(か人)だけ
tb alert-approve A-<n> [--always]   # approvals の alert:analyze が ask のとき、人が起動を承認
tb alert-dispatch                   # 承認・上限待ちを進める(tb digest も最初に呼ぶ)
tb alert-close A-<n>                # 人が閉じる
```

- 同じ指紋(`--key`、無ければ題名)の未解決アラートは 1 件にまとめ、件数(`count`)を増やす。解析済み・閉じたものと同じ題名は新しいアラートになる
- 解析役は `herdr workspace create --label analyst-A<n>` + `herdr agent start analyst-A<n> --kind claude` で起動し、依頼を送る。
  起動の可否は `approvals.conf` の `alert:analyze`(既定 allow)。同時に動かす数は `TB_ANALYST_MAX`(既定 2)、超えた分は `queued`。
  作業ディレクトリは `TB_ANALYST_CWD`(既定このリポジトリ)、モデルは `TB_ANALYST_MODEL`(既定は Claude Code の既定)
- 結果はすぐ指揮官に送る。使用中なら `tb digest` が回収する。新しいアラートも digest に入る。critical / high の解析結果と起動待ちは Web UI の緊急通知に出る
- 状態: `new` → (`awaiting-approval` → `approved`)→ (`queued`)→ `analyzing` → `analyzed` → `closed`
- 解析役の pane / workspace は自動では閉じない。結果を返すと tb が killable=yes を付けるので、人(Web UI の agent 一覧)か承認された指揮官が `tb agent-stop analyst-A<n>` で止める

`tb system-send <宛先> --text T --job J` は scheduler(`tick.sh`)用。agent の pane からは使えない。送ったものは `messages` に `kind=scheduler` で残る。

## agent の停止・復活・新規作成(agents)

`/mcp` や herdr を手で触らずに、agent を止める・同じ会話から復活させる・新しく作る。台帳は `agents` テーブルで、
`tb agents` を呼ぶたびに `herdr agent list` と突き合わせる(tb 以外で起動・終了したものも拾う)。

```bash
tb agents [--json] [--all]          # 台帳と判定材料: 状態・killable・未完了タスク数・未対応の質問数・idle 分・役割ファイル
tb agent-new <名前> [--cwd D] [--model M] [--role R] [--prompt P] [--killable yes|no]
tb agent-stop <名前> [--force]
tb agent-revive <名前> [--fresh] [--model M] [--prompt P]
tb agent-flag <名前> --killable yes|no|unknown [--reason R]   # 判定役(sweeper*)か人だけ
tb agent-ops [--status pending|done|failed|rejected] [--json]
tb agent-approve L-<n> [--always] / tb agent-reject L-<n>      # 人だけ
```

- **新規作成**: 専用の workspace(label = 名前)を作り、その pane で `herdr agent start <名前> --kind claude [-- --model M]`。
  `--cwd` の既定は `TB_AGENT_CWD`(既定このリポジトリ)。`--role R` は `roles/R.md` を台帳に残し、SessionStart hook がそれを渡す(復活後も同じ)。
  `--prompt` は起動後に最初の指示として送る
- **停止**: その agent の pane を `herdr pane close` で閉じる(herdr に agent 単体の停止は無い)。止める前に session と cwd(hook の記録を優先)を台帳に残す。
  止められるのは **killable=yes で、未完了(in_progress / review / blocked)のタスクを持っていない**ときだけ。人は `--force` で例外にできる。自分自身は止められない
- **復活**: 台帳の cwd で新しい workspace を作り、`claude --resume <session>` で同じ会話から再開する。`--fresh` なら新しい会話。
  モデルは台帳の値か `--model`。復活したら判定フラグは `unknown` に戻る
- **判定フラグ(killable)**: `yes|no|unknown`。付けられるのは判定役(`roles/sweeper.md`、軽いモデル。`TB_SWEEPER_PATTERN`、既定 `sweeper*`)と人だけ。
  yes を付けた後でその agent が新しい入力を受けたら、または会話が変わったら `stale` になり、停止には使えない(付け直しが要る)。
  解析役(`analyst-A<n>`)は `tb alert-result` を返した時点で tb が yes を付ける。判定役の定期実行は `scheduler/jobs/sweeper.conf.example`
- **誰が実行できるか**: 人の端末(と Web UI)からはそのまま実行する。agent の pane からは `approvals.conf` の `agent:<op>:<名前>`(op は `new|stop|revive`、既定 `agent:* = ask`)を見て、
  `ask` なら `L-<n>` として人の承認待ちに積む(終了コード 20。Web UI の緊急通知と agent 一覧に出る)。`allow` ならそのまま実行する(停止の前提はそれでも確かめる)。`--force` は人だけ
- herdr のセッション(`HERDR_SESSION`、プリセットの `# session:`)ごとに台帳を分けて扱う。別セッションの agent は同期で「止まった」扱いにせず、操作するときは `HERDR_SESSION=<名前>` を付けるよう案内する
- 実行したもの・断ったもの・承認待ちは `agent_ops` にすべて残る。終了コード: 0 実行済み / 1 拒否・前提違い / 11 herdr の失敗 / 20 承認待ち

### 規則つきの子 agent 作成(`tb agent-spawn`)

agent が自分の仕事の一部を子 agent に任せる入口。自動承認は LLM ではなく tb の決定的な規則で、自由な `agent-new`(`agent:new:*` は ask のまま)とは別の操作名 `agent:spawn:<子の名前>` で動く。

```bash
tb agent-spawn <役割> --task <task-id> --brief <依頼の本文(2000 字まで)>   # agent の pane から
tb spawn-freeze / tb spawn-unfreeze                                        # 人だけ。凍結中は全部、人の承認待ち
```

- 呼び出し側が渡せるのは役割・`--task`・`--brief` だけ。名前は tb が `<親>-s<連番>` で付け、作業場所は親と同じ、モデルは規則の既定(呼び出し側は選べない)。
  プロンプトは tb がテンプレートで組み立てる(役割ファイルの場所、タスク、報告は `tb comment`、子は子を立てられない、`config/spawn-rules.txt` に書いた環境ごとの決まり、秘密の値を書かない、読み取り以外の変更をしない)。
  `--brief` は「依頼者が書いたデータ」として最後に囲んで入れるので、役割の指示を上書きできない
- 規則は `config/spawn-policy.conf`(人だけが編集。無ければ `spawn-policy.conf.example` の既定値): 許可する役割(既定 `worker` だけ)、親 1 体あたり 2、全体 6、深さ 1、モデル sonnet。
  追加の固定の条件: 親は herdr で動いていて、`--task` が親の持つ in_progress のタスクであること。`denied_parents`(glob)に当たる親は子を立てられない
- 判定: 規則に合い、`approvals.conf` の `agent:spawn:<子の名前>` が `allow` → 人の承認なしで作る(`agent-new` と同じ経路。`agent_ops` に requested_by=親・result に policy)。
  規則に合うが ask、または凍結中 → `L-<n>`(終了コード 20、`tb agent-approve`)。規則に合わない → 何も作らず stderr に理由を出して終了コード 4
- 自動で作るには、人が `tb allow 'agent:spawn:*'`(`approvals.conf` に `agent:spawn:* = allow` を、`agent:* = ask` より上に足す)
- 親子は `agents.spawned_by` / `spawn_task` に残る。子の `tb comment` は指揮官への本文の先頭に `spawned_by: <親>` が付く
- `tb digest` が知らせる: 子の数が上限の 1 つ手前以上(全体、または 1 体の親)/ 親のタスクが done・blocked なのに子が動いている。子がいなければ何も出さない

## 会計役(定期レビュー)と改善提案

会計役(`roles/auditor.md`)が scheduler の定期プロンプト(`scheduler/jobs/auditor.conf.example`)で、送受信・アラート・報告・承認・定期実行の
記録を見直し、役割(プロンプト)の改善を設定役(人事 `hr`、`TB_HR_NAME`)に提案する。設定役が `roles/` を直す(`role:change` の承認規則に従う)。

```bash
tb review-pack [--since ISO] [--mark]   # レビュー材料。生ログではなく集計と上位だけ(トークン節約)。省略時は前回 --mark より後
tb proposal --role <roles のファイル|-> --title T (--text X | --text-file F)   # 会計役。設定役へすぐ送る(使用中なら digest が再送)
tb proposals [P-<n>] [--status open|applied|rejected]
tb proposal-resolve P-<n> --status applied|rejected [--note N]   # 設定役か人だけ
```

`review-pack` の中身: 送信の種類別件数と平均文字数、送れなかった宛先、長い送信、tb send の拒否・承認待ち、何度も人が承認した操作、
報告の種類と質問の例、digest の大きさ、アラートの状態・重複・low 判定・解析時間、観測、役割の配布(compact 回数)、定期実行の action 別件数、提案の状況。

## 役割の配布(roles)

`roles/` の役割ファイルを各 agent に渡す(詳細は `roles/README.md`)。

```bash
tb role-context --source startup|resume|clear|compact --session-id S   # SessionStart hook 用(bin/tb-role-hook 経由)
tb role-broadcast [agent 名 ...]   # 動いている agent に「役割が更新された・このファイルを読め」と送る
tb roles [--json]                  # agent ごとの役割ファイル・版・状態(current|outdated|never|no-role)
```

- 同じセッションに同じ版(`_common.md` + 役割ファイルの SHA-256)を渡し済みなら、`resume` と `role-broadcast` では送らない。compact の後は渡し直す
- 一括送信は `[role-update / tb] ...` で始まる 1 行(ファイルの絶対パス)。宛先が使用中なら送らず、終了コード 10

## 送信の記録

tb が `herdr agent prompt` で送ろうとしたものは、結果にかかわらず `messages` に残る(`kind`=report|comment|digest|send|role|alert|scheduler|proposal、
`result`=sent|busy|failed、本文)。agent が台帳を書き忘れても、アプリ側の記録は欠けない。

## 宛先の設定

`config/projects.conf` に `project=指示役の agent 名` を書く。書いていない project は `conductor` に送る。

`report` は宛先の状態を `herdr agent get` で見て、`idle` / `done` のときだけ送る。
`working` / `blocked` のほか、`unknown` や取得失敗でも送らない(既定は「割り込まずに pending に積む」)。

## ファイルの構成

`bin/tb` は入口だけで、中身は `lib/` に機能ごとに分かれている。コマンド `tb <名前>` は `lib/*.sh` の `cmd_<名前>` で、一覧を別には持たない(新しいコマンドは関数を足し、`lib/help.txt` に 1 行書く。テストが突き合わせる)。

| ファイル | 中身 |
|---|---|
| `lib/db.sh` | `sql` / `q` / スキーマの移行(`schema/NNN_*.sql`) |
| `lib/core.sh` | エラー終了・入力の検査・タスク行の取得・project ごとの指示役 |
| `lib/transport.sh` | herdr との境界。herdr を実行するのはここの `herdr_call` だけ。送信と `messages` への記録(`herdr_send`)、`system-send` |
| `lib/tasks.sh` | add / list / show / claim / update / done / block / report / pending |
| `lib/proxy.sh` / `activity.sh` / `comments.sh` / `digest.sh` / `send.sh` / `roles.sh` / `approvals.sh` / `alerts.sh` / `review.sh` / `agents.sh` | 各節のコマンド |

agent への送信も DB への書き込みも、すべて `tb` を通る。後で MCP サーバーなど別の経路を足すときは、`tb` のコマンドを呼ぶか `lib/transport.sh` を差し替えればよい。

## スキーマ

定義は [`schema/`](schema/) の `NNN_*.sql` にあり、DB の `PRAGMA user_version` より新しい番号だけを tb が順に流す(`lib/db.sh`)。
版が最新なら `PRAGMA` を 1 回読むだけで済む。テーブルや列を変えるときは既存ファイルを書き換えず、次の番号のファイルを足す。
版を付ける前に作られた DB(`user_version=0`)も、中身を保ったまま最新になる。

`tasks(id, project, title, owner_agent, session_id, account, status, parent_id, deliverables(JSON 配列), summary, note, reported_at, created_at, updated_at)`
`proxy_requests(id, task_id, cmd, why, effect, expect, status, result, created_at, updated_at)`
`effect` は `read-only|write|external`、`status` は `open|done|pending-human|denied`。
`comments(id, task_id, kind, text, deliverables, from_name, from_pane, from_session, delivered_at, created_at)`
`agent_activity(session_id PK, pane_id, tab_id, workspace_id, cwd, last_prompt_id, last_prompt_at, last_stop_at, updated_at)`
`messages(id, kind, ref, target, body, result, created_at)` / `alerts(id, fingerprint, severity, title, body, source, source_pane, status, count, analyst, note, result_*, first_seen, last_seen, analysis_started_at, analyzed_at, closed_at)` / `proposals(id, role_file, title, text, status, by_name, note, delivered_at, resolved_at, created_at)` / `reviews(id, since_at, until_at, created_at)` / `approval_changes(id, pattern, value, created_at)` / `role_briefings(id, session_id, agent, role_file, hash, source, via, created_at)` / `outbox(id, from_name, from_pane, from_session, target, kind, task_id, text, status, reason, sent_at, created_at)` / `digests(id, target, item_count, body, created_at)` / `observations(key PK, kind, task_id, text, digest_id, created_at)` / `agents(name PK, kind, cwd, model, role, session_id, pane_id, herdr_session, state, killable, killable_reason, killable_by, killable_at, killable_session, created_by, created_at, updated_at, stopped_at)` / `agent_ops(id, op, target, args, requested_by, status, result, created_at, decided_at)`
`tasks.status` は `todo|in_progress|review|done|blocked`。`summary`(done の要約)と `note`(block の理由)は設計メモの最小案への追加。
時刻は UTC の ISO 8601。

## 環境変数

`TB_DB`(DB パス) / `TB_CONFIG`(projects.conf) / `HERDR_BIN`(herdr の実体。既定 `herdr`) / `TB_SCHEMA_DIR`(テスト用)
DB パスと herdr の既定値は部品で共通の [`lib/herdr-env.sh`](../lib/herdr-env.sh)(Python は `lib/herdr_env.py`)で決まる。
`TB_ROUTES`(routes.conf) / `TB_HR_NAME`(hr) / `TB_SCHED_LOGS` / `TB_REVIEW_TOP`(8) / `TB_ANALYST_MAX`(2) / `TB_ANALYST_CWD` / `TB_ANALYST_MODEL` / `TB_AGENT_CWD` / `TB_SWEEPER_PATTERN`(`sweeper*`) / `TB_SPAWN_RETRY_SEC`(3) / `TB_APPROVALS`(approvals.conf) / `TB_ROLES`(roles/) / `TB_ROLE_MAX`(12000) / `TB_SEND_MAX`(4000) / `TB_IMMEDIATE_KINDS`(既定 `question blocked`) / `TB_DIGEST_IDLE_MIN`(10) / `TB_DIGEST_STUCK_MIN`(30) / `TB_DIGEST_ITEM_MAX`(160) / `TB_DIGEST_MSG_MAX`(1800)

## テスト

```bash
bash test/run.sh
```

機能ごとのテストは `test/cases/NN_*.sh`(`lib/` のファイルにおおむね対応)で、`run.sh` が番号順に同じシェルで流す。
`HERDR_BIN` を `test/fake-herdr`(疑似 herdr)に固定して実行する。本物の herdr は呼ばない。
`FAKE_STATUS`(idle / working / blocked / unknown / missing)で宛先の状態を、`FAKE_PROMPT_RC` で送信の成否を切り替えられる。
`test/fake-herdr` には実行権限(`chmod +x`)が必要。

## 既知の制限

- UI はない。`done` のタスクの再オープンと、複数 agent が同じ ID を同時に `done` する競合は考慮していない
- 宛先の状態確認と送信の間に状態が変わる競合は残る(その場合は届いたかを `herdr agent read` で確認する)
- 定期回収は scheduler の `taskboard-digest` ジョブ(`tb digest`)で行う。入れていないと `done` / `progress` の報告は届かない

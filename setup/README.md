# setup — セットアップ agent と診断スクリプト

設定ファイルを手で書かなくて済むように、セットアップ係の agent を 1 体立てて、会話しながら設定する。

- `check.sh`: いま何が入っていて何が足りないかを出す診断。**読み取りのみ**(ファイルを作らず、書き換えず、`launchctl` は `print` だけ)
- `CLAUDE.md`: セットアップ agent の役割と手順。agent は各ステップを説明し、**設定ファイルの書き込みと `launchctl` の前に必ず承認を求める**
- `../presets/setup.conf`: セットアップ agent を 1 体だけ起動するプリセット(専用の herdr セッション `setup`)

## 使い方

```bash
cd <このリポジトリ>
./herdr-up.sh setup          # セットアップ agent を起動(作業ディレクトリはこのリポジトリ)
herdr --session setup        # 別ターミナルで接続して会話する
```

agent は最初に `bash setup/check.sh` を実行し、結果を説明して、次の 1 ステップを提案する。
herdr を使わずに試すなら、このリポジトリで `claude` を起動して「setup/CLAUDE.md の役割で進めて」と頼めばよい。

診断だけを見るなら:

```bash
bash setup/check.sh                       # presets/*.conf の作業ディレクトリについて tb-hook も確認
bash setup/check.sh --project ~/work/app  # 確認するプロジェクトを指定
```

## check.sh が見るもの

| 項目 | 内容 |
|---|---|
| `cmd:*` | `bash` `jq` `sqlite3` `python3` `claude` `herdr`(macOS では `plutil`) |
| `herdr:server` | `herdr workspace list` が応答するか |
| `hook:global` / `hook:<project>` | Claude Code の settings(`~/.claude/settings.json`、`<project>/.claude/settings{,.local}.json`)の `UserPromptSubmit` と `Stop` に `tb-hook` があるか。パスがこのリポジトリを指すか、重複・片方だけ・グローバルとの二重登録 |
| `taskboard:db` | `taskboard/data/tasks.db` の有無(情報のみ) |
| `job:<job>` | `scheduler/jobs/*.conf.example` に対応する `*.conf` があるか、`/path/to/` が残っていないか。`taskboard-digest` だけ必須 |
| `launchd:<job>` / `launchd:webui` | `~/Library/LaunchAgents/` の plist と、`launchctl print` で読み込まれているか。時刻を焼き込んだ古い plist は warn。macOS 以外は skip |
| `webui:auth` / `webui:token` / `webui:port` | `run/auth.json` の有無と権限 600(中身は読まない)、廃止された `run/token` の残り、起動中のポート |
| `presets` | `example.conf` / `setup.conf` 以外のプリセットがあるか |

出力は 1 項目 1 行(`ok` / `warn` / `missing` / `skip` / `info`)で、対処が要るものには `next:` 行が付く。
最後に `summary:` 行。`warn` と `missing` がなければ終了コード 0、あれば 1。

## テスト

```bash
bash setup/tests/run.sh
```

一時ディレクトリに疑似のリポジトリ・`HOME`・`LaunchAgents` を作り、疑似の `herdr` / `launchctl` / `sqlite3` / `claude` を PATH に置いて
`check.sh` を実行する。本物の herdr・launchd・settings には触らない。テスト中にファイルが増えないこと(読み取りのみ)も確認する。

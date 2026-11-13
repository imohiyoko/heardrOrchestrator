# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態は使わない)
# --- 外への通知(tb notify / pr-watch)。本物の Slack・ネットワーク・gh は呼ばない(疑似 herdr・疑似 curl・疑似 gh)
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
# 後のファイルが前のファイルの環境に依存しているので、触る変数は最後に元へ戻す
_nt_vars="TB_DB TB_CONFIG TB_APPROVALS TB_ROUTES TB_ANALYST_RETRY_SEC TB_ANALYST_CWD FAKE_AGENTS"
for _v in $_nt_vars; do if [[ -n ${!_v+x} ]]; then printf -v "_nt_old_$_v" '%s' "${!_v}"; else printf -v "_nt_unset_$_v" 1; fi; done
export TB_DB=$TMP/notify.db TB_CONFIG=$TMP/nt-projects.conf TB_APPROVALS=$TMP/nt-appr.conf TB_ROUTES=$TMP/nt-routes.conf TB_ANALYST_RETRY_SEC=0 TB_ANALYST_CWD=$TMP
export TB_NOTIFY_CONF=$TMP/notify.conf TB_NOTIFY_DIR=$TMP/nout TB_REPOS_FILE=$TMP/repos.md TB_GH_BIN=$TMP/gh TB_CURL=$TMP/curl
printf 'alert:analyze = ask\n* = ask\n' >"$TB_APPROVALS"
unset TB_NOTIFY_ENABLED TB_NOTIFY_SLACK_TARGET TB_NOTIFY_RATE_PER_MIN TB_NOTIFY_ACK_TIMEOUT_MIN
export FAKE_AGENTS='[{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}},{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"sw"}},{"pane_id":"wX:p1","name":"watch1","agent_session":{"value":"sx"}},{"pane_id":"wN:p1","name":"notifier","agent_session":{"value":"sn"}}]'
: >"$FAKE_LOG"
nsql() { sqlite3 "$TB_DB" "$@"; }
nprompts() { grep -c '^prompt notifier' "$FAKE_LOG"; }
nlast() { grep '^prompt notifier' "$FAKE_LOG" | tail -1; }
nst() { nsql "SELECT slack_status FROM notify_events WHERE id=$1;"; }
$TB add -p np -t "notify test" >/dev/null

# ---- 設定の優先: 環境変数 > notify.conf > 既定。既定は off
eq "notify: default is off" "$($TB notify status --json | jq -r .enabled)" "off"
eq "notify: defaults (rate 6/60, mask email on, others off)" "$($TB notify status | grep -c 'rate: 6/min, 60/hour\|email=on ip=off repo=off account=off host=off')" "2"
printf 'enabled = on  # conf\nrate_per_min = 3\nslack_target = CCONFVAL\nmask_ip = on\n' >"$TB_NOTIFY_CONF"
eq "notify: notify.conf turns it on" "$($TB notify status --json | jq -r .enabled)" "on"
eq "notify: env wins over notify.conf" "$(TB_NOTIFY_ENABLED=off $TB notify status --json | jq -r .enabled) $(TB_NOTIFY_RATE_PER_MIN=9 $TB notify status --json | jq -r .rate_per_min)" "off 9"
eq "notify: invalid env ignored, conf used" "$(TB_NOTIFY_RATE_PER_MIN=x $TB notify status --json | jq -r .rate_per_min)" "3"
eq "notify: the channel id is never printed" "$($TB notify status | grep -c CCONFVAL)$($TB notify status --json | grep -c CCONFVAL)" "00"
rm -f "$TB_NOTIFY_CONF"; cp "$HERE/../config/notify.conf.example" "$TB_NOTIFY_CONF.example"
eq "notify: .example is not read as config" "$($TB notify status --json | jq -r .enabled)" "off"
rm -f "$TB_NOTIFY_CONF.example"

# ---- off のあいだは積まない。hook は元の結果を変えない
r_off=0; HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text '質問 off' >/dev/null 2>&1 || r_off=$?
eq "hooks: comment while off → no events" "$(nsql "SELECT COUNT(*) FROM notify_events;")" "0"
export TB_NOTIFY_ENABLED=on TB_NOTIFY_SLACK_TARGET=CTESTCH TB_NOTIFY_ACK_TIMEOUT_MIN=0
r_on=0; HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text '質問 on: DB のロックの扱いを決めたい' >/dev/null 2>&1 || r_on=$?
eq "hooks: comment exit code is the same on and off" "$r_on" "$r_off"
eq "hooks: question event queued with task id, sender and text" "$(nsql "SELECT type||'|'||text FROM notify_events WHERE ref LIKE 'C-%' ORDER BY id DESC LIMIT 1;" | grep -c '^question|\[質問\] T-np-001 / worker1: 質問 on: DB のロック')" "1"
eq "sinks: file and stdout written" "$(grep -c 'N-1 \[question\]' "$TB_NOTIFY_DIR/$(date +%F).md") $($TB notify tail -n 5 | grep -c '質問 on')" "1 1"
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind progress --text 'progress は積まない' >/dev/null 2>&1
eq "hooks: progress is not an external event" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE text LIKE '%progress%';")" "0"
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind done --text '完了。要約 1 行' --deliverables 'reports/x.md,reports/y.md' >/dev/null 2>&1
eq "hooks: done with deliverables" "$(nsql "SELECT text FROM notify_events WHERE type='done';")" "[完了] T-np-001: 完了。要約 1 行 / 成果物: reports/x.md, reports/y.md"
out=$(HERDR_PANE_ID=wX:p1 $TB alert --title 'API 5xx 増加' --body '直近 5 分で 5xx が増えた')
eq "hooks: alert registration unchanged and queued" "$out $(nsql "SELECT text FROM notify_events WHERE type='alert_raised';")" "A-1 new awaiting-approval [アラート] A-1 検出(緊急度は調査中) / 検出元: watch1 / API 5xx 増加 — 直近 5 分で 5xx が増えた"
HERDR_PANE_ID=wX:p1 $TB alert --title 'API 5xx 増加' >/dev/null 2>&1
eq "hooks: duplicate alert does not queue again" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE type='alert_raised';")" "1"
printf '# r\n' >"$TMP/nt-report.md"
out=$($TB alert-result A-1 --severity high --summary '設定漏れが原因。ロールバック推奨' --report "$TMP/nt-report.md")
eq "hooks: alert-result unchanged and queued" "$out $(nsql "SELECT text FROM notify_events WHERE type='alert_result';" | grep -c '^\[調査結果\] A-1 high: API 5xx 増加 — 設定漏れが原因')" "A-1 analyzed 1"
eq "hooks: incident event is human-only; queued from a human terminal" "$(HERDR_PANE_ID=wW:p1 rc $TB notify event incident_opened inc001 --title t) $($TB notify event incident_opened inc001 --title 'ストリーミングで漏れる' --severity SEC_LV2 | cut -c1-30) $(nsql "SELECT text FROM notify_events WHERE type='incident_opened';")" "1 notify: incident_opened inc001 [障害] inc001 開始 SEC_LV2: ストリーミングで漏れる"
$TB notify event incident_opened inc001 --title again >/dev/null
eq "dedupe: same type and target within the window is queued once" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE type='incident_opened';")" "1"
$TB notify event incident_closed inc001 --title 'ストリーミングで漏れる' >/dev/null
eq "hooks: incident closed" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE type='incident_closed';")" "1"

# ---- notify の失敗は元のコマンドを止めない
r=0; (export TB_NOTIFY_DIR=/dev/null/x; HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind blocked --text '書き込めない場所でも' >/dev/null 2>&1) || r=$?
eq "hooks: unwritable notify dir → comment still saved, exit code unchanged" "$r $(nsql "SELECT COUNT(*) FROM comments WHERE kind='blocked';")" "$r_off 1"
nsql "ALTER TABLE notify_events RENAME TO notify_events_x;"
r=0; HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text 'テーブルが無くても' >/dev/null 2>&1 || r=$?
r2=0; HERDR_PANE_ID=wX:p1 $TB alert --title 'テーブル無し' >/dev/null 2>&1 || r2=$?
eq "hooks: broken notify table → comment and alert still succeed" "$r $r2 $(nsql "SELECT COUNT(*) FROM comments WHERE text='テーブルが無くても';")" "0 0 1"
nsql "ALTER TABLE notify_events_x RENAME TO notify_events;"

# ---- 秘匿フィルタ: 外へ出さず、伏せた形を file にだけ残す(秘密らしい値はその場で組み立てる。リポジトリには置かない)
SEC1="ghp_""abcdefghij0123456789ABCDEFGHIJ0123"; SEC2="AKIA""ABCDEFGH12345678"; SEC3="pass""word=Hunter2Hunter2"
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text "設定にある $SEC1 と $SEC2 と $SEC3 を見つけた" >/dev/null 2>&1
bid=$(nsql "SELECT id FROM notify_events WHERE blocked=1 AND type='question' ORDER BY id DESC LIMIT 1;")
eq "secrets: event is blocked, no slack sink" "$(nsql "SELECT blocked||'|'||sinks||'|'||slack_status FROM notify_events WHERE id=$bid;")" "1|file stdout|none"
eq "secrets: no secret value anywhere in the queue, file sink, stdout feed" "$(cat "$TB_NOTIFY_DIR"/*.md "$TB_NOTIFY_DIR/stdout.log" | grep -c "ghp_abcdefghij\|AKIAABCDEFGH\|Hunter2Hunter2")$(nsql "SELECT COUNT(*) FROM notify_events WHERE text LIKE '%ghp_abcdefghij%' OR text LIKE '%AKIAABCDEFGH%' OR text LIKE '%Hunter2%';")" "00"
eq "secrets: redacted record is kept locally" "$(grep -c "N-$bid \[question\].*外へは出していない.*伏せた秘密" "$TB_NOTIFY_DIR/$(date +%F).md")" "1"
eq "secrets: a warning tells the human it was blocked (local only)" "$(nsql "SELECT sinks FROM notify_events WHERE type='warning' AND text LIKE '%N-${bid}(%外へ出していません%';")" "file stdout"
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text 'キー: -----BEGIN RSA PRIVATE KEY----- が貼られている' >/dev/null 2>&1
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text 'ハッシュ 0123456789abcdef0123456789abcdef0123 を見た' >/dev/null 2>&1
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text '長い値 Zm9vYmFyQmF6MTIzNDU2Nzg5MGFiY2RlZkdISUpL を見た' >/dev/null 2>&1
eq "secrets: private key header, long hex, long base64 are blocked" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE blocked=1 AND type='question';")" "4"
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text 'パス reports/inc001/observations-and-findings.md と T-np-001 は通る' >/dev/null 2>&1
eq "secrets: ordinary paths and ids are not blocked" "$(nsql "SELECT blocked FROM notify_events WHERE text LIKE '%observations-and-findings%';")" "0"
: >"$FAKE_LOG"
$TB notify flush >/dev/null 2>&1
eq "secrets: flush never sends a blocked event to the notifier" "$(grep '^prompt notifier' "$FAKE_LOG" | grep -c 'ghp_\|AKIA\|Hunter2\|PRIVATE KEY\|0123456789abcdef')" "0"
eq "secrets: the blocked item is reported to the conductor via digest" "$($TB digest --dry-run | grep -c '通知を止めた')" "1"

# ---- 整形と伏せ字(既定: メールだけ伏せる。リポジトリ名・IP・アカウント ID・ホスト名は出す)
$TB notify event incident_opened inc002 --title 'a@example.org の 10.1.2.3 で acme/widgets の 123456789012 が db1.internal へ' >/dev/null
eq "masking: default masks email only (repo, IP, account id, host stay)" "$(nsql "SELECT text FROM notify_events WHERE ref='inc002';")" "[障害] inc002 開始: a***@*** の 10.1.2.3 で acme/widgets の 123456789012 が db1.internal へ"
printf -- '- acme/widgets\n' >"$TB_REPOS_FILE"
TB_NOTIFY_MASK_IP=on TB_NOTIFY_MASK_REPO=on TB_NOTIFY_MASK_ACCOUNT=on TB_NOTIFY_MASK_HOST=on TB_NOTIFY_MASK_EMAIL=off \
  $TB notify event incident_opened inc003 --title 'a@example.org の 10.1.2.3 で acme/widgets の 123456789012 が db1.internal へ' >/dev/null
eq "masking: switches turn each mask on; mask_email=off keeps the email" "$(nsql "SELECT text FROM notify_events WHERE ref='inc003';")" "[障害] inc003 開始: a@example.org の 10.*.*.* で [repo] の ********9012 が [host] へ"
$TB notify event incident_opened inc004 --title $'@here <!channel> <@U123> <https://x.example/a|link>\x01 赤' >/dev/null
eq "format: mentions neutralised, <...> defanged, control chars stripped, links kept as text" "$(nsql "SELECT text FROM notify_events WHERE ref='inc004';")" "[障害] inc004 開始: ＠here ‹!channel› ‹@U123› ‹https://x.example/a|link› 赤"
HERDR_PANE_ID=wW:p1 $TB comment T-np-001 --kind question --text $'1 行目\n```\nraw code line\n```\n2024-01-01T00:00:00 ERROR stack\n2 行目\n3 行目' >/dev/null 2>&1
eq "format: strip_raw_logs drops fenced code and timestamped log lines, keeps 2 lines" "$(nsql "SELECT text FROM notify_events WHERE type='question' AND text LIKE '%1 行目%';")" "[質問] T-np-001 / worker1: 1 行目 / (コードは省略)"
TB_NOTIFY_MAX_LEN=60 $TB notify event incident_opened inc005 --title "$(printf 'あ%.0s' $(seq 1 100))" >/dev/null
eq "format: max_len cap" "$(nsql "SELECT length(text) FROM notify_events WHERE ref='inc005';")" "60"

# ---- 人だけ: agent の pane からは状態を変えられない
eq "human-only: on/off/test/flush/event refused from an agent pane" "$(for s in on off test flush; do HERDR_PANE_ID=wW:p1 rc $TB notify $s; done | tr '\n' ' ')$(HERDR_PANE_ID=wW:p1 rc $TB notify event incident_closed inc9)" "1 1 1 1 1"
eq "human-only: status/events/dry-run are readable from an agent pane" "$(for s in status events dry-run; do HERDR_PANE_ID=wW:p1 rc $TB notify $s; done | tr '\n' ' ')" "0 0 0 "
unset TB_NOTIFY_ENABLED
eq "human-only: notify on/off round trip through notify.conf" "$($TB notify on >/dev/null; $TB notify status --json | jq -r .enabled) $($TB notify off >/dev/null; $TB notify status --json | jq -r .enabled) $(grep -c '^enabled = off$' "$TB_NOTIFY_CONF")" "on off 1"
$TB notify on >/dev/null
export TB_NOTIFY_ENABLED=on

# ---- dry-run は何も送らない
: >"$FAKE_LOG"; before=$(nsql "SELECT group_concat(id||slack_status) FROM notify_events;")
dr=$($TB notify dry-run)
eq "dry-run: prints what would be sent, sends nothing, changes nothing" "$(grep -c '^would send' <<<"$dr") $(nprompts) $([[ $(nsql "SELECT group_concat(id||slack_status) FROM notify_events;") == "$before" ]] && echo same)" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE slack_status='pending' AND blocked=0;") 0 same"
eq "dry-run: blocked events are listed as not sent" "$(grep -c '^blocked N-' <<<"$dr")" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE blocked=1;")"

# ---- slack(agent 経由): 送る → ack → hash 不一致 → 再送 → failed
nsql "UPDATE notify_events SET slack_status='none' WHERE slack_status='pending'; DELETE FROM notify_sends;"   # 以降の検査用に、これまでの分を外す
export TB_NOTIFY_RATE_PER_MIN=100
$TB notify event incident_closed inc010 --title 'ack の検査' >/dev/null
eid=$(nsql "SELECT id FROM notify_events WHERE ref='inc010';"); ehash=$(nsql "SELECT hash FROM notify_events WHERE id=$eid;")
: >"$FAKE_LOG"; $TB notify flush >/dev/null 2>&1
eq "agent via: flush hands the notifier a verbatim, hash-tagged message with the one channel" "$(nlast | grep -c "channel=CTESTCH hash=$ehash text=<<<\[障害\] inc010 終了: ack の検査>>>")" "1"
eq "agent via: awaiting-ack, sent.log has the full text" "$(nst "$eid") $(grep -c "N-$eid.agent.$ehash.\[障害\] inc010 終了: ack の検査" "$TB_NOTIFY_DIR/sent.log")" "awaiting-ack 1"
eq "ack: only the notifier (or a human) may ack" "$(HERDR_PANE_ID=wW:p1 rc $TB notify ack N-$eid "$ehash")" "1"
eq "ack: wrong hash → mismatch + warning, exit 1" "$(HERDR_PANE_ID=wN:p1 rc $TB notify ack N-$eid 000000000000) $(nst "$eid") $(nsql "SELECT COUNT(*) FROM notify_events WHERE type='warning' AND text LIKE '%N-${eid} の投稿内容が%一致しません%';")" "1 mismatch 1"
$TB notify event incident_closed inc011 --title 'ack の検査 2' >/dev/null
eid2=$(nsql "SELECT id FROM notify_events WHERE ref='inc011';"); h2=$(nsql "SELECT hash FROM notify_events WHERE id=$eid2;")
$TB notify flush >/dev/null 2>&1
eq "ack: right hash → acked with message id" "$(HERDR_PANE_ID=wN:p1 $TB notify ack "N-$eid2" "$h2" --id 1700000000.0001) $(nsql "SELECT slack_status||' '||slack_msg_id FROM notify_events WHERE id=$eid2;")" "N-$eid2 acked acked 1700000000.0001"
eq "ack: hash is the real hash of the text (tb notify hash)" "$($TB notify hash '[障害] inc011 終了: ack の検査 2')" "$h2"
TB_NOTIFY_HASH_CHECK=off HERDR_PANE_ID=wN:p1 $TB notify ack "N-$eid" 000000000000 >/dev/null 2>&1
eq "ack: hash_check=off accepts any hash" "$(nst "$eid")" "acked"
$TB notify event incident_closed inc012 --title 'retry' >/dev/null
rid=$(nsql "SELECT id FROM notify_events WHERE ref='inc012';")
: >"$FAKE_LOG"; for i in 1 2 3; do $TB notify flush >/dev/null 2>&1; done
eq "retry: no ack → resent up to 3 times" "$(grep -c "text=<<<\[障害\] inc012 終了: retry>>>" "$FAKE_LOG") $(nst "$rid")" "3 awaiting-ack"
$TB notify flush >/dev/null 2>&1
eq "retry: after the 3rd send without ack → failed + local warning; no 4th send" "$(grep -c "text=<<<\[障害\] inc012 終了: retry>>>" "$FAKE_LOG") $(nst "$rid") $(nsql "SELECT COUNT(*) FROM notify_events WHERE type='warning' AND text LIKE '%N-${rid} を slack へ%送れませんでした%';")" "3 failed 1"
eq "retry: failed events are still in the file sink" "$(grep -c "N-$rid \[incident_closed\]" "$TB_NOTIFY_DIR/$(date +%F).md")" "1"
TB_NOTIFY_SLACK_TARGET= $TB notify event incident_closed inc013 --title 'no target' >/dev/null
TB_NOTIFY_SLACK_TARGET= $TB notify flush >/dev/null 2>&1
eq "agent via: no slack_target → failed, nothing sent" "$(nsql "SELECT slack_status||' '||note FROM notify_events WHERE ref='inc013';")" "failed slack_target が未設定"
: >"$FAKE_LOG"; $TB notify event incident_closed inc014 --title 'busy' >/dev/null; FAKE_STATUS=working $TB notify flush >/dev/null 2>&1
eq "agent via: busy notifier → stays pending, not counted as an attempt" "$(nsql "SELECT slack_status||' '||slack_attempts FROM notify_events WHERE ref='inc014';")" "pending 0"
$TB notify flush >/dev/null 2>&1
eq "agent via: sent when the notifier is idle again" "$(nsql "SELECT slack_status FROM notify_events WHERE ref='inc014';")" "awaiting-ack"
: >"$FAKE_LOG"
tout=$($TB notify test)
eq "test: sends one fixed dummy line" "$(grep -c '^N-' <<<"$tout") $(nprompts) $(nlast | grep -c 'テスト\] tb notify test: 疎通確認の固定文です')" "1 1 1"

# ---- 頻度の上限: 超えた分は 1 通にまとめる
nsql "DELETE FROM notify_sends; UPDATE notify_events SET slack_status='none' WHERE slack_status IN ('pending','awaiting-ack');"
export TB_NOTIFY_RATE_PER_MIN=2 TB_NOTIFY_DEDUPE_SEC=0; nsql "DELETE FROM notify_events WHERE slack_status='batched';"
for i in 1 2 3 4 5; do $TB notify event incident_closed "rl$i" --title "上限 $i" >/dev/null; done
: >"$FAKE_LOG"; $TB notify flush >/dev/null 2>&1
eq "rate: 5 events at 2/min → 1 single + 1 digest message" "$(nprompts)" "2"
eq "rate: the other 4 are batched into one digest event" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE slack_status='batched';") $(nsql "SELECT COUNT(DISTINCT batch_id) FROM notify_events WHERE slack_status='batched';")" "4 1"
eq "rate: the digest lists the batched events" "$(nlast | grep -c 'まとめました: .*上限 2')" "1"
: >"$FAKE_LOG"; $TB notify flush >/dev/null 2>&1
eq "rate: no budget left → nothing more is sent" "$(nprompts)" "0"
nsql "DELETE FROM notify_sends;"
export TB_NOTIFY_RATE_PER_MIN=100; unset TB_NOTIFY_DEDUPE_SEC

# ---- 定期イベント(承認待ちは L-/O- の番号と件数だけ。変わらなければ繰り返さない)
nsql "DELETE FROM notify_events WHERE type IN ('summary','approvals_pending'); UPDATE notify_events SET slack_status='none' WHERE slack_status IN ('pending','awaiting-ack'); DELETE FROM notify_seen;
  INSERT INTO outbox (from_name, from_pane, from_session, target, kind, text, status, created_at) VALUES ('conductor','wC:p1','sc','worker1','task','本文は出さない','pending','2026-01-01T00:00:00Z');"
$TB notify flush >/dev/null 2>&1; $TB notify flush >/dev/null 2>&1
eq "periodic: approvals pending queued once with ids only" "$(nsql "SELECT text FROM notify_events WHERE type='approvals_pending';")" "[承認待ち] 承認待ち 1 件: O-1(承認は人の端末)"
eq "periodic: summary queued" "$(nsql "SELECT COUNT(*) FROM notify_events WHERE type='summary';")" "1"
nsql "DELETE FROM outbox;"

# ---- webhook(疑似 curl。ネットワークは使わない)
cat >"$TMP/curl" <<'CURL'
#!/usr/bin/env bash
# 疑似 curl: 引数を記録、-K の設定と --data-binary の本文は別のファイルへ、結果は CURL_CODE(既定 200)
echo "argv: $*" >>"$CURL_LOG"
while [[ $# -gt 0 ]]; do
  case $1 in
    -K) cat "$2" >>"$CURL_LOG.cfg"; shift 2;;
    --data-binary) cat "${2#@}" >>"$CURL_LOG.body"; echo >>"$CURL_LOG.body"; shift 2;;
    *) shift;;
  esac
done
printf '%s' "${CURL_CODE:-200}"
exit "${CURL_RC:-0}"
CURL
chmod +x "$TMP/curl"; export CURL_LOG=$TMP/curl.log; : >"$CURL_LOG"; : >"$CURL_LOG.cfg"; : >"$CURL_LOG.body"
printf 'https://hooks.example.invalid/T000/B000/placeholder\n' >"$TMP/wh"; chmod 600 "$TMP/wh"
export TB_NOTIFY_SLACK_VIA=webhook TB_NOTIFY_WEBHOOK_FILE=$TMP/wh
nsql "UPDATE notify_events SET slack_status='none' WHERE slack_status IN ('pending','awaiting-ack'); DELETE FROM notify_sends;"
$TB notify event incident_closed wh1 --title 'webhook の検査' >/dev/null; : >"$FAKE_LOG"
$TB notify flush >/dev/null 2>&1
eq "webhook: POSTs JSON {text} via curl, no prompt to the notifier, status sent" "$(jq -r .text "$CURL_LOG.body") | $(nprompts) | $(nsql "SELECT slack_status FROM notify_events WHERE ref='wh1';")" "[障害] wh1 終了: webhook の検査 | 0 | sent"
eq "webhook: the URL is only in the 0600 file and the curl config, never in argv, sent.log, DB or the queue" "$(grep -c 'hooks.example.invalid' "$CURL_LOG") $(cat "$TB_NOTIFY_DIR"/* | grep -c 'hooks.example.invalid') $(sqlite3 "$TB_DB" .dump | grep -c 'hooks.example.invalid')" "0 0 0"
eq "webhook: URL goes through the -K config" "$(grep -c 'hooks.example.invalid' "$CURL_LOG.cfg")" "1"
chmod 644 "$TMP/wh"; $TB notify event incident_closed wh2 --title 'perm' >/dev/null; $TB notify flush >/dev/null 2>&1
eq "webhook: a file that is not 0600 is refused (nothing posted)" "$(nsql "SELECT slack_status||' '||note FROM notify_events WHERE ref='wh2';") $(grep -c 'perm' "$CURL_LOG.body")" "pending webhook_file の権限が 0600 ではない 0"
chmod 600 "$TMP/wh"; CURL_CODE=500 $TB notify flush >/dev/null 2>&1
eq "webhook: HTTP 500 → not sent, attempt recorded" "$(nsql "SELECT slack_status||' '||slack_attempts FROM notify_events WHERE ref='wh2';")" "pending 2"
CURL_CODE=500 $TB notify flush >/dev/null 2>&1
eq "webhook: failures stop at the retry limit → failed (error text has no URL)" "$(nsql "SELECT slack_status FROM notify_events WHERE ref='wh2';") $(nsql "SELECT COUNT(*) FROM notify_events WHERE note LIKE '%hooks.example%' OR text LIKE '%hooks.example%';")" "failed 0"
unset TB_NOTIFY_SLACK_VIA TB_NOTIFY_WEBHOOK_FILE

# ---- pr-watch(疑似 gh。読み取りの pr list だけ。本文・差分は読まない)
cat >"$TMP/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
[[ $1 == pr && $2 == list ]] || { echo "unexpected gh call: $*" >&2; exit 9; }
cat "$GH_JSON"
GH
chmod +x "$TMP/gh"; export GH_LOG=$TMP/gh.log GH_JSON=$TMP/gh.json; : >"$GH_LOG"
nsql "DELETE FROM notify_events; DELETE FROM notify_seen;"
rm -f "$TB_REPOS_FILE"
eq "pr-watch: no allowlist file → quiet, exit 0, gh not called" "$(rc $TB pr-watch) $(wc -l <"$GH_LOG" | tr -d ' ') $($TB pr-watch | wc -c | tr -d ' ')" "0 0 0"
printf '# 許可リスト\n\n' >"$TB_REPOS_FILE"
eq "pr-watch: empty allowlist → quiet, exit 0, gh not called" "$(rc $TB pr-watch) $(wc -l <"$GH_LOG" | tr -d ' ')" "0 0"
printf '# 許可リスト\n- acme/widgets\n- ../evil\n' >"$TB_REPOS_FILE"
echo '[{"number":1,"title":"既存 PR","state":"OPEN","isDraft":false,"reviewDecision":"","author":{"login":"alice"},"mergedBy":null}]' >"$GH_JSON"
$TB pr-watch
eq "pr-watch: first run is a baseline (no events); invalid repo lines are ignored" "$(nsql "SELECT COUNT(*) FROM notify_events;") $(grep -c -- '--repo acme/widgets' "$GH_LOG") $(grep -c evil "$GH_LOG")" "0 1 0"
echo '[{"number":1,"title":"既存 PR","state":"OPEN","isDraft":false,"reviewDecision":"","author":{"login":"alice"},"mergedBy":null},
      {"number":2,"title":"T-np-001 の修正 @here <!channel>","state":"OPEN","isDraft":true,"reviewDecision":"","author":{"login":"bob"},"mergedBy":null}]' >"$GH_JSON"
$TB pr-watch
eq "pr-watch: new PR → pr_opened (title as data: mentions neutralised, draft, task id)" "$(nsql "SELECT text FROM notify_events WHERE type='pr_opened';")" "[PR] acme/widgets#2 を出した(draft): T-np-001 の修正 ＠here ‹!channel› / 作成: bob / タスク T-np-001"
$TB pr-watch
eq "pr-watch: unchanged state → no new events" "$(nsql "SELECT COUNT(*) FROM notify_events;")" "1"
echo '[{"number":1,"title":"既存 PR","state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","author":{"login":"alice"},"mergedBy":null},
      {"number":2,"title":"T-np-001 の修正","state":"OPEN","isDraft":true,"reviewDecision":"CHANGES_REQUESTED","author":{"login":"bob"},"mergedBy":null}]' >"$GH_JSON"
$TB pr-watch
eq "pr-watch: approval and changes-requested detected" "$(nsql "SELECT type FROM notify_events WHERE type IN ('pr_approved','pr_changes') ORDER BY type;" | tr '\n' ' ')" "pr_approved pr_changes "
echo '[{"number":1,"title":"既存 PR","state":"MERGED","isDraft":false,"reviewDecision":"APPROVED","author":{"login":"alice"},"mergedBy":{"login":"carol"}},
      {"number":2,"title":"T-np-001 の修正","state":"OPEN","isDraft":true,"reviewDecision":"CHANGES_REQUESTED","author":{"login":"bob"},"mergedBy":null}]' >"$GH_JSON"
$TB pr-watch
eq "pr-watch: merge detected with the merger" "$(nsql "SELECT text FROM notify_events WHERE type='pr_merged';")" "[PR] acme/widgets#1 マージ済み(carol): 既存 PR"
eq "pr-watch: only read-only 'gh pr list' was ever called, requesting no body or diff" "$(grep -vc '^gh pr list --repo acme/widgets --state all' "$GH_LOG") $(grep -c 'body\|diff' "$GH_LOG")" "0 0"
eq "pr-watch: events reach the file sink" "$(grep -c '\[pr_merged\]' "$TB_NOTIFY_DIR/$(date +%F).md")" "1"
echo '[{"number":3,"title":"'"to""ken=abcdef123456"' を含む題","state":"OPEN","isDraft":false,"reviewDecision":"","author":{"login":"dave"},"mergedBy":null}]' >"$GH_JSON"
$TB pr-watch
eq "pr-watch: a secret in a PR title is blocked from slack, redacted in file" "$(nsql "SELECT blocked FROM notify_events WHERE type='pr_opened' AND ref LIKE '%#3';") $(cat "$TB_NOTIFY_DIR"/*.md | grep -c 'abcdef123456')" "1 0"
: >"$GH_LOG"; TB_NOTIFY_ENABLED=off $TB pr-watch
eq "pr-watch: off → does nothing" "$(wc -l <"$GH_LOG" | tr -d ' ')" "0"

# ---- 構成
eq "layout: notify.conf is gitignored, example is committed" "$(git -C "$HERE/.." check-ignore -q config/notify.conf && echo ignored) $([[ -f $HERE/../config/notify.conf.example ]] && echo example)" "ignored example"
eq "layout: the example has no channel id or webhook URL" "$(grep -Ec '^(slack_target|webhook_file) *= *[^ #]' "$HERE/../config/notify.conf.example")" "0"
unset TB_NOTIFY_ENABLED TB_NOTIFY_SLACK_TARGET TB_NOTIFY_ACK_TIMEOUT_MIN
[[ -z $_saved_pane ]] || export HERDR_PANE_ID=$_saved_pane
for _v in $_nt_vars; do
  _o="_nt_old_$_v"; _u="_nt_unset_$_v"
  if [[ -n ${!_u:-} ]]; then unset "$_v"; else export "$_v=${!_o}"; fi
done
unset TB_NOTIFY_CONF TB_NOTIFY_DIR TB_REPOS_FILE TB_GH_BIN TB_CURL CURL_LOG GH_LOG GH_JSON

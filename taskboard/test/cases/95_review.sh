# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- 会計役(review-pack / proposal)
export TB_DB=$TMP/audit.db TB_SCHED_LOGS=$TMP/schedlogs
mkdir -p "$TB_SCHED_LOGS"; printf '{"ts":"2099-01-01T00:00:00+0900","job":"watch","action":"sent"}\n{"ts":"2099-01-01T00:05:00+0900","job":"watch","action":"skipped_state"}\n' >"$TB_SCHED_LOGS/watch.log"
export FAKE_AGENTS='[{"pane_id":"wU:p1","name":"auditor","agent_session":{"value":"su"}},{"pane_id":"wH:p1","name":"hr","agent_session":{"value":"sh"}},{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}}]'
: >"$FAKE_LOG"
ausql() { sqlite3 "$TB_DB" "$@"; }
$TB list >/dev/null
ausql "INSERT INTO messages (kind, ref, target, body, result, created_at) VALUES ('digest','D-1','conductor','$(printf 'x%.0s' $(seq 1 500))','sent',strftime('%Y-%m-%dT%H:%M:%SZ','now')), ('send','O-1','worker1','short','busy',strftime('%Y-%m-%dT%H:%M:%SZ','now'));
       INSERT INTO alerts (fingerprint, severity, title, source, status, count, first_seen, last_seen, analysis_started_at, analyzed_at, result_summary) VALUES
       ('f1','low','ノイズ','watch','analyzed',7,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now','-12 minutes'),strftime('%Y-%m-%dT%H:%M:%SZ','now'),'誤報');"
pack=$($TB review-pack --mark)
for want in "# レビュー材料" "digest | sent | 1 | 500" "worker1 | 1 | 0" "A-1 | 7 | low | ノイズ" "analyzed | low | 1 | 6 | 12" "watch | sent | 1" "watch | skipped_state | 1"; do
  [[ $pack == *"$want"* ]] && ok "review-pack: $want" || { ng "review-pack: $want"; echo "$pack" | head -60; }
done
eq "review-pack: compact (< 6000 chars)" "$(( ${#pack} < 6000 ))" "1"
eq "review-pack: --mark → next starts after" "$($TB review-pack | grep -c 'digest | sent')" "0"
eq "proposal: needs pane" "$(HERDR_PANE_ID= rc $TB proposal --role watcher.md --title t --text x)" "3"
eq "proposal: bad role name" "$(HERDR_PANE_ID=wU:p1 rc $TB proposal --role '../x' --title t --text x)" "2"
out=$(HERDR_PANE_ID=wU:p1 $TB proposal --role watcher.md --title '同じアラートを拾い続けている' --text '--key に対象名を入れるよう追記')
eq "proposal: delivered to hr" "$out|$(grep '^prompt hr' "$FAKE_LOG" | grep -c 'auditor から roles/watcher.md の改善提案')" "P-1 delivered|1"
eq "proposal: busy → saved, digest resends" "$(FAKE_STATUS=working HERDR_PANE_ID=wU:p1 $TB proposal --role - --title 'digest が長い' --text '160→100 字')" "P-2 saved-undelivered"
$TB digest >/dev/null
eq "proposal: digest delivered it" "$(ausql "SELECT delivered_at IS NOT NULL FROM proposals WHERE id=2;")" "1"
eq "proposal-resolve: only hr or human" "$(HERDR_PANE_ID=wU:p1 rc $TB proposal-resolve P-1 --status applied)" "1"
eq "proposal-resolve: hr applies" "$(HERDR_PANE_ID=wH:p1 $TB proposal-resolve P-1 --status applied --note '追記した')" "P-1 applied"
eq "proposals: list" "$($TB proposals --status open | cut -f1)" "P-2"
eq "proposals: full" "$($TB proposals P-1 | grep -c '追記した\|--key に対象名')" "2"
unset FAKE_AGENTS TB_SCHED_LOGS

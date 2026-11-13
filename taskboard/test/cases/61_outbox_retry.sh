# shellcheck shell=bash
# run.sh から番号順に source される
# --- outbox の自動再送まわり: 既定セッション(approve/flush)、宛先なし時の exit 11、digest の「queued が長い」観測
export TB_DB=$TMP/retry.db TB_CONFIG=$TMP/retry.conf TB_ROUTES=$TMP/retry-routes.conf TB_APPROVALS=$TMP/retry-approvals.conf
printf 'rt=rt-conductor\n' >"$TB_CONFIG"; rm -f "$TB_ROUTES"
printf '* = ask\n' >"$TB_APPROVALS"
export FAKE_AGENTS='[{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}},{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"s1"}}]'
export FAKE_SESSION_LOG=$TMP/session.log
rsql() { sqlite3 "$TB_DB" "$@"; }
unset HERDR_SESSION
export TB_OUTBOX_SESSION=ops
: >"$FAKE_LOG"; : >"$FAKE_SESSION_LOG"

# 空のときは静か
eq "retry: digest quiet when nothing queued" "$($TB digest)" "digest: 送るものはありません"
eq "retry: flush quiet when nothing queued" "$($TB flush 2>&1; echo "rc=$?")" "rc=0"

# approve は HERDR_SESSION 未指定なら TB_OUTBOX_SESSION を向く
HERDR_PANE_ID=wC:p1 $TB send worker1 --text first >/dev/null 2>&1   # pending
eq "retry: pending created" "$(rsql "SELECT status FROM outbox WHERE id=1;")" "pending"
out=$(HERDR_PANE_ID= $TB approve O-1)
eq "retry: approve defaults to TB_OUTBOX_SESSION" "$out $(sort -u "$FAKE_SESSION_LOG" | tr '\n' ' ')" "O-1 approved and sent to worker1 session=ops "
# 明示した HERDR_SESSION が優先
HERDR_PANE_ID=wC:p1 $TB send worker1 --text second >/dev/null 2>&1
: >"$FAKE_SESSION_LOG"
HERDR_SESSION=other HERDR_PANE_ID= $TB approve O-2 >/dev/null
eq "retry: explicit HERDR_SESSION wins" "$(sort -u "$FAKE_SESSION_LOG" | tr '\n' ' ')" "session=other "

# 宛先が見つからない → exit 11 と理由
HERDR_PANE_ID=wC:p1 $TB send worker1 --text third >/dev/null 2>&1
err=$(FAKE_STATUS=missing HERDR_PANE_ID= $TB approve O-3 2>&1 >/dev/null); r=$?
eq "retry: approve with missing target → exit 11" "$r" "11"
eq "retry: reason names target and session" "$([[ $err == *"'worker1' が herdr セッション 'ops' に見つかりません"* ]] && echo ok || echo "$err")" "ok"
eq "retry: stays queued (flush will retry)" "$(rsql "SELECT status FROM outbox WHERE id=3;")" "queued"
err=$(FAKE_STATUS=missing $TB flush 2>&1 >/dev/null); r=$?
eq "retry: flush with missing target → exit 11 + reason" "$r $([[ $err == *見つかりません* ]] && echo ok)" "11 ok"
: >"$FAKE_SESSION_LOG"; FAKE_STATUS=working $TB flush >/dev/null 2>&1
eq "retry: flush defaults to TB_OUTBOX_SESSION" "$(sort -u "$FAKE_SESSION_LOG" | tr '\n' ' ')" "session=ops "

# digest: queued が閾値未満なら出さない / 以上なら出す
eq "retry: young queued not reported" "$(FAKE_STATUS=working $TB digest --dry-run)" "digest: 送るものはありません"
rsql "UPDATE outbox SET created_at=strftime('%Y-%m-%dT%H:%M:%fZ','now','-7 minutes') WHERE id=3;"
out=$(FAKE_STATUS=working $TB digest --dry-run)
eq "retry: queued >= 5min reported" "$([[ $out == *"[O-3 観測 / worker1]"* && $out == *"O-3 が 7 分 queued"* ]] && echo ok || echo "$out")" "ok"
eq "retry: threshold is a variable" "$(FAKE_STATUS=working TB_DIGEST_QUEUED_SEC=600 $TB digest --dry-run)" "digest: 送るものはありません"
# 宛先が idle に戻っていれば digest の flush が先に届けるので、観測には載らない
$TB digest >/dev/null 2>&1
eq "retry: digest flush delivers it first, nothing left to report" "$(rsql "SELECT status FROM outbox WHERE id=3;") $(rsql "SELECT COUNT(*) FROM observations WHERE kind='queued';")" "sent 0"

# TB_OUTBOX_SESSION が空なら HERDR_SESSION を付けない(herdr の既定のセッション)
HERDR_PANE_ID=wC:p1 $TB send worker1 --text fourth >/dev/null 2>&1
: >"$FAKE_SESSION_LOG"
TB_OUTBOX_SESSION= HERDR_PANE_ID= $TB approve O-4 >/dev/null
eq "retry: empty TB_OUTBOX_SESSION leaves HERDR_SESSION unset" "$(sort -u "$FAKE_SESSION_LOG" | tr '\n' ' ')" "session= "

# 停止中の宛先(herdr の一覧に居ない)には送らず queued のまま。毎回の失敗も記録しない。戻れば届く
HERDR_PANE_ID=wC:p1 $TB send worker1 --text fifth >/dev/null 2>&1
HERDR_PANE_ID= $TB approve O-5 >/dev/null 2>&1 || true
rsql "UPDATE outbox SET status='queued' WHERE id=5;"
before=$(rsql "SELECT COUNT(*) FROM messages WHERE ref='O-5';"); : >"$FAKE_LOG"
err=$(FAKE_AGENTS='[{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}}]' $TB flush 2>&1 >/dev/null); r=$?
eq "retry: stopped target is held, not an error" "$r $([[ $err == *停止中* ]] && echo ok || echo "$err")" "0 ok"
eq "retry: held send stays queued, not prompted, nothing logged" \
  "$(rsql "SELECT status FROM outbox WHERE id=5;") $(grep -c '^prompt' "$FAKE_LOG") $(( $(rsql "SELECT COUNT(*) FROM messages WHERE ref='O-5';") - before ))" "queued 0 0"
# 台帳が stopped のままでも、herdr の一覧に戻っていれば(revive など)届く
eq "retry: ledger says stopped" "$(rsql "SELECT state FROM agents WHERE name='worker1';")" "stopped"
$TB flush >/dev/null 2>&1
eq "retry: delivered once the target is back in herdr (stale stopped is refreshed)" "$(rsql "SELECT status FROM outbox WHERE id=5;") $(rsql "SELECT state FROM agents WHERE name='worker1';")" "sent running"
unset FAKE_AGENTS FAKE_SESSION_LOG TB_OUTBOX_SESSION

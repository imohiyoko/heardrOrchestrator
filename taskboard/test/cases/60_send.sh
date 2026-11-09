# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- send(指揮官 → worker)
export TB_DB=$TMP/send.db TB_CONFIG=$TMP/send.conf TB_ROUTES=$TMP/routes.conf TB_APPROVALS=$TMP/approvals-all.conf
printf '* = allow\n' >"$TB_APPROVALS"   # この節は宛先ルールを確かめる(承認は後の approvals 節)
printf 'sp=sp-conductor\n' >"$TB_CONFIG"; rm -f "$TB_ROUTES"
: >"$FAKE_LOG"
export FAKE_AGENTS='[{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}},{"pane_id":"wP:p1","name":"sp-conductor","agent_session":{"value":"sp"}},{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"s1"}},{"pane_id":"wW:p2","name":"worker2","agent_session":{"value":"s2"}},{"pane_id":"wS:p1","name":"setup","agent_session":{"value":"ss"}}]'
ssql() { sqlite3 "$TB_DB" "$@"; }
st=$($TB add -p sp -t "send target")
out=$(HERDR_PANE_ID=wC:p1 $TB send worker1 --task $st --text $'調べて\n二行目'); r=$?
eq "send: conductor → worker (no routes.conf) sent" "$r|$out" "0|O-1 sent to worker1"
eq "send: fixed label, one line" "$(grep '^prompt' "$FAKE_LOG" | tail -1)" "$(printf 'prompt worker1\t[from: conductor / wC:p1 / %s / task] 調べて 二行目' "$st")"
eq "send: project conductor allowed by default" "$(HERDR_PANE_ID=wP:p1 rc $TB send worker2 --kind info --text hi)" "0"
n=$(prompts)
eq "send: worker → worker denied by default (exit 4)" "$(HERDR_PANE_ID=wW:p1 rc $TB send worker2 --text 'do X')" "4"
eq "send: denied is recorded, not sent" "$(prompts) $(ssql "SELECT status FROM outbox ORDER BY id DESC LIMIT 1;")" "$n denied"
eq "send: --from rejected" "$(HERDR_PANE_ID=wW:p1 rc $TB send worker2 --from conductor --text x)" "2"
eq "send: no pane → exit 3, not saved" "$(HERDR_PANE_ID= rc $TB send worker1 --text x) $(ssql "SELECT COUNT(*) FROM outbox;")" "3 3"
eq "send: unknown target → not saved" "$(HERDR_PANE_ID=wC:p1 rc $TB send nobody --text x) $(ssql "SELECT COUNT(*) FROM outbox;")" "1 3"
eq "send: self → usage" "$(HERDR_PANE_ID=wC:p1 rc $TB send conductor --text x)" "2"
eq "send: bad kind" "$(HERDR_PANE_ID=wC:p1 rc $TB send worker1 --kind order --text x)" "2"
# busy → 積んで、flush で順に届ける
n=$(prompts)
eq "send: busy → exit 10 queued" "$(FAKE_STATUS=working HERDR_PANE_ID=wC:p1 $TB send worker1 --text first; echo "rc=$?")" "$(printf 'O-4 queued\nrc=10')"
FAKE_STATUS=working HERDR_PANE_ID=wC:p1 $TB send worker1 --text second >/dev/null
eq "send: nothing sent while busy" "$(prompts)" "$n"
eq "flush: still busy → exit 10, kept" "$(FAKE_STATUS=working rc $TB flush) $($TB outbox --status queued --json | wc -l | tr -d ' ')" "10 2"
$TB flush >/dev/null
eq "flush: delivered in order" "$(grep '^prompt worker1' "$FAKE_LOG" | tail -2 | sed 's/.*task\] //' | tr '\n' ' ')" "first second "
eq "flush: none queued" "$($TB outbox --status queued --json | wc -l | tr -d ' ')" "0"
eq "send: messages log kind=send" "$(ssql "SELECT COUNT(*) FROM messages WHERE kind='send' AND result='sent';")" "4"
# 宛先ルール
printf '# rules\n!conductor -> setup*\nconductor -> *\nworker1 -> worker2\n' >"$TB_ROUTES"
eq "routes: explicit deny first match" "$(HERDR_PANE_ID=wC:p1 rc $TB send setup --text x)" "4"
eq "routes: deny reason recorded" "$(ssql "SELECT reason FROM outbox ORDER BY id DESC LIMIT 1;")" "routes.conf: !conductor -> setup*"
eq "routes: glob allow" "$(HERDR_PANE_ID=wC:p1 rc $TB send worker2 --text x)" "0"
eq "routes: worker1 -> worker2 allowed" "$(HERDR_PANE_ID=wW:p1 rc $TB send worker2 --kind answer --text x)" "0"
eq "routes: no matching line → deny (project conductor)" "$(HERDR_PANE_ID=wP:p1 rc $TB send worker1 --text x)" "4"
# digest も flush する
FAKE_STATUS=working HERDR_PANE_ID=wC:p1 $TB send worker1 --text later >/dev/null
$TB digest >/dev/null
eq "digest: flushes outbox" "$($TB outbox --status queued --json | wc -l | tr -d ' ')" "0"
unset FAKE_AGENTS TB_ROUTES

# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- approvals(人の承認)
export TB_DB=$TMP/appr.db TB_CONFIG=$TMP/send.conf TB_APPROVALS=$TMP/approvals.conf
cp "$HERE/../config/approvals.conf" "$TB_APPROVALS"
export FAKE_AGENTS='[{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}},{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"s1"}}]'
: >"$FAKE_LOG"
asql() { sqlite3 "$TB_DB" "$@"; }
eq "approval: default file asks for tasks" "$($TB approval send:task:worker1; echo "rc=$?")" "$(printf 'ask\nrule: send:task:* = ask\nrc=20')"
eq "approval: info allowed" "$($TB approval send:info:worker1 | head -1)" "allow"
eq "approval: unknown → ask (catch-all)" "$($TB approval setup:hooks | head -1)" "ask"
eq "approval: bad name" "$(rc $TB approval 'a b')" "2"
out=$(HERDR_PANE_ID=wC:p1 $TB send worker1 --text 'do it'); r=$?
eq "send: task needs approval → pending (exit 20)" "$r|$out|$(prompts)" "20|O-1 pending-approval|0"
eq "flush: pending is not delivered" "$($TB flush; prompts)" "0"
eq "send: info goes straight" "$(HERDR_PANE_ID=wC:p1 rc $TB send worker1 --kind info --text fyi) $(prompts)" "0 1"
eq "approve: refused from an agent pane" "$(HERDR_PANE_ID=wW:p1 rc $TB approve O-1) $(asql "SELECT status FROM outbox WHERE id=1;")" "1 pending"
eq "approve: human sends it" "$(HERDR_PANE_ID= $TB approve O-1)" "O-1 approved and sent to worker1"
eq "approve: delivered with label" "$(grep '^prompt' "$FAKE_LOG" | tail -1 | grep -c 'task\] do it')" "1"
eq "approve: twice → error" "$(HERDR_PANE_ID= rc $TB approve O-1)" "1"
HERDR_PANE_ID=wC:p1 $TB send worker1 --text 'second' >/dev/null 2>&1
eq "reject: human rejects" "$(HERDR_PANE_ID= $TB reject O-3) $(asql "SELECT status FROM outbox WHERE id=3;")" "O-3 rejected denied"
# 「今後は許可」
HERDR_PANE_ID=wC:p1 $TB send worker1 --text 'third' >/dev/null 2>&1
eq "approve --always: sends and allows from now on" "$(HERDR_PANE_ID= $TB approve O-4 --always | head -1)" "send:task:worker1 = allow(今後は承認なし)"
eq "approve --always: rule written before the catch-all" "$($TB approval send:task:worker1; echo "rc=$?")" "$(printf 'allow\nrule: send:task:worker1 = allow\nrc=0')"
eq "send: now goes without approval" "$(HERDR_PANE_ID=wC:p1 $TB send worker1 --text fourth)" "O-5 sent to worker1"
eq "allow: refused from an agent pane" "$(HERDR_PANE_ID=wC:p1 rc $TB allow 'role:change')" "1"
eq "allow: human" "$(HERDR_PANE_ID= $TB allow 'role:change') $($TB approval role:change | head -1)" "role:change = allow allow"
eq "allow: rewrites the same line (no duplicate)" "$(grep -c '^role:change' "$TB_APPROVALS")" "1"
eq "ask: back to ask" "$(HERDR_PANE_ID= $TB ask 'send:task:worker1' >/dev/null; $TB approval send:task:worker1 | head -1)" "ask"
eq "approval changes recorded" "$(asql "SELECT pattern||'='||value FROM approval_changes ORDER BY id;" | tr '\n' ' ')" "send:task:worker1=allow role:change=allow send:task:worker1=ask "
eq "comments survive in approvals.conf" "$(grep -c '^#' "$TB_APPROVALS") -gt 5" "$(grep -c '^#' "$HERE/../config/approvals.conf") -gt 5"
# 古い outbox(pending なし)の移行
export TB_DB=$TMP/old.db
sqlite3 "$TB_DB" "CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, from_name TEXT NOT NULL, from_pane TEXT NOT NULL, from_session TEXT NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('task','info','answer')), task_id TEXT, text TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('queued','sent','denied')), reason TEXT, sent_at TEXT, created_at TEXT NOT NULL); INSERT INTO outbox (from_name, from_pane, from_session, target, kind, text, status, created_at) VALUES ('c','p','s','worker1','info','old','sent','t');"
eq "migrate: old outbox rows kept, pending allowed" "$(HERDR_PANE_ID=wC:p1 $TB send worker1 --text new; sqlite3 "$TB_DB" "SELECT COUNT(*) FROM outbox;")" "$(printf 'O-2 pending-approval\n2')"
eq "migrate: old DB reaches the latest schema version" "$(sqlite3 "$TB_DB" "PRAGMA user_version;")" "$(ls "$HERE/../schema"/[0-9][0-9][0-9]_*.sql | wc -l | tr -d ' ')"
unset FAKE_AGENTS TB_APPROVALS

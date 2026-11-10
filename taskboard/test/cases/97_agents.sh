# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- agent の停止・復活・新規作成と判定フラグ
eq "agents: analyst flagged killable after returning a result (90_alerts)" "$(sqlite3 "$TMP/alerts.db" "SELECT killable||' '||killable_by FROM agents WHERE name='analyst-A1';")" "yes tb"
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
export TB_DB=$TMP/agents.db TB_APPROVALS=$TMP/appr-agent.conf TB_SPAWN_RETRY_SEC=0 TB_AGENT_CWD=$TMP
printf 'agent:* = ask\n* = ask\n' >"$TB_APPROVALS"
A_C='{"pane_id":"wC:p1","name":"conductor","agent_status":"idle","agent_session":{"value":"sc"}}'
A_W='{"pane_id":"wW:p1","name":"worker1","agent_status":"idle","agent_session":{"value":"s1"},"cwd":"/tmp"}'
A_S='{"pane_id":"wS:p1","name":"sweeper","agent_status":"idle","agent_session":{"value":"ss"}}'
A_H='{"pane_id":"wA:p1","name":"helper1","agent_status":"idle","agent_session":{"value":"sh1"}}'
export FAKE_AGENTS="[$A_C,$A_W,$A_S]"
: >"$FAKE_LOG"
agsql() { sqlite3 "$TB_DB" "$@"; }
eq "agents: synced from herdr" "$($TB agents | cut -f1,2,4 | tr '\t\n' ' ')" "conductor running unknown sweeper running unknown worker1 running unknown "
eq "agent-new: bad name → 2" "$(rc $TB agent-new 'Bad Name')" "2"
eq "agent-new: unknown role → 2" "$(rc $TB agent-new helper1 --role nosuch)" "2"
eq "agent-new: bad model → 2" "$(rc $TB agent-new helper1 --model 'x;y')" "2"
out=$($TB agent-new helper1 --cwd "$TMP" --model haiku --role worker --prompt 'まず tb list を見て')
eq "agent-new: human starts it" "$(cut -d' ' -f1-2 <<<"$out")" "helper1 started"
eq "agent-new: own workspace + claude with model" "$(grep -c "^workspace-create.*--label helper1" "$FAKE_LOG") $(grep -c '^start helper1 --kind claude --pane wA:p1 -- --model haiku$' "$FAKE_LOG")" "1 1"
eq "agent-new: first prompt sent" "$(grep '^prompt helper1' "$FAKE_LOG" | grep -c '\[from: tb / agent / human\] まず tb list を見て')" "1"
eq "agent-new: registry" "$(agsql "SELECT state||' '||role||' '||model||' '||created_by||' '||pane_id FROM agents WHERE name='helper1';")" "running worker haiku human wA:p1"
export FAKE_AGENTS="[$A_C,$A_W,$A_S,$A_H]"
eq "roles: --role is used for the role file" "$($TB roles --json | jq -r 'select(.name=="helper1") | .role_file')" "worker.md"
eq "agent-new: live name → 1" "$(rc $TB agent-new helper1)" "1"
eq "agent-stop: not flagged → refused" "$(rc $TB agent-stop worker1) $(grep -c '^pane-close' "$FAKE_LOG")" "1 0"
eq "agent-flag: only the sweeper or a human" "$(HERDR_PANE_ID=wW:p1 rc $TB agent-flag conductor --killable yes --reason x)" "1"
eq "agent-flag: yes needs a reason" "$(HERDR_PANE_ID=wS:p1 rc $TB agent-flag worker1 --killable yes)" "2"
eq "agent-flag: not on itself" "$(HERDR_PANE_ID=wS:p1 rc $TB agent-flag sweeper --killable yes --reason x)" "1"
eq "agent-flag: sweeper flags" "$(HERDR_PANE_ID=wS:p1 $TB agent-flag worker1 --killable yes --reason '2 時間 idle、タスクなし')" "worker1 killable=yes"
eq "agents: flag shown with reason" "$($TB agents | grep '^worker1' | cut -f4,9 | tr '\t' ' ')" "yes 2 時間 idle、タスクなし"
tid=$($TB add -p ag -t 'open work' --owner worker1); $TB update "$tid" --status in_progress >/dev/null
eq "agent-stop: open task → refused" "$($TB agent-stop worker1 2>&1 | grep -c "未完了タスク $tid")" "1"
$TB update "$tid" --status todo >/dev/null
agsql "INSERT INTO agent_activity (session_id, pane_id, last_prompt_at, updated_at) VALUES ('s1','wW:p1', strftime('%Y-%m-%dT%H:%M:%fZ','now','+1 minute'), 'x');"
eq "agent-stop: new input after the flag → stale" "$($TB agent-stop worker1 2>&1 | grep -c 'killable=stale')" "1"
agsql "UPDATE agent_activity SET last_prompt_at='2000-01-01T00:00:00.000Z', last_stop_at='2000-01-01T00:01:00.000Z', cwd='$TMP' WHERE session_id='s1';"
eq "agent-stop: --force refused from an agent pane" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-stop worker1 --force)" "1"
out=$(HERDR_PANE_ID=wC:p1 $TB agent-stop worker1; echo "rc=$?"); lid=$(head -1 <<<"$out" | cut -d' ' -f1)
eq "agent-stop: conductor needs approval" "$(tr '\n' ' ' <<<"$out")" "$lid pending (人の承認待ち: tb agent-approve $lid) rc=20 "
eq "agent-ops: pending listed" "$($TB agent-ops --status pending | cut -f1-5 | tr '\t' ' ')" "$lid stop worker1 conductor pending"
eq "agent-approve: refused from an agent pane" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-approve "$lid")" "1"
out=$(HERDR_PANE_ID= $TB agent-approve "$lid")
eq "agent-approve: human runs it" "$(grep -c 'worker1 stopped (session s1' <<<"$out") $(grep -c '^pane-close wW:p1' "$FAKE_LOG")" "1 1"
eq "agent-stop: registry keeps session and the hook's cwd" "$(agsql "SELECT state||' '||session_id||' '||(cwd='$TMP') FROM agents WHERE name='worker1';")" "stopped s1 1"
eq "agent-ops: done with requester" "$(agsql "SELECT status||' '||requested_by FROM agent_ops WHERE id=${lid#L-};")" "done conductor"
export FAKE_AGENTS="[$A_C,$A_S,$A_H]"
eq "agent-stop: already stopped → 1" "$(rc $TB agent-stop worker1)" "1"
eq "agent-new: stopped name → suggests revive" "$($TB agent-new worker1 2>&1 | grep -c 'agent-revive worker1')" "1"
eq "agent-revive: unknown → 1" "$(rc $TB agent-revive nobody)" "1"
out=$($TB agent-revive worker1 --model sonnet)
eq "agent-revive: resumes the same conversation" "$(cut -d' ' -f1-4 <<<"$out") $(grep -c '^start worker1 --kind claude --pane wA:p1 -- --resume s1 --model sonnet$' "$FAKE_LOG")" "worker1 revived (resume s1, 1"
eq "agent-revive: flag reset for the new life" "$(agsql "SELECT state||' '||killable FROM agents WHERE name='worker1';")" "running unknown"
export FAKE_AGENTS="[$A_C,$A_S,$A_H,$A_W]"
eq "agent-revive: live → 1" "$(rc $TB agent-revive worker1)" "1"
printf 'agent:stop:helper1 = allow\nagent:stop:conductor = allow\nagent:* = ask\n' >"$TB_APPROVALS"
eq "agent-stop: allowed but not flagged → 1, recorded failed" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-stop helper1) $(agsql "SELECT status FROM agent_ops ORDER BY id DESC LIMIT 1;")" "1 failed"
$TB agent-flag helper1 --killable yes --reason 'done' >/dev/null
eq "agent-stop: allowed + flagged → stopped without a human" "$(HERDR_PANE_ID=wC:p1 $TB agent-stop helper1 | cut -d' ' -f1-2)" "helper1 stopped"
eq "agent-stop: not itself" "$(HERDR_PANE_ID=wC:p1 $TB agent-stop conductor 2>&1 | grep -c '自分自身')" "1"
export FAKE_AGENTS="[$A_C,$A_S,$A_W]"
: >"$FAKE_LOG"
eq "agent-revive --fresh: no --resume" "$($TB agent-revive helper1 --fresh | cut -d' ' -f1-3) $(grep -c '^start helper1 --kind claude --pane wA:p1 -- --model haiku$' "$FAKE_LOG")" "helper1 revived (新しい会話, 1"
eq "agent-new: from an agent → pending" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-new helper2)" "20"
lid=$($TB agent-ops --status pending | cut -f1 | head -1)
eq "agent-reject" "$($TB agent-reject "$lid") $(agsql "SELECT status FROM agent_ops WHERE id=${lid#L-};")" "$lid rejected rejected"
eq "agent-approve: rejected one cannot run" "$(rc $TB agent-approve "$lid")" "1"
eq "agent-stop --force: human" "$(FAKE_AGENTS="[$A_C,$A_S,$A_W]" $TB agent-stop worker1 --force | cut -d' ' -f1-2)" "worker1 stopped"
export FAKE_AGENTS="[$A_C,$A_S,$A_W]"
eq "agent-stop: pane close fails → 11" "$(FAKE_CLOSE_RC=1 rc $TB agent-stop worker1 --force)" "11"
eq "agent-new: start fails → 11 and nothing left in the registry" "$(FAKE_START_RC=1 rc $TB agent-new helper3) $(agsql "SELECT COUNT(*) FROM agents WHERE name='helper3';") $(grep -c '^workspace-close wN' "$FAKE_LOG")" "11 0 1"
eq "agents --json: material for the sweeper" "$($TB agents --json | jq -r 'select(.name=="worker1") | [.state, .killable, .open_tasks, .open_questions, .idle_min != null, .role_file] | map(tostring) | join(" ")')" "running unknown 0 0 true worker.md"
export TB_APPROVALS=$TMP/appr.conf
unset FAKE_AGENTS; export HERDR_PANE_ID=$_saved_pane
# 別の herdr セッションの agent は、見えなくても止まった扱いにせず、復活もさせない
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
export TB_DB=$TMP/agents.db TB_APPROVALS=$TMP/appr-agent.conf TB_SPAWN_RETRY_SEC=0 TB_AGENT_CWD=$TMP
export FAKE_AGENTS='[{"pane_id":"wX:p1","name":"far","agent_status":"idle","agent_session":{"value":"sf"}}]'
HERDR_SESSION=other $TB agents >/dev/null
export FAKE_AGENTS='[]'
$TB agents >/dev/null
eq "agents: other herdr session is not marked stopped" "$(sqlite3 "$TB_DB" "SELECT state||' '||herdr_session FROM agents WHERE name='far';")" "running other"
eq "agent-revive: other herdr session → 1 with a hint" "$($TB agent-revive far 2>&1 | grep -c 'HERDR_SESSION=other')" "1"
eq "agent-stop: other herdr session → hint" "$($TB agent-stop far --force 2>&1 | grep -c 'HERDR_SESSION=other')" "1"
export TB_APPROVALS=$TMP/appr.conf
unset FAKE_AGENTS; export HERDR_PANE_ID=$_saved_pane
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
export TB_DB=$TMP/agents.db TB_SPAWN_RETRY_SEC=0 TB_AGENT_CWD=$TMP FAKE_AGENTS='[]'
sqlite3 "$TB_DB" "UPDATE agents SET state='stopped', cwd='/no/such/dir', session_id='sz' WHERE name='helper1';"
eq "agent-revive: resume needs the original cwd" "$($TB agent-revive helper1 2>&1 | grep -c '作業ディレクトリがありません')" "1"
eq "agent-revive --fresh: falls back to TB_AGENT_CWD" "$($TB agent-revive helper1 --fresh | grep -c "cwd $TMP")" "1"
unset FAKE_AGENTS; export HERDR_PANE_ID=$_saved_pane

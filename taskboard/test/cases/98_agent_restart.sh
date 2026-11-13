# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態は使わない)
# --- tb agent-restart: 停止 + 同じ会話での復活(MCP の再接続)。安全条件・権限・失敗時の扱い
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
export TB_DB=$TMP/restart.db TB_APPROVALS=$TMP/appr-restart.conf TB_SPAWN_RETRY_SEC=0 TB_AGENT_CWD=$TMP TB_LIMITS=$TMP/rs-lim.conf
export FAKE_DYNAMIC=1
rssql() { sqlite3 "$TB_DB" "$@"; }
rs_ag() { printf '{"pane_id":"%s","name":"%s","agent_status":"%s","agent_session":{"value":"%s"},"cwd":"%s"}' "$2" "$1" "${3:-idle}" "${4:-s-$1}" "$TMP"; }
rs_reset() { : >"$FAKE_LOG"; rm -f "$FAKE_LOG.closed" "$FAKE_LOG.started" "$FAKE_LOG.ready" "$FAKE_LOG.working"; unset FAKE_START_RC FAKE_START_SESSION FAKE_CLOSE_RC FAKE_STATUS; }
rs_closes() { grep -c '^pane-close' "$FAKE_LOG"; }
rs_last() { rssql "SELECT op||' '||status||' '||requested_by||' '||COALESCE(json_extract(args,'\$.restart'),'-') FROM agent_ops ORDER BY id DESC LIMIT 1;"; }
RS_C=$(rs_ag conductor wC:p1); RS_W=$(rs_ag worker1 wW:p1 idle s1); RS_H=$(rs_ag helper1 wH:p1 idle sh)
export FAKE_AGENTS="[$RS_C,$RS_W,$RS_H]"
printf 'agent:stop:worker1 = allow\nagent:revive:worker1 = allow\nagent:stop:conductor = allow\nagent:revive:conductor = allow\nagent:stop:helper1 = allow\n* = ask\n' >"$TB_APPROVALS"
rs_reset
$TB agents >/dev/null

# ---- 人の端末から: 停止して、同じ session を --resume で復活し、既定の指示を送る
out=$($TB agent-restart worker1 2>&1; echo "rc=$?")
eq "restart: human run succeeds" "$(tail -1 <<<"$out")" "rc=0"
eq "restart: pane closed, then resumed with the same session in the same cwd" "$(rs_closes) $(grep -c '^pane-close wW:p1' "$FAKE_LOG") $(grep -c '^start worker1 --kind claude --pane wA:p1 -- --resume s1$' "$FAKE_LOG") $(grep -c "^workspace-create workspace create --cwd $TMP --label worker1" "$FAKE_LOG")" "1 1 1 1"
eq "restart: default prompt (MCP reconnected) sent once" "$(grep -c '^prompt worker1.*MCP.*tb comment' "$FAKE_LOG")" "1"
eq "restart: output says who, stop, revive, same conversation, time" "$(grep -c 'restarted by human: stop ok.*revive ok.*同じ会話に戻った(session s1 のまま).* 秒' <<<"$out")" "1"
eq "restart: recorded as one revive op with args.restart=1" "$(rs_last) $(rssql "SELECT COUNT(*) FROM agent_ops;")" "revive done human 1 1"
eq "restart: ledger running again with the same session" "$(rssql "SELECT state||' '||session_id FROM agents WHERE name='worker1';")" "running s1"

# ---- --prompt はそのまま使う
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
$TB agent-restart worker1 --prompt '続きは T-1 から' >/dev/null 2>&1
eq "restart: --prompt replaces the default" "$(grep -c '^prompt worker1.*続きは T-1 から' "$FAKE_LOG") $(grep -c 'MCP の接続を張り直す' "$FAKE_LOG")" "1 0"

# ---- 安全条件
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 working s1),$RS_H]"
eq "restart: working → refused, nothing closed" "$(rc $TB agent-restart worker1) $(rs_closes)" "1 0"
export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 blocked s1),$RS_H]"
eq "restart: blocked → refused" "$(rc $TB agent-restart worker1) $(rs_closes)" "1 0"
export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 done s1),$RS_H]"
eq "restart: done is allowed" "$(rc $TB agent-restart worker1)" "0"
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
eq "restart: a name that is not running → 1" "$(rc $TB agent-restart nobody)" "1"
eq "restart: bad name → 2" "$(rc $TB agent-restart 'Bad Name')" "2"

# in_progress のタスク: --prompt(再開メモ)が無ければ拒否、あれば通る。review / todo は関係しない
tid=$($TB add -p rs -t 'busy' --owner worker1); $TB update "$tid" --status in_progress >/dev/null
out=$($TB agent-restart worker1 2>&1; echo "rc=$?")
eq "restart: in_progress task without --prompt → refused with the reason" "$(grep -c "in_progress.*$tid.*--prompt" <<<"$out") $(tail -1 <<<"$out") $(rs_closes)" "1 rc=1 0"
eq "restart: in_progress task with working status stays refused even with --prompt" "$(FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 working s1),$RS_H]" rc $TB agent-restart worker1 --prompt memo) $(rs_closes)" "1 0"
eq "restart: in_progress task with --prompt → restarted" "$(rc $TB agent-restart worker1 --prompt '再開メモ: T の続き') $(grep -c '^prompt worker1.*再開メモ' "$FAKE_LOG")" "0 1"
$TB update "$tid" --status todo >/dev/null

# 会話に戻れないなら止めない
rs_reset; export FAKE_AGENTS="[$RS_C,$(printf '{"pane_id":"wW:p1","name":"worker1","agent_status":"idle","cwd":"%s"}' "$TMP"),$RS_H]"
rssql "UPDATE agents SET session_id=NULL WHERE name='worker1';"
eq "restart: no session id → refused before stopping anything" "$(rc $TB agent-restart worker1) $(rs_closes)" "1 0"
export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"; $TB agents >/dev/null
rssql "UPDATE agents SET cwd='/no/such/dir' WHERE name='worker1';"; rs_reset
export FAKE_AGENTS="[$RS_C,$(printf '{"pane_id":"wW:p1","name":"worker1","agent_status":"idle","agent_session":{"value":"s1"},"cwd":"/no/such/dir"}'),$RS_H]"
eq "restart: cwd missing → refused before stopping anything" "$(rc $TB agent-restart worker1) $(rs_closes)" "1 0"
export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"

# 別の herdr セッション
rs_reset
rssql "INSERT INTO agents (name, herdr_session, cwd, session_id, state, killable, created_by, created_at, updated_at) VALUES ('far','other','$TMP','sf','running','unknown','herdr','x','x');"
eq "restart: agent of another herdr session → 1 with a hint" "$($TB agent-restart far 2>&1 | grep -c 'HERDR_SESSION=other') $(rs_closes)" "1 0"

# ---- 復活に失敗: 停止のまま、復旧コマンドを出し、非 0
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
rssql "UPDATE agents SET cwd='$TMP', session_id='s1' WHERE name='worker1';"
out=$(FAKE_START_RC=1 $TB agent-restart worker1 2>&1; echo "rc=$?")
eq "restart: resume fails → non-zero, stays stopped, prints the revive command" "$(tail -1 <<<"$out") $(grep -c 'tb agent-revive worker1 \[--fresh\]' <<<"$out") $(rssql "SELECT state FROM agents WHERE name='worker1';")" "rc=11 1 stopped"
eq "restart: failure never starts a fresh conversation" "$(grep -c '^start worker1 --kind claude --pane wA:p1$' "$FAKE_LOG")" "0"
eq "restart: failure recorded as failed" "$(rs_last)" "revive failed human 1"

# 最初の指示が確認できない → 再開はしたが 10
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
rssql "UPDATE agents SET state='running' WHERE name='worker1';"
out=$(FAKE_PROMPT_MODE=swallow-always TB_PROMPT_VERIFY_SEC=0.2 $TB agent-restart worker1 2>&1; echo "rc=$?")
eq "restart: first prompt not confirmed → rc 10 and says so" "$(tail -1 <<<"$out") $(grep -c '再送せず' <<<"$out")" "rc=10 1"

# session が変わったときはそう言う
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
out=$(FAKE_START_SESSION=s-other $TB agent-restart worker1 2>&1)
eq "restart: reports when the session id changed" "$(grep -c 'session CHANGED (s1 -> s-other' <<<"$out")" "1"

# ---- agent の pane から
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
out=$(HERDR_PANE_ID=wC:p1 $TB agent-restart worker1 2>&1; echo "rc=$?")
eq "restart: conductor may restart an allowed agent (both ops allow)" "$(tail -1 <<<"$out") $(rs_last)" "rc=0 revive done conductor 1"
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
eq "restart: only stop allowed (helper1) → 4, nothing closed, recorded rejected" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-restart helper1) $(rs_closes) $(rs_last)" "4 0 revive rejected conductor 1"
eq "restart: no approval rule (ask) → 4, not queued" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-restart far) $(rssql "SELECT COUNT(*) FROM agent_ops WHERE status='pending';")" "4 0"
eq "restart: an agent cannot restart itself" "$(HERDR_PANE_ID=wW:p1 rc $TB agent-restart worker1) $(rs_closes)" "4 0"
eq "restart: an agent cannot restart a conductor even if both ops are allow" "$(HERDR_PANE_ID=wW:p1 rc $TB agent-restart conductor) $(rs_closes)" "4 0"
eq "restart: --force does not exist (human)" "$(rc $TB agent-restart worker1 --force) $(rs_closes)" "2 0"
eq "restart: --force does not exist (agent pane)" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-restart worker1 --force) $(rs_closes)" "2 0"
eq "restart: stop gate unchanged: agent-stop --force stays human-only" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-stop worker1 --force)" "1"
eq "restart: herdr list failure from a pane is not treated as a human" "$(FAKE_LIST_FAIL=1 HERDR_PANE_ID=wC:p1 rc $TB agent-restart worker1) $(rs_closes)" "1 0"

# ---- 上限(max_running_agents。数えるのは現在の herdr セッションだけ)
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
printf 'max_running_agents = 2\n' >"$TB_LIMITS"
eq "restart: already above the limit → 4, nothing closed" "$(rc $TB agent-restart worker1) $(rs_closes)" "4 0"
printf 'max_running_agents = 3\n' >"$TB_LIMITS"
eq "restart: at the limit is fine (net count unchanged); the far agent of another session is not counted" "$(rc $TB agent-restart worker1) $(rs_closes)" "0 1"
rs_reset; export FAKE_AGENTS="[$RS_C,$(rs_ag worker1 wW:p1 idle s1),$RS_H]"
rm -f "$TB_LIMITS"

export TB_APPROVALS=$TMP/appr.conf
unset FAKE_AGENTS FAKE_DYNAMIC TB_LIMITS; export TB_LIMITS=$TMP/limits-default.conf
rs_reset
[[ -n $_saved_pane ]] && export HERDR_PANE_ID=$_saved_pane

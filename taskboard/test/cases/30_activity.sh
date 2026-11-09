# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- touch / activity / tb-hook
DUMMY_CRED=not-a-real-credential-SECRET   # ログ・DB に出ないことの検査用のダミー
LOG=$TMP/touch-errors.log
HOOK="bash $HERE/../bin/tb-hook"
nlog() { [[ -f $LOG ]] && wc -l <"$LOG" | tr -d ' ' || echo 0; }
act()  { $TB activity --json | jq -c "select(.session_id==\"$1\")"; }

out=$($TB touch --event UserPromptSubmit --session-id s1 --pane-id wG:p1 --tab-id wG:t1 --workspace-id wG --cwd /w/dir --prompt-id pr1 2>&1); r=$?
eq "touch: exit 0 and empty output" "$r|$out" "0|"
eq "touch: prompt sets last_prompt_at, working" "$(act s1 | jq -r '(.last_prompt_at!=null|tostring)+" "+(.last_stop_at==null|tostring)+" "+(.working|tostring)')" "true true 1"
out=$($TB touch --event Stop --session-id s1 2>&1); r=$?
eq "touch: Stop exit 0 and empty output" "$r|$out" "0|"
eq "touch: Stop sets last_stop_at, keeps prompt/pane, not working" "$(act s1 | jq -r '(.last_stop_at!=null|tostring)+" "+(.last_prompt_at!=null|tostring)+" "+.pane_id+" "+(.working|tostring)')" "true true wG:p1 0"
# 同一 session の連続 upsert(行は増えない・省略した項目は保持・指定した項目は更新)
$TB touch --event UserPromptSubmit --session-id s1 --pane-id wG:p9 --prompt-id pr2
$TB touch --event UserPromptSubmit --session-id s1
eq "touch: one row per session" "$($TB activity --json | jq -c 'select(.session_id=="s1")' | wc -l | tr -d ' ')" "1"
eq "touch: update/keep fields" "$(act s1 | jq -r '.pane_id+" "+.last_prompt_id+" "+.cwd+" "+(.working|tostring)')" "wG:p9 pr2 /w/dir 1"
# Stop が先に来る(UserPromptSubmit を取りこぼした)
$TB touch --event Stop --session-id s2 --pane-id wG:p2
eq "touch: Stop first → row, prompt null, not working" "$(act s2 | jq -r '(.last_prompt_at==null|tostring)+" "+(.last_stop_at!=null|tostring)+" "+(.working|tostring)')" "true true 0"
$TB touch --event UserPromptSubmit --session-id s2
eq "touch: prompt after Stop → working" "$(act s2 | jq -r '.working')" "1"

# 不正入力: exit 0・出力なし・ログ 1 行(理由コードのみ)・行は作らない
rm -f "$LOG"; n0=$($TB activity --json | wc -l | tr -d ' ')
out=$($TB touch --event UserPromptSubmit 2>&1); r=$?
eq "touch: session-id missing → exit 0, no output" "$r|$out" "0|"
eq "touch: session-id missing → 1 log line w/ code" "$(nlog) $(grep -c 'event=UserPromptSubmit reason=missing-session-id' "$LOG")" "1 1"
eq "touch: invalid event → logged, exit 0" "$($TB touch --event Bogus --session-id sx >/dev/null 2>&1; echo $?) $(grep -c 'event=- reason=invalid-event' "$LOG")" "0 1"
eq "touch: invalid session id chars" "$($TB touch --event Stop --session-id 'a b;rm' >/dev/null 2>&1; echo $?) $(grep -c 'reason=invalid-session-id' "$LOG")" "0 1"
eq "touch: invalid pane id" "$($TB touch --event Stop --session-id sx --pane-id 'p;x' >/dev/null 2>&1; echo $?) $(grep -c 'reason=invalid-field' "$LOG")" "0 1"
eq "touch: unknown flag / missing value" "$($TB touch --event Stop --session-id sx --prompt 'SECRET-PROMPT-BODY' >/dev/null 2>&1; $TB touch --event >/dev/null 2>&1; echo $?) $(grep -c 'reason=invalid-args' "$LOG")" "0 2"
eq "touch: no rows created by invalid input" "$($TB activity --json | wc -l | tr -d ' ')" "$n0"
eq "log has no input values" "$(grep -c 'SECRET-PROMPT-BODY\|sx\|a b' "$LOG")" "0"

# DB 読み取り専用 / ロック: exit 0・出力なし・ログ 1 行
cp "$TB_DB" "$TMP/ro.db"; chmod 444 "$TMP/ro.db"; rm -f "$LOG"
out=$(TB_DB=$TMP/ro.db $TB touch --event Stop --session-id s1 2>&1); r=$?
eq "touch: read-only DB → exit 0, no output" "$r|$out" "0|"
if [[ $(id -u) -eq 0 ]]; then
  echo "skip touch: read-only DB → logged as db-readonly(root はファイルの権限を無視して書けるため確かめられない)"
else
  eq "touch: read-only DB → logged as db-readonly" "$(nlog) $(grep -c 'reason=db-readonly' "$LOG")" "1 1"
fi
rm -f "$LOG"
( echo "BEGIN EXCLUSIVE;"; sleep 4 ) | sqlite3 "$TB_DB" >/dev/null 2>&1 &
locker=$!; sleep 1
t0=$SECONDS; out=$($TB touch --event Stop --session-id s1 2>&1); r=$?; el=$((SECONDS-t0))
eq "touch: locked DB → exit 0, no output" "$r|$out" "0|"
eq "touch: locked DB → gives up quickly (<4s)" "$([[ $el -lt 4 ]] && echo fast || echo "slow:${el}s")" "fast"
eq "touch: locked DB → logged as db-locked" "$(nlog) $(grep -c 'reason=db-locked' "$LOG")" "1 1"
kill $locker 2>/dev/null; wait $locker 2>/dev/null

# tb-hook: stdin の JSON と env から拾う。本文・env 全体は DB にもログにも出ない
rm -f "$LOG"
out=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"hk1","cwd":"/h/dir","prompt_id":"hp1","prompt":"SECRET-PROMPT-BODY","last_assistant_message":"SECRET-REPLY"}' \
  | HERDR_PANE_ID=wZ:p7 HERDR_TAB_ID=wZ:t7 HERDR_WORKSPACE_ID=wZ CLAUDE_CODE_MESSAGING_TOKEN=$DUMMY_CRED $HOOK 2>&1); r=$?
eq "hook: exit 0, empty stdout/stderr" "$r|$out" "0|"
eq "hook: fields from stdin and env" "$(act hk1 | jq -r '[.pane_id,.tab_id,.workspace_id,.cwd,.last_prompt_id,(.working|tostring)]|join(" ")')" "wZ:p7 wZ:t7 wZ /h/dir hp1 1"
out=$(printf '%s' '{"hook_event_name":"Stop","session_id":"hk1","cwd":"/h/dir","prompt_id":"hp1","prompt":null,"last_assistant_message":"SECRET-REPLY"}' | HERDR_PANE_ID=wZ:p7 $HOOK 2>&1)
eq "hook: Stop → not working" "$(act hk1 | jq -r '.working')" "0"
out=$(printf '%s' '{bad json SECRET-PROMPT-BODY' | CLAUDE_CODE_MESSAGING_TOKEN=$DUMMY_CRED $HOOK 2>&1); r=$?
eq "hook: invalid JSON → exit 0, no output" "$r|$out" "0|"
out=$(printf '%s' '{"hook_event_name":"Stop"}' | $HOOK 2>&1); r=$?
eq "hook: session_id missing → exit 0, no output" "$r|$out" "0|"
out=$($HOOK </dev/null 2>&1); r=$?
eq "hook: empty stdin → exit 0, no output" "$r|$out" "0|"
eq "hook: errors logged (3 lines, codes only)" "$(nlog) $(grep -c 'reason=missing-session-id\|reason=invalid-event' "$LOG")" "3 3"
eq "hook: no body/reply/token in log" "$(grep -c 'SECRET' "$LOG")" "0"
eq "hook: no body/reply/token in DB" "$(sqlite3 "$TB_DB" .dump | grep -c 'SECRET')" "0"

# activity: working 推定と滞留(stuck)
old='2020-01-01T00:00:00.000Z'; new=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
sqlite3 "$TB_DB" "INSERT INTO agent_activity(session_id,last_prompt_at,last_stop_at,updated_at) VALUES
  ('old-working','$old',NULL,'$old'), ('old-done','$old','2020-01-01T00:05:00.000Z','$old'), ('fresh-working','$new',NULL,'$new');"
eq "activity: old prompt w/o stop → working+stuck" "$(act old-working | jq -r '"\(.working) \(.stuck)"')" "1 1"
eq "activity: stopped after prompt → neither" "$(act old-done | jq -r '"\(.working) \(.stuck)"')" "0 0"
eq "activity: fresh prompt → working, not stuck" "$(act fresh-working | jq -r '"\(.working) \(.stuck)"')" "1 0"
eq "activity: --stuck-min huge → not stuck" "$($TB activity --json --stuck-min 99999999 | jq -c 'select(.session_id=="old-working") | .stuck')" "0"
eq "activity: bad --stuck-min" "$(rc $TB activity --stuck-min x)" "2"
eq "activity: tsv row" "$($TB activity | grep -c '^old-working	-	1	1	')" "1"

# tb show: tasks.session_id と結んだ最終活動
ts1=$($TB add -p act -t "with session" --session old-working); ts2=$($TB add -p act -t "no session"); ts3=$($TB add -p act -t "unknown session" --session nobody)
eq "show: activity joined by session_id" "$($TB show $ts1 | jq -r '"\(.activity.session_id) \(.activity.working) \(.activity.stuck)"')" "old-working 1 1"
eq "show: no session → activity null" "$($TB show $ts2 | jq -c '.activity')" "null"
eq "show: unknown session → activity null" "$($TB show $ts3 | jq -c '.activity')" "null"

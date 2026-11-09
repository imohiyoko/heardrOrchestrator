# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- roles(役割の配布)
export TB_DB=$TMP/roles.db TB_ROLES=$TMP/roles
mkdir -p "$TB_ROLES"
printf '共通ルール\n' >"$TB_ROLES/_common.md"
printf '指揮官の役割\n' >"$TB_ROLES/conductor.md"
printf 'worker の役割\n' >"$TB_ROLES/worker.md"
printf '# map\nworker* = worker\nghost* = missing\n' >"$TB_ROLES/map.conf"
: >"$FAKE_LOG"
export FAKE_AGENTS='[{"pane_id":"wC:p1","name":"conductor","agent_session":{"value":"sc"}},{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"s1"}},{"pane_id":"wG:p1","name":"ghost1","agent_session":{"value":"sg"}},{"pane_id":"wN:p1","agent_session":{"value":"sn"}}]'
RH=$HERE/../bin/tb-role-hook
hook() { printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"}' "$2" "$3" | HERDR_PANE_ID=$1 bash "$RH"; }
out=$(hook wC:p1 startup sc1)
eq "role: startup gives common + own role" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out" | grep -c '共通ルール\|指揮官の役割')" "2"
eq "role: hook JSON shape" "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" "SessionStart"
eq "role: map.conf glob" "$(hook wW:p1 startup sw1 | jq -r .hookSpecificOutput.additionalContext | grep -c 'worker の役割')" "1"
eq "role: map to missing file → common only" "$(hook wG:p1 startup sg1 | jq -r .hookSpecificOutput.additionalContext | grep -c '共通ルール')" "1"
eq "role: resume with same version → nothing" "$(hook wC:p1 resume sc1)" ""
eq "role: compact → given again" "$(hook wC:p1 compact sc1 | jq -r .hookSpecificOutput.hookEventName)" "SessionStart"
printf '指揮官の役割 v2\n' >"$TB_ROLES/conductor.md"
eq "role: resume after role change → new version" "$(hook wC:p1 resume sc1 | jq -r .hookSpecificOutput.additionalContext | grep -c 'v2')" "1"
eq "role: unnamed agent → nothing" "$(hook wN:p1 startup sn1)" ""
eq "role: no pane → nothing" "$(hook '' startup sx)" ""
eq "role: bad source → nothing, exit 0" "$(printf '{"source":"evil","session_id":"a"}' | HERDR_PANE_ID=wC:p1 bash "$RH"; echo "rc=$?")" "rc=0"
eq "role: broken db → exit 0, no stderr" "$(printf '{"source":"startup","session_id":"z"}' | TB_DB=/etc/hostname/x.db HERDR_PANE_ID=wC:p1 bash "$RH" 2>&1; echo "rc=$?")" "rc=0"
eq "role: briefings recorded" "$(sqlite3 "$TB_DB" "SELECT source||':'||via FROM role_briefings WHERE session_id='sc1' ORDER BY id;" | tr '\n' ' ')" "startup:hook compact:hook resume:hook "
# 一括送信
out=$($TB role-broadcast); r=$?
eq "broadcast: sends to agents without current version" "$r|$(grep -c '^sent' <<<"$out")" "0|3"
eq "broadcast: unnamed skipped silently" "$(grep -c 'wN' <<<"$out")" "0"
eq "broadcast: message points to files" "$(grep '^prompt worker1' "$FAKE_LOG" | grep -c "\[role-update / tb\] .*$TB_ROLES/_common.md .*$TB_ROLES/worker.md")" "1"
eq "broadcast: second run skips (already given)" "$($TB role-broadcast | grep -c '^skip')" "3"
printf 'worker の役割 v2\n' >"$TB_ROLES/worker.md"
eq "broadcast: only changed roles resent" "$($TB role-broadcast | grep '^sent' | cut -d' ' -f2)" "worker1"
printf 'worker v3\n' >"$TB_ROLES/worker.md"
eq "broadcast: busy → exit 10, not recorded" "$(FAKE_STATUS=working rc $TB role-broadcast worker1) $($TB roles | awk -F'\t' '$1=="worker1"{print $4}')" "10 outdated"
eq "roles: states" "$($TB roles --json | jq -r '.name+":"+.state' | tr '\n' ' ')" "conductor:current worker1:outdated ghost1:current "
unset FAKE_AGENTS TB_ROLES

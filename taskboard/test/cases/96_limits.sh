# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態は使わない)
# --- 制限(tb limits / agent-shed / handoff / limits check の上限 / 各経路の強制)
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
_saved_am=${TB_ANALYST_MAX-}; unset TB_ANALYST_MAX
export TB_DB=$TMP/limits.db TB_APPROVALS=$TMP/appr-lim.conf TB_SPAWN_RETRY_SEC=0 TB_AGENT_CWD=$TMP TB_ANALYST_RETRY_SEC=0
export TB_LIMITS=$TMP/lim.conf TB_HANDOFF_DIR=$TMP/handoff TB_ROUTES=$TMP/lim-routes.conf
unset TB_SPAWN_POLICY
printf 'agent:spawn:* = allow\nagent:* = ask\nsend:*:* = allow\nalert:analyze = allow\n* = ask\n' >"$TB_APPROVALS"
printf 'conductor -> *\n' >"$TB_ROUTES"
lg_ag() { printf '{"pane_id":"%s","name":"%s","agent_status":"%s","agent_session":{"value":"s-%s"},"cwd":"%s"}' "$2" "$1" "${3:-idle}" "$1" "$TMP"; }
LG_C=$(lg_ag conductor wC:p1); LG_W1=$(lg_ag w1 wW:p1 working); LG_W2=$(lg_ag w2 wW:p2 idle); LG_W3=$(lg_ag w3 wW:p3 working)
export FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2]"
: >"$FAKE_LOG"
lgsql() { sqlite3 "$TB_DB" "$@"; }
lg_ws() { grep -c '^workspace-create' "$FAKE_LOG"; }
lg_get() { $TB limits get "$1"; }
ALL5="investigator containment fixer lateral verifier"

# ---- 優先: 環境変数 > limits.conf > limits.conf.example > 既定
eq "limits: built-in defaults (no files)" "$(for k in max_running_agents max_working_agents incident_max_open analyst_max watchers human_handoff; do lg_get $k; done | tr '\n' ,)" "30,0,2,2,watch,off,"
eq "limits: default incident_roles is all five" "$(lg_get incident_roles)" "$ALL5"
printf 'max_running_agents = 7  # example\nincident_max_open = 5\n' >"$TB_LIMITS.example"
eq "limits: falls back to limits.conf.example" "$(lg_get max_running_agents) $(lg_get incident_max_open)" "7 5"
printf 'max_running_agents = 8\n' >"$TB_LIMITS"
eq "limits: limits.conf wins over the example (the example is not merged)" "$(lg_get max_running_agents) $(lg_get incident_max_open)" "8 2"
eq "limits: env TB_LIMIT_<KEY> wins over limits.conf" "$(TB_LIMIT_MAX_RUNNING_AGENTS=9 lg_get max_running_agents)" "9"
eq "limits: an invalid env value is ignored" "$(TB_LIMIT_MAX_RUNNING_AGENTS=x lg_get max_running_agents)" "8"
eq "limits show --json: source per key" "$(TB_LIMIT_ANALYST_MAX=4 $TB limits show --json | jq -r '[.limits.max_running_agents.source, .limits.analyst_max.source, .limits.watchers.source] | join(" ")')" "conf env default"
rm -f "$TB_LIMITS" "$TB_LIMITS.example"
# 既存の設定との統合
printf 'max_children_per_parent = 3\nmax_children_total = 5\n' >"$TMP/lim-spawn.conf"
eq "limits: spawn keys fall back to spawn-policy.conf when unset" "$(TB_SPAWN_POLICY=$TMP/lim-spawn.conf lg_get spawn_max_per_parent) $(TB_SPAWN_POLICY=$TMP/lim-spawn.conf lg_get spawn_max_total)" "3 5"
printf 'spawn_max_total = 2\n' >"$TB_LIMITS"
eq "limits: spawn_max_total in limits.conf overrides spawn-policy.conf; the other key still comes from it" "$(TB_SPAWN_POLICY=$TMP/lim-spawn.conf lg_get spawn_max_total) $(TB_SPAWN_POLICY=$TMP/lim-spawn.conf lg_get spawn_max_per_parent)" "2 3"
rm -f "$TB_LIMITS"
eq "limits: analyst_max follows TB_ANALYST_MAX when not set in limits" "$(TB_ANALYST_MAX=3 lg_get analyst_max)" "3"
printf 'analyst_max = 1\n' >"$TB_LIMITS"
eq "limits: analyst_max in limits.conf overrides TB_ANALYST_MAX; TB_LIMIT_ANALYST_MAX overrides both" "$(TB_ANALYST_MAX=3 lg_get analyst_max) $(TB_ANALYST_MAX=3 TB_LIMIT_ANALYST_MAX=4 lg_get analyst_max)" "1 4"
rm -f "$TB_LIMITS"

# ---- 数える(herdr と同期してから。停止中は数えない。working は herdr の状態)
FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2,$LG_W3]"
eq "limits show: one line (running / working / incidents / analysts / spawn / mode)" "$($TB limits show --line)" "running 4/30  working 2/無制限  incidents 0/2  analysts 0/2  spawn 0/6  mode normal"
FAKE_AGENTS="[$LG_C,$LG_W1]"
eq "limits show: a stopped agent is not counted" "$($TB limits show --json | jq -c '[.running.n, .working.n]') $(lgsql "SELECT state FROM agents WHERE name='w2';")" "[2,1] stopped"
FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2,$LG_W3]"
eq "limits show --json: numbers and keys" "$($TB limits show --json | jq -c '[.running.n, .working.n, .working.max, .incidents.n, .mode, (.limits|keys|length)]')" '[4,2,0,0,"normal",9]'
eq "limits show: lists every key" "$($TB limits show | grep -c '^  [a-z_]* *= ')" "9"
FAKE_WORKSPACES='[{"label":"inc-001"},{"label":"scratch"}]'; export FAKE_WORKSPACES
eq "limits show: open incidents are inc-<3 digits> workspaces only" "$($TB limits show --line | grep -o 'incidents [0-9?]*/[0-9]*')" "incidents 1/2"
unset FAKE_WORKSPACES

# ---- set / unset / mode(人だけ。検査つき)
eq "limits set: unknown key → 2" "$(rc $TB limits set nope 1)" "2"
eq "limits set: non-integer / zero running / bad roles / bad bool → 2" "$(rc $TB limits set max_working_agents x) $(rc $TB limits set max_running_agents 0) $(rc $TB limits set incident_roles 'fixer bogus') $(rc $TB limits set human_handoff yes) $(rc $TB limits set watchers 'a/b')" "2 2 2 2 2"
eq "limits set: nothing written by refused values" "$([[ -e $TB_LIMITS ]] && echo written || echo none)" "none"
eq "limits set: writes the value" "$($TB limits set max_working_agents 2) $(grep -c '^max_working_agents = 2$' "$TB_LIMITS")" "max_working_agents = 2 1"
eq "limits set: list syntax accepts commas and de-duplicates" "$($TB limits set incident_roles 'fixer,investigator fixer')" "incident_roles = fixer investigator"
eq "limits set: empty watchers is allowed" "$($TB limits set watchers '') $(grep -c '^watchers = $' "$TB_LIMITS")" "watchers =  1"
eq "limits set: an existing key is replaced, not duplicated; no temp files left" "$($TB limits set max_working_agents 3 >/dev/null; grep -c '^max_working_agents' "$TB_LIMITS") $(ls "$TMP" | grep -c '^lim\.conf\.')" "1 0"
eq "limits set: the recorded mode becomes custom" "$(lg_get max_working_agents) $($TB limits show --line | grep -o 'mode .*')" "3 mode custom"
$TB limits unset max_working_agents >/dev/null
eq "limits unset: removes the key (back to default)" "$(grep -c '^max_working_agents' "$TB_LIMITS") $(lg_get max_working_agents)" "0 0"
eq "limits unset: unknown key → 2" "$(rc $TB limits unset nope)" "2"
$TB limits mode lean >/dev/null
eq "limits mode lean: values from the table, mode recorded" "$(for k in max_working_agents incident_max_open incident_roles analyst_max spawn_max_total; do lg_get $k; done | tr '\n' ,) $($TB limits show --line | grep -o 'mode .*')" "10,1,investigator fixer verifier,1,2, mode lean"
eq "limits mode lean: watchers (not in the table) go back to the default" "$(lg_get watchers)" "watch"
$TB limits mode minimal >/dev/null
eq "limits mode minimal: values from the table (watchers empty, spawn 0)" "$(for k in max_working_agents incident_max_open incident_roles analyst_max spawn_max_total; do lg_get $k; done | tr '\n' ,)[$(lg_get watchers)]" "5,1,investigator,1,0,[]"
$TB limits set max_running_agents 12 >/dev/null; $TB limits mode normal >/dev/null
eq "limits mode normal: managed keys cleared, others kept, mode recorded" "$(grep -vc '^#' "$TB_LIMITS") $(grep -c '^max_running_agents = 12$' "$TB_LIMITS") $(grep -c '^mode = normal$' "$TB_LIMITS") $(lg_get incident_max_open)" "2 1 1 2"
eq "limits mode: unknown mode → 2" "$(rc $TB limits mode extreme)" "2"
$TB limits unset max_running_agents >/dev/null
# agent の pane からは set / unset / mode を拒否する(読み取りは通る)
cksum "$TB_LIMITS" >"$TMP/lim.sum"
eq "limits: set / unset / mode are refused from an agent pane" "$(HERDR_PANE_ID=wC:p1 rc $TB limits set max_running_agents 99) $(HERDR_PANE_ID=wC:p1 rc $TB limits unset incident_max_open) $(HERDR_PANE_ID=wC:p1 rc $TB limits mode minimal) $(cksum "$TB_LIMITS" | cmp -s - "$TMP/lim.sum" && echo same)" "1 1 1 same"
eq "limits: show / get / watcher-enabled still work from an agent pane" "$(HERDR_PANE_ID=wC:p1 rc $TB limits show) $(HERDR_PANE_ID=wC:p1 rc $TB limits get analyst_max) $(HERDR_PANE_ID=wC:p1 rc $TB limits watcher-enabled watch)" "0 0 0"
rm -f "$TB_LIMITS"

# ---- watchers
eq "watcher-enabled: in the default list → 0, not in the list → 1" "$(rc $TB limits watcher-enabled watch) $(rc $TB limits watcher-enabled watch-other)" "0 1"
eq "watcher-enabled: env list" "$(TB_LIMIT_WATCHERS='x y' rc $TB limits watcher-enabled y) $(TB_LIMIT_WATCHERS='x y' rc $TB limits watcher-enabled watch)" "0 1"
$TB limits set watchers '' >/dev/null
eq "watcher-enabled: an empty list disables every watcher; bad name → 2" "$(rc $TB limits watcher-enabled watch) $(rc $TB limits watcher-enabled 'a b')" "1 2"
rm -f "$TB_LIMITS"
eq "watcher-enabled: the job example documents the guard" "$(grep -c 'limits watcher-enabled' "$HERE/../../scheduler/jobs/watch.conf.example")" "2"

# ---- 強制: agent-new(上限で 4、何も作らない。下回れば通る)
FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2]"; : >"$FAKE_LOG"
printf 'max_running_agents = 3\n' >"$TB_LIMITS"
out=$($TB agent-new lg1 --cwd "$TMP" 2>&1 >/dev/null); r=$?
eq "agent-new: at the limit → 4 with the reason, nothing created" "$(rc $TB agent-new lg1 --cwd "$TMP") $(grep -c 'max_running_agents=3' <<<"$out") $(lg_ws) $(lgsql "SELECT COUNT(*) FROM agent_ops;") $(lgsql "SELECT COUNT(*) FROM agents WHERE name='lg1';")" "4 1 0 0 0"
eq "agent-new: from an agent pane at the limit → 4 (not queued for approval)" "$(HERDR_PANE_ID=wC:p1 rc $TB agent-new lg1) $(lgsql "SELECT COUNT(*) FROM agent_ops;")" "4 0"
printf 'max_running_agents = 4\n' >"$TB_LIMITS"
eq "agent-new: below the limit passes" "$($TB agent-new lg1 --cwd "$TMP" | cut -d' ' -f1-2) $(lg_ws)" "lg1 started 1"
# 承認待ちの間に上限へ達したら、承認は拒否され、承認待ちのまま残る
printf 'max_running_agents = 30\n' >"$TB_LIMITS"
out=$(HERDR_PANE_ID=wC:p1 $TB agent-new lg2 --cwd "$TMP" 2>&1); lid=$(grep -o 'L-[0-9]*' <<<"$out" | head -1)
printf 'max_running_agents = 3\n' >"$TB_LIMITS"; n0=$(lg_ws)
eq "agent-approve: a pending agent-new is refused at the limit and stays pending" "$(rc $TB agent-approve "$lid") $(lgsql "SELECT status FROM agent_ops WHERE id=${lid#L-};") $(( $(lg_ws) - n0 ))" "4 pending 0"
$TB agent-reject "$lid" >/dev/null
# revive
lgsql "UPDATE agents SET state='stopped', session_id=NULL, cwd=NULL WHERE name='w2';"; FAKE_AGENTS="[$LG_C,$LG_W1]"
printf 'max_running_agents = 2\n' >"$TB_LIMITS"
eq "agent-revive: at the limit → 4" "$(rc $TB agent-revive w2)" "4"
printf 'max_running_agents = 9\n' >"$TB_LIMITS"
eq "agent-revive: below the limit is not refused by limits (4 is only the limit)" "$([[ $(rc $TB agent-revive w2 --fresh) != 4 ]] && echo notlimit)" "notlimit"
rm -f "$TB_LIMITS"

# ---- 強制: agent-spawn(上限で 4。spawn-policy.conf の互換)
FAKE_AGENTS="[$LG_C,$(lg_ag parent1 wP:p1)]"; : >"$FAKE_LOG"
LT=$($TB add -p lm -t 'work of parent1' --owner parent1); $TB update "$LT" --status in_progress >/dev/null
printf 'max_running_agents = 2\n' >"$TB_LIMITS"
eq "agent-spawn: at max_running_agents → 4 with the reason, nothing created" "$(HERDR_PANE_ID=wP:p1 $TB agent-spawn worker --task "$LT" --brief x 2>&1 >/dev/null | grep -c 'max_running_agents=2') $(HERDR_PANE_ID=wP:p1 rc $TB agent-spawn worker --task "$LT" --brief x) $(lg_ws) $(lgsql "SELECT COUNT(*) FROM agent_ops WHERE op='new' AND target LIKE 'parent1-s%';")" "1 4 0 0"
printf 'max_running_agents = 3\n' >"$TB_LIMITS"
eq "agent-spawn: below the limit passes" "$(HERDR_PANE_ID=wP:p1 $TB agent-spawn worker --task "$LT" --brief x | cut -d' ' -f1-2)" "parent1-s1 started"
# spawn-policy.conf は limits.conf が spawn キーを持たない限りそのまま効く
rm -f "$TB_LIMITS"; FAKE_AGENTS="[$LG_C,$(lg_ag parent1 wP:p1),$(lg_ag parent1-s1 wA:p1)]"
printf 'max_children_per_parent = 5\nmax_children_total = 1\n' >"$TMP/lim-spawn-old.conf"
eq "spawn-policy.conf alone still decides (total 1 reached → 4)" "$(TB_SPAWN_POLICY=$TMP/lim-spawn-old.conf HERDR_PANE_ID=wP:p1 $TB agent-spawn worker --task "$LT" --brief x 2>&1 >/dev/null | grep -c '全体の子の数が上限(1)') $(TB_SPAWN_POLICY=$TMP/lim-spawn-old.conf HERDR_PANE_ID=wP:p1 rc $TB agent-spawn worker --task "$LT" --brief x)" "1 4"
eq "limits.conf spawn_max_total overrides it (raised to 9 → passes)" "$(TB_LIMIT_SPAWN_MAX_TOTAL=9 TB_SPAWN_POLICY=$TMP/lim-spawn-old.conf HERDR_PANE_ID=wP:p1 $TB agent-spawn worker --task "$LT" --brief x | cut -d' ' -f1-2)" "parent1-s2 started"
printf 'spawn_max_per_parent = 1\n' >"$TB_LIMITS"
eq "limits.conf spawn_max_per_parent overrides it (lowered to 1 → 4)" "$(TB_SPAWN_POLICY=$TMP/lim-spawn-old.conf HERDR_PANE_ID=wP:p1 rc $TB agent-spawn worker --task "$LT" --brief x)" "4"
rm -f "$TB_LIMITS"

# ---- 強制: 解析役(analyst_max、max_running_agents)
export TB_DB=$TMP/limits-alert.db; : >"$FAKE_LOG"
LG_X=$(lg_ag watch1 wX:p1); FAKE_AGENTS="[$LG_C,$LG_X]"
eq "analyst: TB_ANALYST_MAX still works when limits does not set analyst_max" "$(TB_ANALYST_MAX=1 HERDR_PANE_ID=wX:p1 $TB alert --title 'a1' | cut -d' ' -f1-3) $(TB_ANALYST_MAX=1 HERDR_PANE_ID=wX:p1 $TB alert --title 'a2' | cut -d' ' -f1-3)" "A-1 new analyzing A-2 new queued"
printf 'analyst_max = 2\n' >"$TB_LIMITS"
eq "analyst: analyst_max in limits.conf wins over TB_ANALYST_MAX → the queued one starts" "$(TB_ANALYST_MAX=1 $TB alert-dispatch >/dev/null; lgsql "SELECT status FROM alerts WHERE id=2;")" "analyzing"
eq "analyst: analyst_max reached → the next one is queued" "$(HERDR_PANE_ID=wX:p1 $TB alert --title 'a3' | cut -d' ' -f1-3)" "A-3 new queued"
printf 'analyst_max = 5\nmax_running_agents = 2\n' >"$TB_LIMITS"
n0=$(lg_ws)
eq "analyst: max_running_agents reached → queued with the reason, no workspace" "$($TB alert-dispatch >/dev/null; lgsql "SELECT status||' '||(note LIKE '%max_running_agents%') FROM alerts WHERE id=3;") $(( $(lg_ws) - n0 ))" "queued 1 0"
printf 'analyst_max = 5\n' >"$TB_LIMITS"
eq "analyst: room again → it starts" "$($TB alert-dispatch >/dev/null; lgsql "SELECT status FROM alerts WHERE id=3;")" "analyzing"
rm -f "$TB_LIMITS"
export TB_DB=$TMP/limits.db

# ---- 強制: send(max_working_agents。超えたら outbox で待たせる)
FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2,$LG_W3]"; : >"$FAKE_LOG"
printf 'max_working_agents = 2\n' >"$TB_LIMITS"
out=$(HERDR_PANE_ID=wC:p1 $TB send w2 --text 'hello' 2>&1); r=$?
eq "send: working >= max_working_agents and the target is idle → exit 10, queued, not delivered" "$r $(grep -c 'max_working_agents=2' <<<"$out") $(grep -c '^prompt w2' "$FAKE_LOG") $(lgsql "SELECT status FROM outbox ORDER BY id DESC LIMIT 1;")" "10 1 0 queued"
eq "flush: still waits while the limit is reached" "$(rc $TB flush) $(grep -c '^prompt w2' "$FAKE_LOG") $(lgsql "SELECT COUNT(*) FROM outbox WHERE status='queued';")" "10 0 1"
printf 'max_working_agents = 3\n' >"$TB_LIMITS"
eq "flush: delivers once the limit has room" "$(rc $TB flush) $(grep -c '^prompt w2' "$FAKE_LOG") $(lgsql "SELECT COUNT(*) FROM outbox WHERE status='queued';")" "0 1 0"
printf 'max_working_agents = 2\n' >"$TB_LIMITS"
eq "send: below the limit (a working count of 1) delivers" "$(FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2]" HERDR_PANE_ID=wC:p1 rc $TB send w2 --text 'again') $(grep -c '^prompt w2' "$FAKE_LOG")" "0 2"
rm -f "$TB_LIMITS"
eq "send: no limit (0) never queues for it" "$(HERDR_PANE_ID=wC:p1 rc $TB send w2 --text 'free') $(grep -c '^prompt w2' "$FAKE_LOG")" "0 3"

# ---- 別の herdr セッションの台帳の行は、数えない・一覧に出さない・止める候補にしない
export TB_DB=$TMP/limits-sess.db; : >"$FAKE_LOG"
FAKE_AGENTS="[$LG_C,$LG_W1]"
$TB agents >/dev/null
lgsql "INSERT INTO agents (name, herdr_session, state, killable, created_by, created_at, updated_at, spawned_by, spawn_task) VALUES
  ('foreign1','other-sess','running','yes','herdr','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',NULL,NULL),
  ('foreign2','other-sess','running','unknown','herdr','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',NULL,NULL),
  ('analyst-A77','other-sess','running','unknown','herdr','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',NULL,NULL),
  ('foreign-kid','other-sess','running','unknown','herdr','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','gone-parent','T-x-001');"
eq "sessions: running counts only the current session's rows" "$($TB limits show --line | cut -d' ' -f1-2) $($TB limits show --json | jq -c '[.running.n, .spawn.n]')" "running 2/30 [2,0]"
printf 'max_running_agents = 3\n' >"$TB_LIMITS"
eq "sessions: the max_running_agents check ignores rows of other sessions (2 of 3 → one more passes)" "$($TB agent-new sess1 --cwd "$TMP" | cut -d' ' -f1-2)" "sess1 started"
eq "sessions: ...and then the current session is at the limit → 4" "$(FAKE_AGENTS="[$LG_C,$LG_W1,$(lg_ag sess1 wA:p1)]" rc $TB agent-new sess2 --cwd "$TMP")" "4"
rm -f "$TB_LIMITS"
eq "sessions: agent-shed offers nothing from another session (killable, analyst, orphan rows)" "$($TB agent-shed | wc -l | tr -d ' ')" "0"
eq "sessions: the foreign rows are untouched (still running, none stopped)" "$(lgsql "SELECT COUNT(*) FROM agents WHERE herdr_session='other-sess' AND state='running';") $(grep -c '^pane-close' "$FAKE_LOG")" "4 0"
# agent-spawn / digest の「子の数」も現在のセッションだけ
printf 'max_children_per_parent = 5\nmax_children_total = 1\n' >"$TMP/lim-spawn-sess.conf"
FAKE_AGENTS="[$LG_C,$(lg_ag parent1 wP:p1)]"
ST=$($TB add -p ss -t 'work of parent1' --owner parent1); $TB update "$ST" --status in_progress >/dev/null
eq "sessions: agent-spawn total ignores another session's children (foreign-kid does not fill the quota)" "$(TB_SPAWN_POLICY=$TMP/lim-spawn-sess.conf HERDR_PANE_ID=wP:p1 $TB agent-spawn worker --task "$ST" --brief x | cut -d' ' -f1-2)" "parent1-s1 started"
eq "sessions: digest spawn observations ignore another session's children" "$(lgsql "DELETE FROM agents WHERE spawned_by='parent1'; UPDATE agents SET state='running' WHERE name='foreign-kid';"; TB_SPAWN_POLICY=$TMP/lim-spawn-sess.conf $TB digest --dry-run | grep -c 'spawn 観測')" "0"
export TB_DB=$TMP/limits.db

# ---- agent-shed(読み取り専用。順番: 完了済みで待機中 → 止めてよい判定 → 解析役・親が終わった子)
export TB_DB=$TMP/shed.db; : >"$FAKE_LOG"
SH_AG() { lg_ag "$1" "$2" "$3"; }
FAKE_AGENTS="[$LG_C,$(SH_AG zdone wA:p1 idle),$(SH_AG kill1 wA:p2 idle),$(SH_AG kill0 wA:p3 idle),$(SH_AG busy1 wA:p4 working),$(SH_AG analyst-A9 wA:p5 idle),$(SH_AG kid1 wA:p6 idle),$(SH_AG adone wA:p7 working)]"
$TB agents >/dev/null
sqlite3 "$TB_DB" "INSERT INTO agents (name, herdr_session, state, killable, created_by, created_at, updated_at) VALUES ('analyst-A9','default','running','unknown','tb','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');"
for t in zdone busy1 adone; do $TB add -p sh -t "work $t" --owner "$t" >/dev/null; done
shsql() { sqlite3 "$TB_DB" "$@"; }
shsql "UPDATE tasks SET status='done' WHERE owner_agent IN ('zdone','adone'); UPDATE tasks SET status='in_progress' WHERE owner_agent='busy1';
       UPDATE agents SET spawned_by='gone-parent', spawn_task='T-none-001' WHERE name='kid1';"
$TB agent-flag kill1 --killable yes --reason 'finished' >/dev/null; $TB agent-flag kill0 --killable no --reason 'in use' >/dev/null
out=$($TB agent-shed)
eq "agent-shed: candidates in the design's order" "$(awk '{print $1":"$2}' <<<"$out" | tr '\n' ' ')" "done-idle:zdone killable:kill1 analyst:analyst-A9 orphan:kid1 "
eq "agent-shed: prints the exact stop command (--force only when not judged killable)" "$(grep -o 'tb agent-stop .*' <<<"$out" | tr '\n' ';')" "tb agent-stop zdone --force;tb agent-stop kill1;tb agent-stop analyst-A9 --force;tb agent-stop kid1 --force;"
eq "agent-shed: not listed — conductor, working, killable=no, open tasks" "$(grep -cE 'conductor|busy1|kill0|adone' <<<"$out")" "0"
eq "agent-shed --count 2 keeps the order" "$($TB agent-shed --count 2 | awk '{print $2}' | tr '\n' ' ')" "zdone kill1 "
eq "agent-shed --json: one object per line with the command" "$($TB agent-shed --json | jq -rc '[.group, .name, .command] | join("|")' | head -2 | tr '\n' ' ')" "done-idle|zdone|tb agent-stop zdone --force killable|kill1|tb agent-stop kill1 "
eq "agent-shed: stops nothing (no pane closed, every agent still running)" "$(grep -c '^pane-close' "$FAKE_LOG") $(shsql "SELECT COUNT(*) FROM agents WHERE state='running';") $(shsql "SELECT COUNT(*) FROM agent_ops;")" "0 8 0"
eq "agent-shed: a bad --count → 2" "$(rc $TB agent-shed --count x)" "2"
export TB_DB=$TMP/limits.db

# ---- limits check incident-open(障害対応の workspace を開くスクリプトが、何かを作る前に呼ぶ)
FAKE_AGENTS="[$LG_C,$LG_W1,$LG_W2]"; unset FAKE_WORKSPACES
eq "limits check incident-open: refusal creates nothing (no workspace, no agent)" "$(FAKE_AGENTS="[$LG_C]" TB_LIMIT_INCIDENT_MAX_OPEN=0 rc $TB limits check incident-open) $(lg_ws)" "4 0"
# ---- handoff(human_handoff が on のときだけ。文面を書くだけで、何も送らない)
HT=$($TB add -p hd -t 'Investigate intermittent login errors'); p0=$(prompts); ob0=$(lgsql "SELECT COUNT(*) FROM outbox;"); ms0=$(lgsql "SELECT COUNT(*) FROM messages;")
eq "handoff: off (default) → 4 and no file" "$(rc $TB handoff "$HT") $([[ -e $TMP/handoff ]] && echo dir || echo none)" "4 none"
eq "handoff: bad id → 2; unknown task (when on) → 1" "$(rc $TB handoff nope) $(TB_LIMIT_HUMAN_HANDOFF=on rc $TB handoff T-hd-999)" "2 1"
$TB limits set human_handoff on >/dev/null
out=$($TB handoff "$HT"); f=$TMP/handoff/$HT.md
eq "handoff: on → writes data/handoff/<task-id>.md and says nothing was sent" "$([[ -f $f ]] && echo file) $(grep -c '何も送っていません' <<<"$out")" "file 1"
eq "handoff: has purpose, access, deadline, return path" "$(grep -c -e '^## 目的' -e '^## 必要なアクセス' -e '^## 期限' -e '^## 成果物の返し先' "$f") $(grep -c 'Investigate intermittent login errors' "$f")" "4 1"
eq "handoff: states the text is for a human to post and agents contact nobody" "$(grep -c 'agent は誰にも連絡しません' "$f")" "1"
eq "handoff: sends nothing anywhere (no prompt, no outbox, no message)" "$(( $(prompts) - p0 )) $(( $(lgsql "SELECT COUNT(*) FROM outbox;") - ob0 )) $(( $(lgsql "SELECT COUNT(*) FROM messages;") - ms0 ))" "0 0 0"
eq "handoff: does not overwrite an existing text" "$(rc $TB handoff "$HT")" "1"
lg_secret() {  # $1=題名 → handoff の終了コードと、ファイルが作られていないこと
  local t; t=$($TB add -p hd -t "$1"); local rr; rr=$(rc $TB handoff "$t"); echo "$rr $([[ -e $TMP/handoff/$t.md ]] && echo written || echo none)"
}
eq "handoff: AWS access key id in the title → 4, not written" "$(lg_secret "key AK""IA$(printf 'A%.0s' {1..16}) here")" "4 none"
eq "handoff: private key header → 4, not written" "$(lg_secret "-----BEGIN RSA PRIV""ATE KEY-----")" "4 none"
eq "handoff: token-like strings → 4, not written" "$(lg_secret "use gh""p_$(printf 'a%.0s' {1..24})") $(lg_secret "token=$(printf 'x%.0s' {1..12})") $(lg_secret "id $(printf 'b%.0s' {1..40})")" "4 none 4 none 4 none"
errtxt=$(HERDR_PANE_ID= $TB add -p hd -t "pw AK""IA$(printf 'B%.0s' {1..16})" | xargs $TB handoff 2>&1 >/dev/null)
eq "handoff: tells the human to edit, without printing the secret" "$(grep -c '取り除いてから' <<<"$errtxt") $(grep -c 'AKIABBBB' <<<"$errtxt")" "1 0"
$TB limits unset human_handoff >/dev/null; rm -f "$TB_LIMITS"

# ---- 構成: help と README に載っている
eq "limits: new commands are in help.txt" "$(for c in limits agent-shed handoff; do grep -qE "^tb $c( |$)" "$HERE/../lib/help.txt" && echo 1 || echo 0; done | tr '\n' ' ')" "1 1 1 "
eq "limits: limits.conf.example lists every key" "$(for k in max_running_agents max_working_agents incident_max_open incident_roles analyst_max spawn_max_per_parent spawn_max_total watchers human_handoff; do grep -cE "^#? *$k = " "$HERE/../config/limits.conf.example"; done | tr '\n' ' ')" "1 1 1 1 1 1 1 1 1 "
[[ -z $_saved_pane ]] || export HERDR_PANE_ID=$_saved_pane
[[ -z $_saved_am ]] || export TB_ANALYST_MAX=$_saved_am
unset TB_LIMITS TB_HANDOFF_DIR FAKE_WORKSPACES

# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- add / 採番
a1=$($TB add -p alpha -t "first"); a2=$($TB add -p alpha -t "it's \"quoted\"; DROP TABLE tasks;--"); b1=$($TB add -p beta -t "b")
eq "id format/sequence" "$a1 $a2 $b1" "T-alpha-001 T-alpha-002 T-beta-001"
eq "title with quotes stored" "$($TB show $a2 | jq -r .title)" "it's \"quoted\"; DROP TABLE tasks;--"
eq "bad project rejected" "$(rc $TB add -p 'a-b' -t x)" "2"
eq "bad id rejected" "$(rc $TB show foo)" "2"
eq "missing task" "$(rc $TB show T-alpha-999)" "1"

# --- claim
eq "claim ok" "$(rc $TB claim $a1 --owner w1 --session s1)" "0"
eq "claim twice fails" "$(rc $TB claim $a1 --owner w2)" "1"
eq "owner kept" "$($TB show $a1 | jq -r '.owner_agent+"/"+.session_id+"/"+.status')" "w1/s1/in_progress"
eq "update status" "$(rc $TB update $a1 --status review)" "0"
eq "update to done rejected" "$(rc $TB update $a1 --status done)" "2"

# --- done の必須項目
eq "done without -d/-m" "$(rc $TB done $a1)" "2"
eq "done without -m" "$(rc $TB done $a1 -d /x/y)" "2"
eq "done without -d" "$(rc $TB done $a1 -m s)" "2"
eq "status unchanged after failed done" "$($TB show $a1 | jq -r .status)" "review"
eq "report before done fails" "$(rc $TB report $a1)" "1"

# --- report: idle → 送って reported_at を埋める(既定宛先 conductor)
$TB done $a1 -d /tmp/a.md -d https://example.invalid/pr/1 -m $'要約\n二行目' >/dev/null
eq "pending lists done+unreported" "$($TB pending --ids)" "$a1"
eq "pending shows default target" "$($TB pending | cut -f1,3)" "$(printf '%s\tconductor' "$a1")"
FAKE_STATUS=idle $TB report $a1 >/dev/null; r=$?
eq "report idle exit" "$r" "0"
eq "prompt message" "$(grep '^prompt' "$FAKE_LOG" | tail -1)" "$(printf 'prompt conductor\t[%s done] 要約 二行目 / /tmp/a.md, https://example.invalid/pr/1' "$a1")"
eq "reported_at set" "$($TB show $a1 | jq -r '.reported_at != null')" "true"
eq "pending empty" "$($TB pending --ids)" ""
n=$(prompts); $TB report $a1 >/dev/null
eq "re-report is idempotent (no resend)" "$(prompts)" "$n"

# --- report: working / blocked / unknown は送らず pending に残す
$TB done $a2 -d /tmp/b.md -m s2 >/dev/null
n=$(prompts)
eq "working → exit 10" "$(FAKE_STATUS=working rc $TB report $a2)" "10"
eq "blocked → exit 10" "$(FAKE_STATUS=blocked rc $TB report $a2)" "10"
eq "unknown → exit 10" "$(FAKE_STATUS=unknown rc $TB report $a2)" "10"
eq "no prompt sent while busy" "$(prompts)" "$n"
eq "reported_at still empty" "$($TB show $a2 | jq -r '.reported_at')" "null"
eq "still pending" "$($TB pending --ids)" "$a2"
eq "missing target → exit 11" "$(FAKE_STATUS=missing rc $TB report $a2)" "11"
eq "prompt failure → exit 11" "$(FAKE_PROMPT_RC=1 rc $TB report $a2)" "11"
eq "reported_at empty after failure" "$($TB show $a2 | jq -r '.reported_at')" "null"
eq "retry succeeds when idle" "$(FAKE_STATUS=done rc $TB report $a2)" "0"
eq "pending empty after retry" "$($TB pending --ids)" ""

# --- project ごとの宛先
printf '# c\nbeta = beta-conductor\n' >"$TB_CONFIG"
$TB done $b1 -d /tmp/c -m sb >/dev/null; $TB report $b1 >/dev/null
eq "project-specific target" "$(grep '^prompt' "$FAKE_LOG" | tail -1 | cut -f1)" "prompt beta-conductor"

# --- block / list / parent
b2=$($TB add -p beta -t child --parent $b1)
eq "parent stored" "$($TB show $b2 | jq -r .parent_id)" "$b1"
eq "bad parent rejected" "$(rc $TB add -p beta -t x --parent T-beta-999)" "1"
$TB block $b2 -m "wait" >/dev/null
eq "block" "$($TB list -p beta -s blocked | cut -f1,2)" "$(printf '%s\tblocked' "$b2")"
eq "done task can't be blocked" "$(rc $TB block $a1)" "1"

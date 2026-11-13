# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態は使わない)
# --- tb compact-check: 大きい文脈の待機中 agent に /compact を送る。判定の各条件と dry-run / apply / approvals
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
export TB_DB=$TMP/compact.db TB_APPROVALS=$TMP/appr-compact.conf TB_COMPACT_CONF=$TMP/compact.conf TB_CLAUDE_PROJECTS=$TMP/cprojects
unset FAKE_DYNAMIC FAKE_STATUS
cpsql() { sqlite3 "$TB_DB" "$@"; }
cp_ag() { printf '{"pane_id":"%s","name":"%s","agent_status":"%s","agent_session":{"value":"s-%s"},"cwd":"%s"}' "$2" "$1" "${3:-idle}" "$1" "$TMP"; }
# 疑似 transcript: 最後の "usage" 行が input 1000 + cache_creation 2000 + cache_read $2。その後ろに usage の無い行を置く
cp_tr() {  # $1=名前 $2=cache_read
  mkdir -p "$TMP/cprojects/proj-x"
  { printf '{"message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}}}\n'
    printf '{"message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":%s}}}\n' "$2"
    printf '{"type":"user","message":{"content":"SECRET-BODY"}}\n'; } >"$TMP/cprojects/proj-x/s-$1.jsonl"
}
cp_keys() { grep -c "^prompt .*	/compact$" "$FAKE_LOG"; }
printf 'enabled = 1\nthreshold_tokens = 150000\nmin_interval_sec = 1800\nexclude = conductor skipme\n' >"$TB_COMPACT_CONF"
printf 'agent:compact:big = allow\nagent:compact:busy = allow\nagent:compact:skipme = allow\nagent:compact:small = allow\nagent:compact:recent = allow\n* = ask\n' >"$TB_APPROVALS"
cp_tr big 200000; cp_tr busy 200000; cp_tr skipme 200000; cp_tr small 1000; cp_tr recent 200000; cp_tr noappr 200000; cp_tr conductor 200000
export FAKE_AGENTS="[$(cp_ag conductor wC:p1),$(cp_ag big wB:p1),$(cp_ag busy wY:p1 working),$(cp_ag skipme wS:p1),$(cp_ag small wM:p1),$(cp_ag recent wR:p1),$(cp_ag noappr wN:p1)]"
: >"$FAKE_LOG"
$TB agents >/dev/null
cpsql "INSERT INTO agent_ops (op,target,args,requested_by,status,result,created_at,decided_at) VALUES ('compact','recent','{}','human','done','x',strftime('%Y-%m-%dT%H:%M:%SZ','now','-60 seconds'),strftime('%Y-%m-%dT%H:%M:%SZ','now','-60 seconds'));"

# ---- dry-run(既定): 何も送らない。tokens は最後の usage 行の合計(203000)。transcript の中身は出さない
out=$($TB compact-check 2>&1)
eq "compact: dry-run sends nothing, records nothing new" "$(cp_keys) $(cpsql "SELECT COUNT(*) FROM agent_ops WHERE op='compact';")" "0 1"
eq "compact: dry-run lists the eligible agent with summed tokens" "$(grep -c '^big 203000 would-compact' <<<"$out")" "1"
eq "compact: below threshold skipped" "$(grep -c '^small 4000 skip(below threshold' <<<"$out")" "1"
eq "compact: working skipped" "$(grep -c '^busy - skip(working)' <<<"$out")" "1"
eq "compact: excluded (config list and conductor) skipped" "$(grep -c '^skipme - skip(excluded)' <<<"$out") $(grep -c '^conductor - skip(excluded)' <<<"$out")" "1 1"
eq "compact: compacted within min_interval skipped" "$(grep -c '^recent 203000 skip(compacted' <<<"$out")" "1"
eq "compact: no approvals rule (ask) skipped with the line to add" "$(grep -c "^noappr 203000 skip(approval: agent:compact:noappr is ask; add 'agent:compact:\* = allow'" <<<"$out")" "1"
eq "compact: output never contains transcript content" "$(grep -c SECRET-BODY <<<"$out")" "0"
eq "compact: --dry-run explicit sends nothing" "$($TB compact-check --dry-run >/dev/null; echo $?)$(cp_keys)" "00"

# ---- --apply: 対象 1 体にだけ /compact を 1 回送り、記録を残す。2 回目は min_interval で送らない
out=$($TB compact-check --apply 2>&1)
eq "compact: apply sends /compact once, to the eligible agent only" "$(cp_keys) $(grep -c "^prompt big	/compact$" "$FAKE_LOG")" "1 1"
eq "compact: apply prints a sent line" "$(grep -c '^big 203000 sent' <<<"$out")" "1"
eq "compact: apply recorded as agent_ops kind compact" "$(cpsql "SELECT op||' '||status||' '||requested_by FROM agent_ops WHERE target='big';")" "compact done human"
$TB compact-check --apply >/dev/null 2>&1
eq "compact: second apply is blocked by min_interval" "$(cp_keys)" "1"

# ---- 無効のとき / 状態が直前で変わったとき
printf 'enabled = 0\n' >"$TB_COMPACT_CONF"
eq "compact: disabled does nothing" "$($TB compact-check --apply | grep -c '^compact-check: disabled') $(cp_keys)" "1 1"
printf 'enabled = 1\nexclude = conductor\nmin_interval_sec = 0\n' >"$TB_COMPACT_CONF"
FAKE_STATUS=working $TB compact-check --apply >/dev/null 2>&1
eq "compact: herdr says working right before send → nothing sent" "$(cp_keys)" "1"
eq "compact: bad usage → 2" "$(rc $TB compact-check --bogus)" "2"
[[ -z $_saved_pane ]] || export HERDR_PANE_ID=$_saved_pane

# shellcheck shell=bash
# run.sh から番号順に source される
# --- 起動直後の最初の指示: 準備完了を待つ / 送ったあと動き出したか確かめる / 本文を二重に送らない
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
export TB_DB=$TMP/ready.db TB_APPROVALS=$TMP/appr-ready.conf TB_SPAWN_RETRY_SEC=0 TB_AGENT_CWD=$TMP
printf 'agent:* = ask\nsend:info:* = allow\n* = ask\n' >"$TB_APPROVALS"
rd_reset() { : >"$FAKE_LOG"; rm -f "$FAKE_LOG.ready" "$FAKE_LOG.working"; unset FAKE_READY_AFTER FAKE_PROMPT_MODE FAKE_STATUS; }
rd_n() { grep -c "$1" "$FAKE_LOG"; }   # 一致する行数

# 準備ができるまで待ってから送る(最初の 3 回は interactive_ready=false)
rd_reset; export FAKE_READY_AFTER=3 FAKE_PROMPT_MODE=work TB_SPAWN_READY_SEC=2 TB_PROMPT_VERIFY_SEC=1
out=$($TB agent-new rd1 --cwd "$TMP" --prompt 'hello' 2>&1; echo "rc=$?")
eq "ready: waits for interactive_ready, then sends once" "$(rd_n '^prompt rd1') $(rd_n '^keys')" "1 0"
eq "ready: not ready at first (polled get before the prompt)" "$(awk '/^get rd1/{g++} /^prompt rd1/{print (g>=4)}' "$FAKE_LOG")" "1"
eq "ready: success output has no warning, rc 0" "$(grep -c '未送信\|確認できません' <<<"$out") $(tail -1 <<<"$out")" "0 rc=0"

# 準備完了にならない → 送らず、きれいに諦める(起動は成功のまま)
rd_reset; export FAKE_READY_AFTER=100000 TB_SPAWN_READY_SEC=0.3
out=$($TB agent-new rd2 --cwd "$TMP" --prompt 'hello' 2>&1; echo "rc=$?")
eq "ready: never ready → nothing sent" "$(rd_n '^prompt') $(rd_n '^keys')" "0 0"
eq "ready: never ready → clear message, agent stays registered, rc 0" "$(grep -c '最初の指示は未送信' <<<"$out") $(tail -1 <<<"$out")" "1 rc=0"

# 動き出さない(Enter が失われた)→ 本文は再送せず Enter だけを 1 回送る
rd_reset; export FAKE_PROMPT_MODE=swallow-once TB_SPAWN_READY_SEC=2 TB_PROMPT_VERIFY_SEC=0.3
out=$($TB agent-new rd3 --cwd "$TMP" --prompt 'hello' 2>&1; echo "rc=$?")
eq "verify: swallowed submit → text sent once, Enter sent once" "$(rd_n '^prompt rd3') $(grep -c '^keys rd3'"$(printf '\t')"'Enter$' "$FAKE_LOG")" "1 1"
eq "verify: recovered by Enter → no warning" "$(grep -c '確認できません' <<<"$out") $(tail -1 <<<"$out")" "0 rc=0"

# Enter でも動かない → それ以上はしない(Enter は 1 回だけ、本文は 1 回だけ)。人に知らせる
rd_reset; export FAKE_PROMPT_MODE=swallow-always TB_PROMPT_VERIFY_SEC=0.3
out=$($TB agent-new rd4 --cwd "$TMP" --prompt 'hello' 2>&1; echo "rc=$?")
eq "verify: still idle → no duplicate text, one Enter only" "$(rd_n '^prompt rd4') $(rd_n '^keys')" "1 1"
eq "verify: still idle → tells the human to press Enter" "$(grep -c '再送せず' <<<"$out")" "1"

# 動き出さない状態でも、検証を切れば従来どおり(待たず、Enter も送らない)
rd_reset; export FAKE_PROMPT_MODE=swallow-always TB_PROMPT_VERIFY_SEC=0
out=$($TB agent-new rd5 --cwd "$TMP" --prompt 'hello' 2>&1; echo "rc=$?")
eq "verify: TB_PROMPT_VERIFY_SEC=0 disables the check" "$(rd_n '^prompt rd5') $(rd_n '^keys')" "1 0"

# tb send は準備待ちも検証もしない(ready な agent への送信は従来どおり 1 回)
rd_reset; export FAKE_PROMPT_MODE=swallow-always TB_PROMPT_VERIFY_SEC=5 TB_SPAWN_READY_SEC=5 FAKE_READY_AFTER=100000
n0=$SECONDS
RD_AG='[{"pane_id":"wC:p1","name":"conductor","agent_status":"idle","agent_session":{"value":"sc"}},{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"sw"}}]'
eq "send: unaffected by readiness/verification" "$(FAKE_AGENTS=$RD_AG HERDR_PANE_ID=wC:p1 $TB send worker1 --kind info --text hi >/dev/null 2>&1; echo $?) $(rd_n '^prompt worker1') $(rd_n '^keys')" "0 1 0"
eq "send: returns promptly" "$(( SECONDS - n0 < 3 ))" "1"

rd_reset; unset TB_SPAWN_READY_SEC TB_PROMPT_VERIFY_SEC
export TB_PROMPT_VERIFY_SEC=0 TB_SPAWN_POLL_SEC=0.05 TB_SPAWN_READY_SEC=0.2 TB_VERIFY_POLL_SEC=0.05
[[ -n $_saved_pane ]] && export HERDR_PANE_ID=$_saved_pane

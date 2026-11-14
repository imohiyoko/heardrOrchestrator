# shellcheck shell=bash
# run.sh から番号順に source される
# --- PR 作成キュー(tb pr-queue)。本物の gh・ネットワーク・GitHub は呼ばない(疑似 gh)
_saved_pane=${HERDR_PANE_ID-}; unset HERDR_PANE_ID
_pq_saved=$(env | grep -E '^(TB_DB|TB_REPOS_FILE|PR_QUEUE_[A-Z_]+|FAKE_GH_[A-Z_]+|FAKE_AGENTS)=' || true)
export TB_DB=$TMP/pq.db TB_REPOS_FILE=$TMP/pq-repos.md PR_QUEUE_BODY_ROOT=$TMP/pq-reports PR_QUEUE_GH=$TMP/pq-gh FAKE_GH_LOG=$TMP/pq-gh.log
export FAKE_AGENTS='[{"pane_id":"wW:p1","name":"worker1","agent_session":{"value":"sw"}}]'
unset PR_QUEUE_REPO_DIR FAKE_GH_LIST FAKE_GH_LIST_FAIL FAKE_GH_CREATE_FAIL
mkdir -p "$PR_QUEUE_BODY_ROOT"; : >"$FAKE_GH_LOG"
printf '%s\n' '# 許可リスト' '- org/repo   # 対象' >"$TB_REPOS_FILE"
cat >"$PR_QUEUE_GH" <<'G'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "pr list") [[ -z ${FAKE_GH_LIST_FAIL:-} ]] || exit 1
    if [[ -n ${FAKE_GH_DUP:-} && " $* " == *" --head $FAKE_GH_DUP "* ]]; then echo '[{"number":5}]'; else echo "${FAKE_GH_LIST:-[]}"; fi;;
  "pr create") [[ -z ${FAKE_GH_CREATE_FAIL:-} ]] || exit 1; echo "https://github.com/org/repo/pull/77";;
  *) exit 9;;
esac
G
chmod +x "$PR_QUEUE_GH"
PQ_L1='Report: https://example.com/r/123'
PQ_RULE='body_first_line = ^Report: https://example\.com/r/[0-9]+$'
export PR_QUEUE_CONF=$TMP/pq.conf; printf '%s\n' "$PQ_RULE" >"$PR_QUEUE_CONF"
pqbody() { printf '%s\n\n## 原因\nテスト\n' "${2:-$PQ_L1}" >"$PR_QUEUE_BODY_ROOT/$1.md"; }
pqsql() { sqlite3 "$TB_DB" "$@"; }
pqgh() { grep -c "$1" "$FAKE_GH_LOG"; }
pqadd() { $TB pr-queue add --branch "$1" --body-file "$PR_QUEUE_BODY_ROOT/$2.md" --title "題 $2" "${@:3}" 2>&1; }

# ---- add: 置くだけ。pending。gh は呼ばれない
pqbody b1
eq "pr-queue add: pending" "$(pqadd agent/t-1 b1)" "PQ-1 pending"
eq "pr-queue list: shows it" "$($TB pr-queue list | cut -f1-3)" "$(printf 'PQ-1\tpending\tagent/t-1')"
eq "pr-queue add: invalid input refused (branch prefix, branch chars, repo not on list, outside body_root, missing file, no repo list)" \
  "$(rc $TB pr-queue add --branch feature/x --body-file "$PR_QUEUE_BODY_ROOT/b1.md" --title t) $(rc $TB pr-queue add --branch 'agent/a b' --body-file "$PR_QUEUE_BODY_ROOT/b1.md" --title t) $(rc $TB pr-queue add --branch agent/x --body-file "$PR_QUEUE_BODY_ROOT/b1.md" --title t --repo other/repo) $(rc $TB pr-queue add --branch agent/x --body-file /etc/hosts --title t) $(rc $TB pr-queue add --branch agent/x --body-file "$PR_QUEUE_BODY_ROOT/none.md" --title t)" "1 1 1 1 1"
ln -sf "$PR_QUEUE_BODY_ROOT/b1.md" "$PR_QUEUE_BODY_ROOT/link.md"
eq "pr-queue add: symlink body refused" "$(rc $TB pr-queue add --branch agent/x --body-file "$PR_QUEUE_BODY_ROOT/link.md" --title t)" "1"
eq "pr-queue add: nothing else was queued" "$(pqsql 'SELECT COUNT(*) FROM pr_queue;')" "1"

# ---- 承認なしは実行されない
$TB pr-queue run >/dev/null 2>&1
eq "pr-queue run: pending is never executed (gh not called)" "$(wc -l <"$FAKE_GH_LOG" | tr -d ' ') $(pqsql 'SELECT status FROM pr_queue WHERE id=1;')" "0 pending"

# ---- agent の pane からは approve / reject できない
export HERDR_PANE_ID=wW:p1
eq "pr-queue approve/reject: refused from an agent pane" "$(rc $TB pr-queue approve 1) $(rc $TB pr-queue reject 1) $(pqsql 'SELECT status FROM pr_queue WHERE id=1;')" "1 1 pending"
unset HERDR_PANE_ID

# ---- 承認 → run: draft PR だけを、決まった引数で作る
eq "pr-queue approve: human approves" "$($TB pr-queue approve PQ-1 | cut -d"(" -f1)" "PQ-1 approved"
out=$($TB pr-queue run 2>&1)
eq "pr-queue run: created, url recorded" "$(grep -c 'PQ-1 created: https://github.com/org/repo/pull/77' <<<"$out") $(pqsql 'SELECT status FROM pr_queue WHERE id=1;')" "1 created"
eq "pr-queue run: duplicate check first, then create with draft/base main/head/repo" \
  "$(sed -n 1p "$FAKE_GH_LOG") | $(sed -n 2p "$FAKE_GH_LOG" | sed "s#--body-file [^ ]*#--body-file F#")" \
  "pr list --repo org/repo --head agent/t-1 --state open --json number | pr create --repo org/repo --base main --head agent/t-1 --title 題 b1 --body-file F --draft"
$TB pr-queue run >/dev/null 2>&1
eq "pr-queue run: created ones are not run again" "$(pqgh 'pr create')" "1"
eq "pr-queue: no merge / review / ready / close is ever issued" "$(pqgh 'pr merge\|pr review\|pr ready\|pr close\|--approve')" "0"
eq "pr-queue: the code has no merge/approve either" "$(grep -cE 'pr (merge|review|ready|close)|--approve' "$HERE/../lib/prqueue.sh")" "0"

# ---- ガード(approve の時点)
pqbody g1 'Report: <!-- link -->'; pqbody g2 'TODO'; pqbody g3 'https://example.com/r/1'
pqadd agent/g1 g1 >/dev/null; pqadd agent/g2 g2 >/dev/null; pqadd agent/g3 g3 >/dev/null
eq "guard: body line 1 must match body_first_line (template / TODO / bare URL refused at approve)" \
  "$(rc $TB pr-queue approve 2) $(rc $TB pr-queue approve 3) $(rc $TB pr-queue approve 4) $(pqsql "SELECT group_concat(status) FROM pr_queue WHERE id IN (2,3,4);")" "1 1 1 pending,pending,pending"
SEC_AWS="AKIA""IOSFODNN7EXAMPLE"
printf '%s\n\nkey は %s です\n' "$PQ_L1" "$SEC_AWS" >"$PR_QUEUE_BODY_ROOT/s1.md"
pqadd agent/s1 s1 >/dev/null
out=$($TB pr-queue approve 5 2>&1); r=$?
eq "guard: secret-looking value in body refused; the value is not printed" "$r $(grep -c "$SEC_AWS" <<<"$out") $(grep -c 'AWS' <<<"$out")" "1 0 1"
printf '%s\n\nトークン %s\n' "$PQ_L1" "ghp_""abcdefghijklmnopqrstuvwxyz0123456789" >"$PR_QUEUE_BODY_ROOT/s2.md"
pqadd agent/s2 s2 >/dev/null
eq "guard: token-shaped value refused" "$(rc $TB pr-queue approve 6)" "1"
printf '%s\n\n何かの手順(コミット %s)\n' "$PQ_L1" "$(printf 'a%.0s' {1..8})" >"$PR_QUEUE_BODY_ROOT/ok2.md"
pqadd agent/ok2 ok2 >/dev/null
eq "guard: a body with a long doc URL on line 1 and normal text passes" "$($TB pr-queue approve 7 | cut -d"(" -f1)" "PQ-7 approved"
$TB pr-queue run >/dev/null 2>&1   # 7 を流して、以後の回数を数えやすくする

# ---- ガード(run の時点: 承認後に状態が変わった)
$TB pr-queue approve 1 >/dev/null 2>&1   # created なので失敗してよい
pqbody c1; pqadd agent/c1 c1 >/dev/null; $TB pr-queue approve 8 >/dev/null
printf 'あとから足した行\n' >>"$PR_QUEUE_BODY_ROOT/c1.md"
: >"$FAKE_GH_LOG"; out=$($TB pr-queue run 2>&1)
eq "guard at run: body changed after approval → rejected, no create" "$(grep -c '本文が、置かれたときから変わっている' <<<"$out") $(pqgh 'pr create') $(pqsql 'SELECT status FROM pr_queue WHERE id=8;')" "1 0 rejected"
pqbody c2; pqadd agent/c2 c2 >/dev/null; $TB pr-queue approve 9 >/dev/null
printf '%s\n' '# 許可リスト' '- other/repo' >"$TB_REPOS_FILE"
: >"$FAKE_GH_LOG"; out=$($TB pr-queue run 2>&1)
eq "guard at run: repo removed from the allowlist → rejected" "$(grep -c '許可リストに無い' <<<"$out") $(pqgh 'pr create') $(pqsql 'SELECT status FROM pr_queue WHERE id=9;')" "1 0 rejected"
printf '%s\n' '# 許可リスト' '- org/repo' >"$TB_REPOS_FILE"
pqbody c3; pqadd agent/c3 c3 >/dev/null; $TB pr-queue approve 10 >/dev/null
pqsql "UPDATE pr_queue SET branch='main' WHERE id=10;"
: >"$FAKE_GH_LOG"; out=$($TB pr-queue run 2>&1)
eq "guard at run: a branch outside branch_prefix (tampered row) → rejected" "$(pqgh 'pr create') $(pqsql 'SELECT status FROM pr_queue WHERE id=10;')" "0 rejected"

# ---- 重複: 同じ head の open PR が既にある
pqbody d1; pqadd agent/d1 d1 >/dev/null; $TB pr-queue approve 11 >/dev/null
: >"$FAKE_GH_LOG"; out=$(FAKE_GH_LIST='[{"number":5}]' $TB pr-queue run 2>&1)
eq "duplicate: an open PR with the same head exists → rejected, no create" "$(grep -c '既にある' <<<"$out") $(pqgh 'pr create') $(pqsql 'SELECT status FROM pr_queue WHERE id=11;')" "1 0 rejected"

# ---- gh の失敗: 重複確認が取れなければ作らない。作成の失敗は 3 回で failed
pqbody e1; pqadd agent/e1 e1 >/dev/null; $TB pr-queue approve 12 >/dev/null
: >"$FAKE_GH_LOG"
for _i in 1 2; do FAKE_GH_LIST_FAIL=1 $TB pr-queue run >/dev/null 2>&1; done
eq "gh list fails: never creates, stays approved, attempts counted" "$(pqgh 'pr create') $(pqsql 'SELECT status||attempts FROM pr_queue WHERE id=12;')" "0 approved2"
FAKE_GH_LIST_FAIL=1 $TB pr-queue run >/dev/null 2>&1
eq "gh list fails 3 times → failed" "$(pqsql 'SELECT status FROM pr_queue WHERE id=12;')" "failed"
pqbody e2; pqadd agent/e2 e2 >/dev/null; $TB pr-queue approve 13 >/dev/null
for _i in 1 2 3; do FAKE_GH_CREATE_FAIL=1 $TB pr-queue run >/dev/null 2>&1; done
eq "gh create fails 3 times → failed, error has no raw gh output" "$(pqsql 'SELECT status||attempts FROM pr_queue WHERE id=13;') $(pqsql 'SELECT last_error FROM pr_queue WHERE id=13;')" "failed3 gh pr create が失敗(exit 1)"

# ---- dry-run / reject
pqbody f1; pqadd agent/f1 f1 >/dev/null; $TB pr-queue approve 14 >/dev/null
: >"$FAKE_GH_LOG"; out=$($TB pr-queue run --dry-run 2>&1)
eq "run --dry-run: reports, creates nothing, changes nothing" "$(grep -c 'would-create' <<<"$out") $(pqgh 'pr create') $(pqsql 'SELECT status FROM pr_queue WHERE id=14;')" "1 0 approved"
eq "reject: human rejects an approved item; it is not run" "$($TB pr-queue reject 14 -m 不要) $($TB pr-queue run >/dev/null 2>&1; pqgh 'pr create')" "PQ-14 rejected 0"
eq "approve: only pending can be approved" "$(rc $TB pr-queue approve 14)" "1"

# ---- 差分のガード(ローカルの clone があるときだけ。読み取りだけ)
R=$TMP/pq-clone; mkdir -p "$R"; git -C "$R" init -q -b main; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
echo base >"$R/a.txt"; git -C "$R" add .; git -C "$R" commit -qm base; git -C "$R" update-ref refs/remotes/origin/main HEAD
mkbranch() { git -C "$R" checkout -q -b "$1" main; mkdir -p "$R/$(dirname "$2")"; printf '%s\n' "$3" >"$R/$2"; git -C "$R" add .; git -C "$R" commit -qm c; git -C "$R" checkout -q main; }
mkbranch agent/df-ok terraform/a.tf 'resource "x" "y" {}'
mkbranch agent/df-ci .github/workflows/ci.yml 'on: push'
mkbranch agent/df-sec terraform/b.tf "key = \"$SEC_AWS\""
mkbranch agent/df-admin terraform/c.tf 'policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"'
export PR_QUEUE_REPO_DIR=$R
for b in df-ok df-ci df-sec df-admin; do pqbody $b; pqadd agent/$b $b >/dev/null; done
for i in 15 16 17 18; do PR_QUEUE_REPO_DIR= $TB pr-queue approve $i >/dev/null 2>&1; done   # approve 時は診断を切って、run 時のガードを見る
: >"$FAKE_GH_LOG"; out=$($TB pr-queue run 2>&1)
eq "diff guard: clean change created; CI config / secret-looking / AdministratorAccess rejected" \
  "$(pqsql "SELECT group_concat(status) FROM pr_queue WHERE id IN (15,16,17,18);") $(pqgh 'pr create') $(grep -c "$SEC_AWS" <<<"$out")" "created,rejected,rejected,rejected 1 0"
mkbranch agent/df-unknown terraform/z.tf 'x'
pqbody dfx; pqadd agent/df-missing dfx >/dev/null; PR_QUEUE_REPO_DIR= $TB pr-queue approve 19 >/dev/null 2>&1
: >"$FAKE_GH_LOG"; $TB pr-queue run >/dev/null 2>&1
eq "diff guard: branch missing in the clone → rejected (fail closed)" "$(pqgh 'pr create') $(pqsql 'SELECT status FROM pr_queue WHERE id=19;')" "0 rejected"
unset PR_QUEUE_REPO_DIR

# ---- scan: origin の agent/* を走査してキューに積む(疑似 git: ls-remote / fetch / log だけ差し替え、残りは本物の git)
PQ_FAKEGIT=$TMP/pq-git; mkdir -p "$TMP/pq-titles"
cat >"$PQ_FAKEGIT" <<'G'
#!/usr/bin/env bash
args=("$@"); [[ ${args[0]} == -C ]] && args=("${args[@]:2}")
case ${args[0]} in
  ls-remote) for b in $FAKE_GIT_HEADS; do printf 'deadbeef\trefs/heads/%s\n' "$b"; done;;
  fetch) exit 0;;
  log) cat "$FAKE_GIT_TITLES/$(sed 's#.*origin/agent/##' <<<"${args[${#args[@]}-1]}")" 2>/dev/null;;
  *) exec git "$@";;
esac
G
chmod +x "$PQ_FAKEGIT"
export PR_QUEUE_GIT=$PQ_FAKEGIT FAKE_GIT_TITLES=$TMP/pq-titles PR_QUEUE_CONF=$TMP/pq.conf PR_QUEUE_REPO_DIR=$R
unset FAKE_GH_DUP
printf '%s\n' "$PQ_RULE" >"$PR_QUEUE_CONF"
sc_title() { printf '%s\n' "$2" >"$FAKE_GIT_TITLES/$1"; }
for n in ok1 ok2x nolink dup sec ph notitle nobody; do mkbranch agent/sc-$n terraform/$n.tf "x $n"; done
for n in ok1 ok2x nolink dup sec ph; do pqbody pr-body-agent-sc-$n; done
mv_body() { mv "$PR_QUEUE_BODY_ROOT/$1.md" "$PR_QUEUE_BODY_ROOT/$2.md"; }
for n in ok1 ok2x nolink dup sec ph notitle; do pqbody "pr-body-agent-sc-$n"; done
pqbody pr-body-agent-sc-nolink 'TODO リンクを貼る'
pqbody pr-body-agent-sc-ph "$PQ_L1"; printf '{{原因}} を書く\n' >>"$PR_QUEUE_BODY_ROOT/pr-body-agent-sc-ph.md"
printf '%s\n\nkey %s\n' "$PQ_L1" "$SEC_AWS" >"$PR_QUEUE_BODY_ROOT/pr-body-agent-sc-sec.md"
for n in ok1 ok2x nolink dup sec ph; do sc_title sc-$n "対応 $n"; done
: >"$FAKE_GIT_TITLES/sc-notitle"
export FAKE_GIT_HEADS="agent/sc-ok1 agent/sc-nolink agent/sc-dup agent/sc-sec agent/sc-ph agent/sc-notitle agent/sc-nobody"
export FAKE_GH_DUP=agent/sc-dup
: >"$FAKE_GH_LOG"; out=$($TB pr-queue scan 2>&1)
eq "scan (auto_approve unset): only the good branch is queued, as pending (never approved)" \
  "$(pqsql "SELECT group_concat(branch||':'||status) FROM pr_queue WHERE id>=20;") $(pqsql "SELECT title FROM pr_queue WHERE branch='agent/sc-ok1';")" "agent/sc-ok1:pending 対応 ok1"
eq "scan: skip reasons (no body / no link / placeholder / duplicate / secret / empty title)" \
  "$(grep -c 'sc-nobody: 本文' <<<"$out") $(grep -c 'sc-nolink: .*1 行目' <<<"$out") $(grep -c 'sc-ph: .*プレースホルダ' <<<"$out") $(grep -c 'sc-dup: 同じ head の PR' <<<"$out") $(grep -c 'sc-sec: .*秘密' <<<"$out") $(grep -c 'sc-notitle: 最新コミットの題が空' <<<"$out") $(grep -c "$SEC_AWS" <<<"$out")" "1 1 1 1 1 1 0"
eq "scan: duplicate check looks at all states; no create happened" "$(grep -c -- '--state all' "$FAKE_GH_LOG") $(pqgh 'pr create')" "2 0"
: >"$FAKE_GH_LOG"; $TB pr-queue run >/dev/null 2>&1
eq "run after scan (auto_approve=0): nothing is created for pending items" "$(pqgh 'pr create')" "0"
eq "scan: already-queued branch is not queued twice" "$($TB pr-queue scan 2>&1 | grep -c 'sc-ok1: 既にキューにある') $(pqsql "SELECT COUNT(*) FROM pr_queue WHERE branch='agent/sc-ok1';")" "1 1"
eq "scan --dry-run: queues nothing" "$(pqsql "SELECT COUNT(*) FROM pr_queue;") $(FAKE_GIT_HEADS=agent/sc-ok2x pqbody pr-body-agent-sc-ok2x; FAKE_GIT_HEADS=agent/sc-ok2x $TB pr-queue scan --dry-run | grep -c 'would-queue') $(pqsql "SELECT COUNT(*) FROM pr_queue;")" "$(pqsql "SELECT COUNT(*) FROM pr_queue;") 1 $(pqsql "SELECT COUNT(*) FROM pr_queue;")"
# auto_approve=1: approved で積む。run のガードは同じ。1 回の上限は 3
printf '%s\nauto_approve=1\n' "$PQ_RULE" >"$PR_QUEUE_CONF"
for n in a b c d; do mkbranch agent/cap-$n terraform/cap$n.tf "x $n"; pqbody pr-body-agent-cap-$n; sc_title cap-$n "cap $n"; done
export FAKE_GIT_HEADS="agent/cap-a agent/cap-b agent/cap-c agent/cap-d"
$TB pr-queue scan >/dev/null 2>&1
eq "scan (auto_approve=1): queued as approved" "$(pqsql "SELECT group_concat(status) FROM pr_queue WHERE branch LIKE 'agent/cap-%';")" "approved,approved,approved,approved"
: >"$FAKE_GH_LOG"; out=$($TB pr-queue run 2>&1)
eq "run: at most 3 PRs per run; the rest wait for the next run" "$(pqgh 'pr create') $(pqsql "SELECT COUNT(*) FROM pr_queue WHERE branch LIKE 'agent/cap-%' AND status='approved';") $(grep -c '上限' <<<"$out")" "3 1 1"
$TB pr-queue run >/dev/null 2>&1
eq "run: next run creates the remaining one" "$(pqsql "SELECT COUNT(*) FROM pr_queue WHERE branch LIKE 'agent/cap-%' AND status='created';")" "4"
# 再試行の上限: 作成が失敗し続けたブランチは 3 回で failed、scan は積み直さない
mkbranch agent/fl terraform/fl.tf x; pqbody pr-body-agent-fl; sc_title fl "fl"
export FAKE_GIT_HEADS="agent/fl"; $TB pr-queue scan >/dev/null 2>&1
export FAKE_GH_CREATE_FAIL=1; for i in 1 2 3 4; do $TB pr-queue run >/dev/null 2>&1; done; unset FAKE_GH_CREATE_FAIL
eq "retry cap: failing branch becomes failed after 3 attempts and is not re-queued by scan" \
  "$(pqsql "SELECT status||attempts FROM pr_queue WHERE branch='agent/fl';") $($TB pr-queue scan 2>&1 | grep -c 'fl: 既にキューにある') $(pqsql "SELECT COUNT(*) FROM pr_queue WHERE branch='agent/fl';")" "failed3 1 1"
eq "scan: no merge/approve/ready in the code or the gh calls" "$(pqgh 'pr merge\|pr review\|pr ready\|pr close\|--approve')" "0"
for _v in PR_QUEUE_GIT FAKE_GIT_TITLES PR_QUEUE_CONF FAKE_GIT_HEADS FAKE_GH_DUP; do unset "$_v"; done
unset PR_QUEUE_REPO_DIR

# ---- 設定: branch_prefix を変える / body_first_line が空なら 1 行目は見ない
export PR_QUEUE_CONF=$TMP/pq2.conf; printf 'branch_prefix = bot/\n' >"$PR_QUEUE_CONF"
pqbody nf1 'anything on the first line'
out=$(pqadd bot/nf1 nf1); nid=${out%% *}; nid=${nid#PQ-}
eq "config: custom branch_prefix is used, the default one is refused" \
  "$(rc $TB pr-queue add --branch agent/nf2 --body-file "$PR_QUEUE_BODY_ROOT/nf1.md" --title t) ${out#* }" "1 pending"
eq "config: without body_first_line any first line passes the guard" "$(rc $TB pr-queue approve "$nid") $(pqsql "SELECT status FROM pr_queue WHERE id=$nid;")" "0 approved"
printf 'branch_prefix = not valid\n' >"$PR_QUEUE_CONF"
eq "config: an invalid branch_prefix falls back to agent/" "$(pqadd agent/nf3 nf1 | cut -d' ' -f2)" "pending"
unset PR_QUEUE_CONF

# 後片付け: 触った変数を元に戻す
for _v in TB_DB TB_REPOS_FILE PR_QUEUE_BODY_ROOT PR_QUEUE_GH FAKE_GH_LOG FAKE_AGENTS; do unset "$_v"; done
while IFS= read -r _l; do [[ -n $_l ]] && export "$_l"; done <<<"$_pq_saved"
[[ -z $_saved_pane ]] || export HERDR_PANE_ID=$_saved_pane

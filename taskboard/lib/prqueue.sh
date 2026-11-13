# shellcheck shell=bash
# PR 作成キュー(tb pr-queue)。bin/tb から source される。単体では実行しない。
#   add     agent が依頼(branch・本文ファイル・題)を置く                      → pending
#   approve 人が承認(本文が置いたときから変わっていないことも確かめる)          → approved
#   run     scheduler の COMMAND ジョブ。approved だけをガードに通し gh pr create --draft  → created / rejected / failed
# できないこと(実装しない): マージ・approve・ready・close・コメント。gh は create(--draft 固定)と pr list(重複確認)だけ。
# gh は PR_QUEUE_GH で差し替える(既定 gh)。書き込み用の認証は gh のラッパー(人が用意する)に持たせる。
# 環境ごとの決まりは config/pr-queue.conf(人だけが編集): branch_prefix(既定 agent/)・body_root(本文の置き場)・
# body_first_line(本文 1 行目が合うべき正規表現。空なら見ない。# は書けない)・auto_approve・max_create_per_run。
# 値は読まない・出さない: 秘密らしい値が見つかっても、出すのは種類の名前だけ。
PQ_BASE=main
PQ_MAX_BODY=102400
PQ_MAX_ATTEMPTS=3
PQ_MAX_CREATE=3   # 1 回の run で作る PR の上限(config/pr-queue.conf の max_create_per_run で変える)
PQ_REASON=""

pq_body_root() {
  local d=${PR_QUEUE_BODY_ROOT:-$(pq_conf body_root "$TB_ROOT/data/pr-bodies")}
  (cd "$d" 2>/dev/null && pwd -P) || return 1
}

# 許可リスト(config/repos.md。TB_REPOS_FILE)の "- <org>/<repo>   # 注釈" から <org>/<repo> を 1 行ずつ。注釈(# 以降)は落とす。
# (notify_repos は注釈つきの行を読めないので使わない。実物の repos.md は注釈つき)
pq_repos() {
  local line f=${NOTIFY_REPOS_FILE:-}
  [[ -f $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "$line"); [[ $line == -* ]] || continue
    line=$(trim "${line#-}"); line=$(trim "${line%%#*}")
    [[ $line =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] && printf '%s\n' "$line"
  done <"$f"
  return 0
}

pq_ref() {  # "PQ-12" か "12" → 数字
  local r=${1#PQ-}; [[ $r =~ ^[0-9]+$ ]] || usage "pr-queue: ID は PQ-<数字>: $1"; printf '%s' "$r"
}

pq_row() { sql -json "SELECT * FROM pr_queue WHERE id=$1;" | jq -c '.[0] // empty'; }

# ブランチの接頭辞(conf の branch_prefix。英数字と . _ - の後に / 。既定 agent/)
pq_prefix() {
  local p; p=$(pq_conf branch_prefix agent/)
  [[ $p =~ ^[A-Za-z0-9._-]{1,40}/$ ]] || p=agent/
  printf '%s' "$p"
}

pq_valid_branch() {  # 接頭辞で始まり、安全な文字だけ
  local b=$1 p; p=$(pq_prefix)
  [[ $b == "$p"* && ${b#"$p"} =~ ^[A-Za-z0-9._/-]{1,120}$ ]] || return 1
  [[ $b != *..* && $b != */ && $b != *.lock && $b != *//* ]] || return 1
}

pq_sha() { sha256 <"$1"; }

# 見つかった種類の名前だけを PQ_REASON に入れる(値は入れない)。$1=本文。見つかれば 0
pq_patterns_only() {
  local line name pat kinds="" h
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    name=${line%%|*}; pat=${line#*|}
    h=$(printf '%s' "$1" | grep -oEi -- "$pat" 2>/dev/null || true)
    [[ -z $h ]] || kinds+="${kinds:+, }$name"
  done <<<"$NOTIFY_SECRET_PATTERNS"
  PQ_REASON=$kinds
  [[ -n $kinds ]]
}

# 本文・題・差分のガード。通れば 0。落ちれば PQ_REASON に理由(値は含めない)を入れて 1
# $1=行(JSON)。base は PQ_BASE 固定(キューから受けない)
pq_guard() {
  local row=$1 repo branch title file sha now_sha first rest strip root dir abs re
  repo=$(jq -r .repo <<<"$row"); branch=$(jq -r .branch <<<"$row"); title=$(jq -r .title <<<"$row")
  file=$(jq -r .body_file <<<"$row"); sha=$(jq -r .body_sha256 <<<"$row")
  PQ_REASON=""
  pq_valid_branch "$branch" || { PQ_REASON="ブランチ名が $(pq_prefix) で始まる安全な形ではない"; return 1; }
  pq_repos | grep -qxF -- "$repo" || { PQ_REASON="リポジトリが許可リストに無い"; return 1; }
  root=$(pq_body_root) || { PQ_REASON="本文のルートが見つからない"; return 1; }
  [[ ! -L $file && -f $file ]] || { PQ_REASON="本文ファイルが無い(か、シンボリックリンク)"; return 1; }
  dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || { PQ_REASON="本文ファイルの場所が不正"; return 1; }
  abs=$dir/$(basename "$file")
  [[ $abs == "$root"/* ]] || { PQ_REASON="本文ファイルが許可された場所(body_root)の外"; return 1; }
  now_sha=$(pq_sha "$abs")
  [[ $now_sha == "$sha" ]] || { PQ_REASON="本文が、置かれたときから変わっている(承認のやり直しが要る)"; return 1; }
  first=$(head -n 1 "$abs" | tr -d '\r'); re=$(pq_conf body_first_line "")
  if [[ -n $re ]]; then
    [[ $first =~ $re ]] || { PQ_REASON="本文 1 行目が body_first_line の形ではない"; return 1; }
    # 1 行目(形を検査済み)は除き、残りと題を秘密の検査にかける
    rest=$(tail -n +2 "$abs")
  else
    rest=$(cat "$abs")
  fi
  strip="$title"$'\n'"$rest"
  if notify_secret_scan "$strip"; then PQ_REASON="本文か題に秘密らしい値がある(種類: $NOTIFY_HIT_KINDS)"; NOTIFY_HITS=""; return 1; fi
  pq_diff_guard "$branch" || return 1
  return 0
}

# PR_QUEUE_REPO_DIR(ローカルの clone)があるときだけ、差分を見る。clone を変更しない(読み取りだけ)
pq_diff_guard() {
  local b=$1 d=${PR_QUEUE_REPO_DIR:-} ref files added
  [[ -n $d ]] || return 0
  [[ -d $d ]] || { PQ_REASON="PR_QUEUE_REPO_DIR が見つからない"; return 1; }
  if git -C "$d" rev-parse -q --verify "refs/heads/$b^{commit}" >/dev/null 2>&1; then ref=refs/heads/$b
  elif git -C "$d" rev-parse -q --verify "refs/remotes/origin/$b^{commit}" >/dev/null 2>&1; then ref=refs/remotes/origin/$b
  else PQ_REASON="差分を取得できない(ブランチが clone に無い)"; return 1; fi
  git -C "$d" rev-parse -q --verify "refs/remotes/origin/$PQ_BASE^{commit}" >/dev/null 2>&1 \
    || { PQ_REASON="差分を取得できない(origin/$PQ_BASE が clone に無い)"; return 1; }
  files=$(git -C "$d" diff --name-only "origin/$PQ_BASE...$ref" 2>/dev/null) || { PQ_REASON="差分を取得できない"; return 1; }
  if grep -qE '^\.github/(workflows|actions)/' <<<"$files"; then PQ_REASON="CI 設定(.github/workflows)を含む。人が作る"; return 1; fi
  added=$(git -C "$d" diff -U0 "origin/$PQ_BASE...$ref" 2>/dev/null | grep -E '^\+[^+]' || true)
  if grep -qE 'AdministratorAccess' <<<"$added"; then PQ_REASON="AdministratorAccess を足す差分を含む。人が作る"; return 1; fi
  if pq_patterns_only "$added"; then PQ_REASON="差分に秘密らしい値がある(種類: $PQ_REASON)"; return 1; fi
  return 0
}

cmd_pr-queue() {
  local sub=${1:-}; shift || true
  case $sub in
    add) pq_add "$@";;
    list) pq_list "$@";;
    show) pq_show "$@";;
    approve) pq_approve "$@";;
    reject) pq_reject "$@";;
    run) pq_run "$@";;
    scan) pq_scan "$@";;
    *) usage "pr-queue add|list|show|approve|reject|run|scan";;
  esac
}

pq_add() {
  local branch="" file="" title="" repo="" task="" by id root dir abs n repos
  while [[ $# -gt 0 ]]; do
    case $1 in
      --branch) need_arg "$@"; branch=$2; shift 2;;
      --body-file) need_arg "$@"; file=$2; shift 2;;
      --title) need_arg "$@"; title=$2; shift 2;;
      --repo) need_arg "$@"; repo=$2; shift 2;;
      --task) need_arg "$@"; task=$2; shift 2;;
      *) usage "pr-queue add: 不明な引数 $1";;
    esac
  done
  [[ -n $branch && -n $file && -n $title ]] || usage "pr-queue add --branch <接頭辞/…> --body-file <body_root の中のファイル> --title <題> [--repo <org/repo>] [--task T-…]"
  pq_valid_branch "$branch" || die "pr-queue: ブランチは $(pq_prefix) で始め、英数字と . _ - / だけにします: $branch"
  [[ $title != *$'\n'* && $title != *$'\r'* ]] && ! blank "$title" && ((${#title} <= 200)) || die "pr-queue: 題は 1 行・200 字まで"
  [[ -z $task ]] || valid_id "$task"
  repos=$(pq_repos)
  [[ -n $repos ]] || die "pr-queue: 許可リスト(config/repos.md)が空です。人に聞いてください"
  if [[ -z $repo ]]; then
    n=$(grep -c . <<<"$repos"); ((n == 1)) || die "pr-queue: 許可リストが複数あります。--repo を付けてください"
    repo=$repos
  fi
  grep -qxF -- "$repo" <<<"$repos" || die "pr-queue: リポジトリが許可リストにありません: $repo"
  root=$(pq_body_root) || die "pr-queue: 本文のルート(body_root)が見つかりません"
  [[ ! -L $file && -f $file ]] || die "pr-queue: 本文ファイルが無い(かシンボリックリンク): $file"
  dir=$(cd "$(dirname "$file")" && pwd -P); abs=$dir/$(basename "$file")
  [[ $abs == "$root"/* ]] || die "pr-queue: 本文ファイルは body_root の中だけ: $file"
  (($(wc -c <"$abs") <= PQ_MAX_BODY)) || die "pr-queue: 本文が大きすぎます(100KB まで)"
  if [[ -n ${HERDR_PANE_ID:-} ]]; then by=$(pane_owner_name "$HERDR_PANE_ID" 2>/dev/null || true); by=${by:-unknown}; else by=human; fi
  id=$(sql "INSERT INTO pr_queue (repo,branch,title,body_file,body_sha256,task_id,requested_by,status,created_at)
    VALUES ($(q "$repo"),$(q "$branch"),$(q "$title"),$(q "$abs"),$(q "$(pq_sha "$abs")"),NULLIF($(q "$task"),''),$(q "$by"),'pending',$(q "$(now)")); SELECT last_insert_rowid();")
  echo "PQ-$id pending"
}

pq_list() {
  local status="" json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --status) need_arg "$@"; status=$2; shift 2;;
      --json) json=1; shift;;
      *) usage "pr-queue list [--status S] [--json]";;
    esac
  done
  [[ -z $status || $status =~ ^(pending|approved|rejected|created|failed)$ ]] || usage "pr-queue: status は pending|approved|rejected|created|failed"
  local where=""; [[ -z $status ]] || where="WHERE status=$(q "$status")"
  if ((json)); then sql -json "SELECT id,repo,branch,title,task_id,requested_by,status,last_error,attempts,pr_url,created_at FROM pr_queue $where ORDER BY id;" | jq -c '.[]?'
  else sql -separator $'\t' "SELECT 'PQ-'||id, status, branch, title FROM pr_queue $where ORDER BY id;"; fi
}

pq_show() {
  [[ $# -eq 1 ]] || usage "pr-queue show <PQ-n>"
  local id row; id=$(pq_ref "$1"); row=$(pq_row "$id"); [[ -n $row ]] || die "見つかりません: PQ-$id"
  jq -r '"PQ-\(.id) \(.status)\nrepo: \(.repo)\nbranch: \(.branch)  → base: main(draft)\ntitle: \(.title)\nbody: \(.body_file)\ntask: \(.task_id // "-")  依頼: \(.requested_by)\n試行: \(.attempts)  PR: \(.pr_url // "-")\n理由/エラー: \(.last_error // "-")"' <<<"$row"
}

pq_approve() {
  [[ $# -eq 1 ]] || usage "pr-queue approve <PQ-n>"
  require_human "tb pr-queue approve"
  local id row st; id=$(pq_ref "$1"); row=$(pq_row "$id"); [[ -n $row ]] || die "見つかりません: PQ-$id"
  st=$(jq -r .status <<<"$row"); [[ $st == pending ]] || die "PQ-$id は $st です(承認できるのは pending だけ)"
  if ! pq_guard "$row"; then die "PQ-$id はガードに落ちるため承認しません: $PQ_REASON"; fi
  sql "UPDATE pr_queue SET status='approved', decided_at=$(q "$(now)"), last_error=NULL WHERE id=$id AND status='pending';"
  echo "PQ-$id approved(次の tb pr-queue run で draft PR を作ります)"
}

pq_reject() {
  [[ $# -ge 1 ]] || usage "pr-queue reject <PQ-n> [-m 理由]"
  local id note="" st row; id=$(pq_ref "$1"); shift
  while [[ $# -gt 0 ]]; do case $1 in -m|--message) need_arg "$@"; note=$2; shift 2;; *) usage "pr-queue reject: 不明な引数 $1";; esac; done
  ((${#note} <= 300)) || usage "pr-queue reject: 理由は 300 字まで"
  require_human "tb pr-queue reject"
  row=$(pq_row "$id"); [[ -n $row ]] || die "見つかりません: PQ-$id"
  st=$(jq -r .status <<<"$row"); [[ $st == pending || $st == approved ]] || die "PQ-$id は $st です(却下できるのは pending / approved だけ)"
  sql "UPDATE pr_queue SET status='rejected', decided_at=$(q "$(now)"), last_error=$(q "人が却下${note:+: $note}") WHERE id=$id AND status IN ('pending','approved');"
  echo "PQ-$id rejected"
}

# scheduler の COMMAND から。approved だけを処理する。--dry-run は gh pr create も DB 更新もしない
pq_run() {
  local dry=0 gh=${PR_QUEUE_GH:-gh} id row repo branch title file out rc n url made=0 maxc
  case ${1:-} in "") ;; --dry-run) dry=1;; *) usage "pr-queue run [--dry-run]";; esac
  command -v "$gh" >/dev/null 2>&1 || { echo "pr-queue: gh が見つかりません($gh)" >&2; return 0; }
  maxc=$(pq_conf max_create_per_run "$PQ_MAX_CREATE"); [[ $maxc =~ ^[0-9]+$ ]] || maxc=$PQ_MAX_CREATE
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    if ((made >= maxc)); then echo "pr-queue: 1 回の上限($maxc 件)に達した。残りは次の回"; break; fi
    row=$(pq_row "$id"); [[ -n $row ]] || continue
    repo=$(jq -r .repo <<<"$row"); branch=$(jq -r .branch <<<"$row"); title=$(jq -r .title <<<"$row"); file=$(jq -r .body_file <<<"$row")
    if ! pq_guard "$row"; then
      echo "PQ-$id rejected: $PQ_REASON"
      ((dry)) || sql "UPDATE pr_queue SET status='rejected', last_error=$(q "ガード: $PQ_REASON"), executed_at=$(q "$(now)") WHERE id=$id AND status='approved';"
      continue
    fi
    # 重複確認(読み取り)。取れないときは作らない(次の回に回す)
    if ! out=$("$gh" pr list --repo "$repo" --head "$branch" --state open --json number 2>/dev/null) || ! jq -e 'type=="array"' <<<"$out" >/dev/null 2>&1; then
      echo "PQ-$id skipped: 重複確認の gh pr list に失敗(作らない)"
      ((dry)) || sql "UPDATE pr_queue SET attempts=attempts+1, last_error='重複確認に失敗' WHERE id=$id;"
      pq_cap_attempts "$id" "$dry"; continue
    fi
    n=$(jq 'length' <<<"$out")
    if ((n > 0)); then
      echo "PQ-$id rejected: 同じ head の open PR が既にある"
      ((dry)) || sql "UPDATE pr_queue SET status='rejected', last_error='同じ head の open PR が既にある', executed_at=$(q "$(now)") WHERE id=$id AND status='approved';"
      continue
    fi
    if ((dry)); then echo "PQ-$id would-create: $repo $branch → $PQ_BASE (draft)"; made=$((made+1)); continue; fi
    out=$("$gh" pr create --repo "$repo" --base "$PQ_BASE" --head "$branch" --title "$title" --body-file "$file" --draft 2>/dev/null) && rc=0 || rc=$?
    if ((rc == 0)); then
      url=$(grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' <<<"$out" | head -n 1 || true)
      sql "UPDATE pr_queue SET status='created', pr_url=NULLIF($(q "$url"),''), last_error=NULL, executed_at=$(q "$(now)") WHERE id=$id AND status='approved';"
      echo "PQ-$id created${url:+: $url}"; made=$((made+1))
    else
      sql "UPDATE pr_queue SET attempts=attempts+1, last_error=$(q "gh pr create が失敗(exit $rc)") WHERE id=$id;"
      echo "PQ-$id error: gh pr create が失敗(exit $rc)"
      pq_cap_attempts "$id" 0
    fi
  done < <(sql "SELECT id FROM pr_queue WHERE status='approved' ORDER BY id;")
  return 0
}

pq_cap_attempts() {  # $1=id $2=dry。上限を超えたら failed にして、人に見える形にする
  [[ $2 == 1 ]] && return 0
  sql "UPDATE pr_queue SET status='failed', executed_at=$(q "$(now)") WHERE id=$1 AND status='approved' AND attempts>=$PQ_MAX_ATTEMPTS;"
}

# config/pr-queue.conf(人だけが編集。無ければ既定)の "<キー>=<値>" を読む。$1=キー $2=既定
pq_conf() {
  local f=${PR_QUEUE_CONF:-$TB_ROOT/config/pr-queue.conf} v
  [[ -f $f ]] && v=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$f" | tail -n 1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*(#.*)?$//') || v=""
  printf '%s' "${v:-$2}"
}

# ブランチ走査(scheduler の COMMAND で run の前に呼ぶ)。origin の <branch_prefix>* のうち条件を満たすものをキューに積む。
# 積むのは (a) 同じ head の PR(open/closed/merged)が無い (b) <body_root>/pr-body-<名>.md がある (c) ガード(1 行目の形など)を通り、{{…}} が残っていない
# (d) 秘密らしい値が無い (e) 最新コミットの題が空でない。auto_approve=1(conf。既定 0)のときだけ approved で積む。それ以外は pending
# 読み取りだけ: git は fetch と ls-remote、gh は pr list だけ。PR_QUEUE_REPO_DIR(clone)が要る。PR_QUEUE_GIT で git を差し替える
pq_scan() {
  local dry=0 repo="" gh=${PR_QUEUE_GH:-gh} git=${PR_QUEUE_GIT:-git} d=${PR_QUEUE_REPO_DIR:-} repos n auto st root
  local b slug file title out cnt row sha by id
  while [[ $# -gt 0 ]]; do
    case $1 in --dry-run) dry=1; shift;; --repo) need_arg "$@"; repo=$2; shift 2;; *) usage "pr-queue scan [--dry-run] [--repo <org/repo>]";; esac
  done
  repos=$(pq_repos); [[ -n $repos ]] || { echo "pr-queue scan: 許可リスト(config/repos.md)が空" >&2; return 0; }
  if [[ -z $repo ]]; then n=$(grep -c . <<<"$repos"); ((n == 1)) || { echo "pr-queue scan: 許可リストが複数。--repo を付ける" >&2; return 0; }; repo=$repos; fi
  grep -qxF -- "$repo" <<<"$repos" || { echo "pr-queue scan: リポジトリが許可リストに無い" >&2; return 0; }
  [[ -n $d && -d $d ]] || { echo "pr-queue scan: PR_QUEUE_REPO_DIR(clone)が必要" >&2; return 0; }
  command -v "$gh" >/dev/null 2>&1 || { echo "pr-queue scan: gh が見つかりません($gh)" >&2; return 0; }
  root=$(pq_body_root) || { echo "pr-queue scan: 本文のルートが無い" >&2; return 0; }
  auto=$(pq_conf auto_approve 0); [[ $auto == 1 ]] && st=approved || st=pending
  local heads pfx; pfx=$(pq_prefix)
  heads=$("$git" -C "$d" ls-remote --heads origin "refs/heads/${pfx}*" 2>/dev/null | awk '{print $2}' | sed 's#^refs/heads/##') \
    || { echo "pr-queue scan: origin の一覧を取れない" >&2; return 0; }
  [[ -n $heads ]] || { echo "pr-queue scan: 対象ブランチなし"; return 0; }
  ((dry)) || "$git" -C "$d" fetch -q origin "+refs/heads/${pfx}*:refs/remotes/origin/${pfx}*" 2>/dev/null || true
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    pq_valid_branch "$b" || { echo "skip $b: ブランチ名が安全な形ではない"; continue; }
    cnt=$(sql "SELECT COUNT(*) FROM pr_queue WHERE repo=$(q "$repo") AND branch=$(q "$b");")
    if (($(sql "SELECT COUNT(*) FROM pr_queue WHERE repo=$(q "$repo") AND branch=$(q "$b") AND status<>'rejected';") > 0)); then echo "skip $b: 既にキューにある"; continue; fi
    if ((cnt >= PQ_MAX_ATTEMPTS)); then echo "skip $b: 同じブランチの試行が上限($PQ_MAX_ATTEMPTS)"; continue; fi
    slug=${b//\//-}; file=$root/pr-body-$slug.md
    [[ -f $file && ! -L $file ]] || { echo "skip $b: 本文(pr-body-$slug.md)が無い"; continue; }
    if grep -qE '\{\{[^}]*\}\}' "$file"; then echo "skip $b: 本文にプレースホルダ {{…}} が残っている"; continue; fi
    title=$("$git" -C "$d" log -1 --format=%s "refs/remotes/origin/$b" 2>/dev/null | head -n 1 | tr -d '\r') || title=""
    blank "$title" && { echo "skip $b: 最新コミットの題が空(か取得できない)"; continue; }
    ((${#title} <= 200)) || title=${title:0:200}
    sha=$(pq_sha "$file")
    row=$(jq -nc --arg r "$repo" --arg b "$b" --arg t "$title" --arg f "$file" --arg s "$sha" '{repo:$r,branch:$b,title:$t,body_file:$f,body_sha256:$s}')
    # 本文・題・(clone があれば)差分のガードは、承認前でも同じものを通す。落ちたものは積まない
    if ! pq_guard "$row"; then echo "skip $b: $PQ_REASON"; continue; fi
    # 重複確認: open / closed / merged のどれでも、同じ head の PR があれば積まない。取れなければ積まない
    if ! out=$("$gh" pr list --repo "$repo" --head "$b" --state all --json number 2>/dev/null) || ! jq -e 'type=="array"' <<<"$out" >/dev/null 2>&1; then
      echo "skip $b: 重複確認の gh pr list に失敗"; continue
    fi
    if (($(jq length <<<"$out") > 0)); then echo "skip $b: 同じ head の PR が既にある"; continue; fi
    if ((dry)); then echo "would-queue $b ($st): $title"; continue; fi
    by=scan
    id=$(sql "INSERT INTO pr_queue (repo,branch,title,body_file,body_sha256,requested_by,status,created_at,decided_at)
      VALUES ($(q "$repo"),$(q "$b"),$(q "$title"),$(q "$file"),$(q "$sha"),'scan',$(q "$st"),$(q "$(now)"),$([[ $st == approved ]] && q "$(now)" || echo NULL)); SELECT last_insert_rowid();")
    echo "PQ-$id $st: $b"
  done <<<"$heads"
  return 0
}

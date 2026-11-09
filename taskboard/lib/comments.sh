# shellcheck shell=bash
# worker → 指揮官の報告コメント(comment / comments)
# bin/tb から source される。単体では実行しない。

# ---------- comment / comments(worker → 指揮官の報告コメント) ----------
COMMENT_KINDS="done progress question blocked"
# すぐ送る kind。それ以外は保存だけして tb digest でまとめて送る
IMMEDIATE_KINDS=${TB_IMMEDIATE_KINDS:-question blocked}
LABEL_NAME=""; LABEL_PANE=""; LABEL_SESSION=""

# 報告者ラベルは herdr から引く(自己申告にしない)。引けなければ 1 を返す(理由は stderr)
resolve_label() {
  local pane=${HERDR_PANE_ID:-} out row
  [[ -n $pane ]] || { echo "tb: HERDR_PANE_ID がありません。報告者を特定できないため保存しません" >&2; return 1; }
  out=$(herdr_call agent list 2>/dev/null) || { echo "tb: herdr agent list に失敗。報告者を特定できないため保存しません" >&2; return 1; }
  row=$(jq -c --arg p "$pane" '[.result.agents[]? | select(.pane_id==$p)][0] // empty' <<<"$out" 2>/dev/null) || row=""
  [[ -n $row ]] || { echo "tb: pane $pane に該当する agent がありません。保存しません" >&2; return 1; }
  LABEL_NAME=$(jq -r '.name // ""' <<<"$row"); LABEL_SESSION=$(jq -r '.agent_session.value // ""' <<<"$row"); LABEL_PANE=$pane
  [[ -n $LABEL_NAME ]] || { echo "tb: pane $pane の agent に名前がありません(herdr agent rename)。保存しません" >&2; return 1; }
  [[ -n $LABEL_SESSION ]] || { echo "tb: pane $pane の agent に session がありません。保存しません" >&2; return 1; }
  [[ $LABEL_NAME =~ ^[A-Za-z0-9._-]{1,64}$ && $LABEL_PANE =~ ^[A-Za-z0-9._:-]{1,64}$ ]] \
    || { echo "tb: 報告者名/pane に使えない文字があります。保存しません" >&2; return 1; }
}

# 1 行化 + ラベル偽装の無効化 + 先頭 N 字
oneline() {  # $1=本文 $2=最大字数
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -d '\000-\010\013\014\016-\037' | tr -s ' ' \
    | jq -Rrs --argjson n "$2" 'gsub("\\[\\s*from\\s*[:：]";"(from:";"i") | gsub("^\\s+|\\s+$";"") | .[0:$n]'
}

deliver_comment() {  # $1=comments.id → 0 送信済み / 10 / 11
  local cid=$1 row delivered tid kind text name pane project target msg
  [[ $cid =~ ^[0-9]+$ ]] || usage "コメント ID は C-<数字>"
  row=$(sql -json "SELECT * FROM comments WHERE id=$cid;" | jq -c '.[0] // empty')
  [[ -n $row ]] || die "コメントが見つかりません: C-$cid"
  delivered=$(jq -r '.delivered_at // ""' <<<"$row")
  if [[ -n $delivered ]]; then echo "C-$cid は配送済みです($delivered)"; return 0; fi
  tid=$(jq -r .task_id <<<"$row"); kind=$(jq -r .kind <<<"$row"); text=$(jq -r .text <<<"$row")
  name=$(jq -r .from_name <<<"$row"); pane=$(jq -r .from_pane <<<"$row")
  project=$(sql "SELECT project FROM tasks WHERE id=$(q "$tid");"); target=$(target_for "$project")
  msg="[from: $name / $pane / $tid / $kind] $(oneline "$text" 200) (詳細: tb comments $tid)"
  herdr_send "$target" "$msg" "C-$cid" comment || return $?
  sql "UPDATE comments SET delivered_at=$(q "$(now)") WHERE id=$cid;"
  echo "C-$cid delivered to $target"
}

# 終了コード: 0 配送済み / 10 保存済み・宛先使用中で未配送 / 11 保存済み・送信失敗 / 3 報告者を特定できず未保存 / 2 使い方 / 1 その他
cmd_comment() {
  [[ $# -ge 1 ]] || usage "comment <task-id> --kind done|progress|question|blocked --text T [--deliverables a,b] [--json]"
  local tid=$1 kind="" text="" dels="" json=0; shift
  valid_id "$tid"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --kind) need_arg "$@"; kind=$2; shift 2;;
      --text) need_arg "$@"; text=$2; shift 2;;
      --deliverables) need_arg "$@"; dels=$2; shift 2;;
      --json) json=1; shift;;
      --from|--from-*|--name|--pane|--session) usage "comment: 報告者は herdr から自動で決まります。$1 は指定できません";;
      *) usage "comment: 不明な引数 $1";;
    esac
  done
  [[ " $COMMENT_KINDS " == *" $kind "* ]] || usage "comment: --kind は $COMMENT_KINDS のどれか"
  blank "$text" && usage "comment: --text が必要です"
  local darr="[]"
  if [[ -n $dels ]]; then
    darr=$(jq -nc --arg d "$dels" '$d | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  fi
  if [[ $kind == done && $darr == "[]" ]]; then usage "comment: done は --deliverables(成果物)が必須です"; fi
  require_task "$tid" >/dev/null
  resolve_label || return 3
  local cid rc=0
  cid=$(sql "INSERT INTO comments (task_id, kind, text, deliverables, from_name, from_pane, from_session, created_at)
    VALUES ($(q "$tid"), $(q "$kind"), $(q "$text"), $(q "$darr"), $(q "$LABEL_NAME"), $(q "$LABEL_PANE"), $(q "$LABEL_SESSION"), $(q "$(now)"));
    SELECT last_insert_rowid();")
  local state=queued
  if [[ " $IMMEDIATE_KINDS " == *" $kind "* ]]; then   # 人の判断待ちはすぐ送る。それ以外は tb digest でまとめて送る
    deliver_comment "$cid" >/dev/null || rc=$?   # 保存は済んでいる。配送の結果は終了コードで返す
    state=$([[ $rc == 0 ]] && echo delivered || echo saved-undelivered)
  fi
  if ((json)); then sql -json "SELECT * FROM comments WHERE id=$cid;" | jq -c '.[0] | .deliverables |= fromjson | .id = "C-\(.id)"'
  else echo "C-$cid $state"; fi
  return $rc
}

cmd_comments() {
  local tid="" kind="" und=0 json=0 where="1=1"
  if [[ ${1:-} == T-* ]]; then tid=$1; shift; valid_id "$tid"; fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --kind) need_arg "$@"; kind=$2; shift 2;;
      --undelivered) und=1; shift;;
      --json) json=1; shift;;
      *) usage "comments: 不明な引数 $1";;
    esac
  done
  [[ -z $tid ]] || where+=" AND task_id=$(q "$tid")"
  if [[ -n $kind ]]; then [[ " $COMMENT_KINDS " == *" $kind "* ]] || usage "comments: --kind は $COMMENT_KINDS"; where+=" AND kind=$(q "$kind")"; fi
  ((und)) && where+=" AND delivered_at IS NULL"
  if ((json)); then
    sql -json "SELECT * FROM comments WHERE $where ORDER BY id;" | jq -c '(. // [])[] | .deliverables |= fromjson | .id = "C-\(.id)"'
  else
    # needs_human: question/blocked は人の判断・承認待ち
    sql -separator $'\t' "SELECT 'C-'||id, kind, CASE WHEN kind IN ('question','blocked') THEN 'needs-human' ELSE '-' END,
      CASE WHEN delivered_at IS NULL THEN 'undelivered' ELSE 'delivered' END, task_id, from_name,
      replace(replace(text, char(10), ' '), char(9), ' ') FROM comments WHERE $where ORDER BY id;"
  fi
}

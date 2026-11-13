# shellcheck shell=bash
# タスクの登録・状態遷移・報告(add / list / show / claim / update / done / block / report / pending)
# bin/tb から source される。単体では実行しない。

# ---------- add ----------
cmd_add() {
  local project="" title="" parent="" owner="" session="" account=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--project) need_arg "$@"; project=$2; shift 2;;
      -t|--title)   need_arg "$@"; title=$2; shift 2;;
      --parent)     need_arg "$@"; parent=$2; shift 2;;
      --owner)      need_arg "$@"; owner=$2; shift 2;;
      --session)    need_arg "$@"; session=$2; shift 2;;
      --account)    need_arg "$@"; account=$2; shift 2;;
      *) usage "add: 不明な引数 $1";;
    esac
  done
  [[ -n $project ]] || usage "add: -p <project> が必要です"
  valid_project "$project"
  blank "$title" && usage "add: -t <title> が必要です"
  if [[ -n $parent ]]; then valid_id "$parent"; require_task "$parent" >/dev/null; fi
  local n=$(now) p; p=$(q "$project")
  # 採番と挿入を 1 文で行い、同時 add でも重複しないようにする
  sql "INSERT INTO tasks (id, project, title, owner_agent, session_id, account, parent_id, created_at, updated_at)
       SELECT 'T-'||$p||'-'||printf('%03d', COALESCE(MAX(CAST(substr(id, length($p)+4) AS INTEGER)),0)+1),
              $p, $(q "$title"), NULLIF($(q "$owner"),''), NULLIF($(q "$session"),''), NULLIF($(q "$account"),''),
              NULLIF($(q "$parent"),''), $(q "$n"), $(q "$n")
       FROM tasks WHERE project=$p;
       SELECT id FROM tasks WHERE rowid=last_insert_rowid();"
}

# ---------- list ----------
cmd_list() {
  local project="" status="" json=0 where="1=1"
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--project) need_arg "$@"; project=$2; shift 2;;
      -s|--status)  need_arg "$@"; status=$2; shift 2;;
      --json)       json=1; shift;;
      *) usage "list: 不明な引数 $1";;
    esac
  done
  [[ -z $project ]] || where+=" AND project=$(q "$project")"
  if [[ -n $status ]]; then valid_status "$status"; where+=" AND status=$(q "$status")"; fi
  if ((json)); then
    sql -json "SELECT * FROM tasks WHERE $where ORDER BY project, id;" | jq -c '(. // [])[] | .deliverables |= fromjson'
  else
    sql -separator $'\t' "SELECT id, status, COALESCE(owner_agent,'-'), replace(title, char(10), ' ') FROM tasks WHERE $where ORDER BY project, id;"
  fi
}

# ---------- show ----------
cmd_show() {
  [[ $# -eq 1 ]] || usage "show <id>"
  valid_id "$1"
  local row sid act=""
  row=$(require_task "$1"); sid=$(jq -r '.session_id // empty' <<<"$row")
  if [[ -n $sid ]]; then   # 担当 agent の最終活動(tasks.session_id と agent_activity.session_id を結ぶ)
    act=$(sql -json "$(act_select 10) WHERE session_id=$(q "$sid");" | jq -c '.[0] // null')
  fi
  jq --argjson a "${act:-null}" '.deliverables |= fromjson | .activity = $a' <<<"$row"
}

# ---------- claim ----------
cmd_claim() {
  [[ $# -ge 1 ]] || usage "claim <id> --owner <name> [--session <sid>] [--account <acct>]"
  local id=$1 owner="" session="" account=""; shift
  valid_id "$id"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --owner)   need_arg "$@"; owner=$2; shift 2;;
      --session) need_arg "$@"; session=$2; shift 2;;
      --account) need_arg "$@"; account=$2; shift 2;;
      *) usage "claim: 不明な引数 $1";;
    esac
  done
  blank "$owner" && usage "claim: --owner が必要です"
  require_task "$id" >/dev/null
  local changed
  changed=$(sql "UPDATE tasks SET status='in_progress', owner_agent=$(q "$owner"),
      session_id=COALESCE(NULLIF($(q "$session"),''), session_id),
      account=COALESCE(NULLIF($(q "$account"),''), account), updated_at=$(q "$(now)")
    WHERE id=$(q "$id") AND status='todo'; SELECT changes();")
  [[ $changed == 1 ]] || die "claim できません(status が todo ではない): $id"
  echo "$id claimed by $owner"
}

# ---------- update ----------
cmd_update() {
  [[ $# -ge 1 ]] || usage "update <id> [--status S] [--title T] [--owner N] [--session S] [--account A] [--parent ID]"
  local id=$1; shift
  valid_id "$id"
  local sets=() row cur
  while [[ $# -gt 0 ]]; do
    case $1 in
      --status)  need_arg "$@"; valid_status "$2"
                 [[ $2 != done ]] || usage "update: done にするには tb done を使う(deliverables と要約が必須)"
                 sets+=("status=$(q "$2")"); shift 2;;
      --title)   need_arg "$@"; blank "$2" && usage "update: title が空です"; sets+=("title=$(q "$2")"); shift 2;;
      --owner)   need_arg "$@"; sets+=("owner_agent=NULLIF($(q "$2"),'')"); shift 2;;
      --session) need_arg "$@"; sets+=("session_id=NULLIF($(q "$2"),'')"); shift 2;;
      --account) need_arg "$@"; sets+=("account=NULLIF($(q "$2"),'')"); shift 2;;
      --parent)  need_arg "$@"; valid_id "$2"; require_task "$2" >/dev/null
                 [[ $2 != "$id" ]] || usage "update: 自分自身を parent にできません"
                 sets+=("parent_id=$(q "$2")"); shift 2;;
      *) usage "update: 不明な引数 $1";;
    esac
  done
  [[ ${#sets[@]} -gt 0 ]] || usage "update: 変更する項目がありません"
  row=$(require_task "$id"); cur=$(jq -r .status <<<"$row")
  [[ $cur != done ]] || die "done のタスクは update できません: $id"
  local IFS=,
  sql "UPDATE tasks SET ${sets[*]}, updated_at=$(q "$(now)") WHERE id=$(q "$id");"
  echo "$id updated"
}

# ---------- done ----------
cmd_done() {
  [[ $# -ge 1 ]] || usage "done <id> -d <成果物パス> [-d ...] -m <要約>"
  local id=$1 summary="" dels=(); shift
  valid_id "$id"
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--deliverable) need_arg "$@"; blank "$2" || dels+=("$2"); shift 2;;
      -m|--summary)     need_arg "$@"; summary=$2; shift 2;;
      *) usage "done: 不明な引数 $1";;
    esac
  done
  [[ ${#dels[@]} -gt 0 ]] || usage "done: 成果物(-d)が必須です"
  blank "$summary" && usage "done: 要約(-m)が必須です"
  local row cur dj
  row=$(require_task "$id"); cur=$(jq -r .status <<<"$row")
  [[ $cur != done ]] || die "すでに done です: $id"
  dj=$(jq -nc '$ARGS.positional' --args "${dels[@]}")
  sql "UPDATE tasks SET status='done', deliverables=$(q "$dj"), summary=$(q "$summary"),
         reported_at=NULL, updated_at=$(q "$(now)") WHERE id=$(q "$id");"
  notify_hook notify_hook_task_done "$id"
  echo "$id done (未報告。tb report $id を実行)"
}

# ---------- block ----------
cmd_block() {
  [[ $# -ge 1 ]] || usage "block <id> [-m <理由>]"
  local id=$1 reason=""; shift
  valid_id "$id"
  while [[ $# -gt 0 ]]; do
    case $1 in
      -m|--message) need_arg "$@"; reason=$2; shift 2;;
      *) usage "block: 不明な引数 $1";;
    esac
  done
  local row cur; row=$(require_task "$id"); cur=$(jq -r .status <<<"$row")
  [[ $cur != done ]] || die "done のタスクは block できません: $id"
  sql "UPDATE tasks SET status='blocked', note=NULLIF($(q "$reason"),''), updated_at=$(q "$(now)") WHERE id=$(q "$id");"
  echo "$id blocked"
}

# ---------- report ----------
cmd_report() {
  [[ $# -eq 1 ]] || usage "report <id>"
  if [[ $1 =~ ^C-[0-9]+$ ]]; then deliver_comment "${1#C-}"; return $?; fi   # 未配送コメントの再送
  local id=$1; valid_id "$id"
  local row status project summary paths reported target msg
  row=$(require_task "$id")
  status=$(jq -r .status <<<"$row"); project=$(jq -r .project <<<"$row")
  summary=$(jq -r '.summary // ""' <<<"$row"); reported=$(jq -r '.reported_at // ""' <<<"$row")
  paths=$(jq -r '.deliverables | fromjson | join(", ")' <<<"$row")
  [[ $status == done ]] || die "done ではないタスクは report できません($status): $id"
  if [[ -n $reported ]]; then echo "$id は報告済みです($reported)"; return 0; fi

  target=$(target_for "$project")
  # prompt は 1 行にする(改行が入ると途中で submit されうる)
  summary=$(printf '%s' "$summary" | tr '\r\n\t' '   ' | tr -s ' ')
  summary=${summary%"${summary##*[![:space:]]}"}
  msg="[$id done] $summary / $paths"
  herdr_send "$target" "$msg" "$id" || return $?
  sql "UPDATE tasks SET reported_at=$(q "$(now)"), updated_at=$(q "$(now)") WHERE id=$(q "$id");"
  echo "$id reported to $target"
}

# ---------- pending ----------
cmd_pending() {
  local mode=tsv
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) mode=json; shift;;
      --ids)  mode=ids; shift;;
      *) usage "pending: 不明な引数 $1";;
    esac
  done
  local where="status='done' AND (reported_at IS NULL OR reported_at='')"
  case $mode in
    ids)  sql "SELECT id FROM tasks WHERE $where ORDER BY updated_at, id;"
          sql "SELECT 'C-'||id FROM comments WHERE delivered_at IS NULL ORDER BY id;";;
    json) sql -json "SELECT * FROM tasks WHERE $where ORDER BY updated_at, id;" | jq -c '(. // [])[] | .deliverables |= fromjson'
          sql -json "SELECT * FROM comments WHERE delivered_at IS NULL ORDER BY id;" | jq -c '(. // [])[] | .deliverables |= fromjson | .id = "C-\(.id)"';;
    tsv)  local id project summary
          while IFS=$'\t' read -r id project summary; do
            printf '%s\t%s\t%s\t%s\n' "$id" "$project" "$(target_for "$project")" "$summary"
          done < <(sql -separator $'\t' "SELECT id, project, replace(replace(COALESCE(summary,''), char(10), ' '), char(9), ' ') FROM tasks WHERE $where ORDER BY updated_at, id;")
          # 未配送のコメント: ID は C-<n>(tb report C-<n> で再送)
          while IFS=$'\t' read -r id project summary; do
            printf '%s\t%s\t%s\t%s\n' "$id" "$project" "$(target_for "$project")" "$summary"
          done < <(sql -separator $'\t' "SELECT 'C-'||c.id, COALESCE(t.project,''), '['||c.kind||'] '||substr(replace(replace(c.text, char(10), ' '), char(9), ' '),1,80)
            FROM comments c LEFT JOIN tasks t ON t.id=c.task_id WHERE c.delivered_at IS NULL ORDER BY c.id;");;
  esac
}

# shellcheck shell=bash
# 絞る候補の一覧(agent-shed)。読み取り専用: 何も止めない。止めるのは人が tb agent-stop を実行する
# bin/tb から source される。単体では実行しない。
#
# 候補の順(止めても失うものが少ない順):
#   1. done-idle  : 完了報告済み(done のタスクがあり、未完了のタスクが無い)で、herdr の状態が idle / done の役
#   2. killable   : 判定役が止めてよい(killable=yes)とし、その後に新しい入力が無く(stale でなく)、未完了のタスクが無い agent
#   3. analyst    : 結果を返した(または起動待ちでない)解析役
#      orphan     : 親のタスクが done、または親が動いていない子 agent
# 指揮官は候補に入れない。止めてよいと判定されていないものの agent-stop には --force(人だけ)が付く

shed_has() { [[ " $SHED_SEEN " == *" $1 "* ]]; }

shed_add() {  # $1=グループ $2=名前
  shed_has "$2" && return 0
  SHED_SEEN+=" $2"
  local k open cmd="tb agent-stop $2"
  k=$(killable_of "$2")
  open=$(sql "SELECT COUNT(*) FROM tasks WHERE owner_agent=$(q "$2") AND status IN ($OPEN_TASK_STATUSES);")
  [[ $k == yes && $open == 0 ]] || cmd+=" --force"
  SHED_OUT+="$1"$'\t'"$2"$'\t'"killable=$k"$'\t'"$cmd"$'\n'
}

cmd_agent-shed() {
  local json=0 count=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --count) need_arg "$@"; [[ $2 =~ ^[0-9]+$ ]] || usage "agent-shed: --count は 0 以上の整数"; count=$2; shift 2;;
      *) usage "agent-shed: 不明な引数 $1";;
    esac
  done
  agent_sync || echo "tb: herdr agent list に失敗しました(台帳の内容だけで選びます)" >&2
  SHED_SEEN=""; SHED_OUT=""
  local name st conductors; conductors=" $(conductor_names | tr '\n' ' ')"
  # 1. 完了報告済みで待機中
  while IFS= read -r name; do
    [[ -n $name && $conductors != *" $name "* ]] || continue
    st=$(jq -r --arg n "$name" '[.[] | select(.name==$n)][0].agent_status // ""' <<<"$LIVE_AGENTS")
    [[ $st == idle || $st == done ]] || continue
    shed_add done-idle "$name"
  done < <(sql "SELECT a.name FROM agents a WHERE a.state='running' AND a.herdr_session=$(q "$HSESS")
      AND EXISTS (SELECT 1 FROM tasks t WHERE t.owner_agent=a.name AND t.status='done')
      AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.owner_agent=a.name AND t.status IN ($OPEN_TASK_STATUSES)) ORDER BY a.name;")
  # 2. 止めてよいと判定されている(stale でない)
  while IFS= read -r name; do
    [[ -n $name && $conductors != *" $name "* ]] || continue
    [[ $(killable_of "$name") == yes ]] || continue
    [[ -z $(sql "SELECT 1 FROM tasks WHERE owner_agent=$(q "$name") AND status IN ($OPEN_TASK_STATUSES) LIMIT 1;") ]] || continue
    shed_add killable "$name"
  done < <(sql "SELECT name FROM agents WHERE state='running' AND herdr_session=$(q "$HSESS") AND killable='yes' ORDER BY name;")
  # 3. 解析役(解析中のものは除く)と、親が終わった子
  local aid
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    aid=${name#analyst-A}
    if [[ $aid =~ ^[0-9]+$ && $(sql "SELECT status FROM alerts WHERE id=$aid;") == analyzing ]]; then continue; fi
    shed_add analyst "$name"
  done < <(sql "SELECT name FROM agents WHERE state='running' AND herdr_session=$(q "$HSESS") AND name LIKE 'analyst-%' ORDER BY name;")
  while IFS= read -r name; do
    [[ -n $name ]] && shed_add orphan "$name"
  done < <(sql "SELECT a.name FROM agents a WHERE a.state='running' AND a.herdr_session=$(q "$HSESS") AND a.spawned_by IS NOT NULL
      AND (COALESCE((SELECT p.state FROM agents p WHERE p.name=a.spawned_by),'stopped')!='running'
           OR EXISTS (SELECT 1 FROM tasks t WHERE t.id=a.spawn_task AND t.status='done')) ORDER BY a.name;")
  local out=$SHED_OUT
  ((count == 0)) || out=$(printf '%s' "$SHED_OUT" | head -n "$count")
  [[ -n $out ]] || return 0
  if ((json)); then
    printf '%s\n' "$out" | jq -Rc 'select(length>0) | split("\t") | {group:.[0], name:.[1], killable:(.[2]|sub("killable=";"")), command:.[3]}'
  else
    printf '%s\n' "$out" | awk -F'\t' 'NF>=4 {printf "%-10s %-24s %-14s %s\n", $1, $2, $3, $4}'
  fi
}

# shellcheck shell=bash
# まとめ送信(digest / digests)
# bin/tb から source される。単体では実行しない。

# ---------- digest(worker → 指揮官のまとめ送信。scheduler から 10 分おきに呼ぶ想定) ----------
# 未配送の報告・未報告の done・tb が観測した事象を、指揮官ごとに 1 通にまとめて送る。
# 観測は worker の自己申告に頼らない: turn が終わったのに in_progress のまま / 長時間 working / blocked(承認待ち)
DIGEST_IDLE_MIN=${TB_DIGEST_IDLE_MIN:-10}
DIGEST_STUCK_MIN=${TB_DIGEST_STUCK_MIN:-30}
DIGEST_ITEM_MAX=${TB_DIGEST_ITEM_MAX:-160}
DIGEST_MSG_MAX=${TB_DIGEST_MSG_MAX:-1800}
DIGEST_QUEUED_SEC=${TB_DIGEST_QUEUED_SEC:-300}   # outbox が queued のまま何秒たったら観測として載せるか

# 項目の本文: 1 行化(oneline)に加え、項目の区切り(|)と角かっこラベルを無効化する
item_text() { oneline "$1" "$2" | tr '[]|' '()/'; }

DIGEST_ITEMS=""
add_item() {  # $1=target $2=type(comment|task|obs) $3=ref $4=key $5=task_id $6=obs_kind $7=label $8=本文
  DIGEST_ITEMS+=$(jq -nc --arg target "$1" --arg type "$2" --arg ref "$3" --arg key "$4" --arg task "$5" \
    --arg okind "$6" --arg short "[$7] $(item_text "$8" "$DIGEST_ITEM_MAX")" --arg full "[$7] $(item_text "$8" 2000)" \
    '{target:$target,type:$type,ref:$ref,key:$key,task:$task,okind:$okind,short:$short,full:$full}')$'\n'
}
obs_seen() { [[ -n $(sql "SELECT 1 FROM observations WHERE key=$(q "$1");") ]]; }

collect_digest() {
  local r tid kind from text dels project id owner summary key m pane sess name list task sby
  # 1. 未配送の報告コメント(kind を問わない。即時送信に失敗したものもここで回収)
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    id=$(jq -r .id <<<"$r"); tid=$(jq -r .task_id <<<"$r"); kind=$(jq -r .kind <<<"$r")
    from=$(jq -r .from_name <<<"$r"); text=$(jq -r .text <<<"$r"); project=$(jq -r '.project // ""' <<<"$r")
    dels=$(jq -r '.deliverables | fromjson | join(", ")' <<<"$r")
    [[ -n $dels ]] && text+=" / 成果物: $dels"
    sby=$(jq -r '.spawned_by // ""' <<<"$r"); [[ -z $sby ]] || from+=" (spawned_by: $sby)"
    add_item "$(target_for "$project")" comment "C-$id" "" "$tid" "" "$tid $kind / $from" "$text"
  done < <(sql -json "SELECT c.*, t.project, ag.spawned_by FROM comments c LEFT JOIN tasks t ON t.id=c.task_id
             LEFT JOIN agents ag ON ag.name=c.from_name
             WHERE c.delivered_at IS NULL ORDER BY c.id;" | jq -c '(. // [])[]')
  # 2. done なのに未報告のタスク
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    id=$(jq -r .id <<<"$r"); project=$(jq -r .project <<<"$r"); owner=$(jq -r '.owner_agent // "-"' <<<"$r")
    summary=$(jq -r '.summary // ""' <<<"$r"); dels=$(jq -r '.deliverables | fromjson | join(", ")' <<<"$r")
    add_item "$(target_for "$project")" task "$id" "" "$id" "" "$id done / $owner" "$summary / 成果物: $dels"
  done < <(sql -json "SELECT * FROM tasks WHERE status='done' AND (reported_at IS NULL OR reported_at='') ORDER BY updated_at, id;" | jq -c '(. // [])[]')
  # 2b. アラート: 新しく登録されたもの(まだまとめに入れていない)と、届いていない解析結果
  while IFS=$'\t' read -r id st title; do
    [[ -n $id ]] || continue
    key="alert:$id"; obs_seen "$key" && continue
    add_item "$DEFAULT_TARGET" obs "A-$id" "$key" "" alert "A-$id アラート / $st" "$title (tb alerts A-$id)"
  done < <(sql -separator $'\t' "SELECT id, status, replace(replace(title, char(10), ' '), char(9), ' ') FROM alerts WHERE status NOT IN ('closed') ORDER BY id;")
  while IFS=$'\t' read -r id sev title summary; do
    [[ -n $id ]] || continue
    add_item "$DEFAULT_TARGET" alert "A-$id" "" "" "" "A-$id 解析結果 / $sev" "$title — $summary (全文: tb alerts A-$id)"
  done < <(sql -separator $'\t' "SELECT id, severity, replace(replace(title, char(10), ' '), char(9), ' '), replace(replace(result_summary, char(10), ' '), char(9), ' ')
             FROM alerts WHERE status='analyzed' AND result_delivered_at IS NULL ORDER BY id;")
  # 3. 観測: turn が終わって DIGEST_IDLE_MIN 分たつのに in_progress のまま(done も報告もない)
  while IFS=$'\t' read -r id project owner key m; do
    [[ -n $id ]] || continue
    obs_seen "$key" && continue
    add_item "$(target_for "$project")" obs "$id" "$key" "$id" idle "$id 観測 / $owner" \
      "turn が終わって $m 分たつが、タスクは in_progress のまま(done・報告なし)"
  done < <(sql -separator $'\t' "SELECT t.id, t.project, COALESCE(t.owner_agent,'-'), 'idle:'||t.id||':'||a.last_stop_at,
             CAST((julianday('now') - julianday(a.last_stop_at)) * 1440 AS INTEGER)
             FROM tasks t JOIN agent_activity a ON a.session_id=t.session_id
             WHERE t.status='in_progress' AND a.last_stop_at IS NOT NULL
               AND (a.last_prompt_at IS NULL OR a.last_prompt_at <= a.last_stop_at)
               AND (julianday('now') - julianday(a.last_stop_at)) * 1440 >= $DIGEST_IDLE_MIN ORDER BY t.id;")
  # 4. 観測: DIGEST_STUCK_MIN 分以上 working のまま
  while IFS=$'\t' read -r id project owner key m; do
    [[ -n $id ]] || continue
    obs_seen "$key" && continue
    add_item "$(target_for "$project")" obs "$id" "$key" "$id" stuck "$id 観測 / $owner" \
      "$m 分 working のまま(長い作業か停止かは区別できない)"
  done < <(sql -separator $'\t' "SELECT t.id, t.project, COALESCE(t.owner_agent,'-'), 'stuck:'||a.session_id||':'||a.last_prompt_at,
             CAST((julianday('now') - julianday(a.last_prompt_at)) * 1440 AS INTEGER)
             FROM tasks t JOIN agent_activity a ON a.session_id=t.session_id
             WHERE t.status IN ('in_progress','review','blocked') AND a.last_prompt_at IS NOT NULL
               AND (a.last_stop_at IS NULL OR a.last_prompt_at > a.last_stop_at)
               AND (julianday('now') - julianday(a.last_prompt_at)) * 1440 >= $DIGEST_STUCK_MIN ORDER BY t.id;")
  # 4b. 観測: outbox が DIGEST_QUEUED_SEC 秒以上 queued のまま(宛先に届いていない)。queued が無ければ何も出さない
  while IFS=$'\t' read -r id owner key m; do
    [[ -n $id ]] || continue
    obs_seen "$key" && continue
    add_item "$DEFAULT_TARGET" obs "O-$id" "$key" "" queued "O-$id 観測 / $owner" \
      "O-$id が $m 分 queued のまま(宛先に届いていない。tb outbox --status queued で確認、tb flush で再送)"
  done < <(sql -separator $'\t' "SELECT id, target, 'queued:'||id, CAST((julianday('now') - julianday(created_at)) * 1440 AS INTEGER)
             FROM outbox WHERE status='queued' AND (julianday('now') - julianday(created_at)) * 86400 >= $DIGEST_QUEUED_SEC ORDER BY id;")
  # 5. 観測: herdr 上で blocked(承認ダイアログ待ちなど)の agent。担当タスクがあるものだけ
  if list=$(herdr_call agent list 2>/dev/null) && jq -e '.result.agents' <<<"$list" >/dev/null 2>&1; then
    local current=""
    while IFS=$'\x1f' read -r pane name sess; do
      [[ -n $pane ]] || continue
      key="blocked:$pane:$sess"; current+="$(q "$key"),"
      obs_seen "$key" && continue
      task=$(sql -separator $'\t' "SELECT id, project FROM tasks WHERE status!='done'
               AND ((session_id IS NOT NULL AND session_id=$(q "$sess")) OR (owner_agent IS NOT NULL AND owner_agent=$(q "$name")))
               ORDER BY updated_at DESC LIMIT 1;")
      [[ -n $task ]] || continue
      id=${task%%$'\t'*}; project=${task#*$'\t'}
      add_item "$(target_for "$project")" obs "$id" "$key" "$id" blocked "$id 観測 / ${name:-$pane}" \
        "blocked のまま(承認ダイアログ待ちの可能性。herdr agent attach ${name:-$pane} で確認)"
    done < <(jq -r '.result.agents[] | select(.agent_status=="blocked") | [.pane_id, (.name // ""), (.agent_session.value // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$list")
    # blocked でなくなった agent の記録は消す(再び blocked になったら、また送る)
    sql "DELETE FROM observations WHERE kind='blocked' AND key NOT IN (${current}'');"
  fi
  collect_spawn_obs
}

# 6. 観測: tb agent-spawn の子。何も無ければ(子が動いていなければ)何も出さない
#    - 子の数が上限の 1 つ手前以上(全体、または 1 体の親)
#    - 親のタスクが done / blocked になったのに、子がまだ動いている
collect_spawn_obs() {
  [[ -n $(sql "SELECT 1 FROM agents WHERE spawned_by IS NOT NULL AND state='running' AND herdr_session=$(q "$HSESS") LIMIT 1;") ]] || { sql "DELETE FROM observations WHERE kind IN ('spawnlimit','spawnorphan');"; return 0; }
  agent_sync 2>/dev/null || true
  load_spawn_policy
  local current="" id parent n key project task st
  n=$(sql "SELECT COUNT(*) FROM agents WHERE spawned_by IS NOT NULL AND state='running' AND herdr_session=$(q "$HSESS");")
  if ((SP_TOTAL > 0 && n >= SP_TOTAL - 1)); then
    key="spawnlimit:total:$n"; current+="$(q "$key"),"
    obs_seen "$key" || add_item "$DEFAULT_TARGET" obs "spawn" "$key" "" spawnlimit "spawn 観測 / 全体" \
      "子 agent が $n 体動いている(上限 ${SP_TOTAL}。tb agents で確認、止めるのは tb agent-stop)"
  fi
  while IFS=$'\t' read -r parent n; do
    [[ -n $parent ]] || continue
    ((SP_PER > 0 && n >= SP_PER - 1)) || continue
    key="spawnlimit:$parent:$n"; current+="$(q "$key"),"
    obs_seen "$key" || add_item "$DEFAULT_TARGET" obs "spawn" "$key" "" spawnlimit "spawn 観測 / $parent" \
      "$parent の子が $n 体動いている(1 体の親あたりの上限 $SP_PER)"
  done < <(sql -separator $'\t' "SELECT spawned_by, COUNT(*) FROM agents WHERE spawned_by IS NOT NULL AND state='running' AND herdr_session=$(q "$HSESS") GROUP BY spawned_by ORDER BY spawned_by;")
  while IFS=$'\t' read -r id parent task st project; do
    [[ -n $id ]] || continue
    key="spawnorphan:$id:$task:$st"; current+="$(q "$key"),"
    obs_seen "$key" && continue
    add_item "$(target_for "$project")" obs "$task" "$key" "$task" spawnorphan "$task 観測 / $parent" \
      "親のタスクが $st になったが、子 $id はまだ動いている(止めるなら tb agent-stop $id)"
  done < <(sql -separator $'\t' "SELECT a.name, a.spawned_by, a.spawn_task, t.status, t.project FROM agents a JOIN tasks t ON t.id=a.spawn_task
             WHERE a.spawned_by IS NOT NULL AND a.state='running' AND a.herdr_session=$(q "$HSESS") AND t.status IN ('done','blocked') ORDER BY a.name;")
  # 条件が外れたものは記録を消す(再び当てはまったら、また送る)
  sql "DELETE FROM observations WHERE kind IN ('spawnlimit','spawnorphan') AND key NOT IN (${current}'');"
}

# 1 通分の本文を組み立てる。長さの上限に収まる項目だけを入れ、残りは次回に回す
# stdout: 1 行目=入れた項目数、2 行目=送る本文(1 行)
build_digest() {  # $1=target の項目(JSON 行) $2=digest ID
  local items=$1 did=$2 total n=0 body tail line acc=""   # 80 = 見出し・「残り N 件」の分
  total=$(grep -c . <<<"$items")
  while IFS= read -r line; do
    local s; s=$(jq -r .short <<<"$line")
    tail=" (全文: tb digests D-$did)"
    local cand="${acc:+$acc | }($((n+1))) $s"
    if (( n > 0 && ${#cand} + ${#tail} + 80 > DIGEST_MSG_MAX )); then break; fi
    acc=$cand; n=$((n+1))
  done <<<"$items"
  body="[digest D-$did / $n 件 / $(now)] $acc"
  (( n < total )) && body+=" (残り $((total-n)) 件は次回)"
  body+=" (全文: tb digests D-$did)"
  printf '%s\n%s\n' "$n" "$body"
}

cmd_digest() {
  local dry=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) dry=1; shift;;
      *) usage "digest: 不明な引数 $1";;
    esac
  done
  [[ $DIGEST_IDLE_MIN =~ ^[0-9]+$ && $DIGEST_STUCK_MIN =~ ^[0-9]+$ && $DIGEST_QUEUED_SEC =~ ^[0-9]+$ ]] || usage "TB_DIGEST_IDLE_MIN / TB_DIGEST_STUCK_MIN / TB_DIGEST_QUEUED_SEC は数字"
  ((dry)) || cmd_flush >/dev/null 2>&1 || true   # 積まれた下りの送信も届ける(結果は outbox / messages に残る)
  ((dry)) || cmd_alert-dispatch >/dev/null 2>&1 || true   # 承認・上限待ちのアラートを進める
  if ! ((dry)); then   # 設定役に届いていない提案を再送
    local _p; while read -r _p; do [[ -n $_p ]] && { proposal_deliver "$_p" >/dev/null 2>&1 || true; }; done \
      < <(sql "SELECT id FROM proposals WHERE delivered_at IS NULL AND status='open' ORDER BY id;")
  fi
  DIGEST_ITEMS=""
  collect_digest
  [[ -n $DIGEST_ITEMS ]] || { echo "digest: 送るものはありません"; return 0; }
  local rc=0 target items did out n body full sel
  while IFS= read -r target; do
    items=$(jq -c --arg t "$target" 'select(.target==$t)' <<<"$DIGEST_ITEMS")
    if ((dry)); then
      out=$(build_digest "$items" "?"); printf '%s\t%s\n' "$target" "$(sed -n 2p <<<"$out")"; continue
    fi
    did=$(sql "INSERT INTO digests (target, item_count, body, created_at) VALUES ($(q "$target"), 0, '', $(q "$(now)")); SELECT last_insert_rowid();")
    out=$(build_digest "$items" "$did"); n=$(sed -n 1p <<<"$out"); body=$(sed -n 2p <<<"$out")
    sel=$(head -n "$n" <<<"$items")
    if herdr_send "$target" "$body" "D-$did" digest; then
      full=$(jq -r .full <<<"$sel")
      sql "UPDATE digests SET item_count=$n, body=$(q "$full") WHERE id=$did;"
      local ts; ts=$(now)
      while IFS= read -r r; do
        local type ref; type=$(jq -r .type <<<"$r"); ref=$(jq -r .ref <<<"$r")
        case $type in
          comment) sql "UPDATE comments SET delivered_at=$(q "$ts") WHERE id=${ref#C-} AND delivered_at IS NULL;";;
          task)    sql "UPDATE tasks SET reported_at=$(q "$ts"), updated_at=$(q "$ts") WHERE id=$(q "$ref") AND reported_at IS NULL;";;
          alert)   sql "UPDATE alerts SET result_delivered_at=$(q "$ts") WHERE id=${ref#A-} AND result_delivered_at IS NULL;";;
          obs)     sql "INSERT OR IGNORE INTO observations (key, kind, task_id, text, digest_id, created_at)
                        VALUES ($(q "$(jq -r .key <<<"$r")"), $(q "$(jq -r .okind <<<"$r")"), $(q "$ref"), $(q "$(jq -r .full <<<"$r")"), $did, $(q "$ts"));";;
        esac
      done <<<"$sel"
      echo "D-$did sent to $target ($n 件)"
    else
      local e=$?
      sql "DELETE FROM digests WHERE id=$did;"   # 送れなかった回は残さない(messages には残る)。項目は次回に持ち越す
      (( e > rc )) && rc=$e
    fi
  done < <(jq -r .target <<<"$DIGEST_ITEMS" | awk '!seen[$0]++')
  return $rc
}

cmd_digests() {
  local did="" json=0
  if [[ ${1:-} == D-* ]]; then did=${1#D-}; shift; [[ $did =~ ^[0-9]+$ ]] || usage "digest ID は D-<数字>"; fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      *) usage "digests: 不明な引数 $1";;
    esac
  done
  if [[ -n $did ]]; then
    local row; row=$(sql -json "SELECT * FROM digests WHERE id=$did;" | jq -c '.[0] // empty')
    [[ -n $row ]] || die "digest が見つかりません: D-$did"
    if ((json)); then jq -c '.id = "D-\(.id)"' <<<"$row"; else jq -r '"D-\(.id) → \(.target) (\(.item_count) 件, \(.created_at))\n\(.body)"' <<<"$row"; fi
  elif ((json)); then
    sql -json "SELECT * FROM digests ORDER BY id DESC LIMIT 50;" | jq -c '(. // [])[] | .id = "D-\(.id)"'
  else
    sql -separator $'\t' "SELECT 'D-'||id, target, item_count, created_at FROM digests ORDER BY id DESC LIMIT 50;"
  fi
}

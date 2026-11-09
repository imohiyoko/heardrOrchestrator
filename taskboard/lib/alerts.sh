# shellcheck shell=bash
# アラートと解析役(alert / alerts / alert-*)
# bin/tb から source される。単体では実行しない。

# ---------- alerts(見張り役が見つけた異常 → 解析役の agent を起動 → 結果を公開) ----------
ALERT_SEVERITIES="critical high medium low"
ANALYST_MAX=${TB_ANALYST_MAX:-2}
ANALYST_CWD=${TB_ANALYST_CWD:-$TB_ROOT/..}
ANALYST_MODEL=${TB_ANALYST_MODEL:-}
valid_aid() { [[ $1 =~ ^A-[0-9]+$ ]] || usage "アラート ID は A-<数字>: $1"; }
alert_row() { sql -json "SELECT * FROM alerts WHERE id=${1#A-};" | jq -c '.[0] // empty'; }

# tb alert: 登録。見張り役は「何が起きたか」だけを書く(緊急度は解析役が決める)。
# 同じ指紋(--key、無ければ題名)の未解決アラートがあれば件数を増やすだけ
# 出力: "A-<n> new|duplicate <status>"。新規なら続けて解析役の起動を試みる(approvals の alert:analyze)
cmd_alert() {
  local title="" body="" bfile="" key="" json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --severity) usage "alert: 緊急度は解析役が tb alert-result --severity で決めます(見張り役は指定しない)";;
      --title) need_arg "$@"; title=$2; shift 2;;
      --body) need_arg "$@"; body=$2; shift 2;;
      --body-file) need_arg "$@"; bfile=$2; shift 2;;
      --key) need_arg "$@"; key=$2; shift 2;;
      --json) json=1; shift;;
      --from|--source|--name|--pane) usage "alert: 報告者は herdr から自動で決まります。$1 は指定できません";;
      *) usage "alert: 不明な引数 $1";;
    esac
  done
  blank "$title" && usage "alert: --title が必要です"
  if [[ -n $bfile ]]; then [[ -f $bfile && -r $bfile ]] || die "alert: --body-file を読めません: $bfile"; body=$(head -c 20000 "$bfile"); fi
  local src="cli" spane=""
  if [[ -n ${HERDR_PANE_ID:-} ]]; then resolve_label || return 3; src=$LABEL_NAME; spane=$LABEL_PANE; fi
  local fp; fp=$(printf '%s' "${key:-$title}" | sha256 | cut -c1-16)
  local dup; dup=$(sql "SELECT id FROM alerts WHERE fingerprint=$(q "$fp") AND status NOT IN ('analyzed','closed') ORDER BY id DESC LIMIT 1;")
  local id state ts; ts=$(now)
  if [[ -n $dup ]]; then
    sql "UPDATE alerts SET count=count+1, last_seen=$(q "$ts") WHERE id=$dup;"
    id=$dup; state=duplicate
  else
    id=$(sql "INSERT INTO alerts (fingerprint, title, body, source, source_pane, status, count, first_seen, last_seen)
      VALUES ($(q "$fp"), $(q "$title"), $(q "$body"), $(q "$src"), NULLIF($(q "$spane"),''), 'new', 1, $(q "$ts"), $(q "$ts"));
      SELECT last_insert_rowid();")
    state=new
  fi
  [[ $state == new ]] && { alert_dispatch_one "$id" >/dev/null 2>&1 || true; }
  if ((json)); then alert_row "$id" | jq -c '.id = "A-\(.id)"'
  else echo "A-$id $state $(sql "SELECT status FROM alerts WHERE id=$id;")"; fi
}

# 解析役を起動する。新規で approvals が ask なら awaiting-approval。上限に達していれば queued(承認は済んだ扱い)
alert_dispatch_one() {  # $1=alerts.id(数字)
  local id=$1 st
  st=$(sql "SELECT status FROM alerts WHERE id=$id;")
  [[ $st == new || $st == queued || $st == approved ]] || return 0
  if [[ $st == new ]]; then
    approval_of "alert:analyze"
    if [[ $APPROVAL_VALUE != allow ]]; then sql "UPDATE alerts SET status='awaiting-approval' WHERE id=$id;"; return 0; fi
  fi
  local busy; busy=$(sql "SELECT COUNT(*) FROM alerts WHERE status='analyzing';")
  if (( busy >= ANALYST_MAX )); then sql "UPDATE alerts SET status='queued' WHERE id=$id;"; return 0; fi
  start_analyst "$id"
}

start_analyst() {  # $1=alerts.id
  local id=$1 name="analyst-A$1" cwd pane out prompt
  cwd=$(cd "$ANALYST_CWD" 2>/dev/null && pwd) || { sql "UPDATE alerts SET status='queued', note='TB_ANALYST_CWD が無い' WHERE id=$id;"; return 11; }
  if ! out=$(herdr_call workspace create --cwd "$cwd" --label "$name" --no-focus 2>&1) \
     || ! pane=$(jq -er '.result.root_pane.pane_id' <<<"$out" 2>/dev/null); then
    sql "UPDATE alerts SET status='queued', note='workspace を作れない' WHERE id=$id;"; return 11
  fi
  local -a extra=(); [[ -n $ANALYST_MODEL ]] && extra=(-- --model "$ANALYST_MODEL")
  local i ok=0
  for i in 1 2 3; do   # シェル初期化が遅いと最初の start が失敗する(herdr-up.sh と同じ)
    if herdr_call agent start "$name" --kind claude --pane "$pane" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1; then ok=1; break; fi
    sleep "${TB_ANALYST_RETRY_SEC:-3}"
  done
  ((ok)) || { sql "UPDATE alerts SET status='queued', note='agent を起動できない' WHERE id=$id;"; return 11; }
  sql "UPDATE alerts SET status='analyzing', analyst=$(q "$name"), analysis_started_at=$(q "$(now)"), note=NULL WHERE id=$id;"
  prompt="[from: tb / alert / A-$id / task] あなたはアラート A-$id の解析役です(役割は roles/analyst.md)。まず tb alerts A-$id で全文を読み、原因の仮説・根拠・影響範囲・推奨対応をまとめ、緊急度を決めて、tb alert-result A-$id --severity critical|high|medium|low --summary '<要約>' --report <報告ファイル> で返してください。"
  # 起動直後は idle になるまで少し待つ(herdr_send は idle/done でしか送らない)
  for i in 1 2 3 4 5; do herdr_send "$name" "$prompt" "A-$id" alert 2>/dev/null && return 0; sleep "${TB_ANALYST_RETRY_SEC:-3}"; done
  sql "UPDATE alerts SET note='解析役に依頼を送れていない(tb alert-dispatch で再送)' WHERE id=$id;"
  return 10
}

# 承認待ち・上限待ちのアラートを進める(tb digest も最初に呼ぶ)。送れていない依頼も再送する
cmd_alert-dispatch() {
  local id
  while read -r id; do [[ -n $id ]] && { alert_dispatch_one "$id" || true; }; done < <(sql "SELECT id FROM alerts WHERE status IN ('new','queued','approved') ORDER BY id;")
  sql -separator ' ' "SELECT 'A-'||id, status FROM alerts WHERE status IN ('awaiting-approval','queued','analyzing') ORDER BY id;"
}

# 人が解析役の起動を承認する(approvals が ask のとき)。--always で alert:analyze を allow に
cmd_alert-approve() {
  [[ $# -ge 1 ]] || usage "alert-approve A-<n> [--always]"
  valid_aid "$1"; local id=${1#A-} always=0; shift
  [[ ${1:-} == --always ]] && always=1
  require_human "tb alert-approve"
  [[ $(sql "SELECT status FROM alerts WHERE id=$id;") == awaiting-approval ]] || die "A-$id は承認待ちではありません"
  sql "UPDATE alerts SET status='approved' WHERE id=$id;"
  ((always)) && set_approval allow "alert:analyze" >/dev/null && echo "alert:analyze = allow(今後は承認なし)"
  alert_dispatch_one "$id" >/dev/null 2>&1 || true
  echo "A-$id $(sql "SELECT status FROM alerts WHERE id=$id;")"
}

# 解析役が結果を返す。担当の解析役(または人)だけ
cmd_alert-result() {
  [[ $# -ge 1 ]] || usage "alert-result A-<n> --severity critical|high|medium|low --summary S [--report <ファイル>]"
  valid_aid "$1"; local id=${1#A-} summary="" report="" sev=""; shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --summary) need_arg "$@"; summary=$2; shift 2;;
      --report) need_arg "$@"; report=$2; shift 2;;
      --severity) need_arg "$@"; sev=$2; shift 2;;
      *) usage "alert-result: 不明な引数 $1";;
    esac
  done
  [[ " $ALERT_SEVERITIES " == *" $sev "* ]] || usage "alert-result: --severity は $ALERT_SEVERITIES のどれか(緊急度は解析役が決める)"
  blank "$summary" && usage "alert-result: --summary が必要です"
  local row; row=$(alert_row "$id"); [[ -n $row ]] || die "アラートが見つかりません: A-$id"
  local by="human"
  if [[ -n ${HERDR_PANE_ID:-} ]]; then
    resolve_label || return 3
    [[ $LABEL_NAME == "$(jq -r '.analyst // ""' <<<"$row")" ]] || die "A-$id の解析役ではありません($LABEL_NAME)"
    by=$LABEL_NAME
  fi
  [[ $(jq -r .status <<<"$row") != closed ]] || die "A-$id は閉じています"
  local rtext=""; if [[ -n $report ]]; then [[ -f $report && -r $report ]] || die "--report を読めません: $report"; rtext=$(head -c 50000 "$report"); fi
  sql "UPDATE alerts SET status='analyzed', severity=$(q "$sev"), result_summary=$(q "$summary"), result_report=NULLIF($(q "$rtext"),''),
         result_path=NULLIF($(q "$report"),''), result_by=$(q "$by"), analyzed_at=$(q "$(now)") WHERE id=$id;"
  alert_deliver "$id" >/dev/null 2>&1 || true
  cmd_alert-dispatch >/dev/null 2>&1 || true   # 枠が空いたので待ちを進める
  echo "A-$id analyzed"
}

# 解析結果を指揮官へ(使用中なら tb digest が回収する)
alert_deliver() {  # $1=id
  local row msg target
  row=$(alert_row "$1"); [[ -n $row && $(jq -r '.result_delivered_at // ""' <<<"$row") == "" ]] || return 0
  target=$DEFAULT_TARGET
  msg="[alert A-$1 analyzed / $(jq -r .severity <<<"$row")] $(oneline "$(jq -r .title <<<"$row")" 80) — $(oneline "$(jq -r .result_summary <<<"$row")" 300) (全文: tb alerts A-$1)"
  herdr_send "$target" "$msg" "A-$1" alert || return $?
  sql "UPDATE alerts SET result_delivered_at=$(q "$(now)") WHERE id=$1;"
}

cmd_alert-close() {
  [[ $# -eq 1 ]] || usage "alert-close A-<n>"
  valid_aid "$1"; require_human "tb alert-close"
  sql "UPDATE alerts SET status='closed', closed_at=$(q "$(now)") WHERE id=${1#A-};"
  echo "$1 closed"
}

cmd_alerts() {
  local json=0 st=""
  if [[ ${1:-} == A-* ]]; then
    valid_aid "$1"; local row; row=$(alert_row "$1"); [[ -n $row ]] || die "アラートが見つかりません: $1"
    [[ ${2:-} == --json ]] && { jq -c '.id = "A-\(.id)"' <<<"$row"; return 0; }
    jq -r '"A-\(.id) [\(.severity // "未解析")] \(.status) ×\(.count)  \(.title)\n報告: \(.source) / 初回 \(.first_seen) / 最終 \(.last_seen)\n解析役: \(.analyst // "-")\n\n\(.body // "")\n" +
      (if .result_summary then "---- 解析結果(\(.result_by), \(.analyzed_at))\n\(.result_summary)\n\n\(.result_report // "")" else "" end)' <<<"$row"
    return 0
  fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --status) need_arg "$@"; st=$2; shift 2;;
      *) usage "alerts: 不明な引数 $1";;
    esac
  done
  local where="1=1"; [[ -z $st ]] || where="status=$(q "$st")"
  if ((json)); then sql -json "SELECT * FROM alerts WHERE $where ORDER BY id DESC LIMIT 100;" | jq -c '(. // [])[] | .id = "A-\(.id)"'
  else sql -nullvalue - -separator $'\t' "SELECT 'A-'||id, COALESCE(severity,'未解析'), status, count, COALESCE(analyst,'-'), last_seen, title FROM alerts WHERE $where ORDER BY id DESC LIMIT 100;"; fi
}

# shellcheck shell=bash
# agent の停止・復活・新規作成と「止めてよいか」の判定フラグ
# (agents / agent-new / agent-stop / agent-revive / agent-flag / agent-ops / agent-approve / agent-reject)
# bin/tb から source される。単体では実行しない。
#
# - 台帳は agents テーブル。herdr agent list と突き合わせて running / stopped を持つ(tb agents が毎回同期する)
# - 停止 = その agent の pane を閉じる(herdr に agent 単体の停止は無い)。止める前に session と cwd を台帳に残す
# - 復活 = 同じ名前で新しい workspace を作り、claude --resume <session> で同じ会話から再開する(--fresh なら新しい会話)
#   役割は SessionStart hook(tb role-context)が渡す。--role で決めた役割は台帳に残り、復活後も同じものが渡る
# - 判定フラグ killable = yes|no|unknown。付けるのは人か判定役(TB_SWEEPER_PATTERN、既定 sweeper*)だけ。
#   yes を付けた後にその agent が新しい入力を受けたら stale(付け直すまで yes として扱わない)
# - 人の端末からはそのまま実行する。agent の pane からは approvals の agent:<op>:<名前> を見て、ask なら L-<n> で人の承認待ち

AGENT_NAME_RE='^[a-z][a-z0-9_-]{0,31}$'   # herdr agent start の名前の規則
MODEL_RE='^[A-Za-z0-9._:-]{1,64}$'
ROLE_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
SWEEPER_PAT=${TB_SWEEPER_PATTERN:-sweeper*}
AGENT_CWD=${TB_AGENT_CWD:-$TB_ROOT/..}
OPEN_TASK_STATUSES="'in_progress','review','blocked'"
HSESS=$(herdr_session_name)   # HERDR_SOCKET_PATH > HERDR_SESSION > default(lib/herdr-env.sh)。 herdr agent list が見せるのはこのセッションの agent だけ

valid_agent_name() { [[ $1 =~ $AGENT_NAME_RE ]] || usage "agent 名は英小文字で始まり、英小文字・数字・_・- の 32 字以内: $1"; }
valid_lid() { [[ $1 =~ ^L-[0-9]+$ ]] || usage "操作 ID は L-<数字>: $1"; }
agent_reg_row() { sql -json "SELECT * FROM agents WHERE name=$(q "$1");" | jq -c '.[0] // empty'; }

# 今動いている agent の一覧(JSON 配列)を LIVE_AGENTS に入れる。取れなければ 1
LIVE_AGENTS="[]"
load_live() {
  local out
  out=$(herdr_call agent list 2>/dev/null) && LIVE_AGENTS=$(jq -c '[.result.agents[]? | select(type=="object")]' <<<"$out" 2>/dev/null) \
    || { LIVE_AGENTS="[]"; return 1; }
}
live_row() { jq -c --arg n "$1" '[.[] | select(.name==$n)][0] // empty' <<<"$LIVE_AGENTS"; }

# 台帳に登録する(新しい命のたびに判定フラグは付け直し)。$1=名前 $2=cwd $3=model $4=role $5=作った人 [$6=killable $7=理由]
agent_register() {
  local name=$1 cwd=$2 model=$3 role=$4 by=$5 kill=${6:-unknown} why=${7:-} ts; ts=$(now)
  sql "INSERT INTO agents (name, herdr_session, cwd, model, role, state, killable, killable_reason, killable_by, killable_at, created_by, created_at, updated_at)
    VALUES ($(q "$name"), $(q "$HSESS"), NULLIF($(q "$cwd"),''), NULLIF($(q "$model"),''), NULLIF($(q "$role"),''), 'running',
            $(q "$kill"), NULLIF($(q "$why"),''), CASE WHEN $(q "$kill")='unknown' THEN NULL ELSE $(q "$by") END,
            CASE WHEN $(q "$kill")='unknown' THEN NULL ELSE $(q "$ts") END, $(q "$by"), $(q "$ts"), $(q "$ts"))
    ON CONFLICT(name) DO UPDATE SET state='running', stopped_at=NULL, pane_id=NULL, herdr_session=excluded.herdr_session,
      cwd=COALESCE(excluded.cwd, cwd), model=COALESCE(excluded.model, model), role=COALESCE(excluded.role, role),
      killable=excluded.killable, killable_reason=excluded.killable_reason, killable_by=excluded.killable_by,
      killable_at=excluded.killable_at, killable_session=NULL, updated_at=excluded.updated_at;"
}

# herdr の一覧と台帳を突き合わせる。動いていれば running(pane / session / cwd を更新)、消えていれば stopped
agent_sync() {
  load_live || return 1
  local ts rows; ts=$(now)
  rows=$(jq -r '.[] | select((.name // "") != "") | [.name, (.pane_id // ""), (.agent_session.value // ""), (.foreground_cwd // .cwd // "")]
    | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$LIVE_AGENTS")
  local name pane sess cwd stmts="" names="''"
  while IFS=$'\x1f' read -r name pane sess cwd; do
    names+=",$(q "$name")"   # 台帳の規則に合わない名前(解析役 analyst-A<n> など)も「いる」ものとして扱い、勝手に stopped にしない
    [[ $name =~ $AGENT_NAME_RE ]] || continue
    stmts+="INSERT INTO agents (name, herdr_session, pane_id, session_id, cwd, state, killable, created_by, created_at, updated_at)
      VALUES ($(q "$name"), $(q "$HSESS"), NULLIF($(q "$pane"),''), NULLIF($(q "$sess"),''),
              COALESCE((SELECT cwd FROM agent_activity WHERE session_id=$(q "$sess") AND cwd IS NOT NULL), NULLIF($(q "$cwd"),'')),
              'running', 'unknown', 'herdr', $(q "$ts"), $(q "$ts"))
      ON CONFLICT(name) DO UPDATE SET state='running', stopped_at=NULL, pane_id=excluded.pane_id, herdr_session=excluded.herdr_session,
        session_id=COALESCE(excluded.session_id, session_id), cwd=COALESCE(excluded.cwd, cwd), updated_at=$(q "$ts");"
  done <<<"$rows"
  sql "BEGIN; $stmts
    UPDATE agents SET state='stopped', stopped_at=$(q "$ts"), updated_at=$(q "$ts") WHERE state='running' AND herdr_session=$(q "$HSESS") AND name NOT IN ($names);
    COMMIT;"
}

# 台帳の agent が別の herdr セッションのものなら 1(OP_OUT に理由)
other_session() {  # $1=名前
  local s; s=$(sql "SELECT herdr_session FROM agents WHERE name=$(q "$1");")
  [[ -n $s && $s != "$HSESS" ]] || return 1
  OP_OUT="$1 は herdr セッション '$s' の agent です。HERDR_SESSION=$s を付けて実行してください"
}

# 判定フラグの実効値: yes|no|unknown|stale
killable_of() {
  sql "SELECT CASE WHEN killable!='yes' THEN killable
      WHEN killable_session IS NOT NULL AND session_id IS NOT NULL AND killable_session!=session_id THEN 'stale'
      WHEN EXISTS (SELECT 1 FROM agent_activity aa WHERE (aa.session_id=agents.session_id OR aa.pane_id=agents.pane_id)
                   AND julianday(aa.last_prompt_at) > julianday(agents.killable_at)) THEN 'stale'
      ELSE 'yes' END FROM agents WHERE name=$(q "$1");"
}

# 呼び出し元: 人なら REQ_BY=human。agent の pane なら REQ_BY=<agent 名>
REQ_BY=""
requester() {
  local n=""
  if [[ -n ${HERDR_PANE_ID:-} ]]; then
    n=$(pane_owner_name "$HERDR_PANE_ID") || die "herdr agent list に失敗したため、実行者を特定できません"
  fi
  REQ_BY=${n:-human}
}

# 実行してよいか。人なら 0。agent なら approvals の agent:<op>:<名前>: allow → 0、ask → L-<n> を積んで 20
authorize_op() {  # $1=op $2=対象 $3=引数の JSON
  requester
  [[ $REQ_BY == human ]] && return 0
  approval_of "agent:$1:$2"
  [[ $APPROVAL_VALUE == allow ]] && return 0
  local id
  id=$(sql "INSERT INTO agent_ops (op, target, args, requested_by, status, result, created_at)
    VALUES ($(q "$1"), $(q "$2"), $(q "$3"), $(q "$REQ_BY"), 'pending', $(q "approvals: $APPROVAL_RULE"), $(q "$(now)"));
    SELECT last_insert_rowid();")
  echo "L-$id pending (人の承認待ち: tb agent-approve L-$id)"
  return 20
}

# 実行した操作を残す(人の直接実行も、承認後の実行も)。$1=op $2=対象 $3=args $4=依頼者 $5=rc $6=結果 [$7=既存の id]
record_op() {
  local st=done; [[ $5 == 0 ]] || st=failed
  if [[ -n ${7:-} ]]; then
    sql "UPDATE agent_ops SET status='$st', result=$(q "$6"), decided_at=$(q "$(now)") WHERE id=$7;"
  else
    sql "INSERT INTO agent_ops (op, target, args, requested_by, status, result, created_at, decided_at)
      VALUES ($(q "$1"), $(q "$2"), $(q "$3"), $(q "$4"), '$st', $(q "$6"), $(q "$(now)"), $(q "$(now)"));"
  fi
}

# 起動直後の agent に最初の指示を送る(idle になるまで少し待つ)
# 起動直後は herdr が idle と言っても Claude の UI が未準備で、Enter が失われることがある。
# 準備完了(interactive_ready)を待ってから送り、送ったあと動き出したかを確かめる。
# 0=送って動き出した 10=送れていない、または送ったが処理を確認できない(FP_NOTE に理由。本文は再送しない)
FP_NOTE=""
first_prompt() {  # $1=名前 $2=本文 $3=依頼者
  local i sent=0
  FP_NOTE=""
  if ! herdr_wait_ready "$1"; then
    FP_NOTE="最初の指示は未送信(${TB_SPAWN_READY_SEC:-60} 秒待っても入力待ちになりません。tb send で送り直す)"
    echo "tb: $1 が入力待ちにならないため最初の指示を送っていません" >&2; return 10
  fi
  for i in 1 2 3 4 5; do
    if herdr_send "$1" "[from: tb / agent / $3] $(oneline "$2" 4000)" "agent:$1" agent 2>/dev/null; then sent=1; break; fi
    sleep "${TB_SPAWN_RETRY_SEC:-3}"
  done
  if ((! sent)); then FP_NOTE="最初の指示は未送信(tb send などで送り直す)"; return 10; fi
  if ! herdr_verify_prompt "$1"; then
    FP_NOTE="最初の指示は送ったが処理が始まったか確認できません(二重になるので再送せず、${1} の pane で Enter を押してください)"
    echo "tb: $1 に送ったが処理を確認できません。pane で Enter を押してください" >&2; return 10
  fi
  return 0
}

# ---------- 実体(引数は検査済み。結果を OP_OUT に入れて 0 / 1 / 11 を返す) ----------
OP_OUT=""
do_agent_new() {  # name cwd model role prompt killable by [spawned_by spawn_task](tb agent-spawn のときだけ)
  local name=$1 cwd=$2 model=$3 role=$4 prompt=$5 kill=$6 by=$7 sby=${8:-} stask=${9:-}
  agent_sync || { OP_OUT="herdr agent list に失敗しました"; return 11; }
  [[ -z $(live_row "$name") ]] || { OP_OUT="$name はすでに動いています"; return 1; }
  ! other_session "$name" || return 1
  [[ $(sql "SELECT state FROM agents WHERE name=$(q "$name");") != stopped ]] \
    || { OP_OUT="停止中の $name が台帳にあります。tb agent-revive $name で再開するか、別の名前にしてください"; return 1; }
  [[ -d $cwd ]] || { OP_OUT="ディレクトリがありません: $cwd"; return 1; }
  cwd=$(cd "$cwd" && pwd)
  # 先に台帳へ載せる(SessionStart hook が --role の役割を引けるように)
  local why=""; [[ $kill == unknown ]] || why="作成時に指定"
  agent_register "$name" "$cwd" "$model" "$role" "$by" "$kill" "$why"
  local -a args=(); [[ -n $model ]] && args=(--model "$model")
  if ! herdr_spawn "$name" "$cwd" ${args[@]+"${args[@]}"}; then
    sql "DELETE FROM agents WHERE name=$(q "$name");"
    OP_OUT="$name を起動できません: $SPAWN_ERR"; return 11
  fi
  sql "UPDATE agents SET pane_id=$(q "$SPAWN_PANE"), spawned_by=NULLIF($(q "$sby"),''), spawn_task=NULLIF($(q "$stask"),'') WHERE name=$(q "$name");"
  OP_OUT="$name started (pane $SPAWN_PANE, cwd $cwd${model:+, model $model}${role:+, role $role})"
  if [[ -n $prompt ]]; then first_prompt "$name" "$prompt" "$by" || OP_OUT+=" / $FP_NOTE"; fi
  return 0
}

do_agent_stop() {  # name force by
  local name=$1 force=$2 by=$3 row pane sess k open
  agent_sync || { OP_OUT="herdr agent list に失敗しました"; return 11; }
  row=$(live_row "$name")
  [[ -n $row ]] || { other_session "$name" && return 1; OP_OUT="$name は動いていません"; return 1; }
  [[ $by != "$name" ]] || { OP_OUT="自分自身は止められません"; return 1; }
  pane=$(jq -r '.pane_id // ""' <<<"$row"); sess=$(jq -r '.agent_session.value // ""' <<<"$row")
  [[ -n $pane ]] || { OP_OUT="$name の pane が分かりません"; return 1; }
  if [[ $force != 1 ]]; then
    k=$(killable_of "$name")
    open=$(sql "SELECT group_concat(id, ' ') FROM tasks WHERE owner_agent=$(q "$name") AND status IN ($OPEN_TASK_STATUSES);")
    if [[ $k != yes || -n $open ]]; then
      OP_OUT="$name は止めてよいと判定されていません(killable=$k${open:+、未完了タスク $open})。判定役に付けてもらうか(tb agent-flag)、人が --force で止めます"
      return 1
    fi
  fi
  agent_close_pane "$name" "$pane" "$sess" || return $?
  sess=$(sql "SELECT COALESCE(session_id,'') FROM agents WHERE name=$(q "$name");")
  OP_OUT="$name stopped${sess:+ (session ${sess}。tb agent-revive $name で同じ会話から再開できます)}"
}

# pane を閉じて台帳を stopped にする(session は残す)。do_agent_stop と do_agent_restart が共有。失敗は 11
agent_close_pane() {  # name pane session
  herdr_close_pane "$2" || { OP_OUT="pane $2 を閉じられません"; return 11; }
  sql "UPDATE agents SET state='stopped', stopped_at=$(q "$(now)"), updated_at=$(q "$(now)"), pane_id=NULL,
         session_id=COALESCE(NULLIF($(q "$3"),''), session_id) WHERE name=$(q "$1");"
}

do_agent_revive() {  # name fresh model prompt by
  local name=$1 fresh=$2 model=$3 prompt=$4 by=$5 row cwd sess
  agent_sync || { OP_OUT="herdr agent list に失敗しました"; return 11; }
  [[ -z $(live_row "$name") ]] || { OP_OUT="$name はすでに動いています"; return 1; }
  row=$(agent_reg_row "$name")
  [[ -n $row ]] || { OP_OUT="$name は台帳にありません(新しく作るなら tb agent-new)"; return 1; }
  ! other_session "$name" || return 1
  cwd=$(jq -r '.cwd // ""' <<<"$row"); [[ -n $model ]] || model=$(jq -r '.model // ""' <<<"$row")
  sess=""; [[ $fresh == 1 ]] || sess=$(jq -r '.session_id // ""' <<<"$row")
  if [[ -z $cwd || ! -d $cwd ]]; then
    # claude --resume は会話を作業ディレクトリごとに探すので、別の場所では同じ会話に戻れない
    [[ -z $sess ]] || { OP_OUT="$name の作業ディレクトリがありません(${cwd:-未記録})。--fresh なら $AGENT_CWD で新しい会話として起動します"; return 1; }
    cwd=$(cd "$AGENT_CWD" && pwd)
  fi
  local -a args=()
  [[ -n $sess ]] && args+=(--resume "$sess")
  [[ -n $model ]] && args+=(--model "$model")
  agent_register "$name" "$cwd" "$model" "" "$by"
  if ! herdr_spawn "$name" "$cwd" ${args[@]+"${args[@]}"}; then
    sql "UPDATE agents SET state='stopped', stopped_at=$(q "$(now)") WHERE name=$(q "$name");"
    OP_OUT="$name を起動できません: $SPAWN_ERR"; return 11
  fi
  sql "UPDATE agents SET pane_id=$(q "$SPAWN_PANE") WHERE name=$(q "$name");"
  local how="新しい会話"; [[ -z $sess ]] || how="resume $sess"
  OP_OUT="$name revived ($how, pane $SPAWN_PANE, cwd $cwd)"
  if [[ -n $prompt ]]; then first_prompt "$name" "$prompt" "$by" || OP_OUT+=" / $FP_NOTE"; fi
  return 0
}

# 再起動 = 停止 + 同じ会話での復活(MCP の接続を張り直す)。killable の判定は見ない代わりに、次の安全条件を全部満たすときだけ:
#   現在の herdr セッションで動いている / herdr の状態が idle か done / in_progress のタスクを持たない
#   (持つなら idle/done かつ --prompt に再開メモがあるときだけ) / 会話を再開できる(session と cwd が分かる) / 自分自身ではない
# 復活に失敗したら停止のまま残し、tb agent-revive の実行例を出す(勝手に新しい会話は作らない)。0 / 1 / 4 / 10(再開したが最初の指示を確認できない) / 11
RESTART_DEFAULT_PROMPT='MCP の接続を張り直すために再起動しました。直前の作業を続けてください。まず MCP のツールが使えることを確認し、まだ使えないなら tb comment で報告してください。'
do_agent_restart() {  # name prompt by
  local name=$1 prompt=$2 by=$3 row pane sess cwd status open t0 old_sess new_sess rev how stoprc=0 rr=0 cur
  t0=$(date +%s); FP_NOTE=""
  agent_sync || { OP_OUT="herdr agent list に失敗しました"; return 11; }
  row=$(live_row "$name")
  [[ -n $row ]] || { other_session "$name" && return 1; OP_OUT="$name は動いていません(再起動は動いている agent だけ。止まっているなら tb agent-revive $name)"; return 1; }
  ! other_session "$name" || return 1
  [[ $by != "$name" ]] || { OP_OUT="自分自身は再起動できません"; return 1; }
  pane=$(jq -r '.pane_id // ""' <<<"$row"); old_sess=$(jq -r '.agent_session.value // ""' <<<"$row")
  status=$(jq -r '.agent_status // ""' <<<"$row")
  [[ -n $pane ]] || { OP_OUT="$name の pane が分かりません"; return 1; }
  case $status in idle|done) ;; *) OP_OUT="$name は ${status:-状態不明} のため再起動しません(idle か done のときだけ)"; return 1;; esac
  open=$(sql "SELECT group_concat(id, ' ') FROM tasks WHERE owner_agent=$(q "$name") AND status='in_progress';")
  if [[ -n $open ]] && blank "$prompt"; then
    OP_OUT="$name は in_progress のタスク($open)を持っています。再開メモを --prompt で渡したときだけ再起動できます"; return 1
  fi
  [[ -n $old_sess ]] || old_sess=$(sql "SELECT COALESCE(session_id,'') FROM agents WHERE name=$(q "$name");")
  cwd=$(sql "SELECT COALESCE(cwd,'') FROM agents WHERE name=$(q "$name");")
  # 閉じてから再開できないと困るので、再開できることを先に確かめる(だめなら何も止めない)
  [[ -n $old_sess ]] || { OP_OUT="$name の session id が台帳にありません。同じ会話に戻れないので止めません"; return 1; }
  [[ -n $cwd && -d $cwd ]] || { OP_OUT="$name の作業ディレクトリがありません(${cwd:-未記録})。同じ会話に戻れないので止めません"; return 1; }
  blank "$prompt" && prompt=$RESTART_DEFAULT_PROMPT
  agent_close_pane "$name" "$pane" "$old_sess" || return $?
  agent_sync || true
  limits_refuse_running 1 >/dev/null 2>&1 || rr=$?
  if ((rr)); then
    OP_OUT="$name を停止しましたが、動作中の agent が上限のため復活していません。停止のままです。上限が空いたら: tb agent-revive $name [--fresh]"; return 4
  fi
  do_agent_revive "$name" 0 "" "$prompt" "$by" || rr=$?
  if ((rr)); then
    OP_OUT="$name を停止しました(pane $pane を閉じた)が、復活に失敗: ${OP_OUT}。停止のままです。自分で戻すなら: tb agent-revive $name [--fresh](--fresh は新しい会話になります)"
    return "$rr"
  fi
  rev=$OP_OUT
  agent_sync || true
  cur=$(live_row "$name"); new_sess=$(jq -r '.agent_session.value // ""' <<<"$cur")
  if [[ -z $new_sess ]]; then how="session unconfirmed (herdr reports none yet; was $old_sess)"
  elif [[ $new_sess == "$old_sess" ]]; then how="同じ会話に戻った(session $old_sess のまま)"
  else how="session CHANGED ($old_sess -> $new_sess; verify it is the same conversation)"; fi
  OP_OUT="$name restarted by $by: stop ok(pane $pane を閉じた) / revive ok(${rev#"$name revived "}) / $how / $(( $(date +%s) - t0 )) 秒"
  if [[ -n $FP_NOTE ]]; then OP_OUT+=" / $FP_NOTE"; return 10; fi
  return 0
}

# op と args(JSON)から実行する(直接実行と承認後の実行で共通)
run_op() {  # $1=op $2=対象 $3=args $4=依頼者
  local a=$3
  case $1 in
    new)    do_agent_new "$2" "$(jq -r '.cwd // ""' <<<"$a")" "$(jq -r '.model // ""' <<<"$a")" "$(jq -r '.role // ""' <<<"$a")" \
                         "$(jq -r '.prompt // ""' <<<"$a")" "$(jq -r '.killable // "unknown"' <<<"$a")" "$4" \
                         "$(jq -r '.spawn.parent // ""' <<<"$a")" "$(jq -r '.spawn.task // ""' <<<"$a")";;
    stop)   do_agent_stop "$2" "$(jq -r '.force // 0' <<<"$a")" "$4";;
    revive) do_agent_revive "$2" "$(jq -r '.fresh // 0' <<<"$a")" "$(jq -r '.model // ""' <<<"$a")" "$(jq -r '.prompt // ""' <<<"$a")" "$4";;
    *) OP_OUT="不明な操作: $1"; return 1;;
  esac
}

# 承認を確かめて実行し、結果を出す。終了コード 0 / 1 / 11 / 20(承認待ち)
op_entry() {  # $1=op $2=対象 $3=args
  local r=0
  authorize_op "$1" "$2" "$3" || return $?
  run_op "$1" "$2" "$3" "$REQ_BY" || r=$?
  record_op "$1" "$2" "$3" "$REQ_BY" "$r" "$OP_OUT"
  if ((r)); then echo "tb: $OP_OUT" >&2; else echo "$OP_OUT"; fi
  return $r
}

# ---------- コマンド ----------
cmd_agent-new() {
  [[ $# -ge 1 && $1 != -* ]] || usage "agent-new <名前> [--cwd D] [--model M] [--role R] [--prompt P] [--killable yes|no]"
  local name=$1 cwd="" model="" role="" prompt="" kill=unknown; shift
  valid_agent_name "$name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cwd) need_arg "$@"; cwd=$2; shift 2;;
      --model) need_arg "$@"; model=$2; shift 2;;
      --role) need_arg "$@"; role=$2; shift 2;;
      --prompt) need_arg "$@"; prompt=$2; shift 2;;
      --killable) need_arg "$@"; kill=$2; shift 2;;
      *) usage "agent-new: 不明な引数 $1";;
    esac
  done
  [[ -z $model || $model =~ $MODEL_RE ]] || usage "agent-new: --model に使えない文字があります: $model"
  if [[ -n $role ]]; then
    [[ $role =~ $ROLE_RE && $role != _* && $role != README && -f $ROLES_DIR/$role.md ]] || usage "agent-new: --role は roles/<名前>.md の名前: $role"
  fi
  [[ $kill == yes || $kill == no || $kill == unknown ]] || usage "agent-new: --killable は yes|no"
  if [[ $kill != unknown ]]; then   # 判定フラグを付けられるのは agent-flag と同じく判定役か人だけ
    requester
    # shellcheck disable=SC2053  # glob として比べる
    [[ $REQ_BY == human || $REQ_BY == $SWEEPER_PAT ]] || die "agent-new --killable を付けられるのは判定役($SWEEPER_PAT)か人だけです($REQ_BY)"
  fi
  [[ ${#prompt} -le 4000 ]] || usage "agent-new: --prompt は 4000 字まで"
  [[ -n $cwd ]] || cwd=$AGENT_CWD
  cwd=${cwd/#\~/$HOME}
  # 承認する側のカレントで解決されないよう、依頼時に絶対パスにする(存在の検査は実行時に do_agent_new が行う)
  [[ $cwd == /* ]] || cwd=$PWD/$cwd
  [[ ! -d $cwd ]] || cwd=$(cd "$cwd" && pwd)
  limits_refuse_running 1 || return 4   # 動作中が上限なら、承認待ちにも積まず拒否(max_running_agents)
  op_entry new "$name" "$(jq -nc --arg c "$cwd" --arg m "$model" --arg r "$role" --arg p "$prompt" --arg k "$kill" \
    '{cwd:$c} + (if $m=="" then {} else {model:$m} end) + (if $r=="" then {} else {role:$r} end) + (if $p=="" then {} else {prompt:$p} end) + {killable:$k}')"
}

cmd_agent-stop() {
  [[ $# -ge 1 && $1 != -* ]] || usage "agent-stop <名前> [--force]"
  local name=$1 force=0; shift
  valid_agent_name "$name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=1; shift;;
      *) usage "agent-stop: 不明な引数 $1";;
    esac
  done
  if ((force)); then requester; [[ $REQ_BY == human ]] || die "--force は人が自分の端末で使います(agent '$REQ_BY' の pane からは使えません)"; fi
  op_entry stop "$name" "$(jq -nc --argjson f "$force" '{force:$f}')"
}

cmd_agent-revive() {
  [[ $# -ge 1 && $1 != -* ]] || usage "agent-revive <名前> [--fresh] [--model M] [--prompt P]"
  local name=$1 fresh=0 model="" prompt=""; shift
  valid_agent_name "$name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --fresh) fresh=1; shift;;
      --model) need_arg "$@"; model=$2; shift 2;;
      --prompt) need_arg "$@"; prompt=$2; shift 2;;
      *) usage "agent-revive: 不明な引数 $1";;
    esac
  done
  [[ -z $model || $model =~ $MODEL_RE ]] || usage "agent-revive: --model に使えない文字があります: $model"
  [[ ${#prompt} -le 4000 ]] || usage "agent-revive: --prompt は 4000 字まで"
  limits_refuse_running 1 || return 4   # 復活も動作中を 1 つ増やす
  op_entry revive "$name" "$(jq -nc --argjson f "$fresh" --arg m "$model" --arg p "$prompt" \
    '{fresh:$f} + (if $m=="" then {} else {model:$m} end) + (if $p=="" then {} else {prompt:$p} end)')"
}

# 再起動(MCP が切れた agent の復旧)。人はいつでも。agent の pane からは自分以外・指揮官以外で、
# agent:stop:<名前> と agent:revive:<名前> の両方が allow のときだけ(それ以外は何もせず拒否 = 終了コード 4。承認待ちには積まない)
# agent_ops には op=revive、args.restart=1 で 1 行だけ残す(CHECK 制約は変えない)
cmd_agent-restart() {
  [[ $# -ge 1 && $1 != -* ]] || usage "agent-restart <名前> [--prompt P]"
  local name=$1 prompt="" r=0 args; shift
  valid_agent_name "$name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --prompt) need_arg "$@"; prompt=$2; shift 2;;
      *) usage "agent-restart: 不明な引数 $1(--force はありません)";;
    esac
  done
  [[ ${#prompt} -le 4000 ]] || usage "agent-restart: --prompt は 4000 字まで"
  args=$(jq -nc --arg p "$prompt" '{restart:1} + (if $p=="" then {} else {prompt:$p} end)')
  requester
  if [[ $REQ_BY != human ]]; then
    local why="" n s v
    if [[ $REQ_BY == "$name" ]]; then why="自分自身は再起動できません"
    else
      while IFS= read -r n; do [[ $n == "$name" ]] && why="指揮官($name)は agent から再起動できません(人が実行します)"; done < <(conductor_names)
    fi
    if [[ -z $why ]]; then
      approval_of "agent:stop:$name"; s=$APPROVAL_VALUE
      approval_of "agent:revive:$name"; v=$APPROVAL_VALUE
      [[ $s == allow && $v == allow ]] || why="approvals で agent:stop:$name と agent:revive:$name の両方が allow ではありません(stop=$s revive=$v)。人が実行するか、人が許可してください"
    fi
    if [[ -n $why ]]; then
      sql "INSERT INTO agent_ops (op, target, args, requested_by, status, result, created_at, decided_at)
        VALUES ('revive', $(q "$name"), $(q "$args"), $(q "$REQ_BY"), 'rejected', $(q "restart refused: $why"), $(q "$(now)"), $(q "$(now)"));" >/dev/null
      echo "tb: $why" >&2; return 4
    fi
  fi
  limits_refuse_running 0 || return 4   # 動作中が既に上限を超えているときは触らない(再起動で数は増えない)
  do_agent_restart "$name" "$prompt" "$REQ_BY" || r=$?
  record_op revive "$name" "$args" "$REQ_BY" "$r" "restart: $OP_OUT"
  if ((r == 0)); then echo "$OP_OUT"; else echo "tb: $OP_OUT" >&2; fi
  return $r
}

# 判定役(または人)が「止めてよいか」を付ける
cmd_agent-flag() {
  [[ $# -ge 1 && $1 != -* ]] || usage "agent-flag <名前> --killable yes|no|unknown [--reason R]"
  local name=$1 kill="" why=""; shift
  valid_agent_name "$name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --killable) need_arg "$@"; kill=$2; shift 2;;
      --reason) need_arg "$@"; why=$2; shift 2;;
      *) usage "agent-flag: 不明な引数 $1";;
    esac
  done
  [[ $kill == yes || $kill == no || $kill == unknown ]] || usage "agent-flag: --killable は yes|no|unknown"
  [[ $kill == unknown ]] || ! blank "$why" || usage "agent-flag: yes / no には --reason が必要です"
  requester
  if [[ $REQ_BY != human ]]; then
    # shellcheck disable=SC2053  # glob として比べる
    [[ $REQ_BY == $SWEEPER_PAT ]] || die "判定フラグを付けられるのは判定役($SWEEPER_PAT)か人だけです($REQ_BY)"
    [[ $REQ_BY != "$name" ]] || die "自分自身の判定は付けられません"
  fi
  agent_sync || die "herdr agent list に失敗しました"
  [[ $(sql "SELECT state FROM agents WHERE name=$(q "$name");") == running ]] || die "$name は動いていません"
  local ts; ts=$(now)
  sql "UPDATE agents SET killable=$(q "$kill"), killable_reason=NULLIF($(q "$(oneline "$why" 300)"),''),
         killable_by=$(q "$REQ_BY"), killable_at=$(q "$ts"), killable_session=session_id, updated_at=$(q "$ts") WHERE name=$(q "$name");"
  echo "$name killable=$kill"
}

# 台帳 + 判定に使う材料(判定役はこれを読んで決める)
cmd_agents() {
  local json=0 all=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --all) all=1; shift;;
      *) usage "agents: 不明な引数 $1";;
    esac
  done
  agent_sync || echo "tb: herdr agent list に失敗しました(台帳の内容だけを出します)" >&2
  local where="1=1"; ((all)) || where="(a.state='running' OR a.stopped_at > strftime('%Y-%m-%dT%H:%M:%SZ','now','-7 days'))"
  local rows name k status
  rows=$(sql -json "SELECT a.name, a.state, a.pane_id, a.session_id, a.cwd, a.model, a.role, a.killable_reason, a.killable_by, a.killable_at,
      a.created_by, a.created_at, a.stopped_at,
      (SELECT COUNT(*) FROM tasks t WHERE t.owner_agent=a.name AND t.status IN ($OPEN_TASK_STATUSES)) AS open_tasks,
      (SELECT COUNT(*) FROM comments c LEFT JOIN tasks t ON t.id=c.task_id WHERE c.from_name=a.name AND c.kind IN ('question','blocked')
         AND c.resolved_at IS NULL AND COALESCE(t.status,'')!='done') AS open_questions,
      aa.last_prompt_at, aa.last_stop_at,
      CASE WHEN aa.last_stop_at IS NOT NULL AND (aa.last_prompt_at IS NULL OR aa.last_stop_at >= aa.last_prompt_at)
           THEN CAST((julianday('now') - julianday(aa.last_stop_at)) * 1440 AS INTEGER) END AS idle_min
    FROM agents a LEFT JOIN agent_activity aa ON aa.session_id=a.session_id
    WHERE $where ORDER BY a.state, a.name;")
  [[ -n $rows ]] || rows="[]"
  # 実効の判定フラグと herdr の状態を足す
  local out="[]" r
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    name=$(jq -r .name <<<"$r"); k=$(killable_of "$name")
    status=$(jq -r --arg n "$name" '[.[] | select(.name==$n)][0].agent_status // ""' <<<"$LIVE_AGENTS")
    load_role "$name" >/dev/null 2>&1 || true
    out=$(jq -c --argjson r "$r" --arg k "$k" --arg s "$status" --arg f "${ROLE_FILE#"$ROLES_DIR"/}" \
      '. + [$r + {killable:$k, agent_status:(if $s=="" then null else $s end), role_file:(if $f=="" then null else $f end)}]' <<<"$out")
  done < <(jq -c '.[]' <<<"$rows")
  if ((json)); then jq -c '.[]' <<<"$out"; return 0; fi
  jq -r '.[] | [.name, .state, (.agent_status // "-"), .killable, "tasks:\(.open_tasks)", "q:\(.open_questions)",
     "idle:\(.idle_min // "-")m", (.role_file // "-"), (.killable_reason // "")] | join("\t")' <<<"$out"
}

cmd_agent-ops() {
  local json=0 st=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --status) need_arg "$@"; st=$2; shift 2;;
      *) usage "agent-ops: 不明な引数 $1";;
    esac
  done
  local where="1=1"; [[ -z $st ]] || where="status=$(q "$st")"
  if ((json)); then sql -json "SELECT * FROM agent_ops WHERE $where ORDER BY id DESC LIMIT 100;" | jq -c '(. // [])[] | .id = "L-\(.id)"'
  else sql -nullvalue - -separator $'\t' "SELECT 'L-'||id, op, target, requested_by, status, created_at, COALESCE(result,'') FROM agent_ops WHERE $where ORDER BY id DESC LIMIT 100;"; fi
}

# 人が承認待ちの操作を実行する。--always なら agent:<op>:<対象> を allow に
cmd_agent-approve() {
  [[ $# -ge 1 ]] || usage "agent-approve L-<n> [--always]"
  valid_lid "$1"; local id=${1#L-} always=0 row op target args by r=0; shift
  [[ ${1:-} == --always ]] && always=1
  require_human "tb agent-approve"
  row=$(sql -json "SELECT * FROM agent_ops WHERE id=$id;" | jq -c '.[0] // empty')
  [[ -n $row ]] || die "操作が見つかりません: L-$id"
  [[ $(jq -r .status <<<"$row") == pending ]] || die "L-$id は承認待ちではありません($(jq -r .status <<<"$row"))"
  op=$(jq -r .op <<<"$row"); target=$(jq -r .target <<<"$row"); args=$(jq -r .args <<<"$row"); by=$(jq -r .requested_by <<<"$row")
  if [[ $op == new && -n $(jq -r '.spawn.parent // ""' <<<"$args") ]]; then spawn_recheck "$id" "$args" || return 1
  elif [[ $op == new || $op == revive ]]; then limits_refuse_running 1 || return 4   # 承認待ちの間に上限へ達していたら、承認待ちのまま残す
  fi
  ((always)) && set_approval allow "agent:$op:$target" >/dev/null && echo "agent:$op:$target = allow(今後は承認なし)"
  run_op "$op" "$target" "$args" "$by" || r=$?
  record_op "$op" "$target" "$args" "$by" "$r" "$OP_OUT / 人が承認" "$id"
  if ((r)); then echo "tb: L-$id: $OP_OUT" >&2; else echo "L-$id: $OP_OUT"; fi
  return $r
}

cmd_agent-reject() {
  [[ $# -eq 1 ]] || usage "agent-reject L-<n>"
  valid_lid "$1"; local id=${1#L-}
  require_human "tb agent-reject"
  [[ $(sql "SELECT status FROM agent_ops WHERE id=$id;") == pending ]] || die "L-$id は承認待ちではありません"
  sql "UPDATE agent_ops SET status='rejected', result=COALESCE(result,'')||' / 人が却下', decided_at=$(q "$(now)") WHERE id=$id;"
  echo "L-$id rejected"
}

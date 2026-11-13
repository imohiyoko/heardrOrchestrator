# shellcheck shell=bash
# herdr との境界。tb の中で herdr を実行するのはこのファイルだけ(herdr_call)。
# 送ったもの・送れなかったものは messages に残す。後で MCP などの経路を足すときはここを差し替える
# bin/tb から source される。単体では実行しない。

# herdr を実行する唯一の場所。引数はそのまま herdr CLI に渡す
herdr_call() { "$HERDR_BIN" "$@"; }

# 宛先の状態を見て、idle/done のときだけ送る。0=送信済み 10=宛先が使用中 11=状態取得/送信の失敗
herdr_send() {  # $1=宛先 $2=本文 $3=ログ用 ID [$4=種別(report|comment|digest|send)]
  local target=$1 msg=$2 id=$3 kind=${4:-report} st out raw ecode
  raw=$(herdr_call agent get "$target" 2>/dev/null) || true
  st=$(jq -r '.result.agent.agent_status // empty' <<<"$raw" 2>/dev/null) || st=""
  ecode=$(jq -r '.error.code // empty' <<<"$raw" 2>/dev/null) || ecode=""
  case $st in
    idle|done) ;;
    "") log_message "$kind" "$id" "$target" "$msg" failed
        if [[ $ecode == agent_not_found ]]; then
          echo "tb: 宛先 '$target' が herdr セッション '${HERDR_SESSION:-default}' に見つかりません(セッション違いの可能性。HERDR_SESSION=<名前> で指定)。未送信: $id" >&2
        else
          echo "tb: 宛先 '$target' の状態を取得できません(herdr セッション '${HERDR_SESSION:-default}')。未送信(pending に残す): $id" >&2
        fi
        return 11;;
    *)  log_message "$kind" "$id" "$target" "$msg" busy
        echo "tb: 宛先 '$target' が $st のため送りません。未送信(pending に残す): $id" >&2; return 10;;
  esac
  if ! out=$(herdr_call agent prompt "$target" "$msg" 2>&1) || jq -e 'type=="object" and has("error")' <<<"$out" >/dev/null 2>&1; then
    log_message "$kind" "$id" "$target" "$msg" failed
    echo "tb: 送信に失敗しました。未送信(pending に残す): $id" >&2
    echo "$out" >&2
    return 11
  fi
  log_message "$kind" "$id" "$target" "$msg" sent
}

# 送信の記録はアプリ(tb)が書く。agent の自己申告に頼らない
log_message() {  # $1=kind $2=ref $3=target $4=body $5=sent|busy|failed
  sql "INSERT INTO messages (kind, ref, target, body, result, created_at)
    VALUES ($(q "$1"), $(q "$2"), $(q "$3"), $(q "$4"), $(q "$5"), $(q "$(now)"));" >/dev/null || true
}

# scheduler(tick.sh)からのプロンプト送信。agent の pane からは使えない。記録は messages(kind=scheduler)
cmd_system-send() {
  [[ $# -ge 3 && $2 == --text ]] || usage "system-send <宛先> --text T --job J"
  local target=$1 text=$3 job=""; shift 3
  [[ ${1:-} == --job ]] && job=${2:-}
  [[ $job =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || usage "system-send: --job が必要です"
  require_human "tb system-send"
  herdr_send "$target" "$text" "job:$job" scheduler
}

# agent を 1 体起動する: 専用の workspace(label = 名前)を作り、その root pane で claude を起動する。
# 成功時 SPAWN_PANE / SPAWN_WS を埋めて 0。失敗時 SPAWN_ERR に理由を入れて 11(作った workspace は閉じる)
# 起動直後はシェル初期化(mise 等)が遅いと start が失敗するので数回やり直す(herdr-up.sh と同じ)
SPAWN_PANE=""; SPAWN_WS=""; SPAWN_ERR=""
herdr_spawn() {  # $1=名前 $2=cwd [$3...=claude に渡す引数]
  local name=$1 cwd=$2 out i; shift 2
  local -a extra=(); [[ $# -gt 0 ]] && extra=(-- "$@")
  SPAWN_PANE=""; SPAWN_WS=""; SPAWN_ERR=""
  if ! out=$(herdr_call workspace create --cwd "$cwd" --label "$name" --no-focus 2>&1) \
     || ! SPAWN_PANE=$(jq -er '.result.root_pane.pane_id' <<<"$out" 2>/dev/null); then
    SPAWN_PANE=""; SPAWN_ERR="workspace を作れない"; return 11
  fi
  SPAWN_WS=$(jq -r '.result.workspace.workspace_id // empty' <<<"$out" 2>/dev/null) || SPAWN_WS=""
  for i in 1 2 3; do
    herdr_call agent start "$name" --kind claude --pane "$SPAWN_PANE" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 && return 0
    sleep "${TB_SPAWN_RETRY_SEC:-3}"
  done
  SPAWN_ERR="agent を起動できない"
  if [[ -n $SPAWN_WS ]]; then herdr_call workspace close "$SPAWN_WS" >/dev/null 2>&1 || true
  else herdr_call pane close "$SPAWN_PANE" >/dev/null 2>&1 || true; fi
  return 11
}

# agent を止める = その pane を閉じる(herdr に agent 単体の停止コマンドは無い)
herdr_close_pane() { herdr_call pane close "$1" >/dev/null 2>&1; }

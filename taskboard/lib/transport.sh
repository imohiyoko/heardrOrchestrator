# shellcheck shell=bash
# herdr との境界。tb の中で herdr を実行するのはこのファイルだけ(herdr_call)。
# 送ったもの・送れなかったものは messages に残す。後で MCP などの経路を足すときはここを差し替える
# bin/tb から source される。単体では実行しない。

# herdr を実行する唯一の場所。引数はそのまま herdr CLI に渡す
herdr_call() { "$HERDR_BIN" "$@"; }

# 宛先の状態を見て、idle/done のときだけ送る。0=送信済み 10=宛先が使用中 11=状態取得/送信の失敗
herdr_send() {  # $1=宛先 $2=本文 $3=ログ用 ID [$4=種別(report|comment|digest|send)]
  local target=$1 msg=$2 id=$3 kind=${4:-report} st out
  st=$(herdr_call agent get "$target" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null) || st=""
  case $st in
    idle|done) ;;
    "") log_message "$kind" "$id" "$target" "$msg" failed
        echo "tb: 宛先 '$target' の状態を取得できません。未送信(pending に残す): $id" >&2; return 11;;
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

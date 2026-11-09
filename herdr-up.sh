#!/usr/bin/env bash
# herdr の起動プリセット
# usage: herdr-up.sh <preset>        presets/<preset>.conf を読んで workspace と agent を作る
#        herdr-up.sh -l              プリセット一覧
# プリセット定義: presets/*.conf の各行が 1 workspace
#   label|agent数|プロンプト|作業ディレクトリ|モデル  (プロンプト以降は省略可、ディレクトリ既定は HERDR_UP_CWD または実行時のカレント)
#   プロンプトとモデルは ';;' 区切りで agent ごとに指定できる(例: worker|2|1つ目;;2つ目||sonnet;;claude-haiku-5-5)
#   # で始まる行はコメント
#   先頭付近に `# session: <名前>` を書くと、そのプリセット専用の herdr セッション(別 server)で動く。
#   書かなければ default セッション
# 作成後は別ターミナルで `herdr` を実行して接続する(セッション指定時は herdr --session <名前>)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CWD="${HERDR_UP_CWD:-$PWD}"

# server が止まっていれば headless で起動する
ensure_server() {
  herdr workspace list >/dev/null 2>&1 && return
  nohup herdr ${session:+--session "$session"} server >/dev/null 2>&1 &
  local i
  for i in $(seq 1 20); do
    herdr workspace list >/dev/null 2>&1 && return
    sleep 1
  done
  echo "herdr server が起動しません" >&2; exit 1
}

# シェル初期化(mise 等)が遅いと最初の start が失敗するのでリトライする
start_agent() {
  local name=$1 pane=$2 prompt=${3:-} model=${4:-} i
  local -a extra=()
  [[ -n $model ]] && extra=(-- --model "$model")
  for i in 1 2 3; do
    if herdr agent start "$name" --kind claude --pane "$pane" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1; then
      [[ -n "$prompt" ]] && herdr agent prompt "$name" "$prompt" >/dev/null
      echo "  agent: $name${model:+ (model: $model)}"; return
    fi
    sleep 3
  done
  echo "  failed: $name (pane $pane)" >&2
}

workspace_exists() {
  herdr workspace list | jq -e --arg l "$1" '.result.workspaces[] | select(.label==$l)' >/dev/null
}

# label count prompts dir models: workspace を作り、ペインを count 個に分割して agent を並べる
# prompts / models は ';;' 区切りで agent ごとに指定する(空なら無指定)
make_workspace() {
  local label=$1 count=${2:-1} prompt=${3:-} dir=${4:-$CWD} model=${5:-} i p
  local -a prompts models
  IFS=$'\x1f' read -r -a prompts <<<"${prompt//;;/$'\x1f'}" || true
  IFS=$'\x1f' read -r -a models <<<"${model//;;/$'\x1f'}" || true
  dir="${dir/#\~/$HOME}"
  if workspace_exists "$label"; then echo "skip: $label (already exists)"; return; fi
  [[ -d $dir ]] || { echo "skip: $label (no such dir: $dir)" >&2; return; }
  echo "workspace: $label (agents: $count, cwd: $dir)"
  local panes=()
  panes+=("$(herdr workspace create --cwd "$dir" --label "$label" --no-focus | jq -r '.result.root_pane.pane_id')")
  # 右 → 下 → 右下 の順に分割して 2x2 (5個目以降は右端を下へ)
  for ((i = 1; i < count; i++)); do
    case $i in
      1) p=$(herdr pane split "${panes[0]}" --direction right --no-focus | jq -r '.result.pane.pane_id') ;;
      2) p=$(herdr pane split "${panes[0]}" --direction down --no-focus | jq -r '.result.pane.pane_id') ;;
      *) p=$(herdr pane split "${panes[1]}" --direction down --no-focus | jq -r '.result.pane.pane_id') ;;
    esac
    panes+=("$p")
  done
  for ((i = 0; i < count; i++)); do
    local name=$label; [[ $count -gt 1 ]] && name="$label-$((i + 1))"
    # プロンプト・モデルは agent の順に対応する(足りない分は無指定)
    start_agent "$name" "${panes[$i]}" "${prompts[$i]-}" "${models[$i]-}"
  done
}

case "${1:--l}" in
  -l) ls "$DIR/presets" | sed 's/\.conf$//'; exit 0 ;;
esac

# プリセット先頭の `# session: <名前>` を読む。無ければ default セッション
session_of() { sed -n 's/^# session: *//p' "$DIR/presets/$1.conf" | head -1; }

if [[ $1 == --session-of ]]; then session_of "${2:?preset required}"; exit 0; fi

conf="$DIR/presets/$1.conf"
[[ -f $conf ]] || { echo "unknown preset: $1 (herdr-up.sh -l で一覧)" >&2; exit 1; }

# herdr のペイン内から実行しても、意図したセッションを向くよう環境変数を整理する
unset HERDR_SESSION HERDR_SOCKET_PATH
session=$(session_of "$1")
[[ -n $session ]] && export HERDR_SESSION=$session

ensure_server
while IFS='|' read -r label count prompt dir model; do
  [[ -z ${label// } || $label == \#* ]] && continue
  make_workspace "$label" "${count:-1}" "${prompt:-}" "${dir:-}" "${model:-}"
done <"$conf"

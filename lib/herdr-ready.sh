# shellcheck shell=bash
# agent 起動直後の最初のプロンプトを確実に届けるための共有関数。tb(taskboard/lib/transport.sh)と
# ほかのスクリプト(agent を起動して最初の指示を送るもの)からも source できる。呼ぶ側は herdr_call(herdr を実行する関数)を先に定義しておくこと。
#
# 背景: agent start の直後、herdr は agent を idle と報告するが Claude Code の UI は未準備のことがある
# (起動画面・信頼確認など)。その間に送ると本文が入力欄に入るだけで、送信(Enter)が失われる。
#
# 環境変数: TB_SPAWN_READY_SEC(既定 60) 準備待ちの上限 / TB_SPAWN_POLL_SEC(既定 2) その間隔
#           TB_PROMPT_VERIFY_SEC(既定 15。0 なら確認しない) 送信後の確認の上限 / TB_VERIFY_POLL_SEC(既定 1) その間隔

# 上限(秒)と間隔(秒)から繰り返し回数を出す。最低 1 回
_hr_tries() { awk -v t="$1" -v p="$2" 'BEGIN { if (p <= 0) p = 1; n = int(t / p) + 1; print (n < 1 ? 1 : n) }'; }

# agent の状態 JSON から "<status> <ready>" を出す(取れなければ空)
_hr_state() {  # $1=名前
  herdr_call agent get "$1" 2>/dev/null \
    | jq -r '.result.agent | "\(.agent_status // "") \(.interactive_ready // false)"' 2>/dev/null || true
}

# interactive_ready が true かつ idle になるまで待つ。0=準備完了 1=時間切れ
herdr_wait_ready() {  # $1=名前
  local poll=${TB_SPAWN_POLL_SEC:-2} n i st
  n=$(_hr_tries "${TB_SPAWN_READY_SEC:-60}" "$poll")
  for ((i = 0; i < n; i++)); do
    st=$(_hr_state "$1")
    [[ $st == "idle true" ]] && return 0
    ((i < n - 1)) && sleep "$poll"
  done
  return 1
}

# 送信後、idle を抜けた(= 受け付けられて動き出した)ことを確かめる。0=確認できた 1=idle のまま
# idle のままなら、本文は再送せず Enter だけを 1 回送って、もう一度見る(再送すると本文が二重になる)
herdr_verify_prompt() {  # $1=名前
  local poll=${TB_VERIFY_POLL_SEC:-1} n i st pass
  [[ ${TB_PROMPT_VERIFY_SEC:-15} == 0 ]] && return 0
  n=$(_hr_tries "${TB_PROMPT_VERIFY_SEC:-15}" "$poll")
  for pass in 1 2; do
    for ((i = 0; i < n; i++)); do
      st=$(_hr_state "$1"); st=${st%% *}
      [[ -n $st && $st != idle ]] && return 0
      ((i < n - 1)) && sleep "$poll"
    done
    ((pass == 1)) && herdr_call agent send-keys "$1" Enter >/dev/null 2>&1
  done
  return 1
}

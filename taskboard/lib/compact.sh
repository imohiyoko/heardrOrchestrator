# shellcheck shell=bash
# 文脈が大きくなった待機中の agent に /compact を送る(tb compact-check)。LLM は使わない(トークン消費なし)
# bin/tb から source される。単体では実行しない。
#
# - 文脈の大きさ: 台帳(herdr の一覧)の session id から ~/.claude/projects/*/<session>.jsonl を探し、"usage" を含む最後の行の
#   input_tokens + cache_creation_input_tokens + cache_read_input_tokens。transcript の中身は出さない
# - 対象: 現在の herdr セッションの agent で、idle/done、除外でない、しきい値超え、前回の送信から min_interval_sec 以上
#   指揮官(conductor_names)と実行した agent 自身は常に対象外
# - 送る前に approvals の agent:compact:<名前> を見る。allow でなければ送らない(一致なし = ask)。ここで承認待ちは積まない
# - 設定は config/compact.conf(人だけが編集。無ければ compact.conf.example)。環境変数 TB_COMPACT_CONF で場所を変えられる
# - 既定は dry-run。--apply のときだけ送り、送った記録を agent_ops(op=compact)に残す

COMPACT_CONF=${TB_COMPACT_CONF:-$TB_ROOT/config/compact.conf}
COMPACT_PROJECTS=${TB_CLAUDE_PROJECTS:-$HOME/.claude/projects}

# 設定値: 環境変数 TB_COMPACT_<キー大文字> > compact.conf > compact.conf.example > 既定。$1=キー $2=既定
compact_cfg() {
  local key=$1 def=$2 up f line k v ev
  up=$(tr '[:lower:]' '[:upper:]' <<<"$key"); ev="TB_COMPACT_$up"
  [[ -z ${!ev:-} ]] || { printf '%s' "${!ev}"; return; }
  f=$COMPACT_CONF; [[ -f $f ]] || f="$COMPACT_CONF.example"
  if [[ -f $f ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(trim "${line%%#*}"); [[ $line == *=* ]] || continue
      k=$(trim "${line%%=*}"); v=$(trim "${line#*=}")
      [[ $k == "$key" ]] && { printf '%s' "$v"; return; }
    done <"$f"
  fi
  printf '%s' "$def"
}

# session id → 直近の文脈トークン数(見つからなければ空)
compact_tokens() {
  local sid=$1 f="" d line
  [[ $sid =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  for d in "$COMPACT_PROJECTS"/*/; do [[ -f ${d}$sid.jsonl ]] && { f=${d}$sid.jsonl; break; }; done
  [[ -n $f ]] || return 0
  line=$(grep -a '"usage"' "$f" 2>/dev/null | tail -n 1) || true
  [[ -n $line ]] || return 0
  jq -r '(.message.usage // .usage // empty) | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' <<<"$line" 2>/dev/null | head -n 1
}

cmd_compact-check() {
  local apply=0 name st sid tok line self="" thr minint last ex enabled act excl conductors
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) apply=0; shift;;
      --apply) apply=1; shift;;
      *) usage "compact-check: 不明な引数 $1";;
    esac
  done
  enabled=$(compact_cfg enabled 0)
  [[ $enabled == 1 ]] || { echo "compact-check: disabled (config/compact.conf の enabled = 1 で有効)"; return 0; }
  thr=$(compact_cfg threshold_tokens 150000); minint=$(compact_cfg min_interval_sec 1800); ex=$(compact_cfg exclude conductor)
  [[ $thr =~ ^[0-9]+$ && $minint =~ ^[0-9]+$ ]] || die "compact.conf の threshold_tokens / min_interval_sec は 0 以上の整数"
  agent_sync || { echo "tb: herdr agent list に失敗しました" >&2; return 1; }
  if [[ -n ${HERDR_PANE_ID:-} ]]; then
    self=$(pane_owner_name "$HERDR_PANE_ID") || die "herdr agent list に失敗したため、実行者を特定できません"
  fi
  conductors=" $(conductor_names | tr '\n' ' ') "; excl=" $ex "
  while IFS=$'\t' read -r name st sid; do
    [[ -n $name ]] || continue
    if [[ $conductors == *" $name "* || $excl == *" $name "* || $name == "$self" ]]; then
      echo "$name - skip(excluded)"; continue
    fi
    case $st in idle|done) ;; *) echo "$name - skip(${st:-unknown})"; continue;; esac
    [[ -n $sid ]] || sid=$(sql "SELECT COALESCE(session_id,'') FROM agents WHERE name=$(q "$name");")
    tok=$(compact_tokens "$sid")
    [[ $tok =~ ^[0-9]+$ ]] || { echo "$name - skip(no transcript usage)"; continue; }
    ((tok > thr)) || { echo "$name $tok skip(below threshold $thr)"; continue; }
    last=$(sql "SELECT COALESCE(CAST(strftime('%s','now') - strftime('%s', MAX(decided_at)) AS INTEGER), -1) FROM agent_ops WHERE op='compact' AND status='done' AND target=$(q "$name");")
    if ((last >= 0 && last < minint)); then echo "$name $tok skip(compacted ${last}s ago, min_interval ${minint}s)"; continue; fi
    approval_of "agent:compact:$name"
    if [[ $APPROVAL_VALUE != allow ]]; then echo "$name $tok skip(approval: agent:compact:$name is ask; add 'agent:compact:* = allow' to approvals.conf)"; continue; fi
    if ((! apply)); then echo "$name $tok would-compact(dry-run)"; continue; fi
    # 送る直前に状態を見直す(herdr_send が idle/done でなければ送らない)。--prompt と同じ経路なので送信後の確認(Enter の補い)も同じ
    act=sent; line=""
    if herdr_send "$name" "/compact" "compact:$name" compact >/dev/null 2>&1; then
      herdr_verify_prompt "$name" || line=" (処理の開始を確認できない。pane を見てください)"
      record_op compact "$name" "$(jq -nc --argjson t "$tok" '{tokens:$t}')" "${self:-human}" 0 "compact sent at $tok tokens$line"
    else
      act="skip(busy or send failed)"
    fi
    echo "$name $tok $act$line"
  done < <(jq -r '.[] | select((.name // "") != "") | [.name, (.agent_status // ""), (.agent_session.value // "")] | @tsv' <<<"$LIVE_AGENTS")
}

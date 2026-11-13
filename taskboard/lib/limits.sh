# shellcheck shell=bash
# 動作 agent 数などの制限(limits / limits show|set|unset|mode|get|check|watcher-enabled)
# bin/tb から source される。単体では実行しない。
#
# - 値の優先: 環境変数 TB_LIMIT_<キー大文字> > config/limits.conf(人だけが編集。再起動不要) > 既定
#   limits.conf が無ければ limits.conf.example、それも無ければ下の既定を使う
# - spawn_max_per_parent / spawn_max_total / analyst_max は、環境変数か limits.conf で設定したときだけ
#   既存の設定(spawn-policy.conf、TB_ANALYST_MAX)より優先する。設定しなければ既存の設定がそのまま効く
# - 「動作中」= 台帳で running(herdr と同期した後。stopped は数えない)。「作業中」= そのうち herdr の状態が working

LIMITS_CONF=${TB_LIMITS:-$TB_ROOT/config/limits.conf}

# ===== 編集しやすい場所: 既定値とモード表 =====
LIMIT_KEYS="max_running_agents max_working_agents incident_max_open incident_roles analyst_max spawn_max_per_parent spawn_max_total watchers human_handoff"
INCIDENT_ROLES_ALL="investigator containment fixer lateral verifier"

# 既定値。spawn_*・analyst_max は、設定が無いとき既存の設定(spawn-policy.conf / TB_ANALYST_MAX)の値が使われる(下の limit_get)
limit_default() {
  case $1 in
    max_running_agents) echo 30;;
    max_working_agents) echo 0;;            # 0 = 無制限
    incident_max_open) echo 2;;
    incident_roles) echo "$INCIDENT_ROLES_ALL";;
    analyst_max) echo 2;;
    spawn_max_per_parent) echo 2;;
    spawn_max_total) echo 4;;
    watchers) echo "watch";;
    human_handoff) echo off;;
  esac
}

# tb limits mode が触るキー。モードの表に無いキーは limits.conf から消す(= 既定に戻る)
LIMIT_MODE_KEYS="max_working_agents incident_max_open incident_roles analyst_max spawn_max_total watchers"
# モード表(<キー>=<値>)。@unset は limits.conf から消す(既定に戻す)。値の書き方は tb limits set と同じ
limit_mode_table() {  # $1=normal|lean|minimal
  case $1 in
    normal) cat <<'T'
max_working_agents=@unset
incident_max_open=@unset
incident_roles=@unset
analyst_max=@unset
spawn_max_total=@unset
watchers=@unset
T
    ;;
    lean) cat <<'T'
max_working_agents=10
incident_max_open=1
incident_roles=investigator fixer verifier
analyst_max=1
spawn_max_total=2
T
    ;;
    minimal) cat <<'T'
max_working_agents=5
incident_max_open=1
incident_roles=investigator
analyst_max=1
spawn_max_total=0
watchers=
T
    ;;
    *) return 1;;
  esac
}
# ===== ここまで =====

LIMITS_LOADED=0; LIMIT_MODE=normal; LIMIT_ERR=""; LIMIT_NORM=""; LIMIT_SRC=default

# 設定ファイルを読む(source しない。既知のキーだけ)。LIMC_<キー>=値、LIMC_SET_<キー>=1
limits_load() {
  ((LIMITS_LOADED)) && return 0
  local f=$LIMITS_CONF line k v
  [[ -f $f ]] || f=$LIMITS_CONF.example
  LIMIT_MODE=normal
  if [[ -f $f ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(trim "${line%%#*}"); [[ $line == *=* ]] || continue
      k=$(trim "${line%%=*}"); v=$(trim "${line#*=}")
      if [[ $k == mode ]]; then LIMIT_MODE=$v; continue; fi
      [[ " $LIMIT_KEYS " == *" $k "* ]] || continue
      limit_norm "$k" "$v" || continue
      printf -v "LIMC_$k" '%s' "$LIMIT_NORM"; printf -v "LIMC_SET_$k" '%s' 1
    done <"$f"
  fi
  LIMITS_LOADED=1
}

# 値の検査と正規化。通れば LIMIT_NORM に入れて 0、通らなければ LIMIT_ERR に理由を入れて 1
limit_norm() {  # $1=キー $2=値
  local k=$1 v=$2 t out=""
  LIMIT_ERR=""; LIMIT_NORM=""
  case $k in
    max_running_agents)
      [[ $v =~ ^[0-9]{1,6}$ ]] && ((10#$v >= 1)) || { LIMIT_ERR="$k は 1 以上の整数: $v"; return 1; }
      LIMIT_NORM=$((10#$v));;
    max_working_agents|incident_max_open|analyst_max|spawn_max_per_parent|spawn_max_total)
      [[ $v =~ ^[0-9]{1,6}$ ]] || { LIMIT_ERR="$k は 0 以上の整数: $v"; return 1; }
      LIMIT_NORM=$((10#$v));;
    incident_roles)
      v=${v//,/ }
      for t in $v; do
        [[ " $INCIDENT_ROLES_ALL " == *" $t "* ]] || { LIMIT_ERR="incident_roles に使えない役: $t(使えるのは $INCIDENT_ROLES_ALL)"; return 1; }
        [[ " $out " == *" $t "* ]] || out+="${out:+ }$t"
      done
      [[ -n $out ]] || { LIMIT_ERR="incident_roles は 1 つ以上の役が要ります"; return 1; }
      LIMIT_NORM=$out;;
    watchers)
      v=${v//,/ }
      for t in $v; do
        [[ $t =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || { LIMIT_ERR="watchers に使えない名前: ${t}"; return 1; }
        [[ " $out " == *" $t "* ]] || out+="${out:+ }$t"
      done
      LIMIT_NORM=$out;;   # 空は「見張りを動かさない」
    human_handoff)
      [[ $v == on || $v == off ]] || { LIMIT_ERR="human_handoff は on|off: $v"; return 1; }
      LIMIT_NORM=$v;;
    *) LIMIT_ERR="不明なキー: $k(使えるキー: $LIMIT_KEYS)"; return 1;;
  esac
}

# 環境変数か limits.conf で設定されている値(無ければ何も出さず 1)。値の出どころは LIMIT_SRC
# (コマンド置換の中では LIMIT_SRC は親に戻らない。出どころが要るときは limit_source を使う)
limit_raw() {  # $1=キー
  limits_load
  local ev sv="LIMC_SET_$1" cv="LIMC_$1"
  ev="TB_LIMIT_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  LIMIT_SRC=default
  if [[ -n ${!ev+x} ]] && limit_norm "$1" "${!ev}"; then LIMIT_SRC=env; printf '%s' "$LIMIT_NORM"; return 0; fi
  if [[ -n ${!sv:-} ]]; then LIMIT_SRC=conf; printf '%s' "${!cv}"; return 0; fi
  return 1
}
limit_is_set() { limit_raw "$1" >/dev/null; }
limit_source() {  # $1=キー → env|conf|default
  local s=default
  limit_raw "$1" >/dev/null && s=$LIMIT_SRC
  printf '%s' "$s"
}

limit_get() {  # $1=キー → 値(stdout)
  local v
  if v=$(limit_raw "$1"); then printf '%s' "$v"; return 0; fi
  case $1 in
    spawn_max_per_parent) load_spawn_policy; printf '%s' "$SP_PER";;
    spawn_max_total) load_spawn_policy; printf '%s' "$SP_TOTAL";;
    analyst_max) printf '%s' "${TB_ANALYST_MAX:-$(limit_default analyst_max)}";;
    *) printf '%s' "$(limit_default "$1")";;
  esac
}

# spawn-policy.conf を読んだ後に呼ぶ。limits で設定されているものだけ上書きする
limits_override_spawn() {
  local v
  if v=$(limit_raw spawn_max_per_parent); then SP_PER=$v; fi
  if v=$(limit_raw spawn_max_total); then SP_TOTAL=$v; fi
  return 0
}

# ---------- 数える ----------
LIM_RUNNING=0; LIM_WORKING=0
limits_count_working() {  # LIVE_AGENTS から。名前のある(台帳に載る)agent だけ
  LIM_WORKING=$(jq -r --arg re "$AGENT_NAME_RE" '[.[] | select(.agent_status=="working" and ((.name // "") | test($re)))] | length' <<<"$LIVE_AGENTS" 2>/dev/null) || LIM_WORKING=0
}
# herdr と台帳を同期して LIM_RUNNING / LIM_WORKING を出す。同期に失敗したら 1(台帳の値で数える)
limits_counts() {
  local rc=0
  agent_sync || rc=1
  LIM_RUNNING=$(sql "SELECT COUNT(*) FROM agents WHERE state='running' AND herdr_session=$(q "$HSESS");")
  limits_count_working
  return $rc
}

# 今ある障害 workspace の数(herdr の workspace ラベル inc-<3 桁>)。取れなければ 1
limits_open_incidents() {
  local out
  out=$(herdr_call workspace list 2>/dev/null) && jq -e '.result.workspaces' <<<"$out" >/dev/null 2>&1 || return 1
  jq -r '[.result.workspaces[] | select((.label // "") | test("^inc-[0-9]{3}$"))] | length' <<<"$out"
}

# あと $1 体起動してよいか。だめなら理由を stderr に出して 4。herdr の同期に失敗したときは(起動側が失敗を報告するので)通す
limits_refuse_running() {
  local add=${1:-1} max
  limits_counts || return 0
  max=$(limit_get max_running_agents)
  if ((LIM_RUNNING + add > max)); then
    echo "tb: 動作中の agent が上限です(動作中 ${LIM_RUNNING}、上限 max_running_agents=$max)。何も作りません。" \
         "止める候補は tb agent-shed、上限を変えるのは人(tb limits set max_running_agents <数>)" >&2
    return 4
  fi
}

# 送信を待たせるか(max_working_agents)。待たせるなら理由を stderr に出して 1。outbox_deliver が呼ぶ
limits_send_gate() {  # $1=宛先
  local max st
  max=$(limit_get max_working_agents); ((max > 0)) || return 0
  load_live || return 0
  limits_count_working
  st=$(jq -r --arg n "$1" '[.[] | select(.name==$n)][0].agent_status // ""' <<<"$LIVE_AGENTS")
  if ((LIM_WORKING >= max)) && [[ $st != working ]]; then
    echo "tb: 作業中の agent が上限です(作業中 ${LIM_WORKING}、max_working_agents=$max)。'$1' への送信は outbox で待たせます(tb flush で再送)" >&2
    return 1
  fi
}

# ---------- 書く(人だけ) ----------
# limits.conf を書き換える。引数は <キー> <値> の組。値が @unset ならその行を消す
limits_edit() {
  local -a ks=() vs=() dn=()
  local f=$LIMITS_CONF tmp line k i hit n
  while (($#)); do ks+=("$1"); vs+=("$2"); dn+=(0); shift 2; done
  n=${#ks[@]}
  [[ ! -L $f ]] || die "limits.conf がシンボリックリンクです: $f"
  mkdir -p "$(dirname "$f")"
  tmp=$(mktemp "$f.XXXXXX")
  {
    if [[ -f $f ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        hit=-1
        if [[ $line != \#* && $line == *=* ]]; then
          k=$(trim "${line%%#*}"); k=$(trim "${k%%=*}")
          for ((i = 0; i < n; i++)); do [[ $k == "${ks[i]}" ]] && hit=$i; done
        fi
        if ((hit >= 0)); then
          if [[ ${dn[hit]} == 0 && ${vs[hit]} != @unset ]]; then printf '%s = %s\n' "${ks[hit]}" "${vs[hit]}"; fi
          dn[hit]=1
        else
          printf '%s\n' "$line"
        fi
      done <"$f"
    else
      printf '%s\n' "# tb limits が書いた制限の設定。編集するのは人だけ(項目は limits.conf.example)。環境変数 TB_LIMIT_<キー大文字> が優先。"
    fi
    for ((i = 0; i < n; i++)); do
      if [[ ${dn[i]} == 0 && ${vs[i]} != @unset ]]; then printf '%s = %s\n' "${ks[i]}" "${vs[i]}"; fi
    done
  } >"$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$f"
  LIMITS_LOADED=0
}

# ---------- 表示 ----------
limits_collect() {  # 数と上限を LS_* に入れる
  local rc=0
  limits_counts || rc=1
  LS_SYNC_FAIL=$rc
  LS_RMAX=$(limit_get max_running_agents); LS_WMAX=$(limit_get max_working_agents)
  LS_IMAX=$(limit_get incident_max_open);  LS_AMAX=$(limit_get analyst_max)
  LS_SMAX=$(limit_get spawn_max_total)
  LS_INC=$(limits_open_incidents) || LS_INC="?"
  LS_AN=$(sql "SELECT COUNT(*) FROM alerts WHERE status='analyzing';")
  LS_SP=$(sql "SELECT COUNT(*) FROM agents WHERE state='running' AND herdr_session=$(q "$HSESS") AND spawned_by IS NOT NULL;")
  limits_load
  LS_MODE=$LIMIT_MODE
  LS_OVER=""
  ((LIM_RUNNING > LS_RMAX)) && LS_OVER+=" running"
  ((LS_WMAX > 0 && LIM_WORKING > LS_WMAX)) && LS_OVER+=" working"
  if [[ $LS_INC != "?" ]] && ((LS_INC > LS_IMAX)); then LS_OVER+=" incidents"; fi
  ((LS_AN > LS_AMAX)) && LS_OVER+=" analysts"
  ((LS_SP > LS_SMAX)) && LS_OVER+=" spawn"
  LS_OVER=${LS_OVER# }
  return 0
}

limits_show() {
  local json=0 line=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --line) line=1; shift;;
      *) usage "limits show: 不明な引数 $1";;
    esac
  done
  limits_collect
  local wmax=$LS_WMAX; [[ $wmax != 0 ]] || wmax=無制限
  if ((json)); then
    local keys="{}" k v
    for k in $LIMIT_KEYS; do
      v=$(limit_get "$k")
      keys=$(jq -c --arg k "$k" --arg v "$v" --arg s "$(limit_source "$k")" '. + {($k): {value:$v, source:$s}}' <<<"$keys")
    done
    jq -nc --argjson r "$LIM_RUNNING" --argjson rm "$LS_RMAX" --argjson w "$LIM_WORKING" --argjson wm "$LS_WMAX" \
      --arg i "$LS_INC" --argjson im "$LS_IMAX" --argjson a "$LS_AN" --argjson am "$LS_AMAX" --argjson s "$LS_SP" --argjson sm "$LS_SMAX" \
      --arg mode "$LS_MODE" --arg over "$LS_OVER" --argjson keys "$keys" \
      '{running:{n:$r,max:$rm}, working:{n:$w,max:$wm}, incidents:{n:(if $i=="?" then null else ($i|tonumber) end),max:$im},
        analysts:{n:$a,max:$am}, spawn:{n:$s,max:$sm}, mode:$mode, over:($over|split(" ")|map(select(.!=""))), limits:$keys}'
    return 0
  fi
  echo "running $LIM_RUNNING/$LS_RMAX  working $LIM_WORKING/$wmax  incidents $LS_INC/$LS_IMAX  analysts $LS_AN/$LS_AMAX  spawn $LS_SP/$LS_SMAX  mode $LS_MODE"
  ((line)) && return 0
  [[ -z $LS_OVER ]] || echo "超過: $LS_OVER(新しく作る経路は拒否されます。止める候補: tb agent-shed)"
  ((LS_SYNC_FAIL == 0)) || echo "注意: herdr agent list に失敗したため、台帳の値で数えました" >&2
  local k
  for k in $LIMIT_KEYS; do printf '  %-22s = %s   (%s)\n' "$k" "$(limit_get "$k")" "$(limit_source "$k")"; done
}

cmd_limits() {
  [[ $# -ge 1 ]] || usage "limits show|set|unset|mode|get|check|watcher-enabled"
  local sub=$1 k v; shift
  case $sub in
    show) limits_show "$@";;
    get)
      [[ $# -eq 1 ]] || usage "limits get <キー>"
      [[ " $LIMIT_KEYS " == *" $1 "* ]] || usage "不明なキー: $1(使えるキー: $LIMIT_KEYS)"
      limit_get "$1"; echo;;
    set)
      [[ $# -eq 2 ]] || usage "limits set <キー> <値>(キー: ${LIMIT_KEYS}。空にする値は '')"
      k=$1; v=$2
      limit_norm "$k" "$v" || usage "limits set: $LIMIT_ERR"
      require_human "tb limits set"
      limits_edit "$k" "$LIMIT_NORM" mode custom
      echo "$k = $LIMIT_NORM";;
    unset)
      [[ $# -eq 1 ]] || usage "limits unset <キー>"
      [[ " $LIMIT_KEYS " == *" $1 "* ]] || usage "不明なキー: $1(使えるキー: $LIMIT_KEYS)"
      require_human "tb limits unset"
      limits_edit "$1" @unset mode custom
      echo "$1 unset(既定に戻る)";;
    mode)
      [[ $# -eq 1 ]] || usage "limits mode normal|lean|minimal"
      limit_mode_table "$1" >/dev/null || usage "limits mode: normal|lean|minimal のどれか: $1"
      require_human "tb limits mode"
      local -a pairs=(); local line tk tv found i
      for tk in $LIMIT_MODE_KEYS; do
        found=@unset
        while IFS= read -r line; do
          [[ $line == "$tk="* ]] || continue
          tv=${line#*=}
          if [[ $tv != @unset ]]; then limit_norm "$tk" "$tv" || die "モード表の値が不正です($tk=$tv): $LIMIT_ERR"; tv=$LIMIT_NORM; fi
          found=$tv
        done < <(limit_mode_table "$1")
        pairs+=("$tk" "$found")
      done
      limits_edit "${pairs[@]}" mode "$1"
      echo "mode $1"
      for ((i = 0; i < ${#pairs[@]}; i += 2)); do v=${pairs[i+1]}; [[ $v != @unset ]] || v="(既定)"; printf '  %-18s = %s\n' "${pairs[i]}" "$v"; done;;
    watcher-enabled)
      [[ $# -eq 1 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || usage "limits watcher-enabled <見張りの名前>"
      [[ " $(limit_get watchers) " == *" $1 "* ]];;
    check)
      [[ $# -eq 1 ]] || usage "limits check incident-open|running"
      case $1 in
        running) limits_refuse_running 1 || return 4; echo "ok";;
        incident-open) limits_check_incident_open;;
        *) usage "limits check: incident-open|running のどれか: $1";;
      esac;;
    *) usage "limits: 不明なサブコマンド $sub(show|set|unset|mode|get|check|watcher-enabled)";;
  esac
}

# 障害 workspace を開く前の検査。0 ok / 4 上限 / 1 確かめられない
limits_check_incident_open() {
  local roles n max imax open
  roles=$(limit_get incident_roles); n=$(wc -w <<<"$roles" | tr -d ' ')
  max=$(limit_get max_running_agents); imax=$(limit_get incident_max_open)
  limits_counts || { echo "tb: herdr agent list に失敗したため、動作中の agent の数を確かめられません" >&2; return 1; }
  if ((LIM_RUNNING + n > max)); then
    echo "tb: 障害 workspace を開けません(動作中 $LIM_RUNNING + 起動する役 $n > 上限 max_running_agents=$max)。何も作りません。" \
         "止める候補は tb agent-shed、起動する役を減らす・上限を変えるのは人(tb limits set incident_roles / max_running_agents)" >&2
    return 4
  fi
  open=$(limits_open_incidents) || { echo "tb: herdr workspace list に失敗したため、開いている障害の数を確かめられません" >&2; return 1; }
  if ((open >= imax)); then
    echo "tb: 障害 workspace を開けません(開いている障害 ${open}、上限 incident_max_open=$imax)。何も作りません。上限を変えるのは人(tb limits set incident_max_open)" >&2
    return 4
  fi
  echo "ok(動作中 $LIM_RUNNING + $n <= ${max}、障害 $open < $imax)"
}

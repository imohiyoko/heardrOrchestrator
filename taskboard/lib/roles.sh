# shellcheck shell=bash
# 役割の配布(role-context / role-broadcast / roles)
# bin/tb から source される。単体では実行しない。

# ---------- roles(agent ごとの役割の配布。SessionStart hook と一括送信) ----------
ROLES_DIR=${TB_ROLES:-$TB_ROOT/../roles}
ROLE_MAX=${TB_ROLE_MAX:-12000}
ROLE_FILE=""; ROLE_HASH=""; ROLE_TEXT=""

sha256() { if command -v sha256sum >/dev/null; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi; }

role_file_for() {  # $1=agent 名 → 役割ファイルのパス(無ければ空)
  local name=$1 k v pat
  [[ $name =~ ^[A-Za-z0-9._-]{1,64}$ && $name != _* && $name != README ]] || return 0
  if [[ -f $ROLES_DIR/$name.md ]]; then printf '%s' "$ROLES_DIR/$name.md"; return 0; fi
  # tb agent-new --role で決めた役割(台帳 agents.role)
  local reg; reg=$(sql "SELECT COALESCE(role,'') FROM agents WHERE name=$(q "$name");" 2>/dev/null) || reg=""
  if [[ $reg =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -f $ROLES_DIR/$reg.md ]]; then printf '%s' "$ROLES_DIR/$reg.md"; return 0; fi
  [[ -f $ROLES_DIR/map.conf ]] || return 0
  while IFS='=' read -r k v || [[ -n $k ]]; do
    pat=$(trim "${k%%#*}"); v=$(trim "${v%%#*}")
    [[ -n $pat && -n $v && $v =~ ^[A-Za-z0-9._-]+$ ]] || continue
    # shellcheck disable=SC2053  # glob として比べる
    if [[ $name == $pat ]]; then
      [[ -f $ROLES_DIR/$v.md ]] && printf '%s' "$ROLES_DIR/$v.md"
      return 0
    fi
  done <"$ROLES_DIR/map.conf"
}

# ROLE_FILE / ROLE_HASH / ROLE_TEXT を埋める。渡すものが無ければ 1
load_role() {  # $1=agent 名
  local body=""
  ROLE_FILE=$(role_file_for "$1"); ROLE_HASH=""; ROLE_TEXT=""
  [[ -f $ROLES_DIR/_common.md ]] && body+="$(cat "$ROLES_DIR/_common.md")"$'\n\n'
  [[ -n $ROLE_FILE ]] && body+="$(cat "$ROLE_FILE")"$'\n'
  blank "$body" && return 1
  ROLE_HASH=$(printf '%s' "$body" | sha256)
  if (( ${#body} > ROLE_MAX )); then body="${body:0:ROLE_MAX}"$'\n\n(長すぎるため途中で切りました。全文は roles/ を読んでください)'; fi
  ROLE_TEXT="# あなたの役割(agent 名: $1。roles/ から自動で渡しています。版 ${ROLE_HASH:0:12})"$'\n\n'"$body"
}

last_briefed_hash() {  # $1=session_id
  sql "SELECT hash FROM role_briefings WHERE session_id=$(q "$1") ORDER BY id DESC LIMIT 1;"
}
record_briefing() {  # session agent file hash source via
  sql "INSERT INTO role_briefings (session_id, agent, role_file, hash, source, via, created_at)
    VALUES ($(q "$1"), $(q "$2"), NULLIF($(q "$3"),''), $(q "$4"), $(q "$5"), $(q "$6"), $(q "$(now)"));" >/dev/null
}

# 人か agent かの判定用: 一覧を取れなければ 1(「名前が無い」= 人の pane と区別する)
pane_owner_name() {  # $1=pane → 名前(無ければ空)
  local out
  out=$(herdr_call agent list 2>/dev/null) || return 1
  jq -r --arg p "$1" '[.result.agents[]? | select(.pane_id==$p)][0].name // empty' <<<"$out" 2>/dev/null || return 1
}

agent_name_by_pane() {  # $1=pane → 名前(無ければ空)
  herdr_call agent list 2>/dev/null | jq -r --arg p "$1" '[.result.agents[]? | select(.pane_id==$p)][0].name // empty' 2>/dev/null
}

# SessionStart hook から呼ぶ(bin/tb-role-hook 経由)。常に終了コード 0。渡すときだけ stdout に hook 用の JSON を出す
cmd_role-context() {
  local src="" sid="" name
  while [[ $# -gt 0 ]]; do
    case $1 in
      --source) [[ $# -ge 2 ]] || return 0; src=$2; shift 2;;
      --session-id) [[ $# -ge 2 ]] || return 0; sid=$2; shift 2;;
      *) return 0;;
    esac
  done
  [[ $src =~ ^(startup|resume|clear|compact)$ && $sid =~ ^[A-Za-z0-9._-]{1,128}$ && -n ${HERDR_PANE_ID:-} ]] || return 0
  name=$(agent_name_by_pane "$HERDR_PANE_ID"); [[ -n $name ]] || return 0
  load_role "$name" || return 0
  # 同じ会話の再開で、同じ版を渡し済みなら渡さない(履歴に残っている)
  if [[ $src == resume && $(last_briefed_hash "$sid") == "$ROLE_HASH" ]]; then return 0; fi
  record_briefing "$sid" "$name" "${ROLE_FILE#"$ROLES_DIR"/}" "$ROLE_HASH" "$src" hook || true
  jq -nc --arg c "$ROLE_TEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
}

# 動いている agent に役割(の置き場所)を送る。同じセッションに同じ版を渡し済みなら飛ばす
# 終了コード: 0 / 10 使用中で送れなかった agent がある / 11 送信失敗がある
cmd_role-broadcast() {
  local only=" $* " list rc=0 name pane sess files msg r
  list=$(herdr_call agent list 2>/dev/null) || die "herdr agent list に失敗しました"
  while IFS=$'\x1f' read -r pane name sess; do
    [[ -n $name ]] || continue
    [[ $# -eq 0 || $only == *" $name "* ]] || continue
    if ! load_role "$name"; then echo "skip $name (役割ファイルなし)"; continue; fi
    if [[ -n $sess && $(last_briefed_hash "$sess") == "$ROLE_HASH" ]]; then echo "skip $name (渡し済み ${ROLE_HASH:0:12})"; continue; fi
    files="$(cd "$ROLES_DIR" && pwd)/_common.md"; [[ -n $ROLE_FILE ]] && files+=" $(cd "$(dirname "$ROLE_FILE")" && pwd)/$(basename "$ROLE_FILE")"
    msg="[role-update / tb] あなた($name)の役割が更新されました(版 ${ROLE_HASH:0:12})。次のファイルを読み、以後はこれに従ってください: $files"
    r=0; herdr_send "$name" "$msg" "role:$name" role 2>/dev/null || r=$?
    if ((r)); then echo "pending $name (宛先が使用中か送信失敗。あとで再実行)"; ((r > rc)) && rc=$r; continue; fi
    [[ -n $sess ]] && record_briefing "$sess" "$name" "${ROLE_FILE#"$ROLES_DIR"/}" "$ROLE_HASH" broadcast broadcast
    echo "sent $name (${ROLE_HASH:0:12})"
  done < <(jq -r '.result.agents[]? | [.pane_id, (.name // ""), (.agent_session.value // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$list")
  return $rc
}

# agent ごとの役割ファイルと、渡した版が最新か
cmd_roles() {
  local json=0 list name pane sess last at state
  [[ ${1:-} == --json ]] && json=1
  list=$(herdr_call agent list 2>/dev/null) || die "herdr agent list に失敗しました"
  while IFS=$'\x1f' read -r pane name sess; do
    [[ -n $name ]] || continue
    last=""; at=""
    if load_role "$name"; then
      if [[ -n $sess ]]; then
        last=$(last_briefed_hash "$sess")
        at=$(sql "SELECT created_at FROM role_briefings WHERE session_id=$(q "$sess") ORDER BY id DESC LIMIT 1;")
      fi
      if [[ -z $last ]]; then state=never; elif [[ $last == "$ROLE_HASH" ]]; then state=current; else state=outdated; fi
    else state=no-role; fi
    if ((json)); then
      jq -nc --arg n "$name" --arg p "$pane" --arg f "${ROLE_FILE#"$ROLES_DIR"/}" --arg h "${ROLE_HASH:0:12}" --arg s "$state" --arg at "$at" \
        '{name:$n,pane:$p,role_file:$f,version:$h,state:$s,briefed_at:(if $at=="" then null else $at end)}'
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${ROLE_FILE#"$ROLES_DIR"/}" "${ROLE_HASH:0:12}" "$state" "${at:--}"
    fi
  done < <(jq -r '.result.agents[]? | [.pane_id, (.name // ""), (.agent_session.value // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$list")
}

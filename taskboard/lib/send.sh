# shellcheck shell=bash
# 指揮官 → worker の送信(send / flush / outbox)
# bin/tb から source される。単体では実行しない。

# ---------- send(指揮官 → worker の下り。agent は herdr agent prompt を直接打たず、これを使う) ----------
# 送信者は HERDR_PANE_ID + herdr agent list から決まる(自己申告にしない)。宛先は config/routes.conf のルールで許可されたものだけ。
# 宛先が使用中なら outbox に積み、tb flush(tb digest からも呼ばれる)で後から届ける。送ろうとしたものはすべて outbox と messages に残る。
ROUTES=${TB_ROUTES:-$TB_ROOT/config/routes.conf}
SEND_KINDS="task info answer"
SEND_MAX=${TB_SEND_MAX:-4000}

# 指揮官として扱う名前: 既定の宛先と projects.conf の値
conductor_names() {
  local k v
  printf '%s\n' "$DEFAULT_TARGET"
  [[ -f $CONF ]] || return 0
  while IFS='=' read -r k v || [[ -n $k ]]; do
    k=${k//[[:space:]]/}; v=${v//[[:space:]]/}
    [[ -z $k || $k == \#* || -z $v ]] && continue
    printf '%s\n' "$v"
  done <"$CONF"
}

# route_allowed <from> <to>: 0 なら許可。理由は ROUTE_REASON に入る
# routes.conf の各行は "<送信者のパターン> -> <宛先のパターン>"(* と ? の glob)。最初に一致した行で決まる。
# 行頭に ! を付けると拒否。routes.conf が無いときは「指揮官 → 誰でも」だけを許可する
ROUTE_REASON=""
route_allowed() {
  local from=$1 to=$2 line neg l r n
  if [[ ! -f $ROUTES ]]; then
    while IFS= read -r n; do
      [[ $from == "$n" ]] && { ROUTE_REASON="default: conductor $n"; return 0; }
    done < <(conductor_names)
    ROUTE_REASON="default: $from は指揮官ではない(worker からの報告は tb comment を使う)"; return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "${line%%#*}"); [[ -n $line ]] || continue
    neg=0; [[ $line == \!* ]] && { neg=1; line=$(trim "${line#!}"); }
    [[ $line == *"->"* ]] || continue
    l=$(trim "${line%%->*}"); r=$(trim "${line#*->}")
    # shellcheck disable=SC2053  # glob として比べる
    if [[ $from == $l && $to == $r ]]; then
      if ((neg)); then ROUTE_REASON="routes.conf: !$l -> $r"; return 1; fi
      ROUTE_REASON="routes.conf: $l -> $r"; return 0
    fi
  done <"$ROUTES"
  ROUTE_REASON="routes.conf: $from -> $to に一致する行がない"; return 1
}

outbox_deliver() {  # $1=outbox.id → 0 送信済み / 10 / 11
  local oid=$1 row st from pane target kind tid text msg
  row=$(sql -json "SELECT * FROM outbox WHERE id=$oid;" | jq -c '.[0] // empty')
  [[ -n $row ]] || die "outbox が見つかりません: O-$oid"
  st=$(jq -r .status <<<"$row")
  [[ $st == queued ]] || { echo "O-$oid は $st です"; return 0; }
  from=$(jq -r .from_name <<<"$row"); pane=$(jq -r .from_pane <<<"$row"); target=$(jq -r .target <<<"$row")
  kind=$(jq -r .kind <<<"$row"); tid=$(jq -r '.task_id // "-"' <<<"$row"); text=$(jq -r .text <<<"$row")
  msg="[from: $from / $pane / $tid / $kind] $(oneline "$text" "$SEND_MAX")"
  herdr_send "$target" "$msg" "O-$oid" send || return $?
  sql "UPDATE outbox SET status='sent', sent_at=$(q "$(now)") WHERE id=$oid;"
}

# 終了コード: 0 送信済み / 10 宛先使用中で outbox に積んだ / 11 送信失敗で outbox に積んだ / 4 ルールで拒否(記録のみ)
#             20 人の承認待ち(approvals.conf が ask。人が tb approve O-<n>) / 3 送信者を特定できず未保存
cmd_send() {
  [[ $# -ge 1 ]] || usage "send <宛先 agent 名> --text T [--task T-..] [--kind task|info|answer] [--json]"
  local target=$1 text="" tid="" kind=task json=0; shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --text) need_arg "$@"; text=$2; shift 2;;
      --task) need_arg "$@"; tid=$2; shift 2;;
      --kind) need_arg "$@"; kind=$2; shift 2;;
      --json) json=1; shift;;
      --from|--from-*|--name|--pane|--session) usage "send: 送信者は herdr から自動で決まります。$1 は指定できません";;
      *) usage "send: 不明な引数 $1";;
    esac
  done
  [[ $target =~ ^[A-Za-z0-9._-]{1,64}$ ]] || usage "send: 宛先は agent 名(英数字と . _ -): $target"
  [[ " $SEND_KINDS " == *" $kind "* ]] || usage "send: --kind は $SEND_KINDS のどれか"
  blank "$text" && usage "send: --text が必要です"
  [[ -z $tid ]] || { valid_id "$tid"; require_task "$tid" >/dev/null; }
  resolve_label || return 3
  [[ $target != "$LABEL_NAME" ]] || usage "send: 自分自身には送れません"
  local names
  names=$(herdr_call agent list 2>/dev/null | jq -r '.result.agents[]?.name // empty' 2>/dev/null) || names=""
  grep -qxF -- "$target" <<<"$names" || die "send: 宛先の agent が herdr にいません: $target(保存しません)"
  local status=queued reason="" rc=0 oid
  if ! route_allowed "$LABEL_NAME" "$target"; then status=denied; reason=$ROUTE_REASON
  else
    reason=$ROUTE_REASON
    approval_of "send:$kind:$target"
    [[ $APPROVAL_VALUE == allow ]] || status=pending
    reason+=" / approvals: $APPROVAL_RULE"
  fi
  oid=$(sql "INSERT INTO outbox (from_name, from_pane, from_session, target, kind, task_id, text, status, reason, created_at)
    VALUES ($(q "$LABEL_NAME"), $(q "$LABEL_PANE"), $(q "$LABEL_SESSION"), $(q "$target"), $(q "$kind"), NULLIF($(q "$tid"),''),
            $(q "$text"), $(q "$status"), $(q "$reason"), $(q "$(now)"));
    SELECT last_insert_rowid();")
  if [[ $status == denied ]]; then
    echo "tb: 送信を拒否しました($reason): O-$oid" >&2
    rc=4
  elif [[ $status == pending ]]; then
    echo "tb: 人の承認待ちです(approvals.conf: $APPROVAL_RULE)。人が tb approve O-$oid で届けます" >&2
    rc=20
  else
    outbox_deliver "$oid" >/dev/null || rc=$?
  fi
  if ((json)); then sql -json "SELECT * FROM outbox WHERE id=$oid;" | jq -c '.[0] | .id = "O-\(.id)"'
  else
    case $rc in 0) echo "O-$oid sent to $target";; 4) echo "O-$oid denied";; 20) echo "O-$oid pending-approval";; *) echo "O-$oid queued";; esac
  fi
  return $rc
}

# 積まれた送信を届ける。宛先ごとに古い順で、使用中の宛先は次回に回す
cmd_flush() {
  [[ $# -eq 0 ]] || usage "flush(引数なし)"
  local oid target rc=0 r busy=" "
  while IFS=$'\t' read -r oid target; do
    [[ -n $oid ]] || continue
    [[ $busy == *" $target "* ]] && continue   # 同じ宛先の後続は順序を保つため送らない
    r=0; outbox_deliver "$oid" || r=$?
    if ((r)); then busy+="$target "; ((r > rc)) && rc=$r; fi
  done < <(sql -separator $'\t' "SELECT id, target FROM outbox WHERE status='queued' ORDER BY id;")
  return $rc
}

cmd_outbox() {
  local st="" json=0 where="1=1"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --status) need_arg "$@"; st=$2; shift 2;;
      --json) json=1; shift;;
      *) usage "outbox: 不明な引数 $1";;
    esac
  done
  if [[ -n $st ]]; then [[ $st =~ ^(pending|queued|sent|denied)$ ]] || usage "outbox: --status は pending|queued|sent|denied"; where="status=$(q "$st")"; fi
  if ((json)); then sql -json "SELECT * FROM outbox WHERE $where ORDER BY id DESC LIMIT 100;" | jq -c '(. // [])[] | .id = "O-\(.id)"'
  else sql -nullvalue - -separator $'\t' "SELECT 'O-'||id, status, from_name, target, kind, COALESCE(task_id,'-'), created_at,
         substr(replace(replace(text, char(10), ' '), char(9), ' '),1,80) FROM outbox WHERE $where ORDER BY id DESC LIMIT 100;"
  fi
}

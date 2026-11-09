# shellcheck shell=bash
# hook からの活動記録(touch / activity)
# bin/tb から source される。単体では実行しない。

# ---------- touch / activity(hook から呼ばれる。agent を止めないことが最優先) ----------
TOUCH_LOG=${TB_TOUCH_LOG:-$(dirname "$DB")/touch-errors.log}
ID_RE='^[A-Za-z0-9._:-]{1,128}$'

# act_select N: working 推定と、N 分以上の滞留(stuck)を付けた SELECT(WHERE は呼び出し側)
act_select() {
  [[ $1 =~ ^[0-9]+$ ]] || usage "分は数字: $1"
  local w="last_prompt_at IS NOT NULL AND (last_stop_at IS NULL OR last_prompt_at > last_stop_at)"
  echo "SELECT session_id, pane_id, tab_id, workspace_id, cwd, last_prompt_id, last_prompt_at, last_stop_at, updated_at,
    CASE WHEN $w THEN 1 ELSE 0 END AS working,
    CASE WHEN $w AND (julianday('now') - julianday(last_prompt_at)) * 1440 >= $1 THEN 1 ELSE 0 END AS stuck,
    CASE WHEN last_prompt_at IS NULL THEN NULL
         ELSE CAST((julianday('now') - julianday(last_prompt_at)) * 1440 AS INTEGER) END AS since_prompt_min
    FROM agent_activity"
}

# 失敗時は固定の理由コードだけを stdout に出して return 1。入力値・DB のエラー文は一切出さない
touch_impl() {
  local ev="" sid="" pane="" tab="" ws="" cwd="" pid=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || { echo invalid-args; return 1; }
    case $1 in
      --event) ev=$2;; --session-id) sid=$2;; --pane-id) pane=$2;; --tab-id) tab=$2;;
      --workspace-id) ws=$2;; --cwd) cwd=$2;; --prompt-id) pid=$2;;
      *) echo invalid-args; return 1;;
    esac
    shift 2
  done
  [[ $ev == UserPromptSubmit || $ev == Stop ]] || { echo invalid-event; return 1; }
  [[ -n $sid ]] || { echo missing-session-id; return 1; }
  [[ $sid =~ $ID_RE ]] || { echo invalid-session-id; return 1; }
  local v
  for v in "$pane" "$tab" "$ws" "$pid"; do
    [[ -z $v || $v =~ $ID_RE ]] || { echo invalid-field; return 1; }
  done
  { [[ ${#cwd} -le 1024 ]] && [[ $cwd != *$'\n'* ]]; } || { echo invalid-cwd; return 1; }

  local ts="strftime('%Y-%m-%dT%H:%M:%fZ','now')" pa="NULL" sa="NULL" err
  if [[ $ev == UserPromptSubmit ]]; then pa=$ts; else sa=$ts; fi
  local SQL_TIMEOUT=1000   # ロックされていても 1 秒で諦める
  err=$({ init_db && sql "INSERT INTO agent_activity
      (session_id, pane_id, tab_id, workspace_id, cwd, last_prompt_id, last_prompt_at, last_stop_at, updated_at)
    VALUES ($(q "$sid"), NULLIF($(q "$pane"),''), NULLIF($(q "$tab"),''), NULLIF($(q "$ws"),''), NULLIF($(q "$cwd"),''),
            NULLIF($(q "$pid"),''), $pa, $sa, $ts)
    ON CONFLICT(session_id) DO UPDATE SET
      pane_id=COALESCE(excluded.pane_id, pane_id), tab_id=COALESCE(excluded.tab_id, tab_id),
      workspace_id=COALESCE(excluded.workspace_id, workspace_id), cwd=COALESCE(excluded.cwd, cwd),
      last_prompt_id=COALESCE(excluded.last_prompt_id, last_prompt_id),
      last_prompt_at=COALESCE(excluded.last_prompt_at, last_prompt_at),
      last_stop_at=COALESCE(excluded.last_stop_at, last_stop_at),
      updated_at=excluded.updated_at;"; } 2>&1) && return 0
  if grep -qiE 'locked|busy' <<<"$err"; then echo db-locked
  elif grep -qiE 'readonly|read-only|unable to open' <<<"$err"; then echo db-readonly
  else echo db-error; fi
  return 1
}

# 常に終了コード 0・標準出力/標準エラーなし。失敗は touch-errors.log に 1 行(時刻・event・理由コードのみ)
cmd_touch() {
  {
    local reason prev="" a ev="-"
    for a in "$@"; do
      [[ $prev == --event && ( $a == UserPromptSubmit || $a == Stop ) ]] && ev=$a
      prev=$a
    done
    if ! reason=$(touch_impl "$@" 2>/dev/null); then
      mkdir -p "$(dirname "$TOUCH_LOG")" 2>/dev/null || true
      printf '%s event=%s reason=%s\n' "$(now)" "$ev" "${reason:-unknown}" >>"$TOUCH_LOG" 2>/dev/null || true
    fi
  } >/dev/null 2>&1
  return 0
}

cmd_activity() {
  local json=0 stuck=10
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --stuck-min) need_arg "$@"; stuck=$2; shift 2;;
      *) usage "activity: 不明な引数 $1";;
    esac
  done
  local s; s=$(act_select "$stuck")
  if ((json)); then
    sql -json "$s ORDER BY updated_at DESC;" | jq -c '(. // [])[]'
  else
    sql -nullvalue - -separator $'\t' "SELECT session_id, COALESCE(pane_id,'-'), working, stuck, last_prompt_at, last_stop_at, COALESCE(cwd,'-')
      FROM ($s) ORDER BY updated_at DESC;"
  fi
}

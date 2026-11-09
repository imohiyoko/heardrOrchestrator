# shellcheck shell=bash
# 共通の小道具: エラー終了、入力の検査、タスク行の取得、project ごとの指示役
# bin/tb から source される。単体では実行しない。

DEFAULT_TARGET=conductor
STATUSES="todo in_progress review done blocked"

die()   { echo "tb: $*" >&2; exit 1; }
usage() { echo "tb: $*" >&2; echo "(tb help で使い方)" >&2; exit 2; }

need_tools() {
  command -v sqlite3 >/dev/null || die "sqlite3 が必要です"
  command -v jq >/dev/null || die "jq が必要です"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

valid_id()      { [[ $1 =~ ^T-[A-Za-z0-9_]+-[0-9]{3,}$ ]] || usage "タスク ID は T-<project>-NNN 形式: $1"; }
valid_project() { [[ $1 =~ ^[A-Za-z0-9_]+$ ]] || usage "project は英数字と _ のみ: $1"; }
valid_status()  { [[ " $STATUSES " == *" $1 "* ]] || usage "status は $STATUSES のどれか: $1"; }
need_arg()      { [[ $# -ge 2 ]] || usage "$1 に値が必要です"; }
blank()         { [[ -z "${1//[[:space:]]/}" ]]; }

task_row() {  # $1=id → JSON 1 行(なければ空)
  sql -json "SELECT * FROM tasks WHERE id=$(q "$1");" | jq -c '.[0] // empty'
}
require_task() { local r; r=$(task_row "$1"); [[ -n $r ]] || die "タスクが見つかりません: $1"; printf '%s' "$r"; }

target_for() {  # $1=project → 指示役の名前
  local t=$DEFAULT_TARGET k v
  if [[ -f $CONF ]]; then
    while IFS='=' read -r k v || [[ -n $k ]]; do
      k=${k//[[:space:]]/}; v=${v//[[:space:]]/}
      [[ -z $k || $k == \#* ]] && continue
      [[ $k == "$1" && -n $v ]] && t=$v
    done <"$CONF"
  fi
  printf '%s' "$t"
}
